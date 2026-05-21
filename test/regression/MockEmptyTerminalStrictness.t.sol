// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";

import {MockEmptyTerminal} from "../mock/MockEmptyTerminal.sol";

contract MockEmptyTerminalStrictnessTest is Test {
    MockEmptyTerminal internal terminal;

    function setUp() public {
        terminal = new MockEmptyTerminal();
    }

    function test_mockEmptyTerminal_acceptsOnlySetupAndSurplusSelectors() public {
        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](0);

        // Revnet setup registers the router-terminal placeholder with empty accounting contexts.
        terminal.addAccountingContextsFor(1, accountingContexts);

        // Surplus aggregation can safely read the placeholder; it must contribute no value.
        assertEq(terminal.currentSurplusOf(1, new address[](0), 18, uint32(uint160(address(0)))), 0);

        // Any other selector should fail loudly instead of returning a zero word that might satisfy the wrong decoder.
        (bool success, bytes memory revertData) = address(terminal).call(abi.encodeWithSelector(bytes4(0xdeadbeef)));
        assertFalse(success);
        assertEq(bytes4(revertData), MockEmptyTerminal.MockEmptyTerminal_UnexpectedCall.selector);
    }
}
