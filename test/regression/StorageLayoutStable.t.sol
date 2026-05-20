// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";

import {REVLoans} from "../../src/REVLoans.sol";
import {IREVLoans} from "../../src/interfaces/IREVLoans.sol";
import {MockSuckerRegistry} from "../mock/MockSuckerRegistry.sol";

/// @notice Pins REVLoans's storage layout at the slot level by writing through `vm.store` and reading back via the
/// public getter. If any state variable is reordered, inserted, or removed, this test fails — preventing silent
/// breakage of consumers that hardcode slots (e.g. `LoanIdOverflowGuard.t.sol:70` uses slot 11 for
/// `totalLoansBorrowedFor`).
/// @dev If a future change must reorder storage, update BOTH the consumer slot constants AND this file in lockstep,
/// then audit any external indexer / upgrade script that reads raw slots.
contract StorageLayoutStable is TestBaseWorkflow {
    address private constant _TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;
    REVLoans internal LOANS;

    function setUp() public override {
        super.setUp();
        LOANS = new REVLoans({
            controller: jbController(),
            terminal: jbMultiTerminal(),
            suckerRegistry: IJBSuckerRegistry(address(new MockSuckerRegistry())),
            revId: jbProjects().createFor(multisig()),
            owner: address(this),
            permit2: permit2(),
            trustedForwarder: _TRUSTED_FORWARDER
        });
    }

    /// @notice `isLoanSourceOf` (mapping(uint256 => mapping(address => bool))) sits at slot 7.
    function test_slot_isLoanSourceOf_is7() public {
        uint256 revnetId = 1;
        address token = JBConstants.NATIVE_TOKEN;
        bytes32 outerSlot = keccak256(abi.encode(revnetId, uint256(7)));
        bytes32 innerSlot = keccak256(abi.encode(token, outerSlot));
        vm.store(address(LOANS), innerSlot, bytes32(uint256(1)));
        assertTrue(LOANS.isLoanSourceOf(revnetId, token), "isLoanSourceOf expected at slot 7");
    }

    /// @notice `tokenUriResolver` sits at slot 8.
    function test_slot_tokenUriResolver_is8() public {
        address probe = address(0xBEEF);
        vm.store(address(LOANS), bytes32(uint256(8)), bytes32(uint256(uint160(probe))));
        assertEq(address(LOANS.tokenUriResolver()), probe, "tokenUriResolver expected at slot 8");
    }

    /// @notice `totalBorrowedFrom` (mapping(uint256 => mapping(address => uint256))) sits at slot 9.
    function test_slot_totalBorrowedFrom_is9() public {
        uint256 revnetId = 1;
        address token = JBConstants.NATIVE_TOKEN;
        bytes32 outerSlot = keccak256(abi.encode(revnetId, uint256(9)));
        bytes32 innerSlot = keccak256(abi.encode(token, outerSlot));
        vm.store(address(LOANS), innerSlot, bytes32(uint256(123456)));
        assertEq(LOANS.totalBorrowedFrom(revnetId, token), 123456, "totalBorrowedFrom expected at slot 9");
    }

    /// @notice `totalCollateralOf` (mapping(uint256 => uint256)) sits at slot 10.
    function test_slot_totalCollateralOf_is10() public {
        uint256 revnetId = 7;
        bytes32 slot = keccak256(abi.encode(revnetId, uint256(10)));
        vm.store(address(LOANS), slot, bytes32(uint256(987)));
        assertEq(LOANS.totalCollateralOf(revnetId), 987, "totalCollateralOf expected at slot 10");
    }

    /// @notice `totalLoansBorrowedFor` (mapping(uint256 => uint256)) sits at slot 11.
    /// @dev This is the slot hardcoded in `LoanIdOverflowGuard.t.sol`. If this test fails, that test will too —
    /// audit every other `vm.store` reader in the suite, plus any external slot-based tooling, before bumping.
    function test_slot_totalLoansBorrowedFor_is11() public {
        uint256 revnetId = 1;
        bytes32 slot = keccak256(abi.encode(revnetId, uint256(11)));
        vm.store(address(LOANS), slot, bytes32(uint256(1_000_000_000_000)));
        assertEq(
            LOANS.totalLoansBorrowedFor(revnetId),
            1_000_000_000_000,
            "totalLoansBorrowedFor expected at slot 11 (matches LoanIdOverflowGuard.t.sol:70)"
        );
    }
}
