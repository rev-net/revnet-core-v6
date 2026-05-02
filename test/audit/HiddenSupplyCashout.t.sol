// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

import {TestHiddenTokens} from "../TestHiddenTokens.t.sol";

contract CodexNemesisHiddenSupplyCashoutTest is TestHiddenTokens {
    function test_hiddenSupplyCannotDrainCashoutAndThenBeRevealed() public {
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

        uint256 hiddenCount = minted / 2;
        vm.prank(USER);
        HIDDEN_TOKENS.hideTokensOf(REVNET_ID, hiddenCount, USER);

        uint256 visibleSupply = jbController().TOKENS().totalSupplyOf(REVNET_ID);
        assertEq(visibleSupply, minted - hiddenCount, "hidden tokens left the live supply");

        vm.prank(USER);
        jbMultiTerminal()
            .cashOutTokensOf({
            holder: USER,
            projectId: REVNET_ID,
            cashOutCount: visibleSupply,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(USER),
            metadata: ""
        });

        uint256 terminalBalanceAfter =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), REVNET_ID, JBConstants.NATIVE_TOKEN);
        assertGt(terminalBalanceAfter, 0, "hidden supply kept the visible tranche from draining the revnet balance");
        assertLt(
            terminalBalanceAfter, terminalBalanceBefore, "cash out should still reclaim against the visible tranche"
        );

        vm.prank(USER);
        HIDDEN_TOKENS.revealTokensOf(REVNET_ID, hiddenCount, USER);

        assertEq(
            jbController().TOKENS().totalBalanceOf(USER, REVNET_ID),
            hiddenCount,
            "hidden tranche was restored after the cash out"
        );
    }
}
