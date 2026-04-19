// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBBuybackHook} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHook.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice A minimal mock buyback data hook for tests. Returns the default weight and a no-op pay hook specification.
contract MockBuybackDataHook is IJBRulesetDataHook, IJBPayHook {
    bool public shouldReturnCashOutHookSpec;
    uint256 public cashOutCountToReturn;
    bytes public cashOutHookMetadata;
    uint256 public cashOutHookAmount;
    uint256 public cashOutTaxRateToReturn;
    uint256 public totalSupplyToReturn;

    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        override
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        weight = context.weight;
        hookSpecifications = new JBPayHookSpecification[](1);
        hookSpecifications[0] =
            JBPayHookSpecification({hook: IJBPayHook(address(this)), noop: false, amount: 0, metadata: ""});
    }

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        view
        override
        returns (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        cashOutTaxRate = cashOutTaxRateToReturn == 0 ? context.cashOutTaxRate : cashOutTaxRateToReturn;
        cashOutCount = cashOutCountToReturn == 0 ? context.cashOutCount : cashOutCountToReturn;
        totalSupply = totalSupplyToReturn == 0 ? context.totalSupply : totalSupplyToReturn;
        effectiveSurplusValue = 0;

        if (!shouldReturnCashOutHookSpec) {
            hookSpecifications = new JBCashOutHookSpecification[](0);
            return (cashOutTaxRate, cashOutCount, totalSupply, effectiveSurplusValue, hookSpecifications);
        }

        hookSpecifications = new JBCashOutHookSpecification[](1);
        hookSpecifications[0] = JBCashOutHookSpecification({
            hook: IJBCashOutHook(address(this)), noop: false, amount: cashOutHookAmount, metadata: cashOutHookMetadata
        });
    }

    function configureCashOutResult(
        uint256 cashOutTaxRate,
        uint256 cashOutCount,
        uint256 totalSupply,
        uint256 hookAmount,
        bytes calldata hookMetadata
    )
        external
    {
        shouldReturnCashOutHookSpec = true;
        cashOutTaxRateToReturn = cashOutTaxRate;
        cashOutCountToReturn = cashOutCount;
        totalSupplyToReturn = totalSupply;
        cashOutHookAmount = hookAmount;
        cashOutHookMetadata = hookMetadata;
    }

    function resetCashOutResult() external {
        shouldReturnCashOutHookSpec = false;
        cashOutTaxRateToReturn = 0;
        cashOutCountToReturn = 0;
        totalSupplyToReturn = 0;
        cashOutHookAmount = 0;
        cashOutHookMetadata = "";
    }

    function hasMintPermissionFor(uint256, JBRuleset calldata, address) external pure override returns (bool) {
        return false;
    }

    function afterPayRecordedWith(JBAfterPayRecordedContext calldata) external payable override {}

    /// @notice No-op pool configuration for tests (PoolKey overload).
    function setPoolFor(uint256, PoolKey calldata, uint256, address) external pure {}

    /// @notice No-op pool configuration for tests (simplified overload).
    function setPoolFor(uint256, uint24, int24, uint256, address) external pure {}

    /// @notice No-op pool initialization for tests.
    function initializePoolFor(uint256, uint24, int24, uint256, address, uint160) external pure {}

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IJBRulesetDataHook).interfaceId || interfaceId == type(IJBPayHook).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}
