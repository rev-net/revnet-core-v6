// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// forge-lint: disable-next-line(unaliased-plain-import)
import "./ForkTestBase.sol";

/// @notice Fork tests for transferring loan NFTs and repaying from the new owner.
///
/// Covers: transfer + repay by new owner, original owner rejection after transfer, transfer + partial repay.
///
/// Run with: FOUNDRY_PROFILE=fork forge test --match-contract TestLoanTransferFork -vvv
contract TestLoanTransferFork is ForkTestBase {
    uint256 revnetId;
    uint256 loanId;
    REVLoan loan;
    uint256 borrowerTokens;

    address newOwner = makeAddr("newOwner");

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
    }

    /// @notice Transfer loan NFT to a new owner, who then fully repays the loan.
    function test_fork_transferLoan_newOwnerCanRepay() public {
        // Transfer the loan NFT from BORROWER to newOwner.
        vm.prank(BORROWER);
        REVLoans(payable(address(LOANS_CONTRACT))).safeTransferFrom(BORROWER, newOwner, loanId);

        // Verify newOwner is the loan NFT owner.
        assertEq(_loanOwnerOf(loanId), newOwner, "newOwner should own the loan NFT after transfer");

        // Fund newOwner with ETH for repayment.
        vm.deal(newOwner, 100 ether);

        JBSingleAllowance memory allowance;

        // newOwner repays the loan in full.
        vm.prank(newOwner);
        LOANS_CONTRACT.repayLoan{value: loan.amount * 2}({
            loanId: loanId,
            maxRepayBorrowAmount: loan.amount * 2,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(newOwner),
            allowance: allowance
        });

        // Loan NFT should be burned after full repay.
        vm.expectRevert();
        _loanOwnerOf(loanId);

        // Collateral tokens should be minted to newOwner (the beneficiary).
        uint256 newOwnerTokens = jbTokens().totalBalanceOf(newOwner, revnetId);
        assertEq(newOwnerTokens, borrowerTokens, "collateral should be returned to newOwner");
    }

    /// @notice After transferring the loan NFT, the original borrower cannot repay.
    function test_fork_transferLoan_originalBorrowerCannotRepay() public {
        // Transfer the loan NFT from BORROWER to newOwner.
        vm.prank(BORROWER);
        REVLoans(payable(address(LOANS_CONTRACT))).safeTransferFrom(BORROWER, newOwner, loanId);

        // Fund BORROWER with ETH for the attempted repayment.
        vm.deal(BORROWER, 100 ether);

        JBSingleAllowance memory allowance;

        // Original borrower tries to repay — should revert with REVLoans_Unauthorized.
        vm.prank(BORROWER);
        vm.expectRevert(abi.encodeWithSelector(REVLoans.REVLoans_Unauthorized.selector, BORROWER, newOwner));
        LOANS_CONTRACT.repayLoan{value: loan.amount * 2}({
            loanId: loanId,
            maxRepayBorrowAmount: loan.amount * 2,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(BORROWER),
            allowance: allowance
        });
    }

    /// @notice Transfer loan NFT, new owner does a partial repay — old loan burned, new loan minted to new owner.
    function test_fork_transferLoan_newOwnerPartialRepay() public {
        // Transfer the loan NFT from BORROWER to newOwner.
        vm.prank(BORROWER);
        REVLoans(payable(address(LOANS_CONTRACT))).safeTransferFrom(BORROWER, newOwner, loanId);

        // Fund newOwner with ETH for repayment.
        vm.deal(newOwner, 100 ether);

        uint256 halfCollateral = loan.collateral / 2;

        JBSingleAllowance memory allowance;

        // newOwner partially repays the loan (return half the collateral).
        vm.prank(newOwner);
        (uint256 newLoanId, REVLoan memory newLoan) = LOANS_CONTRACT.repayLoan{value: loan.amount * 2}({
            loanId: loanId,
            maxRepayBorrowAmount: loan.amount * 2,
            collateralCountToReturn: halfCollateral,
            beneficiary: payable(newOwner),
            allowance: allowance
        });

        // Original loan NFT should be burned.
        vm.expectRevert();
        _loanOwnerOf(loanId);

        // New loan should exist with reduced collateral.
        assertGt(newLoanId, 0, "new loan should be created");
        assertEq(newLoan.collateral, loan.collateral - halfCollateral, "new loan collateral should be reduced");
        assertLt(newLoan.amount, loan.amount, "new loan borrow amount should be less");

        // New loan NFT should be owned by newOwner.
        assertEq(_loanOwnerOf(newLoanId), newOwner, "new loan NFT should be owned by newOwner");

        // Half collateral should be returned to newOwner.
        uint256 newOwnerTokens = jbTokens().totalBalanceOf(newOwner, revnetId);
        assertEq(newOwnerTokens, halfCollateral, "half collateral should be returned to newOwner");
    }
}
