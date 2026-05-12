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
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesets.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IREVLoans} from "../../src/interfaces/IREVLoans.sol";
import {REVOwner} from "../../src/REVOwner.sol";

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

/// @notice Regression test: when local surplus is exhausted by the non-fee reclaim, the cash-out fee must still be
/// preserved (scaled proportionally to local liquidity). Previously the fee was capped at `localSurplus - reclaim`,
/// which rounded to zero whenever `reclaim` consumed all local surplus.
contract CashOutFeeLocalCapScalingTest is TestBaseWorkflow {
    REVOwner internal ownerHook;
    MockSuckerRegistry internal suckerRegistry;
    EchoBuybackRegistry internal buybackRegistry;

    uint256 internal feeRevnetId;
    address internal projectOwner = address(0xBEEF);

    function setUp() public override {
        super.setUp();

        suckerRegistry = new MockSuckerRegistry();
        buybackRegistry = new EchoBuybackRegistry();

        // Launch a project that will serve as the fee revnet so DIRECTORY.primaryTerminalOf returns nonzero.
        JBAccountingContext[] memory tokens = new JBAccountingContext[](1);
        tokens[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBCurrencyIds.ETH});

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokens});

        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0] = JBRulesetConfig({
            mustStartAtOrAfter: 0,
            duration: 0,
            weight: 1e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
                reservedPercent: 0,
                cashOutTaxRate: 0,
                baseCurrency: JBCurrencyIds.ETH,
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
                scopeCashOutsToLocalBalances: true,
                useDataHookForPay: false,
                useDataHookForCashOut: false,
                dataHook: address(0),
                metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        feeRevnetId = jbController().launchProjectFor(projectOwner, "", rulesetConfigs, terminalConfigs, "");

        ownerHook = new REVOwner(
            IJBBuybackHookRegistry(address(buybackRegistry)),
            jbDirectory(),
            feeRevnetId,
            IJBSuckerRegistry(address(suckerRegistry)),
            IREVLoans(address(0)),
            address(this)
        );
    }

    /// @notice When local liquidity is exhausted by the non-fee reclaim, the fee spec must still surface a nonzero
    /// fee proportional to local liquidity. The previous implementation capped `feeAmount` at
    /// `localSurplus - reclaim` and dropped the fee to zero.
    function test_feeIsPreservedWhenLocalLiquidityExhaustedByReclaim() public {
        // Remote dominates effective surplus. Local liquidity is tiny relative to cross-chain effective surplus.
        suckerRegistry.setRemoteValues(0, 90 ether);

        // Build a context that, with the buggy math, makes the non-fee reclaim equal local surplus.
        // local=10, remote=90, effective=100. 500-of-1000 cashOut at 50% tax → grossReclaim ~36 ETH, capped at 10.
        JBBeforeCashOutRecordedContext memory context = JBBeforeCashOutRecordedContext({
            terminal: address(jbMultiTerminal()),
            holder: address(0xCAFE),
            projectId: feeRevnetId + 1, // distinct project id so this is not the fee revnet itself
            rulesetId: 0,
            cashOutCount: 500 ether,
            totalSupply: 1000 ether,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN, value: 10 ether, decimals: 18, currency: JBCurrencyIds.ETH
            }),
            scopeCashOutsToLocalBalances: false,
            cashOutTaxRate: 5000,
            beneficiaryIsFeeless: false,
            metadata: ""
        });

        (,,,, JBCashOutHookSpecification[] memory specs) = ownerHook.beforeCashOutRecordedWith(context);

        // Find the fee spec (one with hook == ownerHook and noop == false).
        bool foundFeeSpec;
        uint256 feeAmount;
        for (uint256 i; i < specs.length; ++i) {
            if (address(specs[i].hook) == address(ownerHook) && !specs[i].noop) {
                foundFeeSpec = true;
                feeAmount = specs[i].amount;
                break;
            }
        }

        assertTrue(foundFeeSpec, "fee spec must be attached when local liquidity caps the reclaim");
        assertGt(feeAmount, 0, "fee must be nonzero even when reclaim consumes all local surplus");

        // Fee + reclaim must not exceed local surplus.
        // Walk the specs to find the buyback hook's reported reclaim — when echo-routed it's zero because the
        // echo registry returns empty specs, so we can sanity check that the fee alone respects the cap.
        assertLe(feeAmount, 10 ether, "fee must respect local surplus cap");
    }

    /// @notice When effective surplus equals local surplus (no remote), the fee must equal what the previous
    /// implementation computed. This locks in backward compatibility for the simple case.
    function test_feeMatchesLegacyComputationWhenEffectiveEqualsLocal() public {
        suckerRegistry.setRemoteValues(0, 0);

        JBBeforeCashOutRecordedContext memory context = JBBeforeCashOutRecordedContext({
            terminal: address(jbMultiTerminal()),
            holder: address(0xCAFE),
            projectId: feeRevnetId + 1,
            rulesetId: 0,
            cashOutCount: 100 ether,
            totalSupply: 1000 ether,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN, value: 100 ether, decimals: 18, currency: JBCurrencyIds.ETH
            }),
            scopeCashOutsToLocalBalances: false,
            cashOutTaxRate: 5000,
            beneficiaryIsFeeless: false,
            metadata: ""
        });

        (,,,, JBCashOutHookSpecification[] memory specs) = ownerHook.beforeCashOutRecordedWith(context);

        uint256 feeAmount;
        for (uint256 i; i < specs.length; ++i) {
            if (address(specs[i].hook) == address(ownerHook) && !specs[i].noop) {
                feeAmount = specs[i].amount;
                break;
            }
        }

        // Reference computation: feeCount=2.5 of 100, reclaim from full surplus, fee from leftover.
        uint256 feeCount = (100 ether * 25) / 1000;
        uint256 nonFeeCount = 100 ether - feeCount;
        uint256 expectedReclaim = JBCashOuts.cashOutFrom(100 ether, nonFeeCount, 1000 ether, 5000);
        uint256 expectedFee =
            JBCashOuts.cashOutFrom(100 ether - expectedReclaim, feeCount, 1000 ether - nonFeeCount, 5000);

        assertEq(feeAmount, expectedFee, "fee in no-remote-surplus case must match legacy computation");
    }
}
