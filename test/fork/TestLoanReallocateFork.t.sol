// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// forge-lint: disable-next-line(unaliased-plain-import)
import "./ForkTestBase.sol";

/// @notice Fork tests for REVLoans.reallocateCollateralFromLoan() with real Uniswap V4 buyback hook.
///
/// Covers: basic reallocation and source mismatch revert.
///
/// Run with: FOUNDRY_PROFILE=fork forge test --match-contract TestLoanReallocateFork -vvv
contract TestLoanReallocateFork is ForkTestBase {
    uint256 revnetId;

    function setUp() public override {
        super.setUp();

        // Deploy fee project + revnet.
        _deployFeeProject(5000);
        revnetId = _deployRevnet(5000);
        _setupPool(revnetId, 10_000 ether);

        // Pay to create surplus.
        _payRevnet(revnetId, PAYER, 10 ether);
        _payRevnet(revnetId, BORROWER, 10 ether);
    }

    /// @notice Reallocate collateral to a new loan: original reduced, new loan created.
    function test_fork_reallocate_basic() public {
        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);
        (uint256 loanId, REVLoan memory loan) =
            _createLoan(revnetId, BORROWER, borrowerTokens, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());

        // Add more surplus after the loan so the remaining collateral supports the existing borrow amount.
        // Without extra surplus, any collateral removal would make borrowable < loan.amount (bonding curve).
        address extraPayer = makeAddr("extraPayer");
        vm.deal(extraPayer, 20 ether);
        _payRevnet(revnetId, extraPayer, 20 ether);

        uint256 transferAmount = loan.collateral / 20;
        uint256 totalCollateralBefore = LOANS_CONTRACT.totalCollateralOf(revnetId);

        REVLoanSource memory source = _nativeLoanSource();

        // Grant burn permission again for the new loan's collateral.
        _grantBurnPermission(BORROWER, revnetId);

        // Cache before prank to avoid consuming the prank with a static call.
        uint256 minFeePercent = LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT();

        vm.prank(BORROWER);
        (uint256 reallocatedLoanId, uint256 newLoanId, REVLoan memory reallocatedLoan, REVLoan memory newLoan) = LOANS_CONTRACT.reallocateCollateralFromLoan({
            loanId: loanId,
            collateralCountToTransfer: transferAmount,
            source: source,
            minBorrowAmount: 0,
            collateralCountToAdd: 0,
            beneficiary: payable(BORROWER),
            prepaidFeePercent: minFeePercent
        });

        // Original loan reduced.
        assertEq(
            reallocatedLoan.collateral,
            loan.collateral - transferAmount,
            "reallocated loan should have reduced collateral"
        );

        // New loan has the transferred collateral.
        assertEq(newLoan.collateral, transferAmount, "new loan should have transferred collateral");

        // Original loan burned, reallocated loan created.
        vm.expectRevert();
        _loanOwnerOf(loanId);

        assertEq(_loanOwnerOf(reallocatedLoanId), BORROWER, "reallocated loan owned by borrower");
        assertEq(_loanOwnerOf(newLoanId), BORROWER, "new loan owned by borrower");

        // Total collateral should remain approximately the same (moved, not destroyed).
        // It increases by halfCollateral because the new loan's borrowFrom also adds collateral.
        // But reallocateCollateralFromLoan transfers collateral from the existing loan (not burning new tokens),
        // so totalCollateralOf should stay the same (the half was already in the system).
        assertEq(
            LOANS_CONTRACT.totalCollateralOf(revnetId), totalCollateralBefore, "total collateral should be unchanged"
        );
    }

    /// @notice Reallocate with a different source terminal should revert.
    function test_fork_reallocate_sourceMismatchReverts() public {
        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);
        (uint256 loanId, REVLoan memory loan) =
            _createLoan(revnetId, BORROWER, borrowerTokens, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());

        // Create a source with a different terminal address.
        REVLoanSource memory badSource =
            REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: IJBPayoutTerminal(address(0xdead))});

        // Cache before prank to avoid consuming the prank with a static call.
        uint256 minFeePercent = LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT();

        vm.prank(BORROWER);
        vm.expectRevert();
        LOANS_CONTRACT.reallocateCollateralFromLoan({
            loanId: loanId,
            collateralCountToTransfer: loan.collateral / 2,
            source: badSource,
            minBorrowAmount: 0,
            collateralCountToAdd: 0,
            beneficiary: payable(BORROWER),
            prepaidFeePercent: minFeePercent
        });
    }
}
