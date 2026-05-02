// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBPayoutTerminal} from "@bananapus/core-v6/src/interfaces/IJBPayoutTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";

import {REVLoans} from "../../src/REVLoans.sol";
import {REVLoan} from "../../src/structs/REVLoan.sol";
import {REVLoanSource} from "../../src/structs/REVLoanSource.sol";
import {TestHiddenTokens} from "../TestHiddenTokens.t.sol";

contract CodexNemesisHiddenSupplyLoanBorrowTest is TestHiddenTokens {
    function test_hiddenSupplyCannotDrainLoanCapacityAndThenBeRevealed() public {
        uint256 payAmount = 10 ether;

        vm.prank(USER);
        uint256 minted = jbMultiTerminal().pay{value: payAmount}({
            projectId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: USER,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        uint256 terminalBalanceBefore =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), REVNET_ID, JBConstants.NATIVE_TOKEN);
        assertEq(terminalBalanceBefore, payAmount, "setup: revnet terminal balance");

        _allowHolderToHide(USER, REVNET_ID);
        _grantLoansBurnPermission(USER, REVNET_ID);

        uint256 hiddenCount = minted / 2;
        vm.prank(USER);
        HIDDEN_TOKENS.hideTokensOf(REVNET_ID, hiddenCount, USER);

        uint256 visibleSupply = jbController().TOKENS().totalSupplyOf(REVNET_ID);
        assertEq(visibleSupply, minted - hiddenCount, "hidden tokens left the live supply");

        REVLoanSource memory source =
            REVLoanSource({terminal: IJBPayoutTerminal(address(jbMultiTerminal())), token: JBConstants.NATIVE_TOKEN});
        uint256 minPrepaidFeePercent = LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT();
        uint256 borrowable = LOANS_CONTRACT.borrowableAmountFrom(
            REVNET_ID, visibleSupply, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        assertLt(borrowable, terminalBalanceBefore, "hidden supply stays in the loan denominator");

        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(REVLoans.REVLoans_UnderMinBorrowAmount.selector, terminalBalanceBefore, borrowable)
        );
        LOANS_CONTRACT.borrowFrom({
            revnetId: REVNET_ID,
            source: source,
            minBorrowAmount: terminalBalanceBefore,
            collateralCount: visibleSupply,
            beneficiary: payable(USER),
            prepaidFeePercent: minPrepaidFeePercent,
            holder: USER
        });

        vm.prank(USER);
        (uint256 loanId, REVLoan memory loan) = LOANS_CONTRACT.borrowFrom({
            revnetId: REVNET_ID,
            source: source,
            minBorrowAmount: borrowable,
            collateralCount: visibleSupply,
            beneficiary: payable(USER),
            prepaidFeePercent: minPrepaidFeePercent,
            holder: USER
        });

        assertEq(loanId / 1_000_000_000_000, REVNET_ID, "loan should belong to the revnet");
        assertEq(loan.collateral, visibleSupply, "visible tranche became loan collateral");
        assertEq(loan.amount, borrowable, "visible tranche borrowed against the hidden-inclusive denominator");
        assertLt(loan.amount, terminalBalanceBefore, "visible tranche cannot borrow against the full treasury");

        uint256 terminalBalanceAfter =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), REVNET_ID, JBConstants.NATIVE_TOKEN);
        assertGt(terminalBalanceAfter, terminalBalanceBefore / 40, "more than the protocol-fee residue remained");

        vm.prank(USER);
        HIDDEN_TOKENS.revealTokensOf(REVNET_ID, hiddenCount, USER);

        assertGt(
            jbController().TOKENS().totalBalanceOf(USER, REVNET_ID),
            hiddenCount,
            "hidden tranche was restored and the borrower still kept fee-minted tokens"
        );
        assertEq(
            LOANS_CONTRACT.totalBorrowedFrom(REVNET_ID, source.terminal, source.token),
            borrowable,
            "only the hidden-inclusive borrowable amount remains booked as debt"
        );
    }

    function _grantLoansBurnPermission(address account, uint256 revnetId) internal {
        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = JBPermissionIds.BURN_TOKENS;

        JBPermissionsData memory permissionsData = JBPermissionsData({
            operator: address(LOANS_CONTRACT),
            // forge-lint: disable-next-line(unsafe-typecast)
            projectId: uint56(revnetId),
            permissionIds: permissionIds
        });

        vm.prank(account);
        jbPermissions().setPermissionsFor(account, permissionsData);
    }
}
