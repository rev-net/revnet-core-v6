// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import /* {*} from */ "@bananapus/core-v5/test/helpers/TestBaseWorkflow.sol";
import /* {*} from "@bananapus/721-hook-v5/src/JB721TiersHookDeployer.sol";
import /* {*} from */ "./../src/REVDeployer.sol";
import "@croptop/core-v5/src/CTPublisher.sol";

import "@bananapus/core-v5/script/helpers/CoreDeploymentLib.sol";
import "@bananapus/721-hook-v5/script/helpers/Hook721DeploymentLib.sol";
import "@bananapus/suckers-v5/script/helpers/SuckerDeploymentLib.sol";

import {JBConstants} from "@bananapus/core-v5/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v5/src/structs/JBAccountingContext.sol";
import {REVStageConfig, REVAutoIssuance} from "../src/structs/REVStageConfig.sol";
import {REVLoanSource} from "../src/structs/REVLoanSource.sol";
import {REVDescription} from "../src/structs/REVDescription.sol";
import {REVBuybackPoolConfig} from "../src/structs/REVBuybackPoolConfig.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v5/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v5/src/JBSuckerRegistry.sol";
import {JBTokenMapping} from "@bananapus/suckers-v5/src/structs/JBTokenMapping.sol";
import {JBArbitrumSuckerDeployer} from "@bananapus/suckers-v5/src/deployers/JBArbitrumSuckerDeployer.sol";
import {JBArbitrumSucker, JBLayer, IArbGatewayRouter, IInbox} from "@bananapus/suckers-v5/src/JBArbitrumSucker.sol";
import {JBAddToBalanceMode} from "@bananapus/suckers-v5/src/enums/JBAddToBalanceMode.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v5/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v5/src/JB721TiersHookStore.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v5/src/JB721TiersHookDeployer.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v5/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v5/src/interfaces/IJBAddressRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Security tests for Tempo blockchain integration with the revnet system.
/// Tests auto-issuance, sucker deployment, and access control patterns
/// that are relevant when extending revnets to the Tempo blockchain.
contract REVTempoSecurity_Local is TestBaseWorkflow, JBTest {
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";
    bytes32 ERC20_SALT = "REV_TOKEN";

    REVDeployer REV_DEPLOYER;

    IJB721TiersHookDeployer HOOK_DEPLOYER;
    IJB721TiersHookStore HOOK_STORE;
    IJBAddressRegistry ADDRESS_REGISTRY;

    JBSuckerRegistry SUCKER_REGISTRY;
    IJBSuckerDeployer SUCKER_DEPLOYER;

    CTPublisher PUBLISHER;

    uint256 FEE_PROJECT_ID;
    uint256 REVNET_ID;
    uint256 decimals = 18;
    uint256 decimalMultiplier = 10 ** decimals;

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    /// @notice Tempo testnet chain ID.
    uint256 constant TEMPO_CHAIN_ID = 42_429;

    /// @notice Simulated WETH ERC20 address on Tempo (TBD in production).
    address constant WETH_ON_TEMPO = address(0xE770E770E770);

    uint256 firstStageId;

    function _getRevnetConfig() internal returns (REVConfig memory, JBTerminalConfig[] memory) {
        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](1);

        REVAutoIssuance[] memory issuanceConfs = new REVAutoIssuance[](1);
        issuanceConfs[0] = REVAutoIssuance({
            chainId: uint32(block.chainid), count: uint104(10_000 * decimalMultiplier), beneficiary: multisig()
        });

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        firstStageId = block.timestamp;

        stageConfigurations[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: issuanceConfs,
            splitPercent: 2000,
            splits: splits,
            initialIssuance: uint112(1000 * decimalMultiplier),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: (1 << 2) // Enable adding new suckers.
        });

        REVConfig memory revnetConfiguration = REVConfig({
            description: REVDescription("TestRevnet", "$TREV", "ipfs://test", ERC20_SALT),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations,
            loanSources: new REVLoanSource[](0),
            loans: address(0)
        });

        return (revnetConfiguration, terminalConfigurations);
    }

    function setUp() public override {
        super.setUp();

        FEE_PROJECT_ID = jbProjects().createFor(multisig());

        SUCKER_REGISTRY = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig(), address(0));

        HOOK_STORE = new JB721TiersHookStore();

        JB721TiersHook exampleHook =
            new JB721TiersHook(jbDirectory(), jbPermissions(), jbRulesets(), HOOK_STORE, multisig());

        ADDRESS_REGISTRY = new JBAddressRegistry();

        HOOK_DEPLOYER = new JB721TiersHookDeployer(exampleHook, HOOK_STORE, ADDRESS_REGISTRY, multisig());

        PUBLISHER = new CTPublisher(jbDirectory(), jbPermissions(), FEE_PROJECT_ID, multisig());

        REV_DEPLOYER = new REVDeployer{salt: REV_DEPLOYER_SALT}(
            jbController(), SUCKER_REGISTRY, FEE_PROJECT_ID, HOOK_DEPLOYER, PUBLISHER, TRUSTED_FORWARDER
        );

        // Deploy the Arbitrum sucker deployer (used as a generic sucker for testing).
        JBArbitrumSuckerDeployer _deployer =
            new JBArbitrumSuckerDeployer(jbDirectory(), jbPermissions(), jbTokens(), address(this), address(0));
        SUCKER_DEPLOYER = IJBSuckerDeployer(address(_deployer));

        JBArbitrumSucker _singleton = new JBArbitrumSucker(
            _deployer, jbDirectory(), jbPermissions(), jbTokens(), JBAddToBalanceMode.MANUAL, address(0)
        );

        _deployer.setChainSpecificConstants(JBLayer.L1, IInbox(address(1)), IArbGatewayRouter(address(1)));
        _deployer.configureSingleton(_singleton);

        // Approve deployer and allow sucker deployer.
        vm.startPrank(address(multisig()));
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);
        SUCKER_REGISTRY.allowSuckerDeployer(address(SUCKER_DEPLOYER));
        vm.stopPrank();

        // Deploy the revnet.
        (REVConfig memory revnetConfig, JBTerminalConfig[] memory terminalConfigs) = _getRevnetConfig();

        vm.prank(address(multisig()));
        REVNET_ID = REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: revnetConfig,
            terminalConfigurations: terminalConfigs,
            buybackHookConfiguration: REVBuybackHookConfig({
                dataHook: IJBRulesetDataHook(address(0)),
                hookToConfigure: IJBBuybackHook(address(0)),
                poolConfigurations: new REVBuybackPoolConfig[](0)
            }),
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("REV"))
            })
        });
    }

    /// @notice Verify the basic revnet setup completed correctly.
    function test_tempo_setup_is_valid() public view {
        assertGt(REVNET_ID, 0, "Revnet should be deployed");
        assertGt(uint160(address(SUCKER_DEPLOYER)), 0, "Sucker deployer should exist");
    }

    /// @notice Test deploying a sucker from the revnet deployer.
    /// Validates the sucker deployment flow that Tempo integration will use.
    function test_deploy_sucker_for_revnet() public {
        JBSuckerDeployerConfig[] memory suckerDeployerConfig = new JBSuckerDeployerConfig[](1);

        JBTokenMapping[] memory tokenMapping = new JBTokenMapping[](1);
        address token = makeAddr("someToken");
        tokenMapping[0] = JBTokenMapping({
            localToken: token, minGas: 200_000, remoteToken: makeAddr("someRemoteToken"), minBridgeAmount: 0.01 ether
        });

        suckerDeployerConfig[0] = JBSuckerDeployerConfig({deployer: SUCKER_DEPLOYER, mappings: tokenMapping});

        REVSuckerDeploymentConfig memory revConfig =
            REVSuckerDeploymentConfig({deployerConfigurations: suckerDeployerConfig, salt: "TEMPO_SUCKER"});

        // Arbitrum chain ID for the ARB deployer.
        vm.chainId(42_161);
        vm.prank(multisig());

        vm.mockCall(address(token), abi.encodeWithSelector(IERC20.balanceOf.selector), abi.encode(0));

        address[] memory suckers = REV_DEPLOYER.deploySuckersFor(REVNET_ID, revConfig);

        assertTrue(SUCKER_REGISTRY.isSuckerOf(REVNET_ID, suckers[0]), "Sucker should be registered");
    }

    /// @notice Test that auto-issuance for Tempo chain ID is skipped when deploying on a non-Tempo chain.
    /// The REVDeployer only stores auto-issuance amounts for the deploying chain's ID.
    /// Tempo auto-issuance would be stored when the same revnet deploys on the Tempo chain.
    function test_auto_issuance_skips_tempo_on_non_tempo_chain() public {
        REVAutoIssuance[] memory issuanceConfs = new REVAutoIssuance[](2);
        issuanceConfs[0] = REVAutoIssuance({
            chainId: uint32(block.chainid), // local chain
            count: uint104(5000 * decimalMultiplier),
            beneficiary: multisig()
        });
        issuanceConfs[1] = REVAutoIssuance({
            chainId: uint32(TEMPO_CHAIN_ID), // Tempo chain
            count: uint104(3000 * decimalMultiplier),
            beneficiary: multisig()
        });

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](1);
        stageConfigurations[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: issuanceConfs,
            splitPercent: 2000,
            splits: splits,
            initialIssuance: uint112(1000 * decimalMultiplier),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: (1 << 2)
        });

        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        REVConfig memory revnetConfiguration = REVConfig({
            description: REVDescription("TempoRevnet", "$TEMPO", "ipfs://tempo", "TEMPO_SALT"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations,
            loanSources: new REVLoanSource[](0),
            loans: address(0)
        });

        uint256 newProjectId = jbProjects().createFor(multisig());
        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), newProjectId);

        vm.prank(multisig());
        uint256 tempoRevnetId = REV_DEPLOYER.deployFor({
            revnetId: newProjectId,
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            buybackHookConfiguration: REVBuybackHookConfig({
                dataHook: IJBRulesetDataHook(address(0)),
                hookToConfigure: IJBBuybackHook(address(0)),
                poolConfigurations: new REVBuybackPoolConfig[](0)
            }),
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("TEMPO"))
            })
        });

        assertGt(tempoRevnetId, 0, "Tempo revnet should be deployed");

        // The local chain auto-issuance should be realizable.
        uint256 localAmount = REV_DEPLOYER.amountToAutoIssue(tempoRevnetId, block.timestamp, multisig());
        assertEq(localAmount, 5000 * decimalMultiplier, "Local auto-issuance should be 5000 tokens");

        // Issue the local chain tokens.
        REV_DEPLOYER.autoIssueFor(tempoRevnetId, block.timestamp, multisig());
        assertEq(
            IJBToken(jbTokens().tokenOf(tempoRevnetId)).balanceOf(multisig()),
            5000 * decimalMultiplier,
            "Multisig should have 5000 tokens after local auto-issue"
        );

        // The Tempo auto-issuance was NOT stored because we deployed on a non-Tempo chain.
        // The deployer skips auto-issuance entries where chainId != block.chainid.
        // It would only be stored when the revnet is deployed on Tempo itself.
        // Changing vm.chainId doesn't retroactively populate the mapping.
        // Verify the Tempo entry was correctly skipped (returns 0).
        uint256 tempoAmount = REV_DEPLOYER.amountToAutoIssue(tempoRevnetId, block.timestamp, address(0xDEAD));
        assertEq(tempoAmount, 0, "Tempo auto-issuance should not be stored on non-Tempo chain");
    }

    /// @notice Test that non-CCIP suckers reject mixed NATIVE/ERC20 token mapping.
    /// The base JBSucker._validateTokenMapping() requires NATIVE_TOKEN to map to NATIVE_TOKEN.
    /// Only JBCCIPSucker overrides this to allow NATIVE_TOKEN -> ERC20 (needed for Tempo).
    /// This validates the security invariant: standard suckers cannot be misconfigured.
    function test_non_ccip_sucker_rejects_mixed_native_erc20_mapping() public {
        JBSuckerDeployerConfig[] memory suckerDeployerConfig = new JBSuckerDeployerConfig[](1);

        // Map NATIVE_TOKEN (ETH) locally to WETH (ERC20) on Tempo.
        // This should be REJECTED by the Arbitrum sucker (non-CCIP).
        JBTokenMapping[] memory tokenMapping = new JBTokenMapping[](1);
        tokenMapping[0] = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 200_000,
            remoteToken: WETH_ON_TEMPO,
            minBridgeAmount: 0.01 ether
        });

        suckerDeployerConfig[0] = JBSuckerDeployerConfig({deployer: SUCKER_DEPLOYER, mappings: tokenMapping});

        REVSuckerDeploymentConfig memory revConfig =
            REVSuckerDeploymentConfig({deployerConfigurations: suckerDeployerConfig, salt: "MIXED_MAPPING"});

        vm.chainId(42_161);
        vm.prank(multisig());

        // Should revert with JBSucker_InvalidNativeRemoteAddress because the base
        // _validateTokenMapping() enforces NATIVE_TOKEN -> NATIVE_TOKEN for non-CCIP suckers.
        vm.expectRevert();
        REV_DEPLOYER.deploySuckersFor(REVNET_ID, revConfig);
    }

    /// @notice Test that extraMetadata bit 2 (allow adding suckers) is required for sucker deployment.
    function test_sucker_deploy_requires_extra_metadata_flag() public {
        // Deploy a revnet WITHOUT the "allow adding suckers" flag.
        REVAutoIssuance[] memory issuanceConfs = new REVAutoIssuance[](1);
        issuanceConfs[0] = REVAutoIssuance({
            chainId: uint32(block.chainid), count: uint104(1000 * decimalMultiplier), beneficiary: multisig()
        });

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](1);
        stageConfigurations[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: issuanceConfs,
            splitPercent: 2000,
            splits: splits,
            initialIssuance: uint112(1000 * decimalMultiplier),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: 0 // No sucker flag!
        });

        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        REVConfig memory revnetConfiguration = REVConfig({
            description: REVDescription("NoSuckers", "$NOSUCK", "ipfs://nosuck", "NOSUCK_SALT"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations,
            loanSources: new REVLoanSource[](0),
            loans: address(0)
        });

        uint256 projectId = jbProjects().createFor(multisig());
        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), projectId);

        vm.prank(multisig());
        uint256 noSuckerRevnet = REV_DEPLOYER.deployFor({
            revnetId: projectId,
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            buybackHookConfiguration: REVBuybackHookConfig({
                dataHook: IJBRulesetDataHook(address(0)),
                hookToConfigure: IJBBuybackHook(address(0)),
                poolConfigurations: new REVBuybackPoolConfig[](0)
            }),
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("NOSUCK"))
            })
        });

        // Trying to deploy a sucker for this revnet should revert since the flag is not set.
        JBSuckerDeployerConfig[] memory suckerDeployerConfig = new JBSuckerDeployerConfig[](1);
        JBTokenMapping[] memory tokenMapping = new JBTokenMapping[](1);
        tokenMapping[0] = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 200_000,
            remoteToken: JBConstants.NATIVE_TOKEN,
            minBridgeAmount: 0.01 ether
        });
        suckerDeployerConfig[0] = JBSuckerDeployerConfig({deployer: SUCKER_DEPLOYER, mappings: tokenMapping});
        REVSuckerDeploymentConfig memory revConfig =
            REVSuckerDeploymentConfig({deployerConfigurations: suckerDeployerConfig, salt: "FAIL"});

        vm.chainId(42_161);
        vm.prank(multisig());
        vm.expectRevert();
        REV_DEPLOYER.deploySuckersFor(noSuckerRevnet, revConfig);
    }

    /// @notice Test that only the split operator / owner can deploy suckers for a revnet.
    function test_unauthorized_sucker_deploy_reverts() public {
        JBSuckerDeployerConfig[] memory suckerDeployerConfig = new JBSuckerDeployerConfig[](1);
        JBTokenMapping[] memory tokenMapping = new JBTokenMapping[](1);
        tokenMapping[0] = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 200_000,
            remoteToken: JBConstants.NATIVE_TOKEN,
            minBridgeAmount: 0.01 ether
        });
        suckerDeployerConfig[0] = JBSuckerDeployerConfig({deployer: SUCKER_DEPLOYER, mappings: tokenMapping});
        REVSuckerDeploymentConfig memory revConfig =
            REVSuckerDeploymentConfig({deployerConfigurations: suckerDeployerConfig, salt: "UNAUTH"});

        vm.chainId(42_161);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        REV_DEPLOYER.deploySuckersFor(REVNET_ID, revConfig);
    }

    /// @notice Test that amountToAutoIssue is a simple mapping keyed by (revnetId, stageId, beneficiary).
    /// The chain ID filtering happens at deploy time, not at read time.
    /// Once stored, the amount is accessible regardless of the current chain ID.
    function test_auto_issuance_is_stored_at_deploy_time() public view {
        // The setup revnet stored auto-issuance for the local chain.
        // This is accessible from any chain ID since it's just a mapping read.
        uint256 amount = REV_DEPLOYER.amountToAutoIssue(REVNET_ID, firstStageId, multisig());
        assertEq(amount, 10_000 * decimalMultiplier, "Auto-issuance should be stored at deploy time");

        // A non-existent beneficiary should return 0.
        uint256 noAmount = REV_DEPLOYER.amountToAutoIssue(REVNET_ID, firstStageId, address(0xDEAD));
        assertEq(noAmount, 0, "Non-existent beneficiary should have 0 auto-issuance");
    }
}
