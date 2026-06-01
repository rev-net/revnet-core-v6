// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBPayoutTerminal} from "@bananapus/core-v6/src/interfaces/IJBPayoutTerminal.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IREVDeployer} from "../../src/interfaces/IREVDeployer.sol";
import {IREVLoans} from "../../src/interfaces/IREVLoans.sol";
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

/// @notice Minimal loans contract exposing one outstanding loan source for peer-snapshot accounting.
contract PeerSnapshotLoanStateMock {
    IJBPrices public immutable PRICES;

    address[] internal _sources;
    uint256 internal immutable _borrowed;
    uint256 internal immutable _collateral;

    constructor(address sourceToken, uint256 borrowed, uint256 collateral) {
        // Same-currency accounting in this test never touches prices, but REVOwner expects the getter to exist.
        PRICES = IJBPrices(address(0));
        _sources.push(sourceToken);
        _borrowed = borrowed;
        _collateral = collateral;
    }

    function loanSourceTokensOf(uint256) external view returns (address[] memory) {
        return _sources;
    }

    function totalBorrowedFrom(uint256, address token) external view returns (uint256) {
        return token == _sources[0] ? _borrowed : 0;
    }

    function totalCollateralOf(uint256) external view returns (uint256) {
        return _collateral;
    }
}

/// @notice Minimal terminal that returns the accounting context for the tested loan source token.
contract PeerSnapshotTerminalMock {
    uint32 internal immutable _currency;
    address internal immutable _sourceToken;

    constructor(address sourceToken, uint32 currency) {
        _sourceToken = sourceToken;
        _currency = currency;
    }

    function accountingContextForTokenOf(uint256, address token) external view returns (JBAccountingContext memory) {
        return JBAccountingContext({token: token, decimals: 18, currency: token == _sourceToken ? _currency : 0});
    }
}

/// @notice No-op permissions registry used by `PeerSnapshotDeployerMock` to satisfy `REVOwner.setDeployer`'s
/// wildcard permission grants during isolated tests.
contract NoopPermissionsMock {
    // forge-lint: disable-next-line(mixed-case-function)
    function setPermissionsFor(address, JBPermissionsData calldata) external {}

    function hasPermission(address, address, uint256, uint8, bool, bool) external pure returns (bool) {
        return false;
    }

    function hasPermissions(address, address, uint256, uint256[] calldata, bool, bool) external pure returns (bool) {
        return false;
    }
}

/// @notice Minimal deployer exposing the canonical multi terminal expected by REVOwner.
contract PeerSnapshotDeployerMock {
    IJBTerminal public immutable MULTI_TERMINAL;
    IJBController public immutable CONTROLLER;
    IJBPermissions public immutable PERMISSIONS;
    IJBProjects public immutable PROJECTS;

    constructor(IJBTerminal multiTerminal) {
        MULTI_TERMINAL = multiTerminal;
        CONTROLLER = IJBController(address(0));
        PERMISSIONS = IJBPermissions(address(new NoopPermissionsMock()));
        PROJECTS = IJBProjects(address(0));
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
        IJBPayoutTerminal terminal,
        IJBSuckerRegistry registry
    )
        REVLoans(controller, terminal, registry, 1, address(this), IPermit2(address(0)), address(0))
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
        // forge-lint: disable-next-line(unsafe-typecast)
        rulesetMetadata.baseCurrency = uint32(currency);
        rulesetMetadata.scopeCashOutsToLocalBalances = false;

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

        // Surface the economic ceiling — repay and reallocate value collateral against this same figure, and the
        // cross-chain over-statement being measured here lives in this ceiling, not in the live terminal balance.
        (uint256 borrowableCapacity,) = _borrowableAmountFrom({
            revnetId: revnetId,
            collateralCount: collateralCount,
            decimals: decimals,
            currency: currency,
            multiTerminal: terminals[0],
            currentStage: currentStage
        });
        return borrowableCapacity;
    }
}

/// @notice Negative-control and export tests for Revnet loan state in cross-chain accounting.
/// @dev Real Revnet suckers include `REVOwner.peerChainAdjustedAccountsOf(...)` in outbound snapshots. The omission
/// tests below use a synthetic registry that leaves those adjustments out to quantify the consequence when remote
/// snapshots are stale, missing, or produced by a non-adjusting hook.
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
            IREVLoans(address(0)),
            address(this)
        );

        controller = new BorrowableControllerMock(DIRECTORY, PERMISSIONS, PRICES);
        terminal = new BorrowableSurplusTerminalMock();
        loansHarness = new BorrowableHarness({
            controller: IJBController(address(controller)),
            terminal: IJBPayoutTerminal(address(terminal)),
            registry: IJBSuckerRegistry(address(registry))
        });

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
            scopeCashOutsToLocalBalances: false,
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

    function test_revOwnerExportsLocalLoanStateForPeerSnapshots() external {
        PeerSnapshotLoanStateMock loans = new PeerSnapshotLoanStateMock({
            sourceToken: NATIVE_TOKEN, borrowed: OMITTED_REMOTE_LOAN_DEBT, collateral: OMITTED_REMOTE_LOAN_COLLATERAL
        });
        PeerSnapshotTerminalMock peerTerminal =
            new PeerSnapshotTerminalMock({sourceToken: NATIVE_TOKEN, currency: ETH_CURRENCY});

        REVOwner peerOwnerHook = new REVOwner({
            buybackHook: IJBBuybackHookRegistry(address(buybackRegistry)),
            directory: IJBDirectory(DIRECTORY),
            feeRevnetId: 999_999,
            suckerRegistry: IJBSuckerRegistry(address(registry)),
            loans: IREVLoans(address(loans)),
            deployerAddress: address(this)
        });
        peerOwnerHook.setDeployer({
            newDeployer: IREVDeployer(
                address(new PeerSnapshotDeployerMock({multiTerminal: IJBTerminal(address(peerTerminal))}))
            )
        });

        (uint256 supply, uint256 surplus, uint256 balance) =
            peerOwnerHook.peerChainAdjustedAccountsOf({revnetId: REVNET_ID, decimals: 18, currency: ETH_CURRENCY});

        // Peer snapshots need burned loan collateral in supply, otherwise remote holders look artificially scarce.
        assertEq(supply, OMITTED_REMOTE_LOAN_COLLATERAL, "peer snapshot should include loan collateral supply");
        // Borrowed funds are owed back to the revnet, so they are both surplus and balance for peer-chain math.
        assertEq(surplus, OMITTED_REMOTE_LOAN_DEBT, "peer snapshot should include loan debt surplus");
        assertEq(balance, OMITTED_REMOTE_LOAN_DEBT, "peer snapshot should include loan debt balance");
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
