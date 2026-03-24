// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBAfterCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterCashOutRecordedContext.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract MockBuybackCashOutRecorder is IJBRulesetDataHook, IJBPayHook, IJBCashOutHook {
    uint256 public afterCashOutCount;
    address public lastBeneficiary;

    // Pure: does not read or modify state, only returns values derived from calldata.
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        pure
        override
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        weight = context.weight;
        hookSpecifications = new JBPayHookSpecification[](0);
    }

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        view
        override
        returns (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        cashOutTaxRate = JBConstants.MAX_CASH_OUT_TAX_RATE;
        cashOutCount = context.cashOutCount;
        totalSupply = context.totalSupply;
        hookSpecifications = new JBCashOutHookSpecification[](1);
        hookSpecifications[0] = JBCashOutHookSpecification({
            hook: IJBCashOutHook(address(this)),
            noop: false,
            amount: 0,
            metadata: abi.encode(uint256(0), context.cashOutCount)
        });
    }

    function afterCashOutRecordedWith(JBAfterCashOutRecordedContext calldata context) external payable override {
        // Decode the cashOutCount from metadata (matching the real buyback hook's metadata passthrough).
        if (context.hookMetadata.length != 0) {
            (, afterCashOutCount) = abi.decode(context.hookMetadata, (uint256, uint256));
        } else {
            afterCashOutCount = context.cashOutCount;
        }
        lastBeneficiary = context.beneficiary;
    }

    function afterPayRecordedWith(JBAfterPayRecordedContext calldata) external payable override {}

    function hasMintPermissionFor(uint256, JBRuleset memory, address) external pure override returns (bool) {
        return false;
    }

    function setPoolFor(uint256, PoolKey calldata, uint256, address) external pure {}

    function setPoolFor(uint256, uint24, int24, uint256, address) external pure {}

    function initializePoolFor(uint256, uint24, int24, uint256, address, uint160) external pure {}

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IJBRulesetDataHook).interfaceId || interfaceId == type(IJBCashOutHook).interfaceId
            || interfaceId == type(IJBPayHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
