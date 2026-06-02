// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";

import {IREVDeployer} from "../../src/interfaces/IREVDeployer.sol";
import {IREVLoans} from "../../src/interfaces/IREVLoans.sol";
import {REVOwner} from "../../src/REVOwner.sol";

/// @notice Regression test for `REVOwner.beforeCashOutRecordedWith` remote-accounting boundaries.
///         Normal holder cash-outs respect `scopeCashOutsToLocalBalances`: scoped excludes remote values, unscoped
///         includes them. Sucker bridge cash-outs intentionally use local backing in both modes so token movement is
///         proportional to funds on the source chain.
contract ScopeCashOutsToLocalBalancesConditionalTest is Test {
    REVOwner revOwner;

    address constant BUYBACK_HOOK = address(0x1111);
    address constant DIRECTORY = address(0x2222);
    address constant SUCKER_REGISTRY = address(0x3333);
    address constant LOANS = address(0x4444);
    address constant FEE_TERMINAL = address(0x6666);
    address constant HOLDER = address(0x7777);
    address constant SUCKER = address(0x7778);
    address constant TOKEN = address(0x8888);

    uint256 constant REVNET_ID = 10;
    uint256 constant FEE_REVNET_ID = 1;

    // Local values
    uint256 constant LOCAL_SUPPLY = 1000e18;
    uint256 constant LOCAL_SURPLUS = 50e18;
    uint256 constant CASH_OUT_COUNT = 100e18;
    uint256 constant CASH_OUT_TAX_RATE = 5000; // 50%

    // Remote values
    uint256 constant REMOTE_SUPPLY = 500e18;
    uint256 constant REMOTE_SURPLUS = 25e18;

    function setUp() public {
        // Deploy mock addresses with code
        vm.etch(BUYBACK_HOOK, hex"00");
        vm.etch(DIRECTORY, hex"00");
        vm.etch(SUCKER_REGISTRY, hex"00");
        vm.etch(LOANS, hex"00");
        vm.etch(FEE_TERMINAL, hex"00");

        // Deploy REVOwner
        revOwner = new REVOwner(
            IJBBuybackHookRegistry(BUYBACK_HOOK),
            IJBDirectory(DIRECTORY),
            FEE_REVNET_ID,
            IJBSuckerRegistry(SUCKER_REGISTRY),
            IREVLoans(LOANS),
            address(this)
        );

        // Stub the deployer references read during `setDeployer`. The test contract impersonates the deployer,
        // so its `CONTROLLER`/`PERMISSIONS`/`PROJECTS` getters need defined return data. Real deployments wire
        // these to live contracts.
        _mockDeployerImmutables();

        // Bind deployer
        revOwner.setDeployer(IREVDeployer(address(this)));

        // Mock: holder is NOT a sucker
        vm.mockCall(
            SUCKER_REGISTRY, abi.encodeCall(IJBSuckerRegistry.isSuckerOf, (REVNET_ID, HOLDER)), abi.encode(false)
        );
        vm.mockCall(
            SUCKER_REGISTRY, abi.encodeCall(IJBSuckerRegistry.isSuckerOf, (REVNET_ID, SUCKER)), abi.encode(true)
        );

        // Mock: fee terminal exists
        vm.mockCall(
            DIRECTORY, abi.encodeCall(IJBDirectory.primaryTerminalOf, (FEE_REVNET_ID, TOKEN)), abi.encode(FEE_TERMINAL)
        );

        // Mock: loans returns zero (no outstanding loans)
        vm.mockCall(LOANS, abi.encodeCall(IREVLoans.totalCollateralOf, (REVNET_ID)), abi.encode(uint256(0)));
        address[] memory emptySources = new address[](0);
        vm.mockCall(LOANS, abi.encodeCall(IREVLoans.loanSourceTokensOf, (REVNET_ID)), abi.encode(emptySources));

        // Mock: sucker registry remote values
        vm.mockCall(
            SUCKER_REGISTRY,
            abi.encodeCall(IJBSuckerRegistry.remoteTotalSupplyOf, (REVNET_ID)),
            abi.encode(REMOTE_SUPPLY)
        );
        vm.mockCall(
            SUCKER_REGISTRY,
            abi.encodeCall(IJBSuckerRegistry.totalRemoteSurplusOf, (REVNET_ID, uint256(1), 18)),
            abi.encode(REMOTE_SURPLUS)
        );

        // Mock: buyback hook returns passthrough values
        // We need a wildcard mock for the buyback hook's beforeCashOutRecordedWith
        // It should return (cashOutTaxRate, cashOutCount, 0, 0, empty specs)
        vm.mockCall(
            BUYBACK_HOOK,
            abi.encodeWithSelector(IJBRulesetDataHook.beforeCashOutRecordedWith.selector),
            abi.encode(
                CASH_OUT_TAX_RATE,
                CASH_OUT_COUNT - (CASH_OUT_COUNT * 25 / 1000), // non-fee portion
                uint256(0),
                uint256(0),
                new JBCashOutHookSpecification[](0)
            )
        );
    }

    /// @notice Mock the three immutable getters REVOwner reads from the deployer during `setDeployer`. The test
    /// contract impersonates the deployer, so it needs defined return data for these calls. Also stubs the
    /// downstream `PERMISSIONS.setPermissionsFor` calls REVOwner issues during the wildcard permission grants.
    function _mockDeployerImmutables() internal {
        bytes memory permissionsStub = hex"00";
        address permissionsAddr = address(0xBA5E);
        vm.etch(permissionsAddr, permissionsStub);

        vm.mockCall(address(this), abi.encodeWithSignature("CONTROLLER()"), abi.encode(address(0)));
        vm.mockCall(address(this), abi.encodeWithSignature("PERMISSIONS()"), abi.encode(permissionsAddr));
        vm.mockCall(address(this), abi.encodeWithSignature("PROJECTS()"), abi.encode(address(0)));

        // The wildcard permission grants inside `setDeployer` call `setPermissionsFor` on the resolved
        // permissions address. Accept them as no-ops.
        vm.mockCall(
            permissionsAddr,
            abi.encodeWithSelector(bytes4(keccak256("setPermissionsFor(address,(address,uint64,uint8[]))"))),
            bytes("")
        );
    }

    function _buildContext(bool scopeToLocal) internal pure returns (JBBeforeCashOutRecordedContext memory) {
        return _buildContextFor({holder: HOLDER, scopeToLocal: scopeToLocal});
    }

    function _buildContextFor(
        address holder,
        bool scopeToLocal
    )
        internal
        pure
        returns (JBBeforeCashOutRecordedContext memory)
    {
        return JBBeforeCashOutRecordedContext({
            terminal: address(0),
            holder: holder,
            projectId: REVNET_ID,
            rulesetId: 1,
            cashOutCount: CASH_OUT_COUNT,
            totalSupply: LOCAL_SUPPLY,
            surplus: JBTokenAmount({token: TOKEN, decimals: 18, currency: 1, value: LOCAL_SURPLUS}),
            scopeCashOutsToLocalBalances: scopeToLocal,
            cashOutTaxRate: CASH_OUT_TAX_RATE,
            beneficiaryIsFeeless: false,
            metadata: bytes("")
        });
    }

    /// @notice When scopeCashOutsToLocalBalances is TRUE, remote supply/surplus must NOT be added.
    function test_scopeTrue_excludesRemote() public view {
        JBBeforeCashOutRecordedContext memory ctx = _buildContext(true);

        (,, uint256 totalSupply, uint256 effectiveSurplus,) = revOwner.beforeCashOutRecordedWith(ctx);

        // Should equal local values only (no remote added)
        assertEq(totalSupply, LOCAL_SUPPLY, "totalSupply should be local-only when scoped");
        assertEq(effectiveSurplus, LOCAL_SURPLUS, "effectiveSurplus should be local-only when scoped");
    }

    /// @notice When scopeCashOutsToLocalBalances is FALSE, remote supply/surplus MUST be included.
    function test_scopeFalse_includesRemote() public view {
        JBBeforeCashOutRecordedContext memory ctx = _buildContext(false);

        (,, uint256 totalSupply, uint256 effectiveSurplus,) = revOwner.beforeCashOutRecordedWith(ctx);

        // Should include remote values
        assertEq(totalSupply, LOCAL_SUPPLY + REMOTE_SUPPLY, "totalSupply should include remote when not scoped");
        assertEq(
            effectiveSurplus, LOCAL_SURPLUS + REMOTE_SURPLUS, "effectiveSurplus should include remote when not scoped"
        );
    }

    /// @notice Sucker cash-outs are tax/fee exempt and use local backing even when the ruleset is unscoped.
    function test_suckerScopeFalse_usesLocalBacking() public view {
        JBBeforeCashOutRecordedContext memory ctx = _buildContextFor({holder: SUCKER, scopeToLocal: false});

        (
            uint256 cashOutTaxRate,
            uint256 effectiveCashOutCount,
            uint256 totalSupply,
            uint256 effectiveSurplus,
            JBCashOutHookSpecification[] memory specs
        ) = revOwner.beforeCashOutRecordedWith(ctx);

        assertEq(cashOutTaxRate, 0, "sucker cash-out should remain tax exempt");
        assertEq(effectiveCashOutCount, CASH_OUT_COUNT, "sucker should cash out the requested count");
        assertEq(totalSupply, LOCAL_SUPPLY, "sucker totalSupply should use local backing even when not scoped");
        assertEq(
            effectiveSurplus, LOCAL_SURPLUS, "sucker effectiveSurplus should use local backing even when not scoped"
        );
        assertEq(specs.length, 0, "sucker cash-out should not attach fee specs");
    }

    /// @notice Scoped sucker cash-outs remain local-only.
    function test_suckerScopeTrue_excludesRemote() public view {
        JBBeforeCashOutRecordedContext memory ctx = _buildContextFor({holder: SUCKER, scopeToLocal: true});

        (
            uint256 cashOutTaxRate,,
            uint256 totalSupply,
            uint256 effectiveSurplus,
            JBCashOutHookSpecification[] memory specs
        ) = revOwner.beforeCashOutRecordedWith(ctx);

        assertEq(cashOutTaxRate, 0, "sucker cash-out should remain tax exempt");
        assertEq(totalSupply, LOCAL_SUPPLY, "sucker totalSupply should be local-only when scoped");
        assertEq(effectiveSurplus, LOCAL_SURPLUS, "sucker effectiveSurplus should be local-only when scoped");
        assertEq(specs.length, 0, "sucker cash-out should not attach fee specs");
    }

    /// @notice When scoped to local but there are no suckers, result is the same as local-only.
    function test_scopeTrue_noSuckers_sameAsLocal() public {
        // Mock: remote values are zero (no suckers registered)
        vm.mockCall(
            SUCKER_REGISTRY, abi.encodeCall(IJBSuckerRegistry.remoteTotalSupplyOf, (REVNET_ID)), abi.encode(uint256(0))
        );
        vm.mockCall(
            SUCKER_REGISTRY,
            abi.encodeCall(IJBSuckerRegistry.totalRemoteSurplusOf, (REVNET_ID, uint256(1), 18)),
            abi.encode(uint256(0))
        );

        JBBeforeCashOutRecordedContext memory ctxScoped = _buildContext(true);
        JBBeforeCashOutRecordedContext memory ctxUnscoped = _buildContext(false);

        (,, uint256 supplyScoped, uint256 surplusScoped,) = revOwner.beforeCashOutRecordedWith(ctxScoped);
        (,, uint256 supplyUnscoped, uint256 surplusUnscoped,) = revOwner.beforeCashOutRecordedWith(ctxUnscoped);

        // Both should be identical when there are no remote values
        assertEq(supplyScoped, supplyUnscoped, "supply should match when no remote peers");
        assertEq(surplusScoped, surplusUnscoped, "surplus should match when no remote peers");
    }
}
