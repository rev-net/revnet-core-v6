// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "./../src/REVDeployer.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@croptop/core-v6/src/CTPublisher.sol";
import {REVEmpty721Config} from "./helpers/REVEmpty721Config.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@bananapus/721-hook-v6/script/helpers/Hook721DeploymentLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@bananapus/suckers-v6/script/helpers/SuckerDeploymentLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@croptop/core-v6/script/helpers/CroptopDeploymentLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@bananapus/router-terminal-v6/script/helpers/RouterTerminalDeploymentLib.sol";

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {REVLoans} from "../src/REVLoans.sol";
import {REVStageConfig, REVAutoIssuance} from "../src/structs/REVStageConfig.sol";
import {REVDescription} from "../src/structs/REVDescription.sol";
import {IREVLoans} from "./../src/interfaces/IREVLoans.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/JB721CheckpointsDeployer.sol";
import {IJB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721CheckpointsDeployer.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {REVOwner} from "../src/REVOwner.sol";
import {IREVDeployer} from "../src/interfaces/IREVDeployer.sol";
import {MockSuckerRegistry} from "./mock/MockSuckerRegistry.sol";
import {MockBuybackDataHook} from "./mock/MockBuybackDataHook.sol";

/// @notice Tests that terminal addresses are included in the encoded configuration hash.
contract TestTerminalEncodingInHash is TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";

    // forge-lint: disable-next-line(mixed-case-variable)
    REVDeployer REV_DEPLOYER;
    // forge-lint: disable-next-line(mixed-case-variable)
    REVOwner REV_OWNER;
    // forge-lint: disable-next-line(mixed-case-variable)
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    // forge-lint: disable-next-line(mixed-case-variable)
    IJB721TiersHookStore HOOK_STORE;
    // forge-lint: disable-next-line(mixed-case-variable)
    IJBAddressRegistry ADDRESS_REGISTRY;
    // forge-lint: disable-next-line(mixed-case-variable)
    IREVLoans LOANS_CONTRACT;
    // forge-lint: disable-next-line(mixed-case-variable)
    IJBSuckerRegistry SUCKER_REGISTRY;
    // forge-lint: disable-next-line(mixed-case-variable)
    CTPublisher PUBLISHER;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockBuybackDataHook MOCK_BUYBACK;

    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 FEE_PROJECT_ID;

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    function setUp() public override {
        super.setUp();

        FEE_PROJECT_ID = jbProjects().createFor(multisig());

        SUCKER_REGISTRY = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig(), address(0));
        HOOK_STORE = new JB721TiersHookStore();
        JB721TiersHook exampleHook = new JB721TiersHook(
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
        HOOK_DEPLOYER = new JB721TiersHookDeployer(exampleHook, HOOK_STORE, ADDRESS_REGISTRY, multisig());
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

        REV_OWNER = new REVOwner(
            IJBBuybackHookRegistry(address(MOCK_BUYBACK)),
            jbDirectory(),
            FEE_PROJECT_ID,
            SUCKER_REGISTRY,
            address(LOANS_CONTRACT),
            address(0)
        );

        REV_DEPLOYER = new REVDeployer{salt: REV_DEPLOYER_SALT}(
            jbController(),
            SUCKER_REGISTRY,
            FEE_PROJECT_ID,
            HOOK_DEPLOYER,
            PUBLISHER,
            IJBBuybackHookRegistry(address(MOCK_BUYBACK)),
            address(LOANS_CONTRACT),
            TRUSTED_FORWARDER,
            address(REV_OWNER)
        );

        REV_OWNER.setDeployer(REV_DEPLOYER);

        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);

        // Deploy fee project.
        _deployFeeProject();
    }

    /// @notice Two revnets with identical base config but different terminals produce different hashes.
    function test_differentTerminals_produceDifferentHashes() public {
        // Deploy revnet A with the primary multi-terminal (same description salt for both).
        (uint256 revnetA,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: _baseRevConfig("DIFF_TERM"),
            terminalConfigurations: _terminalConfigs(jbMultiTerminal()),
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("A")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        // Deploy revnet B with the secondary multi-terminal (same config, only terminal differs).
        (uint256 revnetB,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: _baseRevConfig("DIFF_TERM"),
            terminalConfigurations: _terminalConfigs(jbMultiTerminal2()),
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("B")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        bytes32 hashA = REV_DEPLOYER.hashedEncodedConfigurationOf(revnetA);
        bytes32 hashB = REV_DEPLOYER.hashedEncodedConfigurationOf(revnetB);

        assertNotEq(hashA, hashB, "Different terminals must produce different configuration hashes");
    }

    /// @notice The hash includes the terminal address — verify by computing it off-chain.
    function test_hashIncludesTerminalAddress() public {
        // Deploy a revnet.
        (uint256 revnetId,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: _baseRevConfig("VERIFY"),
            terminalConfigurations: _terminalConfigs(jbMultiTerminal()),
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("VERIFY")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        // Recompute the expected hash manually.
        bytes memory encodedConfiguration = abi.encode(
            uint32(uint160(JBConstants.NATIVE_TOKEN)), // baseCurrency
            "Terminal Test", // name
            "TERM", // ticker
            bytes32("VERIFY"), // salt
            multisig() // splitOperator
        );
        // Terminal address encoding.
        encodedConfiguration = abi.encode(encodedConfiguration, jbMultiTerminal());
        // Stage encoding.
        encodedConfiguration = abi.encode(
            encodedConfiguration,
            block.timestamp, // startsAtOrAfter
            uint256(0), // splitPercent
            uint112(1000e18), // initialIssuance
            uint256(0), // issuanceCutFrequency
            uint256(0), // issuanceCutPercent
            uint256(5000), // cashOutTaxRate
            uint256(0) // extraMetadata
        );
        bytes32 expectedHash = keccak256(encodedConfiguration);

        assertEq(
            REV_DEPLOYER.hashedEncodedConfigurationOf(revnetId),
            expectedHash,
            "On-chain hash must match off-chain computation including terminal address"
        );
    }

    /// @notice Terminal ordering matters — [A, B] != [B, A].
    function test_terminalOrder_affectsHash() public {
        // Deploy revnet with terminals in order [main, alt].
        JBTerminalConfig[] memory tcAB = new JBTerminalConfig[](2);
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        tcAB[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});
        tcAB[1] = JBTerminalConfig({terminal: jbMultiTerminal2(), accountingContextsToAccept: acc});

        (uint256 revnetAB,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: _baseRevConfig("ORDER"),
            terminalConfigurations: tcAB,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("AB")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        // Deploy revnet with terminals in order [alt, main].
        JBTerminalConfig[] memory tcBA = new JBTerminalConfig[](2);
        tcBA[0] = JBTerminalConfig({terminal: jbMultiTerminal2(), accountingContextsToAccept: acc});
        tcBA[1] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});

        (uint256 revnetBA,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: _baseRevConfig("ORDER"),
            terminalConfigurations: tcBA,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("BA")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        bytes32 hashAB = REV_DEPLOYER.hashedEncodedConfigurationOf(revnetAB);
        bytes32 hashBA = REV_DEPLOYER.hashedEncodedConfigurationOf(revnetBA);

        assertNotEq(hashAB, hashBA, "Terminal order must affect the configuration hash");
    }

    /// @notice Split recipients are mutable operational config, not revnet identity.
    function test_splitRecipient_doesNotAffectHash() public {
        address deployerA = makeAddr("deployerA");
        address deployerB = makeAddr("deployerB");

        vm.prank(deployerA);
        (uint256 revnetA,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: _revConfigWithSplit({salt: "SPLIT_RECIPIENT", splitBeneficiary: makeAddr("recipientA")}),
            terminalConfigurations: _terminalConfigs(jbMultiTerminal()),
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("SPLIT_A")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        vm.prank(deployerB);
        (uint256 revnetB,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: _revConfigWithSplit({salt: "SPLIT_RECIPIENT", splitBeneficiary: makeAddr("recipientB")}),
            terminalConfigurations: _terminalConfigs(jbMultiTerminal()),
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("SPLIT_B")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        assertEq(
            REV_DEPLOYER.hashedEncodedConfigurationOf(revnetA),
            REV_DEPLOYER.hashedEncodedConfigurationOf(revnetB),
            "split recipients should not affect the configuration hash"
        );
    }

    // ─── Helpers
    // ───────────────────────────────────────────────────────────────
    // //

    function _baseRevConfig(bytes32 salt) internal view returns (REVConfig memory) {
        REVStageConfig[] memory stages = new REVStageConfig[](1);
        stages[0] = REVStageConfig({
            startsAtOrAfter: uint48(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: new JBSplit[](0),
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 5000,
            extraMetadata: 0
        });
        return REVConfig({
            description: REVDescription("Terminal Test", "TERM", "", salt),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });
    }

    function _revConfigWithSplit(bytes32 salt, address splitBeneficiary) internal view returns (REVConfig memory) {
        REVStageConfig[] memory stages = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(splitBeneficiary);
        splits[0].percent = 10_000;
        stages[0] = REVStageConfig({
            startsAtOrAfter: uint48(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 2000,
            splits: splits,
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 5000,
            extraMetadata: 0
        });
        return REVConfig({
            description: REVDescription("Terminal Test", "TERM", "", salt),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });
    }

    function _terminalConfigs(IJBMultiTerminal terminal) internal pure returns (JBTerminalConfig[] memory tc) {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: terminal, accountingContextsToAccept: acc});
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
            startsAtOrAfter: uint48(block.timestamp),
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
            description: REVDescription("Fee Project", "FEE", "", bytes32("FEE")),
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
}
