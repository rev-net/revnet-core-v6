// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {REVLoan} from "../../src/structs/REVLoan.sol";
import {REVLoanSource} from "../../src/structs/REVLoanSource.sol";
import {ReallocatePermissionTest} from "./ReallocatePermission.t.sol";

/// @notice A REALLOCATE_LOAN-only operator must not be able to pass `collateralCountToAdd > 0` to
/// `reallocateCollateralFromLoan`, burn the loan owner's freshly held project tokens, open a new loan, and direct
/// the proceeds via `beneficiary` — that would bypass the OPEN_LOAN gate that `borrowFrom` enforces.
contract ReallocateFreshCollateralPermissionTest is ReallocatePermissionTest {
    function test_reallocateOperatorCannotBorrowAgainstFreshCollateralWithoutOpenLoan() public {
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

        // Operator without OPEN_LOAN attempts to add fresh holder collateral and direct the proceeds to themselves.
        // Must revert at the OPEN_LOAN gate.
        vm.prank(OPERATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                HOLDER, // account
                OPERATOR, // sender
                REVNET_ID, // projectId
                JBPermissionIds.OPEN_LOAN // permissionId
            )
        );
        LOANS_CONTRACT.reallocateCollateralFromLoan(
            loanId, collateralToTransfer, source, 0, extraTokens, payable(OPERATOR), 25
        );
    }
}
