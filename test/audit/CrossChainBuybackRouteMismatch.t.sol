// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IREVLoans} from "../../src/interfaces/IREVLoans.sol";
import {REVOwner} from "../../src/REVOwner.sol";

contract ConfigurableSuckerRegistry {
    uint256 public remoteSupply;
    uint256 public remoteSurplus;

    function setRemoteTotals(uint256 supply, uint256 surplus) external {
        remoteSupply = supply;
        remoteSurplus = surplus;
    }

    function isSuckerOf(uint256, address) external pure returns (bool) {
        return false;
    }

    function remoteTotalSupplyOf(uint256) external view returns (uint256) {
        return remoteSupply;
    }

    function remoteSurplusOf(uint256, uint256, uint256) external view returns (uint256) {
        return remoteSurplus;
    }
}

contract ThresholdBuybackRegistry is IJBRulesetDataHook {
    uint256 public immutable minimumSwapAmountOut;

    constructor(uint256 minAmountOut) {
        minimumSwapAmountOut = minAmountOut;
    }

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        view
        returns (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        uint256 directCashOutAmount = JBCashOuts.cashOutFrom({
            surplus: context.surplus.value,
            cashOutCount: context.cashOutCount,
            totalSupply: context.totalSupply,
            cashOutTaxRate: context.cashOutTaxRate
        });

        hookSpecifications = new JBCashOutHookSpecification[](1);
        hookSpecifications[0] = JBCashOutHookSpecification({
            hook: IJBCashOutHook(address(this)),
            noop: directCashOutAmount >= minimumSwapAmountOut,
            amount: 0,
            metadata: ""
        });

        cashOutTaxRate =
            directCashOutAmount >= minimumSwapAmountOut ? context.cashOutTaxRate : JBConstants.MAX_CASH_OUT_TAX_RATE;
        cashOutCount = context.cashOutCount;
        totalSupply = context.totalSupply;
        effectiveSurplusValue = 0;
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

contract CodexCrossChainBuybackRouteMismatchTest is TestBaseWorkflow {
    REVOwner internal ownerHook;
    ConfigurableSuckerRegistry internal suckerRegistry;
    ThresholdBuybackRegistry internal buybackRegistry;

    function setUp() public override {
        super.setUp();

        suckerRegistry = new ConfigurableSuckerRegistry();
        buybackRegistry = new ThresholdBuybackRegistry(50 ether);

        ownerHook = new REVOwner(
            IJBBuybackHookRegistry(address(buybackRegistry)),
            jbDirectory(),
            999_999,
            IJBSuckerRegistry(address(suckerRegistry)),
            IREVLoans(address(0)),
            address(0)
        );
    }

    function test_buybackRouteUsesOmnichainContextForRouting() public {
        suckerRegistry.setRemoteTotals(0, 900 ether);

        JBBeforeCashOutRecordedContext memory context = JBBeforeCashOutRecordedContext({
            terminal: address(jbMultiTerminal()),
            holder: address(0xBEEF),
            projectId: 1,
            rulesetId: 0,
            cashOutCount: 100,
            totalSupply: 1000,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 100 ether,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            useTotalSurplus: true,
            cashOutTaxRate: 0,
            beneficiaryIsFeeless: false,
            metadata: ""
        });

        uint256 localDirectCashOut = JBCashOuts.cashOutFrom({
            surplus: context.surplus.value,
            cashOutCount: context.cashOutCount,
            totalSupply: context.totalSupply,
            cashOutTaxRate: context.cashOutTaxRate
        });
        uint256 omnichainDirectCashOut = JBCashOuts.cashOutFrom({
            surplus: context.surplus.value + 900 ether,
            cashOutCount: context.cashOutCount,
            totalSupply: context.totalSupply,
            cashOutTaxRate: context.cashOutTaxRate
        });

        assertLt(localDirectCashOut, 50 ether, "local route should prefer swap in the mock");
        assertGe(omnichainDirectCashOut, 50 ether, "omnichain route should prefer direct reclaim");

        (uint256 returnedTaxRate,, uint256 returnedSupply, uint256 returnedSurplus,) =
            ownerHook.beforeCashOutRecordedWith(context);

        // After the fix, REVOwner forwards the cross-chain-adjusted context to the buyback hook.
        // The buyback hook now sees the full omnichain surplus (1000 ether) and correctly routes
        // to direct reclaim (passthrough) instead of swap.
        assertEq(returnedSupply, context.totalSupply, "owner returns cross-chain total supply");
        assertEq(returnedSurplus, context.surplus.value + 900 ether, "owner returns cross-chain effective surplus");
        // With omnichain context, the direct reclaim (100 ether) exceeds the threshold (50 ether),
        // so the buyback hook chooses passthrough (returns the original cashOutTaxRate of 0).
        assertEq(
            returnedTaxRate,
            context.cashOutTaxRate,
            "routing correctly uses omnichain context - direct reclaim beats threshold"
        );
    }
}
