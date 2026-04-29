// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {REVOwner} from "../../src/REVOwner.sol";

contract CurrencyAwareSuckerRegistry {
    uint256 public expectedCurrency;
    uint256 public remoteSupply;
    uint256 public remoteSurplus;

    function setRemoteValues(uint256 currency, uint256 supply, uint256 surplus) external {
        expectedCurrency = currency;
        remoteSupply = supply;
        remoteSurplus = surplus;
    }

    function isSuckerOf(uint256, address) external pure returns (bool) {
        return false;
    }

    function remoteTotalSupplyOf(uint256) external view returns (uint256) {
        return remoteSupply;
    }

    function remoteSurplusOf(uint256, uint256, uint256 currency) external view returns (uint256) {
        return currency == expectedCurrency ? remoteSurplus : 0;
    }
}

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

contract REVOwnerRemoteSurplusCurrencyMismatchTest is TestBaseWorkflow {
    REVOwner internal ownerHook;
    CurrencyAwareSuckerRegistry internal suckerRegistry;
    EchoBuybackRegistry internal buybackRegistry;

    uint32 internal constant ETH_CURRENCY = 1;

    function setUp() public override {
        super.setUp();

        suckerRegistry = new CurrencyAwareSuckerRegistry();
        buybackRegistry = new EchoBuybackRegistry();

        ownerHook = new REVOwner(
            IJBBuybackHookRegistry(address(buybackRegistry)),
            jbDirectory(),
            999_999,
            IJBSuckerRegistry(address(suckerRegistry)),
            address(0),
            address(0)
        );
    }

    function test_beforeCashOutRecordedWith_usesTokenAddressInsteadOfCurrencyForRemoteSurplus() public {
        suckerRegistry.setRemoteValues(ETH_CURRENCY, 500 ether, 900 ether);

        address usdToken = address(0xBEEF);

        JBBeforeCashOutRecordedContext memory context = JBBeforeCashOutRecordedContext({
            terminal: address(jbMultiTerminal()),
            holder: address(0xCAFE),
            projectId: 1,
            rulesetId: 0,
            cashOutCount: 100 ether,
            totalSupply: 1000 ether,
            surplus: JBTokenAmount({token: usdToken, value: 100 ether, decimals: 18, currency: ETH_CURRENCY}),
            useTotalSurplus: true,
            cashOutTaxRate: 0,
            beneficiaryIsFeeless: false,
            metadata: ""
        });

        (,, uint256 returnedSupply, uint256 returnedSurplus,) = ownerHook.beforeCashOutRecordedWith(context);

        assertEq(returnedSupply, 1500 ether, "remote supply should still be included");
        // Remote surplus is correctly included (100 local + 900 remote = 1000) because the currency is passed to
        // remoteSurplusOf.
        assertEq(returnedSurplus, 1000 ether, "remote surplus should be included now that currency is passed correctly");
        assertEq(
            suckerRegistry.remoteSurplusOf(1, 18, ETH_CURRENCY),
            900 ether,
            "registry confirms surplus exists for the requested currency"
        );
    }
}
