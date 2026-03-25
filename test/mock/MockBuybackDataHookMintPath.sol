// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Mock buyback hook that simulates the "mint path" — returns EMPTY hookSpecifications.
/// This is what the real JBBuybackHook does when direct minting is cheaper than swapping
/// (i.e., tokenCountWithoutHook >= minimumSwapAmountOut).
contract MockBuybackDataHookMintPath is IJBRulesetDataHook, IJBPayHook {
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        pure
        override
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        weight = context.weight;
        // Return EMPTY hookSpecifications — simulating the mint path where no swap is needed.
        hookSpecifications = new JBPayHookSpecification[](0);
    }

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        pure
        override
        returns (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        cashOutTaxRate = context.cashOutTaxRate;
        cashOutCount = context.cashOutCount;
        totalSupply = context.totalSupply;
        hookSpecifications = new JBCashOutHookSpecification[](0);
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
