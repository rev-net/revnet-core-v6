// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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

    /// @notice Reallocate half collateral to a new loan: original reduced, new loan created.
    function test_fork_reallocate_basic() public onlyFork {
        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);
        (uint256 loanId, REVLoan memory loan) =
            _createLoan(revnetId, BORROWER, borrowerTokens, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());

        uint256 halfCollateral = loan.collateral / 2;
        uint256 totalCollateralBefore = LOANS_CONTRACT.totalCollateralOf(revnetId);

        REVLoanSource memory source = _nativeLoanSource();

        // Grant burn permission again for the new loan's collateral.
        _grantBurnPermission(BORROWER, revnetId);

        vm.prank(BORROWER);
        (uint256 reallocatedLoanId, uint256 newLoanId, REVLoan memory reallocatedLoan, REVLoan memory newLoan) = LOANS_CONTRACT.reallocateCollateralFromLoan({
            loanId: loanId,
            collateralCountToTransfer: halfCollateral,
            source: source,
            minBorrowAmount: 0,
            collateralCountToAdd: 0,
            beneficiary: payable(BORROWER),
            prepaidFeePercent: LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT()
        });

        // Original loan reduced.
        assertEq(
            reallocatedLoan.collateral,
            loan.collateral - halfCollateral,
            "reallocated loan should have reduced collateral"
        );

        // New loan has the transferred collateral.
        assertEq(newLoan.collateral, halfCollateral, "new loan should have transferred collateral");

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
    function test_fork_reallocate_sourceMismatchReverts() public onlyFork {
        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);
        (uint256 loanId, REVLoan memory loan) =
            _createLoan(revnetId, BORROWER, borrowerTokens, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());

        // Create a source with a different terminal address.
        REVLoanSource memory badSource =
            REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: IJBPayoutTerminal(address(0xdead))});

        vm.prank(BORROWER);
        vm.expectRevert();
        LOANS_CONTRACT.reallocateCollateralFromLoan({
            loanId: loanId,
            collateralCountToTransfer: loan.collateral / 2,
            source: badSource,
            minBorrowAmount: 0,
            collateralCountToAdd: 0,
            beneficiary: payable(BORROWER),
            prepaidFeePercent: LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT()
        });
    }
}
