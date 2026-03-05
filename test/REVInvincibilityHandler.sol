// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import /* {*} from */ "@bananapus/core-v5/test/helpers/TestBaseWorkflow.sol";
import {JBConstants} from "@bananapus/core-v5/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v5/src/structs/JBAccountingContext.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IREVLoans} from "../src/interfaces/IREVLoans.sol";
import {REVLoan} from "../src/structs/REVLoan.sol";
import {REVLoanSource} from "../src/structs/REVLoanSource.sol";

/// @title REVInvincibilityHandler
/// @notice Stateful fuzzing handler for the revnet + loans interaction surface.
/// @dev 10 operations with ghost variables tracking all value flows.
contract REVInvincibilityHandler is JBTest {
    // =========================================================================
    // Ghost variables
    // =========================================================================
    uint256 public COLLATERAL_SUM;
    uint256 public COLLATERAL_RETURNED;
    uint256 public BORROWED_SUM;
    uint256 public REPAID_SUM;
    uint256 public PAID_IN_SUM;
    uint256 public CASHED_OUT_SUM;
    uint256 public ADDED_TO_BALANCE_SUM;

    // Per-operation call counts
    uint256 public callCount_payAndBorrow;
    uint256 public callCount_repayLoan;
    uint256 public callCount_reallocateCollateral;
    uint256 public callCount_liquidateLoans;
    uint256 public callCount_advanceTime;
    uint256 public callCount_payInto;
    uint256 public callCount_cashOut;
    uint256 public callCount_addToBalance;
    uint256 public callCount_sendReservedTokens;
    uint256 public callCount_changeStage;

    // Fee project tracking
    uint256 public feeProjectBalanceAtStart;

    // =========================================================================
    // Dependencies
    // =========================================================================
    IJBMultiTerminal public TERMINAL;
    IREVLoans public LOANS;
    IJBPermissions public PERMS;
    IJBTokens public TOKENS;
    IJBController public CTRL;
    uint256 public REVNET_ID;
    uint256 public FEE_PROJECT_ID;
    address public USER;

    // Stage boundaries (for changeStage)
    uint256 public stage1Start;
    uint256 public stage2Start;

    constructor(
        IJBMultiTerminal terminal,
        IREVLoans loans,
        IJBPermissions permissions,
        IJBTokens tokens,
        IJBController controller,
        uint256 revnetId,
        uint256 feeProjectId,
        address user,
        uint256 _stage1Start,
        uint256 _stage2Start
    ) {
        TERMINAL = terminal;
        LOANS = loans;
        PERMS = permissions;
        TOKENS = tokens;
        CTRL = controller;
        REVNET_ID = revnetId;
        FEE_PROJECT_ID = feeProjectId;
        USER = user;
        stage1Start = _stage1Start;
        stage2Start = _stage2Start;
    }

    modifier useActor() {
        vm.startPrank(USER);
        _;
        vm.stopPrank();
    }

    // =========================================================================
    // Operation 1: payAndBorrow — pay ETH, borrow against tokens
    // =========================================================================
    function payAndBorrow(uint256 seed) public useActor {
        uint256 payAmount = bound(seed, 0.1 ether, 5 ether);
        uint256 prepaidFee = bound(seed >> 8, 25, 500);

        vm.deal(USER, payAmount);

        uint256 receivedTokens = TERMINAL.pay{value: payAmount}(REVNET_ID, JBConstants.NATIVE_TOKEN, 0, USER, 0, "", "");

        if (receivedTokens == 0) return;

        uint256 borrowable =
            LOANS.borrowableAmountFrom(REVNET_ID, receivedTokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        if (borrowable == 0) return;

        // Mock permission
        mockExpect(
            address(PERMS),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS), USER, REVNET_ID, 10, true, true)),
            abi.encode(true)
        );

        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: TERMINAL});
        (, REVLoan memory loan) =
            LOANS.borrowFrom(REVNET_ID, source, borrowable, receivedTokens, payable(USER), prepaidFee);

        COLLATERAL_SUM += receivedTokens;
        BORROWED_SUM += loan.amount;
        PAID_IN_SUM += payAmount;
        ++callCount_payAndBorrow;
    }

    // =========================================================================
    // Operation 2: repayLoan — partially/fully repay a loan
    // =========================================================================
    function repayLoan(uint256 seed) public useActor {
        if (callCount_payAndBorrow == 0) return;

        uint256 percentToPayDown = bound(seed, 1000, 9999);
        uint256 daysToWarp = bound(seed >> 16, 1, 90);
        vm.warp(block.timestamp + daysToWarp * 1 days);

        uint256 id = (REVNET_ID * 1_000_000_000_000) + callCount_payAndBorrow;

        try IERC721(address(LOANS)).ownerOf(id) {}
            catch {
            return;
        }

        REVLoan memory latestLoan = LOANS.loanOf(id);
        if (latestLoan.amount == 0) return;

        uint256 collateralReturned = mulDiv(latestLoan.collateral, percentToPayDown, 10_000);
        uint256 newCollateral = latestLoan.collateral - collateralReturned;
        uint256 borrowableFromNewCollateral =
            LOANS.borrowableAmountFrom(REVNET_ID, newCollateral, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        if (borrowableFromNewCollateral > 0) borrowableFromNewCollateral -= 1;

        uint256 amountDiff =
            borrowableFromNewCollateral > latestLoan.amount ? 0 : latestLoan.amount - borrowableFromNewCollateral;

        uint256 amountPaidDown = amountDiff;

        {
            uint256 timeSinceLoanCreated = block.timestamp - latestLoan.createdAt;
            if (timeSinceLoanCreated > latestLoan.prepaidDuration) {
                uint256 prepaidAmount =
                    JBFees.feeAmountFrom({amountBeforeFee: amountDiff, feePercent: latestLoan.prepaidFeePercent});
                amountPaidDown += JBFees.feeAmountFrom({
                    amountBeforeFee: amountDiff - prepaidAmount,
                    feePercent: mulDiv(timeSinceLoanCreated, JBConstants.MAX_FEE, 3650 days)
                });
            }
        }

        JBSingleAllowance memory allowance;
        vm.deal(USER, type(uint256).max);

        try LOANS.repayLoan{value: amountPaidDown}(
            id, amountPaidDown, collateralReturned, payable(USER), allowance
        ) returns (
            uint256, REVLoan memory adjustedLoan
        ) {
            COLLATERAL_RETURNED += collateralReturned;
            COLLATERAL_SUM -= collateralReturned;
            REPAID_SUM += (latestLoan.amount - adjustedLoan.amount);
            if (BORROWED_SUM >= (latestLoan.amount - adjustedLoan.amount)) {
                BORROWED_SUM -= (latestLoan.amount - adjustedLoan.amount);
            }
            ++callCount_repayLoan;
        } catch {}
    }

    // =========================================================================
    // Operation 3: reallocateCollateral — reallocate from existing loan
    // =========================================================================
    function reallocateCollateral(uint256 seed) public useActor {
        if (callCount_payAndBorrow == 0) return;

        uint256 collateralPercentToTransfer = bound(seed, 1, 5000);
        uint256 payAmount = bound(seed >> 8, 1 ether, 10 ether);
        uint256 prepaidFee = bound(seed >> 16, 25, 500);

        uint256 id = (REVNET_ID * 1_000_000_000_000) + callCount_payAndBorrow;

        try IERC721(address(LOANS)).ownerOf(id) {}
            catch {
            return;
        }

        REVLoan memory latestLoan = LOANS.loanOf(id);
        if (latestLoan.amount == 0) return;

        vm.deal(USER, payAmount);
        uint256 collateralToAdd =
            TERMINAL.pay{value: payAmount}(REVNET_ID, JBConstants.NATIVE_TOKEN, 0, USER, 0, "", "");

        uint256 collateralToTransfer = mulDiv(latestLoan.collateral, collateralPercentToTransfer, 10_000);
        if (collateralToTransfer == 0) return;

        uint256 newBorrowable = LOANS.borrowableAmountFrom(
            REVNET_ID, collateralToTransfer + collateralToAdd, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );

        // Mock permission
        mockExpect(
            address(PERMS),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS), USER, REVNET_ID, 10, true, true)),
            abi.encode(true)
        );

        try LOANS.reallocateCollateralFromLoan(
            id,
            collateralToTransfer,
            REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: TERMINAL}),
            newBorrowable,
            collateralToAdd,
            payable(USER),
            prepaidFee
        ) returns (
            uint256, uint256, REVLoan memory, REVLoan memory newLoan
        ) {
            COLLATERAL_SUM += collateralToAdd;
            BORROWED_SUM += newLoan.amount;
            PAID_IN_SUM += payAmount;
            ++callCount_reallocateCollateral;
        } catch {}
    }

    // =========================================================================
    // Operation 4: liquidateLoans — attempt liquidation
    // =========================================================================
    function liquidateLoans(uint256 seed) public {
        if (callCount_payAndBorrow == 0) return;

        uint256 count = bound(seed, 1, 5);
        uint256 startingLoanId = (REVNET_ID * 1_000_000_000_000) + 1;

        try LOANS.liquidateExpiredLoansFrom(REVNET_ID, startingLoanId, count) {} catch {}

        ++callCount_liquidateLoans;
    }

    // =========================================================================
    // Operation 5: advanceTime — warp 1 hour to 30 days
    // =========================================================================
    function advanceTime(uint256 seed) public {
        uint256 hoursToWarp = bound(seed, 1, 720); // 1 hour to 30 days
        vm.warp(block.timestamp + hoursToWarp * 1 hours);
        ++callCount_advanceTime;
    }

    // =========================================================================
    // Operation 6: payInto — pay without borrowing
    // =========================================================================
    function payInto(uint256 seed) public useActor {
        uint256 payAmount = bound(seed, 0.01 ether, 2 ether);
        vm.deal(USER, payAmount);

        TERMINAL.pay{value: payAmount}(REVNET_ID, JBConstants.NATIVE_TOKEN, payAmount, USER, 0, "", "");

        PAID_IN_SUM += payAmount;
        ++callCount_payInto;
    }

    // =========================================================================
    // Operation 7: cashOut — cash out held tokens
    // =========================================================================
    function cashOut(uint256 seed) public useActor {
        IJBToken token = TOKENS.tokenOf(REVNET_ID);
        uint256 balance = token.balanceOf(USER);
        if (balance == 0) return;

        uint256 cashOutCount = bound(seed, 1, balance);

        // Need to advance past the 30-day cash out delay
        // (only if not already past it)
        try TERMINAL.cashOutTokensOf({
            holder: USER,
            projectId: REVNET_ID,
            cashOutCount: cashOutCount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(USER),
            metadata: ""
        }) returns (
            uint256 reclaimAmount
        ) {
            CASHED_OUT_SUM += reclaimAmount;
            ++callCount_cashOut;
        } catch {}
    }

    // =========================================================================
    // Operation 8: addToBalance — donate to treasury (no mint)
    // =========================================================================
    function addToBalance(uint256 seed) public {
        uint256 amount = bound(seed, 0.01 ether, 1 ether);
        vm.deal(address(this), amount);

        TERMINAL.addToBalanceOf{value: amount}(REVNET_ID, JBConstants.NATIVE_TOKEN, amount, false, "", "");

        ADDED_TO_BALANCE_SUM += amount;
        ++callCount_addToBalance;
    }

    // =========================================================================
    // Operation 9: sendReservedTokens — trigger reserved distribution
    // =========================================================================
    function sendReservedTokens(uint256) public {
        try CTRL.sendReservedTokensToSplitsOf(REVNET_ID) {} catch {}
        ++callCount_sendReservedTokens;
    }

    // =========================================================================
    // Operation 10: changeStage — warp to next stage boundary
    // =========================================================================
    function changeStage(uint256 seed) public {
        uint256 target = bound(seed, 0, 2);

        if (target == 0 && block.timestamp < stage1Start) {
            vm.warp(stage1Start + 1);
        } else if (target == 1 && block.timestamp < stage2Start) {
            vm.warp(stage2Start + 1);
        } else {
            // Just advance a bit
            vm.warp(block.timestamp + 30 days);
        }

        ++callCount_changeStage;
    }

    // =========================================================================
    // Helpers
    // =========================================================================
    function totalOperations() public view returns (uint256) {
        return callCount_payAndBorrow + callCount_repayLoan + callCount_reallocateCollateral + callCount_liquidateLoans
            + callCount_advanceTime + callCount_payInto + callCount_cashOut + callCount_addToBalance
            + callCount_sendReservedTokens + callCount_changeStage;
    }

    receive() external payable {}
}
