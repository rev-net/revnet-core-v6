// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import /* {*} from */ "../../src/REVDeployer.sol";
import "@croptop/core-v6/src/CTPublisher.sol";
import {MockBuybackDataHook} from "../mock/MockBuybackDataHook.sol";
import {REVEmpty721Config} from "../helpers/REVEmpty721Config.sol";
import "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
import "@bananapus/721-hook-v6/script/helpers/Hook721DeploymentLib.sol";
import "@bananapus/suckers-v6/script/helpers/SuckerDeploymentLib.sol";
import "@croptop/core-v6/script/helpers/CroptopDeploymentLib.sol";
import "@bananapus/router-terminal-v6/script/helpers/RouterTerminalDeploymentLib.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {REVLoans} from "../../src/REVLoans.sol";
import {REVHiddenTokens} from "../../src/REVHiddenTokens.sol";
import {REVStageConfig, REVAutoIssuance} from "../../src/structs/REVStageConfig.sol";
import {REVDescription} from "../../src/structs/REVDescription.sol";
import {REVConfig} from "../../src/structs/REVConfig.sol";
import {REVSuckerDeploymentConfig} from "../../src/structs/REVSuckerDeploymentConfig.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBTokenMapping} from "@bananapus/suckers-v6/src/structs/JBTokenMapping.sol";
import {IJBSucker} from "@bananapus/suckers-v6/src/interfaces/IJBSucker.sol";
import {IOPMessenger} from "@bananapus/suckers-v6/src/interfaces/IOPMessenger.sol";
import {IOPStandardBridge} from "@bananapus/suckers-v6/src/interfaces/IOPStandardBridge.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {JBOptimismSucker} from "@bananapus/suckers-v6/src/JBOptimismSucker.sol";
import {JBOptimismSuckerDeployer} from "@bananapus/suckers-v6/src/deployers/JBOptimismSuckerDeployer.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/JB721CheckpointsDeployer.sol";
import {IJB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721CheckpointsDeployer.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {REVOwner} from "../../src/REVOwner.sol";
import {MockSuckerRegistry} from "../mock/MockSuckerRegistry.sol";

contract CodexNemesisSuckerCallerDeterminismTest is TestBaseWorkflow {
    bytes32 private constant REV_DEPLOYER_SALT = "REVDeployer";
    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;
    address private constant MESSENGER = address(0x1001);
    address private constant BRIDGE = address(0x1002);

    REVDeployer internal REV_DEPLOYER;
    REVOwner internal REV_OWNER;
    JB721TiersHook internal EXAMPLE_HOOK;
    JB721TiersHookDeployer internal HOOK_DEPLOYER;
    JB721TiersHookStore internal HOOK_STORE;
    JBAddressRegistry internal ADDRESS_REGISTRY;
    REVLoans internal LOANS_CONTRACT;
    REVHiddenTokens internal HIDDEN_TOKENS;
    IJBSuckerRegistry internal SUCKER_REGISTRY;
    CTPublisher internal PUBLISHER;
    MockBuybackDataHook internal MOCK_BUYBACK;
    JBOptimismSuckerDeployer internal OP_SUCKER_DEPLOYER;

    uint256 internal FEE_PROJECT_ID;
    address internal OPERATOR_A;
    address internal OPERATOR_B;

    function setUp() public override {
        vm.chainId(1);
        super.setUp();

        OPERATOR_A = makeAddr("operatorA");
        OPERATOR_B = makeAddr("operatorB");

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
            IJB721CheckpointsDeployer(address(new JB721CheckpointsDeployer(HOOK_STORE))),
            multisig()
        );
        ADDRESS_REGISTRY = new JBAddressRegistry();
        HOOK_DEPLOYER = new JB721TiersHookDeployer(EXAMPLE_HOOK, HOOK_STORE, ADDRESS_REGISTRY, multisig());
        PUBLISHER = new CTPublisher(jbDirectory(), jbPermissions(), FEE_PROJECT_ID, multisig());
        MOCK_BUYBACK = new MockBuybackDataHook();

        LOANS_CONTRACT = new REVLoans({
            controller: jbController(),
            suckerRegistry: IJBSuckerRegistry(address(new MockSuckerRegistry())),
            revId: FEE_PROJECT_ID,
            owner: address(this),
            permit2: permit2(),
            trustedForwarder: TRUSTED_FORWARDER
        });

        HIDDEN_TOKENS = new REVHiddenTokens(jbController(), TRUSTED_FORWARDER);

        REV_OWNER = new REVOwner(
            IJBBuybackHookRegistry(address(MOCK_BUYBACK)),
            jbDirectory(),
            FEE_PROJECT_ID,
            SUCKER_REGISTRY,
            LOANS_CONTRACT,
            HIDDEN_TOKENS
        );

        REV_DEPLOYER = new REVDeployer{salt: REV_DEPLOYER_SALT}(
            jbController(),
            SUCKER_REGISTRY,
            FEE_PROJECT_ID,
            HOOK_DEPLOYER,
            PUBLISHER,
            IJBBuybackHookRegistry(address(MOCK_BUYBACK)),
            LOANS_CONTRACT,
            TRUSTED_FORWARDER,
            address(REV_OWNER)
        );

        REV_OWNER.setDeployer(REV_DEPLOYER);

        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);
        _deployFeeProject();

        OP_SUCKER_DEPLOYER = new JBOptimismSuckerDeployer({
            directory: jbDirectory(),
            permissions: jbPermissions(),
            tokens: jbTokens(),
            configurator: address(this),
            trustedForwarder: address(0)
        });
        OP_SUCKER_DEPLOYER.setChainSpecificConstants(IOPMessenger(MESSENGER), IOPStandardBridge(BRIDGE));

        JBOptimismSucker singleton = new JBOptimismSucker({
            deployer: OP_SUCKER_DEPLOYER,
            directory: jbDirectory(),
            permissions: jbPermissions(),
            prices: address(jbPrices()),
            tokens: jbTokens(),
            feeProjectId: FEE_PROJECT_ID,
            registry: SUCKER_REGISTRY,
            trustedForwarder: address(0)
        });
        OP_SUCKER_DEPLOYER.configureSingleton(singleton);

        vm.prank(multisig());
        JBSuckerRegistry(address(SUCKER_REGISTRY)).allowSuckerDeployer(address(OP_SUCKER_DEPLOYER));
    }

    function test_identicalRevnetConfigsUseCallerNamespacedSuckerSalt() public {
        uint40 commonStart = uint40(block.timestamp);
        bytes32 descriptionSalt = bytes32("REV_SAME_CONFIG");

        uint256 revnetA = _deployRevnetWith(OPERATOR_A, OPERATOR_A, descriptionSalt, commonStart);
        uint256 revnetB = _deployRevnetWith(OPERATOR_B, OPERATOR_A, descriptionSalt, commonStart);

        assertEq(
            REV_DEPLOYER.hashedEncodedConfigurationOf(revnetA),
            REV_DEPLOYER.hashedEncodedConfigurationOf(revnetB),
            "setup: identical revnet configs should hash the same"
        );

        REVSuckerDeploymentConfig memory config = _suckerConfig(bytes32("CALLER_SALTED"));

        vm.prank(OPERATOR_A);
        REV_DEPLOYER.setSplitOperatorOf(revnetB, OPERATOR_B);

        vm.prank(OPERATOR_A);
        address suckerA = REV_DEPLOYER.deploySuckersFor(revnetA, config)[0];

        vm.prank(OPERATOR_B);
        address suckerB = REV_DEPLOYER.deploySuckersFor(revnetB, config)[0];

        assertNotEq(suckerA, suckerB, "caller namespace prevents identical config/salt collision");
        assertEq(
            IJBSucker(suckerA).peer(), bytes32(uint256(uint160(suckerA))), "first default peer remains same-address"
        );
        assertEq(
            IJBSucker(suckerB).peer(), bytes32(uint256(uint160(suckerB))), "second default peer remains same-address"
        );
    }

    function test_onlySplitOperatorCanDeploySuckersForRevnet() public {
        uint256 revnetId = _deployRevnetWith(OPERATOR_A, OPERATOR_A, bytes32("OP_CHAIN_CTRL"), uint40(block.timestamp));
        REVSuckerDeploymentConfig memory config = _suckerConfig(bytes32("CHAIN_CTRL"));

        vm.expectRevert(abi.encodeWithSelector(REVDeployer.REVDeployer_Unauthorized.selector, revnetId, OPERATOR_B));
        vm.prank(OPERATOR_B);
        REV_DEPLOYER.deploySuckersFor(revnetId, config);
    }

    function _deployFeeProject() internal {
        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);
        accountingContexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminals = new JBTerminalConfig[](1);
        terminals[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContexts});

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

        REVConfig memory config = REVConfig({
            description: REVDescription("Fee Revnet", "FEE", "", bytes32("FEE_TOKEN")),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });

        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: config,
            terminalConfigurations: terminals,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("FEE")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    function _deployRevnetWith(
        address caller,
        address splitOperator,
        bytes32 descriptionSalt,
        uint40 start
    )
        internal
        returns (uint256 revnetId)
    {
        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);
        accountingContexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminals = new JBTerminalConfig[](1);
        terminals[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContexts});

        REVStageConfig[] memory stages = new REVStageConfig[](1);
        stages[0] = REVStageConfig({
            startsAtOrAfter: start,
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: new JBSplit[](0),
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 5000,
            extraMetadata: 4
        });

        REVConfig memory config = REVConfig({
            description: REVDescription("Caller Salt Revnet", "CSR", "", descriptionSalt),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: splitOperator,
            stageConfigurations: stages
        });

        vm.prank(caller);
        (revnetId,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: config,
            terminalConfigurations: terminals,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("NO_INITIAL_SUCKERS")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    function _suckerConfig(bytes32 salt) internal view returns (REVSuckerDeploymentConfig memory config) {
        JBTokenMapping[] memory mappings = new JBTokenMapping[](1);
        mappings[0] = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 300_000,
            remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
        });

        JBSuckerDeployerConfig[] memory deployerConfigurations = new JBSuckerDeployerConfig[](1);
        deployerConfigurations[0] =
            JBSuckerDeployerConfig({deployer: OP_SUCKER_DEPLOYER, peer: bytes32(0), mappings: mappings});

        config = REVSuckerDeploymentConfig({deployerConfigurations: deployerConfigurations, salt: salt});
    }
}
