// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./ForkTestBase.sol";
import {JBFees} from "@bananapus/core-v6/src/libraries/JBFees.sol";

/// @notice Fork tests for REVLoans.borrowFrom() with real Uniswap V4 buyback hook.
///
/// Covers: basic borrow, fee distribution, and borrow after tier splits.
///
/// Run with: FOUNDRY_PROFILE=fork forge test --match-contract TestLoanBorrowFork -vvv
contract TestLoanBorrowFork is ForkTestBase {
    uint256 revnetId;

    function setUp() public override {
        super.setUp();

        string memory rpcUrl = vm.envOr("RPC_ETHEREUM_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) return;

        // Deploy fee project + revnet with 50% cashOutTaxRate.
        _deployFeeProject(5000);
        revnetId = _deployRevnet(5000);

        // Set up pool at 1:1 (mint path wins).
        _setupPool(revnetId, 10_000 ether);

        // Pay to create surplus. PAYER gets tokens and BORROWER gets tokens.
        _payRevnet(revnetId, PAYER, 10 ether);
        _payRevnet(revnetId, BORROWER, 5 ether);
    }

    /// @notice Basic borrow: collateralize all borrower tokens, verify loan state.
    function test_fork_borrow_basic() public onlyFork {
        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);

        uint256 borrowable = LOANS_CONTRACT.borrowableAmountFrom(
            revnetId, borrowerTokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        assertGt(borrowable, 0, "should have borrowable amount");

        uint256 totalCollateralBefore = LOANS_CONTRACT.totalCollateralOf(revnetId);
        uint256 totalBorrowedBefore =
            LOANS_CONTRACT.totalBorrowedFrom(revnetId, jbMultiTerminal(), JBConstants.NATIVE_TOKEN);

        uint256 borrowerEthBefore = BORROWER.balance;

        // Create the loan.
        (uint256 loanId, REVLoan memory loan) =
            _createLoan(revnetId, BORROWER, borrowerTokens, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());

        // Verify loan state.
        assertEq(loan.collateral, borrowerTokens, "loan collateral should match");
        assertEq(loan.createdAt, block.timestamp, "loan createdAt should be now");

        // Borrower tokens should be burned (collateral deposited).
        assertEq(jbTokens().totalBalanceOf(BORROWER, revnetId), 0, "borrower tokens should be burned");

        // Borrower received ETH (net of fees).
        assertGt(BORROWER.balance, borrowerEthBefore, "borrower should receive ETH");

        // Tracking updated.
        assertEq(
            LOANS_CONTRACT.totalCollateralOf(revnetId),
            totalCollateralBefore + borrowerTokens,
            "totalCollateralOf should increase"
        );
        assertGt(
            LOANS_CONTRACT.totalBorrowedFrom(revnetId, jbMultiTerminal(), JBConstants.NATIVE_TOKEN),
            totalBorrowedBefore,
            "totalBorrowedFrom should increase"
        );

        // Loan NFT owned by borrower.
        assertEq(_loanOwnerOf(loanId), BORROWER, "loan NFT should be owned by borrower");
    }

    /// @notice Verify fee distribution: source fee (2.5%) + REV fee (1%) deducted correctly.
    function test_fork_borrow_feeDistribution() public onlyFork {
        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);
        uint256 prepaidFeePercent = LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT(); // 25 = 2.5%

        uint256 borrowable = LOANS_CONTRACT.borrowableAmountFrom(
            revnetId, borrowerTokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );

        // Record balances before.
        uint256 borrowerEthBefore = BORROWER.balance;
        uint256 revnetTerminalBefore = _terminalBalance(revnetId, JBConstants.NATIVE_TOKEN);

        _grantBurnPermission(BORROWER, revnetId);

        REVLoanSource memory source = _nativeLoanSource();
        vm.prank(BORROWER);
        LOANS_CONTRACT.borrowFrom({
            revnetId: revnetId,
            source: source,
            minBorrowAmount: 0,
            collateralCount: borrowerTokens,
            beneficiary: payable(BORROWER),
            prepaidFeePercent: prepaidFeePercent
        });

        uint256 borrowerReceived = BORROWER.balance - borrowerEthBefore;

        // Calculate expected fees.
        // The allowance fee is taken by the terminal's useAllowanceOf (2.5% JB protocol fee).
        uint256 allowanceFee = JBFees.feeAmountFrom({amountBeforeFee: borrowable, feePercent: jbMultiTerminal().FEE()});
        // REV fee (1%).
        uint256 revFee =
            JBFees.feeAmountFrom({amountBeforeFee: borrowable, feePercent: LOANS_CONTRACT.REV_PREPAID_FEE_PERCENT()});
        // Source fee (prepaid).
        uint256 sourceFee = JBFees.feeAmountFrom({amountBeforeFee: borrowable, feePercent: prepaidFeePercent});

        uint256 totalFees = allowanceFee + revFee + sourceFee;

        // Borrower should receive borrowable - totalFees.
        assertApproxEqAbs(borrowerReceived, borrowable - totalFees, 10, "borrower net should match expected");

        // Loans contract should not hold any ETH.
        assertEq(address(LOANS_CONTRACT).balance, 0, "loans contract should not hold ETH");
    }

    /// @notice Borrow after a payment with 30% tier splits.
    function test_fork_borrow_afterTierSplits() public onlyFork {
        // Deploy revnet with 721 hook.
        (uint256 splitRevnetId, IJB721TiersHook hook) = _deployRevnetWith721(5000);
        _setupPool(splitRevnetId, 10_000 ether);

        // Pay with tier metadata (30% split).
        address metadataTarget = hook.METADATA_ID_TARGET();
        bytes memory metadata = _buildPayMetadataNoQuote(metadataTarget);

        vm.prank(BORROWER);
        uint256 borrowerTokens = jbMultiTerminal().pay{value: 5 ether}({
            projectId: splitRevnetId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 5 ether,
            beneficiary: BORROWER,
            minReturnedTokens: 0,
            memo: "",
            metadata: metadata
        });

        // With 30% split and 1000 tokens/ETH issuance, borrower gets 700 tokens/ETH * 5 = 3500 tokens.
        assertEq(borrowerTokens, 3500e18, "should get 3500 tokens after 30% split");

        // Surplus should reflect actual terminal balance.
        uint256 surplus = _terminalBalance(splitRevnetId, JBConstants.NATIVE_TOKEN);
        assertGt(surplus, 0, "should have surplus");

        // Borrowable amount should be based on actual surplus, not full payment.
        uint256 borrowable = LOANS_CONTRACT.borrowableAmountFrom(
            splitRevnetId, borrowerTokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );

        if (borrowable > 0) {
            (uint256 loanId,) =
                _createLoan(splitRevnetId, BORROWER, borrowerTokens, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());
            assertGt(loanId, 0, "loan should be created");
        }
    }
}
