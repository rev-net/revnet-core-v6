// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IREVLoans} from "../../src/interfaces/IREVLoans.sol";
import {REVOwner} from "../../src/REVOwner.sol";

/// @notice Mock sucker registry that returns configurable remote values.
/// @dev All functions are view/pure to avoid StateChangeDuringStaticCall when called from
/// REVOwner.beforeCashOutRecordedWith (which is a view function).
contract MockSuckerRegistry {
    uint256 public remoteSurplusToReturn;
    uint256 public remoteSupplyToReturn;

    function setRemoteValues(uint256 supply, uint256 surplus) external {
        remoteSupplyToReturn = supply;
        remoteSurplusToReturn = surplus;
    }

    function isSuckerOf(uint256, address) external pure returns (bool) {
        return false;
    }

    function remoteTotalSupplyOf(uint256) external view returns (uint256) {
        return remoteSupplyToReturn;
    }

    function remoteSurplusOf(uint256, uint256, uint256) external view returns (uint256) {
        return remoteSurplusToReturn;
    }
}

/// @notice Minimal echo buyback registry that passes through cash out context unchanged.
contract EchoBuybackRegistry is IJBRulesetDataHook {
    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        pure
        returns (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        cashOutTaxRate = context.cashOutTaxRate;
        cashOutCount = context.cashOutCount;
        totalSupply = context.totalSupply;
        effectiveSurplusValue = context.surplus.value;
        hookSpecifications = new JBCashOutHookSpecification[](0);
    }

    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        pure
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        weight = context.weight;
        hookSpecifications = new JBPayHookSpecification[](0);
    }

    function hasMintPermissionFor(uint256, JBRuleset calldata, address) external pure returns (bool) {
        return false;
    }

    function setPoolFor(uint256, PoolKey calldata, uint256, address) external pure {}
    function setPoolFor(uint256, uint24, int24, uint256, address) external pure {}
    function initializePoolFor(uint256, uint24, int24, uint256, address, uint160) external pure {}

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBRulesetDataHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice REVOwner.beforeCashOutRecordedWith should pass the surplus currency (not the token address) to
/// remoteSurplusOf. @dev `currency: uint256(context.surplus.currency)` passes the correct currency value,
/// not `uint256(uint160(context.surplus.token))` which would pass the token address (e.g. 61166 for NATIVE_TOKEN).
contract REVOwnerCurrencyMismatchTest is TestBaseWorkflow {
    REVOwner internal ownerHook;
    MockSuckerRegistry internal suckerRegistry;
    EchoBuybackRegistry internal buybackRegistry;

    function setUp() public override {
        super.setUp();

        suckerRegistry = new MockSuckerRegistry();
        buybackRegistry = new EchoBuybackRegistry();

        ownerHook = new REVOwner(
            IJBBuybackHookRegistry(address(buybackRegistry)),
            jbDirectory(),
            999_999, // fee revnet ID (won't be used in this test path)
            IJBSuckerRegistry(address(suckerRegistry)),
            IREVLoans(address(0)), // loans
            address(0) // hidden tokens
        );
    }

    /// @notice Verify that remoteSurplusOf is called with the context's currency, not the token address.
    /// @dev NATIVE_TOKEN = 0x000000000000000000000000000000000000EEEe
    ///      uint160(NATIVE_TOKEN) = 61166
    ///      The correct currency for ETH is 1 (baseCurrency).
    ///      Before the fix, 61166 was passed. After the fix, 1 is passed.
    function test_remoteSurplusOf_receives_currency_not_token_address() public {
        // Set up remote values so the registry returns something.
        suckerRegistry.setRemoteValues(500 ether, 900 ether);

        uint32 ethCurrency = 1; // ETH baseCurrency identifier

        // Build a context where surplus.token = NATIVE_TOKEN and surplus.currency = 1 (ETH).
        // These are intentionally different values to detect the bug.
        JBBeforeCashOutRecordedContext memory context = JBBeforeCashOutRecordedContext({
            terminal: address(jbMultiTerminal()),
            holder: address(0xCAFE),
            projectId: 1,
            rulesetId: 0,
            cashOutCount: 100 ether,
            totalSupply: 1000 ether,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN, // 0xEEEe
                value: 100 ether,
                decimals: 18,
                currency: ethCurrency // 1
            }),
            useTotalSurplus: true,
            cashOutTaxRate: 0, // zero tax = feeless path (simpler, avoids needing fee terminal)
            beneficiaryIsFeeless: false,
            metadata: ""
        });

        // Use vm.expectCall to verify the exact parameters passed to remoteSurplusOf.
        // After fix: currency should be 1 (ethCurrency), NOT 61166 (uint160(NATIVE_TOKEN)).
        // This assertion will fail if the buggy code passes uint256(uint160(NATIVE_TOKEN)) = 61166.
        vm.expectCall(
            address(suckerRegistry), abi.encodeCall(suckerRegistry.remoteSurplusOf, (1, 18, uint256(ethCurrency)))
        );

        ownerHook.beforeCashOutRecordedWith(context);
    }

    /// @notice Verify that the remote surplus is actually included in the returned effectiveSurplusValue.
    /// @dev This is a regression test: if the wrong currency is passed, the registry might return 0
    ///      and the remote surplus would be silently dropped.
    function test_remoteSurplus_included_in_effectiveSurplus() public {
        suckerRegistry.setRemoteValues(500 ether, 900 ether);

        uint32 ethCurrency = 1;

        JBBeforeCashOutRecordedContext memory context = JBBeforeCashOutRecordedContext({
            terminal: address(jbMultiTerminal()),
            holder: address(0xCAFE),
            projectId: 1,
            rulesetId: 0,
            cashOutCount: 100 ether,
            totalSupply: 1000 ether,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN, value: 100 ether, decimals: 18, currency: ethCurrency
            }),
            useTotalSurplus: true,
            cashOutTaxRate: 0,
            beneficiaryIsFeeless: false,
            metadata: ""
        });

        (,, uint256 returnedSupply, uint256 returnedSurplus,) = ownerHook.beforeCashOutRecordedWith(context);

        // Remote supply should be added.
        assertEq(returnedSupply, 1500 ether, "totalSupply should include remote supply");

        // Remote surplus should be added (100 local + 900 remote = 1000).
        assertEq(
            returnedSurplus, 1000 ether, "effectiveSurplusValue should include remote surplus (100 local + 900 remote)"
        );
    }
}
