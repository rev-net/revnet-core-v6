// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBPayoutTerminal} from "@bananapus/core-v6/src/interfaces/IJBPayoutTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {MockPriceFeed} from "@bananapus/core-v6/test/mock/MockPriceFeed.sol";
import {IJBPeerChainAdjustedAccounts} from "@bananapus/suckers-v6/src/interfaces/IJBPeerChainAdjustedAccounts.sol";

import {REVLoan} from "../../src/structs/REVLoan.sol";
import {REVLoanSource} from "../../src/structs/REVLoanSource.sol";
import {TestHiddenTokens} from "../TestHiddenTokens.t.sol";

contract CodexLocalLoanStateOmissionCashoutTest is TestHiddenTokens {
    address internal VICTIM = makeAddr("victim");

    function test_localLoanStateIsIncludedInCashoutPricing() public {
        uint256 payAmount = 50 ether;
        vm.deal(VICTIM, payAmount);

        vm.prank(USER);
        uint256 attackerInitialTokens = jbMultiTerminal().pay{value: payAmount}({
            projectId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: USER,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        vm.prank(VICTIM);
        uint256 victimInitialTokens = jbMultiTerminal().pay{value: payAmount}({
            projectId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: VICTIM,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        assertEq(attackerInitialTokens, victimInitialTokens, "setup: both holders should start evenly");

        _grantLoansBurnPermission(USER, REVNET_ID);

        REVLoanSource memory source =
            REVLoanSource({terminal: IJBPayoutTerminal(address(jbMultiTerminal())), token: JBConstants.NATIVE_TOKEN});
        uint256 collateralCount = attackerInitialTokens / 2;
        uint256 minPrepaidFeePercent = LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT();

        vm.prank(USER);
        (, REVLoan memory loan) = LOANS_CONTRACT.borrowFrom({
            revnetId: REVNET_ID,
            source: source,
            minBorrowAmount: 0,
            collateralCount: collateralCount,
            beneficiary: payable(USER),
            prepaidFeePercent: minPrepaidFeePercent,
            holder: USER
        });

        assertGt(loan.amount, 0, "setup: loan should be opened");

        uint256 attackerVisibleBalance = jbController().TOKENS().totalBalanceOf(USER, REVNET_ID);
        uint256 visibleSupply = jbController().totalTokenSupplyWithReservedTokensOf(REVNET_ID);
        uint256 localSurplus = jbMultiTerminal()
            .currentSurplusOf(REVNET_ID, new address[](0), 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        uint256 totalBorrowed = LOANS_CONTRACT.totalBorrowedFrom(REVNET_ID, source.terminal, JBConstants.NATIVE_TOKEN);
        uint256 totalCollateral = LOANS_CONTRACT.totalCollateralOf(REVNET_ID);

        uint256 correctedCashOut = JBCashOuts.cashOutFrom({
            surplus: localSurplus + totalBorrowed,
            cashOutCount: attackerVisibleBalance,
            totalSupply: visibleSupply + totalCollateral,
            cashOutTaxRate: 5000
        });
        if (correctedCashOut > localSurplus) correctedCashOut = localSurplus;

        uint256 attackerEthBefore = USER.balance;
        vm.prank(USER);
        jbMultiTerminal()
            .cashOutTokensOf({
            holder: USER,
            projectId: REVNET_ID,
            cashOutCount: attackerVisibleBalance,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(USER),
            metadata: ""
        });
        uint256 actualCashOut = USER.balance - attackerEthBefore;

        assertLe(actualCashOut, correctedCashOut, "cash out should not exceed the local-loan-adjusted curve");
    }

    function test_peerSnapshotAdjustedAccountsIncludeLocalLoansButExcludeHiddenSupply() public {
        MockPriceFeed matchingFeed = new MockPriceFeed(1e18, 18);
        vm.prank(multisig());
        jbPrices()
            .addPriceFeedFor({
            projectId: 0,
            pricingCurrency: JBCurrencyIds.ETH,
            unitCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            feed: matchingFeed
        });

        uint256 payAmount = 50 ether;
        vm.prank(USER);
        uint256 userTokens = jbMultiTerminal().pay{value: payAmount}({
            projectId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: USER,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        _allowHolderToHide(USER, REVNET_ID);
        uint256 hiddenCount = userTokens / 5;
        vm.prank(USER);
        HIDDEN_TOKENS.hideTokensOf(REVNET_ID, hiddenCount, USER);

        _grantLoansBurnPermission(USER, REVNET_ID);

        REVLoanSource memory source =
            REVLoanSource({terminal: IJBPayoutTerminal(address(jbMultiTerminal())), token: JBConstants.NATIVE_TOKEN});
        uint256 collateralCount = (userTokens - hiddenCount) / 3;
        uint256 minPrepaidFeePercent = LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT();

        vm.prank(USER);
        (, REVLoan memory loan) = LOANS_CONTRACT.borrowFrom({
            revnetId: REVNET_ID,
            source: source,
            minBorrowAmount: 0,
            collateralCount: collateralCount,
            beneficiary: payable(USER),
            prepaidFeePercent: minPrepaidFeePercent,
            holder: USER
        });

        assertGt(loan.amount, 0, "setup: loan should be opened");

        (uint256 snapshotSupply, uint256 snapshotSurplus) =
            REV_OWNER.peerChainAdjustedAccountsOf(REVNET_ID, 18, JBCurrencyIds.ETH);

        assertEq(
            snapshotSupply,
            LOANS_CONTRACT.totalCollateralOf(REVNET_ID),
            "peer snapshot supply should include loan collateral but not hidden supply"
        );
        assertEq(
            snapshotSurplus,
            LOANS_CONTRACT.totalBorrowedFrom(REVNET_ID, source.terminal, JBConstants.NATIVE_TOKEN),
            "peer snapshot surplus should include outstanding loan debt"
        );
        assertTrue(
            REV_OWNER.supportsInterface(type(IJBPeerChainAdjustedAccounts).interfaceId),
            "peer adjusted accounts interface should be advertised"
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
