// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissioned} from "@bananapus/core-v6/src/interfaces/IJBPermissioned.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBPayoutTerminal} from "@bananapus/core-v6/src/interfaces/IJBPayoutTerminal.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {REVLoans} from "../../src/REVLoans.sol";
import {IREVDeployer} from "../../src/interfaces/IREVDeployer.sol";
import {IREVOwner} from "../../src/interfaces/IREVOwner.sol";

/// @notice Regression test for `scopeCashOutsToLocalBalances` in REVLoans (Consumer 3).
/// @dev References TEST_IMPROVEMENT_PLAN.md Section 8.2, Consumer 3.
///      When scopeCashOutsToLocalBalances=true in the current ruleset, `_borrowableAmountFrom`
///      uses only local surplus/supply. When false, it adds remote values from SUCKER_REGISTRY.
contract ScopeCashOutsREVLoansTest is Test {
    REVLoans loans;

    address constant CONTROLLER = address(0x1111);
    address constant DIRECTORY = address(0x2222);
    address constant PRICES = address(0x3333);
    address constant PERMISSIONS = address(0x4444);
    address constant SUCKER_REGISTRY = address(0x5555);
    address constant TERMINAL = address(0x6666);
    address constant PERMIT2 = address(0x7777);
    address constant OWNER = address(0x8888);
    address constant DEPLOYER = address(0x9999);

    uint256 constant REVNET_ID = 10;
    uint256 constant REV_ID = 1;
    uint256 constant LOCAL_SURPLUS = 100e18;
    uint256 constant REMOTE_SURPLUS = 50e18;
    uint256 constant LOCAL_SUPPLY = 1000e18;
    uint256 constant REMOTE_SUPPLY = 500e18;

    function setUp() public {
        // Etch all mock addresses
        vm.etch(CONTROLLER, hex"00");
        vm.etch(DIRECTORY, hex"00");
        vm.etch(PRICES, hex"00");
        vm.etch(PERMISSIONS, hex"00");
        vm.etch(SUCKER_REGISTRY, hex"00");
        vm.etch(TERMINAL, hex"00");
        vm.etch(PERMIT2, hex"00");
        vm.etch(OWNER, hex"00");
        vm.etch(DEPLOYER, hex"00");

        // Mock constructor dependencies
        vm.mockCall(CONTROLLER, abi.encodeWithSelector(IJBController.DIRECTORY.selector), abi.encode(DIRECTORY));
        vm.mockCall(CONTROLLER, abi.encodeWithSelector(IJBController.PRICES.selector), abi.encode(PRICES));
        vm.mockCall(CONTROLLER, abi.encodeWithSelector(IJBPermissioned.PERMISSIONS.selector), abi.encode(PERMISSIONS));

        loans = new REVLoans({
            controller: IJBController(CONTROLLER),
            terminal: IJBPayoutTerminal(TERMINAL),
            suckerRegistry: IJBSuckerRegistry(SUCKER_REGISTRY),
            revId: REV_ID,
            owner: OWNER,
            permit2: IPermit2(PERMIT2),
            trustedForwarder: address(0) // no trusted forwarder
        });

        vm.mockCall(OWNER, abi.encodeWithSelector(IREVOwner.deployer.selector), abi.encode(IREVDeployer(DEPLOYER)));
        vm.mockCall(OWNER, abi.encodeWithSelector(IREVOwner.cashOutDelayOf.selector, REVNET_ID), abi.encode(uint256(0)));
        vm.mockCall(
            DEPLOYER, abi.encodeWithSelector(IREVDeployer.MULTI_TERMINAL.selector), abi.encode(IJBTerminal(TERMINAL))
        );

        // --- Mock borrowableAmountFrom dependencies ---

        // DIRECTORY.terminalsOf returns a single terminal
        IJBTerminal[] memory terminals = new IJBTerminal[](1);
        terminals[0] = IJBTerminal(TERMINAL);
        vm.mockCall(
            DIRECTORY, abi.encodeWithSelector(IJBDirectory.terminalsOf.selector, REVNET_ID), abi.encode(terminals)
        );

        // Terminal.currentSurplusOf returns local surplus
        vm.mockCall(TERMINAL, abi.encodeWithSelector(IJBTerminal.currentSurplusOf.selector), abi.encode(LOCAL_SURPLUS));

        // Controller.totalTokenSupplyWithReservedTokensOf
        vm.mockCall(
            CONTROLLER,
            abi.encodeWithSelector(IJBController.totalTokenSupplyWithReservedTokensOf.selector, REVNET_ID),
            abi.encode(LOCAL_SUPPLY)
        );

        // Sucker registry remote values
        vm.mockCall(
            SUCKER_REGISTRY,
            abi.encodeWithSelector(IJBSuckerRegistry.remoteTotalSupplyOf.selector, REVNET_ID),
            abi.encode(REMOTE_SUPPLY)
        );
        vm.mockCall(
            SUCKER_REGISTRY,
            abi.encodeWithSelector(IJBSuckerRegistry.remoteSurplusOf.selector),
            abi.encode(REMOTE_SURPLUS)
        );
    }

    /// @notice Pack metadata for a ruleset with given scope flag and cashOutTaxRate.
    function _packMetadata(bool scopeToLocal, uint16 cashOutTaxRate) internal pure returns (uint256 metadata) {
        // Bit layout: reservedPercent(16) | cashOutTaxRate(16) | baseCurrency(32) | ...flags... |
        // scopeCashOutsToLocalBalances(bit 79)
        metadata = uint256(cashOutTaxRate) << 16;
        metadata |= uint256(1) << 32; // baseCurrency = 1
        if (scopeToLocal) metadata |= uint256(1) << 79;
        metadata |= uint256(uint160(OWNER)) << 82;
    }

    /// @notice Build a mock ruleset with the given scope flag. No dataHook → cashOutDelay=0.
    function _mockCurrentRuleset(bool scopeToLocal) internal {
        JBRuleset memory ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 0,
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: _packMetadata(scopeToLocal, 5000) // 50% cashOutTaxRate
        });

        // Controller.currentRulesetOf returns (JBRuleset, JBRulesetMetadata)
        // The second value (metadata struct) isn't used by _borrowableAmountFrom
        vm.mockCall(
            CONTROLLER,
            abi.encodeWithSelector(IJBController.currentRulesetOf.selector, REVNET_ID),
            abi.encode(ruleset, _emptyMetadata())
        );
    }

    function _emptyMetadata() internal pure returns (JBRulesetMetadata memory) {
        return JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: 0,
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            scopeCashOutsToLocalBalances: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });
    }

    /// @notice Unscoped path calls sucker registry for remote values.
    function test_unscopedPath_callsSuckerRegistry() public {
        _mockCurrentRuleset(false);

        vm.expectCall(
            SUCKER_REGISTRY, abi.encodeWithSelector(IJBSuckerRegistry.remoteTotalSupplyOf.selector, REVNET_ID)
        );

        (uint256 amount,) = loans.borrowableAmountFrom(REVNET_ID, 100e18, 18, 1);
        assertGt(amount, 0, "unscoped borrowable amount should be non-zero");
    }

    /// @notice Scoped path does NOT call sucker registry.
    function test_scopedPath_doesNotCallSuckerRegistry() public {
        _mockCurrentRuleset(true);

        // If the scoped path tries to call remoteTotalSupplyOf, it will revert
        vm.mockCallRevert(
            SUCKER_REGISTRY,
            abi.encodeWithSelector(IJBSuckerRegistry.remoteTotalSupplyOf.selector, REVNET_ID),
            "should not call remoteTotalSupplyOf in scoped path"
        );

        (uint256 amount,) = loans.borrowableAmountFrom(REVNET_ID, 100e18, 18, 1);
        assertGt(amount, 0, "scoped borrowable amount should be non-zero");
    }

    /// @notice When no remote values exist, both paths produce the same result.
    function test_noRemote_sameResult() public {
        // Override remote to zero
        vm.mockCall(
            SUCKER_REGISTRY,
            abi.encodeWithSelector(IJBSuckerRegistry.remoteTotalSupplyOf.selector, REVNET_ID),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            SUCKER_REGISTRY, abi.encodeWithSelector(IJBSuckerRegistry.remoteSurplusOf.selector), abi.encode(uint256(0))
        );

        _mockCurrentRuleset(true);
        (uint256 scopedAmount,) = loans.borrowableAmountFrom(REVNET_ID, 100e18, 18, 1);

        _mockCurrentRuleset(false);
        (uint256 unscopedAmount,) = loans.borrowableAmountFrom(REVNET_ID, 100e18, 18, 1);

        assertEq(scopedAmount, unscopedAmount, "no remote: scoped and unscoped should match");
    }
}
