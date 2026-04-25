// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestAuditFixVerification} from "../TestAuditFixVerification.t.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {REVLoanSource} from "../../src/structs/REVLoanSource.sol";
import {REVLoan} from "../../src/structs/REVLoan.sol";

contract CodexRemoteLoanAccountingGap is TestAuditFixVerification {
    function test_remoteLoanStateInflatesLocalBorrowability() public {
        uint256 payAmount = 100 ether;

        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: payAmount}(
            REVNET_ID, JBConstants.NATIVE_TOKEN, payAmount, USER, 0, "", ""
        );

        // Simulate a peer chain that started from 100 ETH / 100k tokens, then originated a loan against
        // 50k burned-collateral tokens. The registry only exports the raw post-loan values, not the
        // remote loan's economic adjustments.
        uint256 remoteRawSupply = 50_000e18;
        uint256 remoteRawSurplus = 62.5e18;
        uint256 remoteLoanCollateral = 50_000e18;
        uint256 remoteLoanDebt = 37.5e18;
        MOCK_SUCKER_REGISTRY.setRemoteValues(remoteRawSupply, remoteRawSurplus);

        uint256 collateral = tokens / 10;
        uint256 actualBorrowable = LOANS_CONTRACT.borrowableAmountFrom(
            REVNET_ID, collateral, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );

        uint256 localSupply = jbController().totalTokenSupplyWithReservedTokensOf(REVNET_ID);
        uint256 localSurplus =
            jbMultiTerminal().currentSurplusOf(REVNET_ID, new address[](0), 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        uint256 correctedBorrowable = JBCashOuts.cashOutFrom({
            surplus: localSurplus + remoteRawSurplus + remoteLoanDebt,
            cashOutCount: collateral,
            totalSupply: localSupply + remoteRawSupply + remoteLoanCollateral,
            cashOutTaxRate: 5000
        });

        if (correctedBorrowable > localSurplus) correctedBorrowable = localSurplus;

        assertGt(actualBorrowable, correctedBorrowable, "raw remote values should overstate borrowability");

        _grantLoansBurnPermission(USER, REVNET_ID);

        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        vm.prank(USER);
        (, REVLoan memory loan) =
            LOANS_CONTRACT.borrowFrom(REVNET_ID, source, actualBorrowable, collateral, payable(USER), 25, USER);

        assertEq(loan.amount, actualBorrowable, "loan should be opened at the inflated amount");
        assertGt(loan.amount, correctedBorrowable, "loan exceeds the corrected omnichain value");
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
