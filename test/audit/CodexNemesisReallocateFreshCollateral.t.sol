// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {REVLoan} from "../../src/structs/REVLoan.sol";
import {REVLoanSource} from "../../src/structs/REVLoanSource.sol";
import {ReallocatePermissionTest} from "../regression/ReallocatePermission.t.sol";

contract CodexNemesisReallocateFreshCollateralTest is ReallocatePermissionTest {
    function test_codexNemesis_reallocateOperatorCanBorrowAgainstFreshCollateralToSelf() public {
        (uint256 loanId,) = _createInitialLoan();

        address donor = makeAddr("donor");
        vm.deal(donor, 500 ether);
        vm.prank(donor);
        jbMultiTerminal().addToBalanceOf{value: 500 ether}(
            REVNET_ID, JBConstants.NATIVE_TOKEN, 500 ether, false, "", ""
        );

        vm.prank(HOLDER);
        uint256 extraTokens =
            jbMultiTerminal().pay{value: 50 ether}(REVNET_ID, JBConstants.NATIVE_TOKEN, 50 ether, HOLDER, 0, "", "");

        REVLoan memory originalLoan = LOANS_CONTRACT.loanOf(loanId);
        uint256 collateralToTransfer = originalLoan.collateral / 10;
        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        _grantPermission(OPERATOR, JBPermissionIds.REALLOCATE_LOAN);

        uint256 operatorBalanceBefore = OPERATOR.balance;

        vm.prank(OPERATOR);
        (, uint256 newLoanId,, REVLoan memory newLoan) = LOANS_CONTRACT.reallocateCollateralFromLoan(
            loanId, collateralToTransfer, source, 0, extraTokens, payable(OPERATOR), 25
        );

        assertGt(newLoanId, 0, "new loan was created");
        assertEq(newLoan.collateral, collateralToTransfer + extraTokens, "fresh holder tokens were used");
        assertGt(newLoan.amount, 0, "new loan borrowed value");
        assertGt(OPERATOR.balance, operatorBalanceBefore, "operator received loan proceeds");
    }
}
