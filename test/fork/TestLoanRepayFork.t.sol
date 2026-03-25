// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "./ForkTestBase.sol";

/// @notice Fork tests for REVLoans.repayLoan() with real Uniswap V4 buyback hook.
///
/// Covers: full repay, partial repay, source fee after prepaid, no-fee within prepaid, expired revert.
///
/// Run with: FOUNDRY_PROFILE=fork forge test --match-contract TestLoanRepayFork -vvv
contract TestLoanRepayFork is ForkTestBase {
    uint256 revnetId;
    uint256 loanId;
    REVLoan loan;
    uint256 borrowerTokens;
    uint256 feeTokensFromLoan; // Tokens minted to borrower from source fee payment back to revnet.

    function setUp() public override {
        super.setUp();

        // Deploy fee project + revnet.
        _deployFeeProject(5000);
        revnetId = _deployRevnet(5000);
        _setupPool(revnetId, 10_000 ether);

        // Pay to create surplus.
        _payRevnet(revnetId, PAYER, 10 ether);
        _payRevnet(revnetId, BORROWER, 5 ether);

        borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);

        // Create a loan with min prepaid fee.
        (loanId, loan) = _createLoan(revnetId, BORROWER, borrowerTokens, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());

        // Record fee tokens minted to borrower from source fee payment back to revnet.
        feeTokensFromLoan = jbTokens().totalBalanceOf(BORROWER, revnetId);
    }

    /// @notice Full repay: return all collateral, burn loan NFT.
    function test_fork_repay_full() public {
        uint256 totalCollateralBefore = LOANS_CONTRACT.totalCollateralOf(revnetId);
        uint256 totalBorrowedBefore =
            LOANS_CONTRACT.totalBorrowedFrom(revnetId, jbMultiTerminal(), JBConstants.NATIVE_TOKEN);

        // Fund borrower to repay (they need more ETH than they got from the loan due to fees).
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
            LOANS_CONTRACT.totalBorrowedFrom(revnetId, jbMultiTerminal(), JBConstants.NATIVE_TOKEN),
            totalBorrowedBefore,
            "totalBorrowedFrom should decrease"
        );
    }

    /// @notice Partial repay: return half the collateral, old loan burned, new loan minted.
    function test_fork_repay_partial() public {
        uint256 halfCollateral = loan.collateral / 2;

        vm.deal(BORROWER, 100 ether);

        JBSingleAllowance memory allowance;

        vm.prank(BORROWER);
        (uint256 newLoanId, REVLoan memory newLoan) = LOANS_CONTRACT.repayLoan{value: loan.amount * 2}({
            loanId: loanId,
            maxRepayBorrowAmount: loan.amount * 2,
            collateralCountToReturn: halfCollateral,
            beneficiary: payable(BORROWER),
            allowance: allowance
        });

        // Some collateral re-minted (plus fee tokens from loan creation).
        uint256 returnedTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);
        assertEq(returnedTokens, halfCollateral + feeTokensFromLoan, "half collateral should be returned");

        // Old loan burned.
        vm.expectRevert();
        _loanOwnerOf(loanId);

        // New loan created with reduced collateral.
        assertGt(newLoanId, 0, "new loan should be created");
        assertEq(newLoan.collateral, loan.collateral - halfCollateral, "new loan collateral should be reduced");
        assertLt(newLoan.amount, loan.amount, "new loan amount should be less");

        // New loan NFT owned by borrower.
        assertEq(_loanOwnerOf(newLoanId), BORROWER, "new loan NFT should be owned by borrower");
    }

    /// @notice After prepaid duration, source fee is charged on repayment.
    function test_fork_repay_withSourceFee() public {
        // Warp well past the prepaid duration to accrue a meaningful source fee.
        vm.warp(block.timestamp + loan.prepaidDuration + 365 days);

        vm.deal(BORROWER, 100 ether);

        // Record ETH spent for repayment.
        uint256 borrowerEthBefore = BORROWER.balance;

        JBSingleAllowance memory allowance;

        vm.prank(BORROWER);
        LOANS_CONTRACT.repayLoan{value: loan.amount * 3}({
            loanId: loanId,
            maxRepayBorrowAmount: loan.amount * 3,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(BORROWER),
            allowance: allowance
        });

        uint256 ethSpent = borrowerEthBefore - BORROWER.balance;

        // Total cost should be more than the loan principal (due to source fee).
        assertGt(ethSpent, loan.amount, "repay cost should exceed loan amount due to source fee");
    }

    /// @notice Repay immediately (within prepaid duration) -> no source fee.
    function test_fork_repay_withinPrepaidNofee() public {
        // Don't warp — we're within prepaid duration.
        vm.deal(BORROWER, 100 ether);

        uint256 borrowerEthBefore = BORROWER.balance;

        JBSingleAllowance memory allowance;

        vm.prank(BORROWER);
        LOANS_CONTRACT.repayLoan{value: loan.amount * 2}({
            loanId: loanId,
            maxRepayBorrowAmount: loan.amount * 2,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(BORROWER),
            allowance: allowance
        });

        uint256 ethSpent = borrowerEthBefore - BORROWER.balance;

        // Within prepaid period, cost should be exactly the loan amount (no additional source fee).
        assertEq(ethSpent, loan.amount, "repay within prepaid should cost exactly loan amount");
    }

    /// @notice Repay after 10 years should revert (loan expired).
    function test_fork_repay_expiredReverts() public {
        // Warp past the 10-year liquidation duration (strict > check, so need +1).
        vm.warp(block.timestamp + LOANS_CONTRACT.LOAN_LIQUIDATION_DURATION() + 1);

        vm.deal(BORROWER, 100 ether);

        JBSingleAllowance memory allowance;

        vm.prank(BORROWER);
        vm.expectRevert();
        LOANS_CONTRACT.repayLoan{value: loan.amount * 3}({
            loanId: loanId,
            maxRepayBorrowAmount: loan.amount * 3,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(BORROWER),
            allowance: allowance
        });
    }
}
