// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {REVLoans} from "../../src/REVLoans.sol";
import {REVOwner} from "../../src/REVOwner.sol";

contract RemoteLoanStateRegistryMock {
    uint256 public remoteSupply;
    uint256 public remoteSurplus;

    function setRemoteVisibleState(uint256 supply, uint256 surplus) external {
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

contract PassThroughBuybackRegistry is IJBRulesetDataHook {
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

contract BorrowableSurplusTerminalMock {
    uint256 public surplus;

    function setSurplus(uint256 newSurplus) external {
        surplus = newSurplus;
    }

    function currentSurplusOf(uint256, address[] calldata, uint256, uint256) external view returns (uint256) {
        return surplus;
    }
}

contract BorrowableControllerMock {
    address public immutable directory;
    address public immutable permissions;
    address public immutable prices;
    uint256 public totalSupply;

    constructor(address _directory, address _permissions, address _prices) {
        directory = _directory;
        permissions = _permissions;
        prices = _prices;
    }

    function setTotalSupply(uint256 newTotalSupply) external {
        totalSupply = newTotalSupply;
    }

    function DIRECTORY() external view returns (IJBDirectory) {
        return IJBDirectory(directory);
    }

    function PERMISSIONS() external view returns (IJBPermissions) {
        return IJBPermissions(permissions);
    }

    function PRICES() external view returns (IJBPrices) {
        return IJBPrices(prices);
    }

    function totalTokenSupplyWithReservedTokensOf(uint256) external view returns (uint256) {
        return totalSupply;
    }
}

contract BorrowableHarness is REVLoans {
    constructor(
        IJBController controller,
        IJBSuckerRegistry registry
    )
        REVLoans(controller, registry, 1, address(this), IPermit2(address(0)), address(0))
    {}

    function exposedBorrowableAmountFrom(
        uint256 revnetId,
        uint256 collateralCount,
        uint256 decimals,
        uint256 currency,
        IJBTerminal[] memory terminals,
        uint16 cashOutTaxRate
    )
        external
        view
        returns (uint256)
    {
        JBRulesetMetadata memory rulesetMetadata;
        rulesetMetadata.cashOutTaxRate = cashOutTaxRate;
        rulesetMetadata.baseCurrency = uint32(currency);
        rulesetMetadata.useTotalSurplusForCashOuts = true;

        JBRuleset memory currentStage = JBRuleset({
            cycleNumber: 0,
            id: 0,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadataResolver.packRulesetMetadata(rulesetMetadata)
        });

        return _borrowableAmountFrom({
            revnetId: revnetId,
            collateralCount: collateralCount,
            decimals: decimals,
            currency: currency,
            terminals: terminals,
            currentStage: currentStage
        });
    }
}

contract RemoteLoanStateOmissionTest is Test {
    address internal constant DIRECTORY = address(0x1001);
    address internal constant PERMISSIONS = address(0x1002);
    address internal constant PRICES = address(0x1003);
    address internal constant NATIVE_TOKEN = address(0x000000000000000000000000000000000000EEEe);

    uint256 internal constant REVNET_ID = 1;
    uint256 internal constant LOCAL_VISIBLE_SUPPLY = 100 ether;
    uint256 internal constant LOCAL_VISIBLE_SURPLUS = 100 ether;
    uint256 internal constant REMOTE_VISIBLE_SUPPLY = 1 ether;
    uint256 internal constant REMOTE_VISIBLE_SURPLUS = 1 ether;
    uint256 internal constant OMITTED_REMOTE_LOAN_COLLATERAL = 99 ether;
    uint256 internal constant OMITTED_REMOTE_LOAN_DEBT = 99 ether;
    uint256 internal constant CASH_OUT_OR_COLLATERAL = 100 ether;
    uint16 internal constant CASH_OUT_TAX_RATE = 1000;
    uint32 internal constant ETH_CURRENCY = 1;

    RemoteLoanStateRegistryMock internal registry;
    PassThroughBuybackRegistry internal buybackRegistry;
    REVOwner internal ownerHook;
    BorrowableControllerMock internal controller;
    BorrowableSurplusTerminalMock internal terminal;
    BorrowableHarness internal loansHarness;

    function setUp() external {
        registry = new RemoteLoanStateRegistryMock();
        buybackRegistry = new PassThroughBuybackRegistry();

        ownerHook = new REVOwner(
            IJBBuybackHookRegistry(address(buybackRegistry)),
            IJBDirectory(DIRECTORY),
            999_999,
            IJBSuckerRegistry(address(registry)),
            address(0),
            address(0)
        );

        controller = new BorrowableControllerMock(DIRECTORY, PERMISSIONS, PRICES);
        terminal = new BorrowableSurplusTerminalMock();
        loansHarness = new BorrowableHarness(IJBController(address(controller)), IJBSuckerRegistry(address(registry)));

        registry.setRemoteVisibleState(REMOTE_VISIBLE_SUPPLY, REMOTE_VISIBLE_SURPLUS);
        controller.setTotalSupply(LOCAL_VISIBLE_SUPPLY);
        terminal.setSurplus(LOCAL_VISIBLE_SURPLUS);

        vm.mockCall(
            DIRECTORY,
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector),
            abi.encode(IJBTerminal(address(0)))
        );
    }

    function test_remoteLoanStateOmissionInflatesCrossChainCashOutValue() external view {
        JBBeforeCashOutRecordedContext memory context = JBBeforeCashOutRecordedContext({
            terminal: address(0xCAFE),
            holder: address(0xBEEF),
            projectId: REVNET_ID,
            rulesetId: 0,
            cashOutCount: CASH_OUT_OR_COLLATERAL,
            totalSupply: LOCAL_VISIBLE_SUPPLY,
            surplus: JBTokenAmount({
                token: NATIVE_TOKEN, value: LOCAL_VISIBLE_SURPLUS, decimals: 18, currency: ETH_CURRENCY
            }),
            useTotalSurplus: true,
            cashOutTaxRate: CASH_OUT_TAX_RATE,
            beneficiaryIsFeeless: false,
            metadata: ""
        });

        (uint256 returnedTaxRate,, uint256 returnedSupply, uint256 returnedSurplus,) =
            ownerHook.beforeCashOutRecordedWith(context);

        uint256 quotedCashOut = JBCashOuts.cashOutFrom({
            surplus: returnedSurplus,
            cashOutCount: context.cashOutCount,
            totalSupply: returnedSupply,
            cashOutTaxRate: returnedTaxRate
        });

        uint256 trueOmnichainCashOut = JBCashOuts.cashOutFrom({
            surplus: returnedSurplus + OMITTED_REMOTE_LOAN_DEBT,
            cashOutCount: context.cashOutCount,
            totalSupply: returnedSupply + OMITTED_REMOTE_LOAN_COLLATERAL,
            cashOutTaxRate: returnedTaxRate
        });

        assertEq(returnedSupply, LOCAL_VISIBLE_SUPPLY + REMOTE_VISIBLE_SUPPLY, "hook only uses visible remote supply");
        assertEq(
            returnedSurplus, LOCAL_VISIBLE_SURPLUS + REMOTE_VISIBLE_SURPLUS, "hook only uses visible remote surplus"
        );
        assertGt(quotedCashOut, trueOmnichainCashOut, "omitting remote loan state should overstate cash-out value");
        assertGt(quotedCashOut - trueOmnichainCashOut, 4 ether, "cash-out overstatement should be material");
    }

    function test_remoteLoanStateOmissionInflatesCrossChainBorrowableAmount() external view {
        IJBTerminal[] memory terminals = new IJBTerminal[](1);
        terminals[0] = IJBTerminal(address(terminal));

        uint256 quotedBorrowable = loansHarness.exposedBorrowableAmountFrom({
            revnetId: REVNET_ID,
            collateralCount: CASH_OUT_OR_COLLATERAL,
            decimals: 18,
            currency: ETH_CURRENCY,
            terminals: terminals,
            cashOutTaxRate: CASH_OUT_TAX_RATE
        });

        uint256 visibleOnlyBorrowable = JBCashOuts.cashOutFrom({
            surplus: LOCAL_VISIBLE_SURPLUS + REMOTE_VISIBLE_SURPLUS,
            cashOutCount: CASH_OUT_OR_COLLATERAL,
            totalSupply: LOCAL_VISIBLE_SUPPLY + REMOTE_VISIBLE_SUPPLY,
            cashOutTaxRate: CASH_OUT_TAX_RATE
        });
        if (visibleOnlyBorrowable > LOCAL_VISIBLE_SURPLUS) visibleOnlyBorrowable = LOCAL_VISIBLE_SURPLUS;

        uint256 trueOmnichainBorrowable = JBCashOuts.cashOutFrom({
            surplus: LOCAL_VISIBLE_SURPLUS + REMOTE_VISIBLE_SURPLUS + OMITTED_REMOTE_LOAN_DEBT,
            cashOutCount: CASH_OUT_OR_COLLATERAL,
            totalSupply: LOCAL_VISIBLE_SUPPLY + REMOTE_VISIBLE_SUPPLY + OMITTED_REMOTE_LOAN_COLLATERAL,
            cashOutTaxRate: CASH_OUT_TAX_RATE
        });
        if (trueOmnichainBorrowable > LOCAL_VISIBLE_SURPLUS) trueOmnichainBorrowable = LOCAL_VISIBLE_SURPLUS;

        assertEq(quotedBorrowable, visibleOnlyBorrowable, "borrow quote uses visible remote state only");
        assertGt(
            quotedBorrowable, trueOmnichainBorrowable, "omitting remote loan state should overstate borrow capacity"
        );
        assertGt(quotedBorrowable - trueOmnichainBorrowable, 4 ether, "borrow overstatement should be material");
    }
}
