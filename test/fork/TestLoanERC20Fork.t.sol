// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// forge-lint: disable-next-line(unaliased-plain-import)
import "./ForkTestBase.sol";
import {JBFees} from "@bananapus/core-v6/src/libraries/JBFees.sol";
import {MockPriceFeed} from "@bananapus/core-v6/test/mock/MockPriceFeed.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/// @notice Fork tests for REVLoans with an ERC-20 (USDC) loan source on a mainnet fork.
///
/// Covers: borrow in USDC (6 decimals), fee distribution in 6-decimal amounts, repay in USDC with collateral return,
/// and dust/rounding checks for 6-decimal token math.
///
/// Run with: FOUNDRY_PROFILE=fork forge test --match-contract TestLoanERC20Fork -vvv
contract TestLoanERC20Fork is ForkTestBase {
    // Mainnet USDC.
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint8 constant USDC_DECIMALS = 6;

    uint256 revnetId;

    // ───────────────────────── Setup
    // ─────────────────────────

    function setUp() public override {
        super.setUp();

        // Set up a price feed: 1 USDC = 0.0005 ETH (i.e. 1 ETH = 2000 USDC).
        // The feed returns the price of 1 unit of pricingCurrency in terms of unitCurrency.
        // pricingCurrency = USDC, unitCurrency = NATIVE_TOKEN -> price per USDC unit in ETH = 0.0005e18 = 5e14.
        MockPriceFeed priceFeed = new MockPriceFeed(5e14, 18);
        vm.prank(multisig());
        jbPrices().addPriceFeedFor(0, uint32(uint160(USDC)), uint32(uint160(JBConstants.NATIVE_TOKEN)), priceFeed);

        // Deploy fee project with both native and USDC terminals.
        _deployFeeProjectWithUsdc(5000);

        // Deploy the revnet with both native and USDC accounting contexts.
        revnetId = _deployRevnetWithUsdc(5000);

        // Set up pool at 1:1 (mint path wins for native payments).
        _setupPool(revnetId, 10_000 ether);

        // Pay with native token so there is general surplus for price feed conversion.
        _payRevnet(revnetId, PAYER, 10 ether);

        // Pay with USDC to build USDC-denominated surplus.
        _payRevnetUsdc(revnetId, PAYER, 10_000e6);
        _payRevnetUsdc(revnetId, BORROWER, 5000e6);
    }

    // ───────────────────────── USDC Config Helpers
    // ─────────────────────────

    /// @notice Build a config with both native and USDC accounting contexts.
    function _buildUsdcConfig(uint16 cashOutTaxRate)
        internal
        view
        returns (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc)
    {
        JBAccountingContext[] memory acc = new JBAccountingContext[](2);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        acc[1] = JBAccountingContext({token: USDC, decimals: USDC_DECIMALS, currency: uint32(uint160(USDC))});

        tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});

        REVStageConfig[] memory stages = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;
        stages[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: INITIAL_ISSUANCE,
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: cashOutTaxRate,
            extraMetadata: 0
        });

        cfg = REVConfig({
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription("ERC20 Fork Test", "ERC20F", "ipfs://erc20fork", "ERC20F_SALT"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });

        sdc = REVSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0),
            salt: keccak256(abi.encodePacked("ERC20_FORK_TEST"))
        });
    }

    /// @notice Deploy the fee project with both native and USDC terminals.
    function _deployFeeProjectWithUsdc(uint16 cashOutTaxRate) internal {
        (REVConfig memory feeCfg, JBTerminalConfig[] memory feeTc, REVSuckerDeploymentConfig memory feeSdc) =
            _buildUsdcConfig(cashOutTaxRate);
        // forge-lint: disable-next-line(named-struct-fields)
        feeCfg.description = REVDescription("Fee", "FEE", "ipfs://fee", "FEE_USDC_SALT");

        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeCfg,
            terminalConfigurations: feeTc,
            suckerDeploymentConfiguration: feeSdc,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    /// @notice Deploy a revnet with both native and USDC terminals.
    function _deployRevnetWithUsdc(uint16 cashOutTaxRate) internal returns (uint256 id) {
        (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc) =
            _buildUsdcConfig(cashOutTaxRate);

        (id,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: cfg,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: sdc,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    // ───────────────────────── USDC Payment Helper
    // ─────────────────────────

    /// @notice Pay the revnet with USDC.
    function _payRevnetUsdc(uint256 id, address payer, uint256 amount) internal returns (uint256 tokensReceived) {
        deal(USDC, payer, amount);
        vm.prank(payer);
        IERC20(USDC).approve(address(jbMultiTerminal()), amount);

        vm.prank(payer);
        tokensReceived = jbMultiTerminal()
            .pay({
                projectId: id,
                token: USDC,
                amount: amount,
                beneficiary: payer,
                minReturnedTokens: 0,
                memo: "",
                metadata: ""
            });
    }

    // ───────────────────────── USDC Loan Helpers
    // ─────────────────────────

    /// @notice Build a USDC loan source.
    function _usdcLoanSource() internal view returns (REVLoanSource memory) {
        return REVLoanSource({token: USDC, terminal: jbMultiTerminal()});
    }

    /// @notice Create a loan using USDC as the source token.
    function _createUsdcLoan(
        uint256 id,
        address borrower,
        uint256 collateral,
        uint256 prepaidFeePercent
    )
        internal
        returns (uint256 loanId, REVLoan memory loan)
    {
        REVLoanSource memory source = _usdcLoanSource();
        uint256 borrowable = LOANS_CONTRACT.borrowableAmountFrom(id, collateral, USDC_DECIMALS, uint32(uint160(USDC)));
        require(borrowable > 0, "no borrowable amount in USDC");

        _grantBurnPermission(borrower, id);

        vm.prank(borrower);
        (loanId, loan) = LOANS_CONTRACT.borrowFrom({
            revnetId: id,
            source: source,
            minBorrowAmount: 0,
            collateralCount: collateral,
            beneficiary: payable(borrower),
            prepaidFeePercent: prepaidFeePercent
        });
    }

    // ───────────────────────── Tests
    // ─────────────────────────

    /// @notice Basic borrow from USDC source: verify USDC disbursed in 6 decimals, loan state correct.
    function test_fork_borrow_usdc_basic() public {
        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);

        uint256 borrowable =
            LOANS_CONTRACT.borrowableAmountFrom(revnetId, borrowerTokens, USDC_DECIMALS, uint32(uint160(USDC)));
        assertGt(borrowable, 0, "should have borrowable amount in USDC");

        uint256 totalCollateralBefore = LOANS_CONTRACT.totalCollateralOf(revnetId);
        uint256 totalBorrowedBefore = LOANS_CONTRACT.totalBorrowedFrom(revnetId, jbMultiTerminal(), USDC);

        uint256 borrowerUsdcBefore = IERC20(USDC).balanceOf(BORROWER);

        // Create the loan.
        (uint256 loanId, REVLoan memory loan) =
            _createUsdcLoan(revnetId, BORROWER, borrowerTokens, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());

        // Verify loan state.
        assertEq(loan.collateral, borrowerTokens, "loan collateral should match");
        assertEq(loan.createdAt, block.timestamp, "loan createdAt should be now");

        // Loan amount should be in 6-decimal USDC units.
        assertGt(loan.amount, 0, "loan amount should be non-zero");
        // Sanity: a 5000 USDC payment should yield a borrowable amount in the hundreds/thousands USDC range.
        assertLt(loan.amount, 20_000e6, "loan amount should be reasonable for USDC");

        // Borrower should have received USDC (net of fees).
        uint256 borrowerUsdcReceived = IERC20(USDC).balanceOf(BORROWER) - borrowerUsdcBefore;
        assertGt(borrowerUsdcReceived, 0, "borrower should receive USDC");

        // Borrower's original tokens are burned as collateral, but the source fee payment back to the revnet mints
        // some tokens to the borrower.
        uint256 feeTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);
        assertGt(feeTokens, 0, "borrower should have tokens from source fee payment");
        assertLt(feeTokens, borrowerTokens, "fee tokens should be less than original collateral");

        // Tracking updated.
        assertEq(
            LOANS_CONTRACT.totalCollateralOf(revnetId),
            totalCollateralBefore + borrowerTokens,
            "totalCollateralOf should increase"
        );
        assertGt(
            LOANS_CONTRACT.totalBorrowedFrom(revnetId, jbMultiTerminal(), USDC),
            totalBorrowedBefore,
            "totalBorrowedFrom should increase"
        );

        // Loan NFT owned by borrower.
        assertEq(_loanOwnerOf(loanId), BORROWER, "loan NFT should be owned by borrower");
    }

    /// @notice Verify fee distribution in 6-decimal USDC: source fee (2.5%), REV fee (1%), allowance fee (2.5%).
    function test_fork_borrow_usdc_feeDistribution() public {
        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);
        uint256 prepaidFeePercent = LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT(); // 25 = 2.5%

        uint256 borrowable =
            LOANS_CONTRACT.borrowableAmountFrom(revnetId, borrowerTokens, USDC_DECIMALS, uint32(uint160(USDC)));

        // Record balances before.
        uint256 borrowerUsdcBefore = IERC20(USDC).balanceOf(BORROWER);
        _grantBurnPermission(BORROWER, revnetId);

        REVLoanSource memory source = _usdcLoanSource();
        vm.prank(BORROWER);
        LOANS_CONTRACT.borrowFrom({
            revnetId: revnetId,
            source: source,
            minBorrowAmount: 0,
            collateralCount: borrowerTokens,
            beneficiary: payable(BORROWER),
            prepaidFeePercent: prepaidFeePercent
        });

        uint256 borrowerUsdcReceived = IERC20(USDC).balanceOf(BORROWER) - borrowerUsdcBefore;

        // Calculate expected fees (all in 6-decimal USDC).
        // The allowance fee is taken by the terminal's useAllowanceOf (2.5% JB protocol fee).
        uint256 allowanceFee = JBFees.feeAmountFrom({amountBeforeFee: borrowable, feePercent: jbMultiTerminal().FEE()});
        // REV fee (1%).
        uint256 revFee =
            JBFees.feeAmountFrom({amountBeforeFee: borrowable, feePercent: LOANS_CONTRACT.REV_PREPAID_FEE_PERCENT()});
        // Source fee (prepaid).
        uint256 sourceFee = JBFees.feeAmountFrom({amountBeforeFee: borrowable, feePercent: prepaidFeePercent});

        uint256 totalFees = allowanceFee + revFee + sourceFee;

        // Borrower should receive borrowable - totalFees (allow small rounding tolerance for 6-decimal math).
        assertApproxEqAbs(
            borrowerUsdcReceived, borrowable - totalFees, 10, "borrower USDC net should match expected (6 dec)"
        );

        // Loans contract should not hold any USDC.
        assertEq(IERC20(USDC).balanceOf(address(LOANS_CONTRACT)), 0, "loans contract should not hold USDC");
    }

    /// @notice Verify no dust remains from 6-decimal rounding: total inflows >= total outflows.
    function test_fork_borrow_usdc_noDust() public {
        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);

        // Record USDC balance of the terminal before the loan.
        uint256 terminalUsdcBefore = IERC20(USDC).balanceOf(address(jbMultiTerminal()));

        // Create the loan.
        _createUsdcLoan(revnetId, BORROWER, borrowerTokens, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());

        // The loans contract should hold zero USDC (no dust).
        assertEq(IERC20(USDC).balanceOf(address(LOANS_CONTRACT)), 0, "loans contract should hold zero USDC dust");

        // Terminal balance should have decreased (funds loaned out), but not be negative.
        uint256 terminalUsdcAfter = IERC20(USDC).balanceOf(address(jbMultiTerminal()));
        assertLt(terminalUsdcAfter, terminalUsdcBefore, "terminal USDC should decrease after loan");
    }

    /// @notice Full repay in USDC: return all collateral, burn loan NFT.
    function test_fork_repay_usdc_full() public {
        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);

        // Create a loan.
        (uint256 loanId, REVLoan memory loan) =
            _createUsdcLoan(revnetId, BORROWER, borrowerTokens, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());

        // Record fee tokens minted to borrower from source fee payment back to revnet.
        uint256 feeTokensFromLoan = jbTokens().totalBalanceOf(BORROWER, revnetId);

        uint256 totalCollateralBefore = LOANS_CONTRACT.totalCollateralOf(revnetId);
        uint256 totalBorrowedBefore = LOANS_CONTRACT.totalBorrowedFrom(revnetId, jbMultiTerminal(), USDC);

        // Fund borrower with enough USDC to repay (they need more than the loan amount due to potential fees).
        uint256 repayFunding = loan.amount * 2;
        deal(USDC, BORROWER, repayFunding);
        vm.prank(BORROWER);
        IERC20(USDC).approve(address(LOANS_CONTRACT), repayFunding);

        JBSingleAllowance memory allowance;

        vm.prank(BORROWER);
        LOANS_CONTRACT.repayLoan({
            loanId: loanId,
            maxRepayBorrowAmount: repayFunding,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(BORROWER),
            allowance: allowance
        });

        // Collateral re-minted to borrower (plus fee tokens from loan creation).
        assertEq(
            jbTokens().totalBalanceOf(BORROWER, revnetId),
            borrowerTokens + feeTokensFromLoan,
            "collateral should be returned to borrower"
        );

        // Loan NFT burned.
        vm.expectRevert();
        _loanOwnerOf(loanId);

        // Tracking decreased.
        assertEq(
            LOANS_CONTRACT.totalCollateralOf(revnetId),
            totalCollateralBefore - loan.collateral,
            "totalCollateralOf should decrease"
        );
        assertLt(
            LOANS_CONTRACT.totalBorrowedFrom(revnetId, jbMultiTerminal(), USDC),
            totalBorrowedBefore,
            "totalBorrowedFrom should decrease"
        );
    }

    /// @notice Repay within prepaid duration -> no additional source fee. Verify exact USDC cost.
    function test_fork_repay_usdc_withinPrepaidNoFee() public {
        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);

        // Create a loan.
        (uint256 loanId, REVLoan memory loan) =
            _createUsdcLoan(revnetId, BORROWER, borrowerTokens, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());

        // Don't warp -- we're within prepaid duration.

        // Fund borrower with USDC to repay.
        uint256 repayFunding = loan.amount * 2;
        deal(USDC, BORROWER, repayFunding);
        vm.prank(BORROWER);
        IERC20(USDC).approve(address(LOANS_CONTRACT), repayFunding);

        uint256 borrowerUsdcBefore = IERC20(USDC).balanceOf(BORROWER);

        JBSingleAllowance memory allowance;

        vm.prank(BORROWER);
        LOANS_CONTRACT.repayLoan({
            loanId: loanId,
            maxRepayBorrowAmount: repayFunding,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(BORROWER),
            allowance: allowance
        });

        uint256 usdcSpent = borrowerUsdcBefore - IERC20(USDC).balanceOf(BORROWER);

        // Within prepaid period, cost should be exactly the loan amount (no additional source fee).
        assertEq(usdcSpent, loan.amount, "repay within prepaid should cost exactly loan amount in USDC");
    }

    /// @notice After prepaid duration, source fee is charged on USDC repayment.
    function test_fork_repay_usdc_withSourceFee() public {
        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);

        // Create a loan.
        (uint256 loanId, REVLoan memory loan) =
            _createUsdcLoan(revnetId, BORROWER, borrowerTokens, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());

        // Warp well past the prepaid duration to accrue a meaningful source fee.
        vm.warp(block.timestamp + loan.prepaidDuration + 365 days);

        // Fund borrower with USDC to repay.
        uint256 repayFunding = loan.amount * 3;
        deal(USDC, BORROWER, repayFunding);
        vm.prank(BORROWER);
        IERC20(USDC).approve(address(LOANS_CONTRACT), repayFunding);

        uint256 borrowerUsdcBefore = IERC20(USDC).balanceOf(BORROWER);

        JBSingleAllowance memory allowance;

        vm.prank(BORROWER);
        LOANS_CONTRACT.repayLoan({
            loanId: loanId,
            maxRepayBorrowAmount: repayFunding,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(BORROWER),
            allowance: allowance
        });

        uint256 usdcSpent = borrowerUsdcBefore - IERC20(USDC).balanceOf(BORROWER);

        // Total cost should be more than the loan principal (due to source fee).
        assertGt(usdcSpent, loan.amount, "repay cost should exceed loan amount due to source fee");
    }

    /// @notice Fee amounts should match expected values calculated from JBFees in 6-decimal precision.
    function test_fork_borrow_usdc_feeAmountsMatch() public view {
        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);
        uint256 prepaidFeePercent = LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT();

        uint256 borrowable =
            LOANS_CONTRACT.borrowableAmountFrom(revnetId, borrowerTokens, USDC_DECIMALS, uint32(uint160(USDC)));

        // Calculate each fee component using JBFees (same as the contract does internally).
        uint256 expectedAllowanceFee =
            JBFees.feeAmountFrom({amountBeforeFee: borrowable, feePercent: jbMultiTerminal().FEE()});
        uint256 expectedRevFee =
            JBFees.feeAmountFrom({amountBeforeFee: borrowable, feePercent: LOANS_CONTRACT.REV_PREPAID_FEE_PERCENT()});
        uint256 expectedSourceFee = JBFees.feeAmountFrom({amountBeforeFee: borrowable, feePercent: prepaidFeePercent});

        // Each fee should be non-zero for a meaningful USDC borrow amount.
        assertGt(expectedAllowanceFee, 0, "allowance fee should be non-zero");
        assertGt(expectedRevFee, 0, "REV fee should be non-zero");
        assertGt(expectedSourceFee, 0, "source fee should be non-zero");

        // Fees should be proportional: allowance fee == source fee (both at 2.5%), REV fee < both (at 1%).
        assertEq(expectedAllowanceFee, expectedSourceFee, "allowance and source fees should match (both 2.5%)");
        assertLt(expectedRevFee, expectedAllowanceFee, "REV fee (1%) should be less than allowance fee (2.5%)");

        // Total fees should be less than the borrowable amount.
        uint256 totalFees = expectedAllowanceFee + expectedRevFee + expectedSourceFee;
        assertLt(totalFees, borrowable, "total fees should be less than borrowable amount");
    }
}
