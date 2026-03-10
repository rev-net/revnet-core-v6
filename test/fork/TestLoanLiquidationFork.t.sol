// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./ForkTestBase.sol";

/// @notice Fork tests for REVLoans.liquidateExpiredLoansFrom() with real Uniswap V4 buyback hook.
///
/// Covers: expired liquidation, non-expired skipping, and gap handling.
///
/// Run with: FOUNDRY_PROFILE=fork forge test --match-contract TestLoanLiquidationFork -vvv
contract TestLoanLiquidationFork is ForkTestBase {
    uint256 revnetId;

    function setUp() public override {
        super.setUp();

        string memory rpcUrl = vm.envOr("RPC_ETHEREUM_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) return;

        // Deploy fee project + revnet.
        _deployFeeProject(5000);
        revnetId = _deployRevnet(5000);
        _setupPool(revnetId, 10_000 ether);

        // Pay to create surplus.
        _payRevnet(revnetId, PAYER, 10 ether);
        _payRevnet(revnetId, BORROWER, 10 ether);
    }

    /// @notice Liquidate an expired loan: NFT burned, collateral permanently lost.
    function test_fork_liquidate_expired() public onlyFork {
        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);
        (uint256 loanId,) = _createLoan(revnetId, BORROWER, borrowerTokens, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());

        uint256 totalCollateralBefore = LOANS_CONTRACT.totalCollateralOf(revnetId);
        uint256 totalBorrowedBefore =
            LOANS_CONTRACT.totalBorrowedFrom(revnetId, jbMultiTerminal(), JBConstants.NATIVE_TOKEN);

        // Warp past 10 years + 1 second.
        vm.warp(block.timestamp + LOANS_CONTRACT.LOAN_LIQUIDATION_DURATION() + 1);

        // The loan number is 1 (first loan for this revnet).
        LOANS_CONTRACT.liquidateExpiredLoansFrom(revnetId, 1, 1);

        // Loan NFT burned.
        vm.expectRevert();
        _loanOwnerOf(loanId);

        // Collateral permanently lost (decreased from tracking).
        assertEq(
            LOANS_CONTRACT.totalCollateralOf(revnetId),
            totalCollateralBefore - borrowerTokens,
            "totalCollateralOf should decrease"
        );

        // Borrowed amount decreased.
        assertLt(
            LOANS_CONTRACT.totalBorrowedFrom(revnetId, jbMultiTerminal(), JBConstants.NATIVE_TOKEN),
            totalBorrowedBefore,
            "totalBorrowedFrom should decrease"
        );

        // No tokens re-minted to borrower.
        assertEq(jbTokens().totalBalanceOf(BORROWER, revnetId), 0, "no tokens should be re-minted");
    }

    /// @notice Non-expired loan is skipped during liquidation.
    function test_fork_liquidate_notExpiredSkipped() public onlyFork {
        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);
        (uint256 loanId,) = _createLoan(revnetId, BORROWER, borrowerTokens, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());

        // Don't warp — loan is fresh.
        LOANS_CONTRACT.liquidateExpiredLoansFrom(revnetId, 1, 1);

        // Loan should still exist.
        assertEq(_loanOwnerOf(loanId), BORROWER, "loan should still exist");
    }

    /// @notice Multiple loans with gaps: create 3, repay #2, warp, liquidate range.
    function test_fork_liquidate_withGaps() public onlyFork {
        // Create 3 loans from different borrowers.
        address borrower2 = makeAddr("borrower2");
        address borrower3 = makeAddr("borrower3");
        vm.deal(borrower2, 100 ether);
        vm.deal(borrower3, 100 ether);

        // Give each borrower tokens.
        _payRevnet(revnetId, borrower2, 3 ether);
        _payRevnet(revnetId, borrower3, 3 ether);

        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);
        uint256 b2Tokens = jbTokens().totalBalanceOf(borrower2, revnetId);
        uint256 b3Tokens = jbTokens().totalBalanceOf(borrower3, revnetId);

        // Create 3 loans.
        (uint256 loanId1,) = _createLoan(revnetId, BORROWER, borrowerTokens, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());
        (uint256 loanId2, REVLoan memory loan2) =
            _createLoan(revnetId, borrower2, b2Tokens, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());
        (uint256 loanId3,) = _createLoan(revnetId, borrower3, b3Tokens, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());

        // Repay loan #2 to create a gap.
        vm.deal(borrower2, 100 ether);
        JBSingleAllowance memory allowance;
        vm.prank(borrower2);
        LOANS_CONTRACT.repayLoan{value: loan2.amount * 2}({
            loanId: loanId2,
            maxRepayBorrowAmount: loan2.amount * 2,
            collateralCountToReturn: loan2.collateral,
            beneficiary: payable(borrower2),
            allowance: allowance
        });

        // Warp past 10 years.
        vm.warp(block.timestamp + LOANS_CONTRACT.LOAN_LIQUIDATION_DURATION() + 1);

        // Liquidate the full range (loans 1-3).
        LOANS_CONTRACT.liquidateExpiredLoansFrom(revnetId, 1, 3);

        // Loans #1 and #3 should be liquidated. #2 was already repaid (skipped).
        vm.expectRevert();
        _loanOwnerOf(loanId1);

        vm.expectRevert();
        _loanOwnerOf(loanId3);

        // Borrower 2 got their collateral back from repayment.
        assertGt(jbTokens().totalBalanceOf(borrower2, revnetId), 0, "borrower2 should have tokens from repayment");
    }
}
