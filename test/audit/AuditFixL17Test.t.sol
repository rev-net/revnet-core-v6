// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {REVOwner} from "../../src/REVOwner.sol";

/// @notice Regression test for L-17: REVOwner.supportsInterface omits IERC165.
contract AuditFixL17Test is Test {
    REVOwner revOwner;

    function setUp() public {
        revOwner = new REVOwner(
            IJBBuybackHookRegistry(makeAddr("buybackHook")),
            IJBDirectory(makeAddr("directory")),
            1, // feeRevnetId
            IJBSuckerRegistry(makeAddr("suckerRegistry")),
            makeAddr("loans"),
            makeAddr("hiddenTokens")
        );
    }

    /// @notice supportsInterface returns true for IERC165 (0x01ffc9a7).
    function test_supportsInterface_IERC165() public view {
        assertTrue(revOwner.supportsInterface(type(IERC165).interfaceId), "should support IERC165");
        assertEq(type(IERC165).interfaceId, bytes4(0x01ffc9a7), "IERC165 interface ID should be 0x01ffc9a7");
    }

    /// @notice supportsInterface returns true for IJBRulesetDataHook.
    function test_supportsInterface_IJBRulesetDataHook() public view {
        assertTrue(
            revOwner.supportsInterface(type(IJBRulesetDataHook).interfaceId), "should support IJBRulesetDataHook"
        );
    }

    /// @notice supportsInterface returns true for IJBCashOutHook.
    function test_supportsInterface_IJBCashOutHook() public view {
        assertTrue(revOwner.supportsInterface(type(IJBCashOutHook).interfaceId), "should support IJBCashOutHook");
    }

    /// @notice supportsInterface returns false for an unsupported interface.
    function test_supportsInterface_unsupported() public view {
        assertFalse(revOwner.supportsInterface(bytes4(0xdeadbeef)), "should not support random interface");
    }
}
