// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// forge-lint: disable-next-line(unaliased-plain-import)
import "./ForkTestBase.sol";
import {REVEmpty721Config} from "../helpers/REVEmpty721Config.sol";

/// @notice Fork tests for loan lifecycle spanning multiple revnet stages (rulesets).
///
/// Verifies that loans created in one stage (high cashOutTaxRate) can be correctly repaid
/// or liquidated after transitioning to a different stage (low cashOutTaxRate). This is
/// critical because the bonding curve parameters change between stages, affecting borrowable
/// amounts, collateral value, and fee calculations.
///
/// Run with: FOUNDRY_PROFILE=fork forge test --match-contract TestLoanCrossRulesetFork -vvv
contract TestLoanCrossRulesetFork is ForkTestBase {
    uint256 revnetId;
    uint256 constant STAGE_DURATION = 30 days;

    /// @notice Build a two-stage config: stage 1 (high tax), stage 2 (low tax).
    function _buildTwoStageConfig(
        uint16 stage1TaxRate,
        uint16 stage2TaxRate
    )
        internal
        view
        returns (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc)
    {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});

        REVStageConfig[] memory stages = new REVStageConfig[](2);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        // Stage 1: high tax — starts immediately.
        stages[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: INITIAL_ISSUANCE,
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: stage1TaxRate,
            extraMetadata: 0
        });

        // Stage 2: low tax — starts after STAGE_DURATION.
        stages[1] = REVStageConfig({
            // forge-lint: disable-next-line(unsafe-typecast)
            startsAtOrAfter: uint40(block.timestamp + STAGE_DURATION),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: INITIAL_ISSUANCE,
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: stage2TaxRate,
            extraMetadata: 0
        });

        cfg = REVConfig({
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription("CrossStage", "XSTG", "ipfs://xstage", "XSTG_SALT"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });

        sdc = REVSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("XSTG"))
        });
    }

    function setUp() public override {
        super.setUp();

        // Deploy fee project with 50% tax.
        _deployFeeProject(5000);

        // Deploy two-stage revnet: 70% tax → 20% tax after 30 days.
        (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc) =
            _buildTwoStageConfig(7000, 2000);

        (revnetId,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: cfg,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: sdc,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        // Set up pool at 1:1 (mint path wins).
        _setupPool(revnetId, 10_000 ether);

        // Create surplus with multiple payers so bonding curve tax has visible effect.
        _payRevnet(revnetId, PAYER, 10 ether);
        _payRevnet(revnetId, BORROWER, 5 ether);

        address otherPayer = makeAddr("otherPayer");
        vm.deal(otherPayer, 10 ether);
        _payRevnet(revnetId, otherPayer, 5 ether);
    }

    /// @notice Borrow in stage 1 (70% tax), repay in stage 2 (20% tax). Repayment should succeed
    /// and return full collateral regardless of the tax rate change.
    function test_fork_crossStage_borrowStage1_repayStage2() public {
        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);
        assertGt(borrowerTokens, 0, "borrower should have tokens");

        // Record borrowable in stage 1.
        uint256 borrowableStage1 = LOANS_CONTRACT.borrowableAmountFrom(
            revnetId, borrowerTokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        assertGt(borrowableStage1, 0, "should have borrowable amount in stage 1");

        // Create loan in stage 1.
        (uint256 loanId, REVLoan memory loan) =
            _createLoan(revnetId, BORROWER, borrowerTokens, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());
        assertGt(loanId, 0, "loan should be created");
        assertEq(loan.collateral, borrowerTokens, "collateral should match");

        // Record fee tokens minted to borrower from source fee payment back to revnet.
        uint256 feeTokensFromLoan = jbTokens().totalBalanceOf(BORROWER, revnetId);

        // Warp past stage 1 into stage 2.
        vm.warp(block.timestamp + STAGE_DURATION + 1);

        // Verify borrowable amount changed (should be higher with lower tax).
        uint256 borrowableStage2 = LOANS_CONTRACT.borrowableAmountFrom(
            revnetId, borrowerTokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        assertGt(borrowableStage2, borrowableStage1, "borrowable should increase with lower tax");

        // Repay the loan in stage 2: return all collateral.
        vm.deal(BORROWER, 100 ether);
        JBSingleAllowance memory allowance;

        vm.prank(BORROWER);
        LOANS_CONTRACT.repayLoan{value: loan.amount * 2}({
            loanId: loanId,
            maxRepayBorrowAmount: loan.amount * 2,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(BORROWER),
            allowance: allowance
        });

        // After repayment, borrower gets collateral back (plus fee tokens from loan creation).
        uint256 borrowerTokensAfter = jbTokens().totalBalanceOf(BORROWER, revnetId);
        assertEq(borrowerTokensAfter, borrowerTokens + feeTokensFromLoan, "borrower should recover full collateral");

        // Loan NFT should be burned.
        vm.expectRevert();
        _loanOwnerOf(loanId);
    }

    /// @notice Borrow in stage 1, attempt to liquidate in stage 2 before expiry. Should skip.
    function test_fork_crossStage_borrowStage1_liquidateStage2_notExpired() public {
        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);

        // Create loan in stage 1.
        (uint256 loanId,) = _createLoan(revnetId, BORROWER, borrowerTokens, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());

        // Warp to stage 2 (but NOT past 10-year expiry).
        vm.warp(block.timestamp + STAGE_DURATION + 1);

        // Attempt liquidation — should skip this loan since it's not expired.
        // Loan number is 1 (first loan for this revnet), count = 1.
        LOANS_CONTRACT.liquidateExpiredLoansFrom(revnetId, 1, 1);

        // Loan should still exist.
        assertEq(_loanOwnerOf(loanId), BORROWER, "loan should not be liquidated");
    }

    /// @notice Borrow in stage 1, liquidate after 10-year expiry (spans far beyond both stages).
    function test_fork_crossStage_borrowStage1_liquidateAfterExpiry() public {
        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);

        // Create loan in stage 1.
        (uint256 loanId,) = _createLoan(revnetId, BORROWER, borrowerTokens, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());

        uint256 totalCollateralBefore = LOANS_CONTRACT.totalCollateralOf(revnetId);

        // Warp past 10-year expiry (well beyond both stages).
        vm.warp(block.timestamp + LOANS_CONTRACT.LOAN_LIQUIDATION_DURATION() + 1);

        // Liquidate starting from loan number 1, count = 1.
        LOANS_CONTRACT.liquidateExpiredLoansFrom(revnetId, 1, 1);

        // Loan NFT should be burned.
        vm.expectRevert();
        _loanOwnerOf(loanId);

        // Collateral is permanently lost (burned during borrow, not returned on liquidation).
        uint256 totalCollateralAfter = LOANS_CONTRACT.totalCollateralOf(revnetId);
        assertEq(totalCollateralAfter, totalCollateralBefore - borrowerTokens, "total collateral should decrease");
    }

    /// @notice Partial repay in stage 1, complete repay in stage 2.
    function test_fork_crossStage_partialRepayStage1_completeRepayStage2() public {
        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);

        // Create loan in stage 1.
        (uint256 loanId, REVLoan memory loan) =
            _createLoan(revnetId, BORROWER, borrowerTokens, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());

        // Record fee tokens minted to borrower from source fee payment back to revnet.
        uint256 feeTokensFromLoan = jbTokens().totalBalanceOf(BORROWER, revnetId);

        // Partial repay in stage 1: return half the collateral.
        uint256 halfCollateral = loan.collateral / 2;

        vm.deal(BORROWER, 100 ether);
        JBSingleAllowance memory allowance;

        vm.prank(BORROWER);
        (uint256 newLoanId,) = LOANS_CONTRACT.repayLoan{value: loan.amount * 2}({
            loanId: loanId,
            maxRepayBorrowAmount: loan.amount * 2,
            collateralCountToReturn: halfCollateral,
            beneficiary: payable(BORROWER),
            allowance: allowance
        });

        // Old loan should be replaced, new loan created for remainder.
        assertGt(newLoanId, 0, "new loan should be created for remainder");

        uint256 borrowerTokensMid = jbTokens().totalBalanceOf(BORROWER, revnetId);
        assertGt(borrowerTokensMid, 0, "borrower should get partial collateral back");

        // Warp to stage 2.
        vm.warp(block.timestamp + STAGE_DURATION + 1);

        // Complete repay in stage 2.
        REVLoan memory remainingLoan = LOANS_CONTRACT.loanOf(newLoanId);

        vm.prank(BORROWER);
        LOANS_CONTRACT.repayLoan{value: remainingLoan.amount * 2}({
            loanId: newLoanId,
            maxRepayBorrowAmount: remainingLoan.amount * 2,
            collateralCountToReturn: remainingLoan.collateral,
            beneficiary: payable(BORROWER),
            allowance: allowance
        });

        // All collateral should be recovered (plus fee tokens from loan creation).
        uint256 borrowerTokensFinal = jbTokens().totalBalanceOf(BORROWER, revnetId);
        assertEq(
            borrowerTokensFinal,
            borrowerTokens + feeTokensFromLoan,
            "should recover full collateral after two repayments"
        );
    }

    /// @notice Reallocate a loan created in stage 1 while in stage 2.
    function test_fork_crossStage_reallocateInStage2() public {
        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);

        // Create loan in stage 1.
        (uint256 loanId, REVLoan memory loan) =
            _createLoan(revnetId, BORROWER, borrowerTokens, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());

        // Warp to stage 2.
        vm.warp(block.timestamp + STAGE_DURATION + 1);

        // Reallocate a small fraction (5%) to a new loan. Using a small fraction ensures the remaining
        // collateral still supports the existing borrow amount (bonding curve non-linearity).
        REVLoanSource memory source = _nativeLoanSource();
        uint256 transferAmount = loan.collateral / 20;

        // Grant burn permission for the new loan.
        _grantBurnPermission(BORROWER, revnetId);

        // Cache before prank to avoid consuming the prank with a static call.
        uint256 minFeePercent = LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT();

        vm.prank(BORROWER);
        (uint256 reallocatedLoanId, uint256 newLoanId, REVLoan memory reallocatedLoan,) = LOANS_CONTRACT.reallocateCollateralFromLoan({
            loanId: loanId,
            collateralCountToTransfer: transferAmount,
            source: source,
            minBorrowAmount: 0,
            collateralCountToAdd: 0,
            beneficiary: payable(BORROWER),
            prepaidFeePercent: minFeePercent
        });

        // Original loan burned, reallocated loan created.
        vm.expectRevert();
        _loanOwnerOf(loanId);

        // Both new loans should exist.
        assertEq(_loanOwnerOf(reallocatedLoanId), BORROWER, "reallocated loan should exist");
        assertEq(_loanOwnerOf(newLoanId), BORROWER, "new loan should exist");

        // Reallocated loan should have reduced collateral.
        assertEq(
            reallocatedLoan.collateral, loan.collateral - transferAmount, "reallocated collateral should be reduced"
        );
    }
}
