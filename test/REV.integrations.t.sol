// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import /* {*} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import /* {*} from */ "./../src/REVDeployer.sol";
import "@croptop/core-v6/src/CTPublisher.sol";
import {MockBuybackDataHook} from "./mock/MockBuybackDataHook.sol";

import "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
import "@bananapus/721-hook-v6/script/helpers/Hook721DeploymentLib.sol";
import "@bananapus/suckers-v6/script/helpers/SuckerDeploymentLib.sol";
import "@croptop/core-v6/script/helpers/CroptopDeploymentLib.sol";
import "@bananapus/swap-terminal-v6/script/helpers/SwapTerminalDeploymentLib.sol";

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {REVLoans} from "../src/REVLoans.sol";
import {REVStageConfig, REVAutoIssuance} from "../src/structs/REVStageConfig.sol";
import {REVDescription} from "../src/structs/REVDescription.sol";
import {IREVLoans} from "./../src/interfaces/IREVLoans.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {JBTokenMapping} from "@bananapus/suckers-v6/src/structs/JBTokenMapping.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JBArbitrumSuckerDeployer} from "@bananapus/suckers-v6/src/deployers/JBArbitrumSuckerDeployer.sol";
import {JBArbitrumSucker, JBLayer, IArbGatewayRouter, IInbox} from "@bananapus/suckers-v6/src/JBArbitrumSucker.sol";
import {JBAddToBalanceMode} from "@bananapus/suckers-v6/src/enums/JBAddToBalanceMode.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";

struct FeeProjectConfig {
    REVConfig configuration;
    JBTerminalConfig[] terminalConfigurations;
    REVSuckerDeploymentConfig suckerDeploymentConfiguration;
}

contract REVnet_Integrations is TestBaseWorkflow, JBTest {
    /// @notice the salts that are used to deploy the contracts.
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";
    bytes32 ERC20_SALT = "REV_TOKEN";

    REVDeployer REV_DEPLOYER;
    JB721TiersHook EXAMPLE_HOOK;

    /// @notice Deploys tiered ERC-721 hooks for revnets.
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    IJB721TiersHookStore HOOK_STORE;
    IJBAddressRegistry ADDRESS_REGISTRY;

    IREVLoans LOANS_CONTRACT;

    /// @notice Deploys and tracks suckers for revnets.
    IJBSuckerRegistry SUCKER_REGISTRY;
    IJBSuckerDeployer ARB_SUCKER_DEPLOYER;
    bytes ENCODED_CONFIG;

    CTPublisher PUBLISHER;
    MockBuybackDataHook MOCK_BUYBACK;

    uint256 FEE_PROJECT_ID;
    uint256 REVNET_ID;
    uint256 decimals = 18;
    uint256 decimalMultiplier = 10 ** decimals;

    /// @notice The address that is allowed to forward calls.
    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    uint256 firstStageId;

    address USER = makeAddr("user");

    function getFeeProjectConfig() internal returns (FeeProjectConfig memory) {
        // Define constants
        string memory name = "Revnet";
        string memory symbol = "$REV";
        string memory projectUri = "ipfs://QmNRHT91HcDgMcenebYX7rJigt77cgNcosvuhX21wkF3tx";

        // The tokens that the project accepts and stores.
        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);

        // Accept the chain's native currency through the multi terminal.
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        // The terminals that the project will accept funds through.
        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        // The project's revnet stage configurations.
        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](3);

        REVAutoIssuance[] memory issuanceConfs = new REVAutoIssuance[](1);
        issuanceConfs[0] = REVAutoIssuance({
            chainId: uint32(block.chainid), count: uint104(70_000 * decimalMultiplier), beneficiary: multisig()
        });

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        {
            firstStageId = block.timestamp;

            stageConfigurations[0] = REVStageConfig({
                startsAtOrAfter: uint40(block.timestamp),
                autoIssuances: issuanceConfs,
                splitPercent: 2000, // 20%
                splits: splits,
                initialIssuance: uint112(1000 * decimalMultiplier),
                issuanceCutFrequency: 90 days,
                issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
                cashOutTaxRate: 6000, // 0.6
                extraMetadata: (1 << 2) // Enable adding new suckers.
            });
        }

        stageConfigurations[1] = REVStageConfig({
            startsAtOrAfter: uint40(stageConfigurations[0].startsAtOrAfter + 720 days),
            autoIssuances: issuanceConfs,
            splitPercent: 2000, // 20%
            splits: splits,
            initialIssuance: 0, // inherit from previous cycle.
            issuanceCutFrequency: 180 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000, // 0.6
            extraMetadata: (1 << 2) // Enable adding new suckers.
        });

        stageConfigurations[2] = REVStageConfig({
            startsAtOrAfter: uint40(stageConfigurations[1].startsAtOrAfter + (20 * 365 days)),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: 1,
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 6000, // 0.6
            extraMetadata: (1 << 2) // Enable adding new suckers.
        });

        // The project's revnet configuration
        REVConfig memory revnetConfiguration = REVConfig({
            description: REVDescription(name, symbol, projectUri, ERC20_SALT),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations
        });

        ENCODED_CONFIG = abi.encode(
            revnetConfiguration.baseCurrency,
            revnetConfiguration.description.name,
            revnetConfiguration.description.ticker,
            revnetConfiguration.description.salt
        );

        return FeeProjectConfig({
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("REV"))
            })
        });
    }

    function setUp() public override {
        super.setUp();

        FEE_PROJECT_ID = jbProjects().createFor(multisig());

        SUCKER_REGISTRY = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig(), address(0));

        HOOK_STORE = new JB721TiersHookStore();

        EXAMPLE_HOOK = new JB721TiersHook(jbDirectory(), jbPermissions(), jbRulesets(), HOOK_STORE, multisig());

        ADDRESS_REGISTRY = new JBAddressRegistry();

        HOOK_DEPLOYER = new JB721TiersHookDeployer(EXAMPLE_HOOK, HOOK_STORE, ADDRESS_REGISTRY, multisig());

        PUBLISHER = new CTPublisher(jbDirectory(), jbPermissions(), FEE_PROJECT_ID, multisig());
        MOCK_BUYBACK = new MockBuybackDataHook();

        REV_DEPLOYER = new REVDeployer{salt: REV_DEPLOYER_SALT}(
            jbController(),
            SUCKER_REGISTRY,
            FEE_PROJECT_ID,
            HOOK_DEPLOYER,
            PUBLISHER,
            IJBRulesetDataHook(address(MOCK_BUYBACK)),
            makeAddr("loans"),
            TRUSTED_FORWARDER
        );

        // Deploy the ARB sucker deployer.
        JBArbitrumSuckerDeployer _deployer =
            new JBArbitrumSuckerDeployer(jbDirectory(), jbPermissions(), jbTokens(), address(this), address(0));
        ARB_SUCKER_DEPLOYER = IJBSuckerDeployer(address(_deployer));

        // Deploy the ARB sucker singleton.
        JBArbitrumSucker _singleton = new JBArbitrumSucker(
            _deployer, jbDirectory(), jbPermissions(), jbTokens(), JBAddToBalanceMode.MANUAL, address(0)
        );

        // Set the layer specific confguration.
        _deployer.setChainSpecificConstants(JBLayer.L1, IInbox(address(1)), IArbGatewayRouter(address(1)));

        // Set the singleton for the deployer.
        _deployer.configureSingleton(_singleton);

        // Approve the basic deployer to configure the project.
        vm.startPrank(address(multisig()));
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);
        SUCKER_REGISTRY.allowSuckerDeployer(address(ARB_SUCKER_DEPLOYER));

        vm.stopPrank();

        // Build the config.
        FeeProjectConfig memory feeProjectConfig = getFeeProjectConfig();

        // Configure the project.
        vm.prank(address(multisig()));
        REVNET_ID = REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID, // Zero to deploy a new revnet
            configuration: feeProjectConfig.configuration,
            terminalConfigurations: feeProjectConfig.terminalConfigurations,
            suckerDeploymentConfiguration: feeProjectConfig.suckerDeploymentConfiguration
        });
    }

    function test_Is_Setup() public view {
        assertGt(uint160(address(jbDirectory())), uint160(0));
        assertGt(FEE_PROJECT_ID, 0);
        assertGt(jbProjects().count(), 0);
        assertGt(REVNET_ID, 0);
    }

    function test_preMint() public {
        uint256 perStageMintAmount = 70_000 * decimalMultiplier;
        vm.expectEmit();
        emit IREVDeployer.AutoIssue(REVNET_ID, firstStageId, multisig(), perStageMintAmount, address(this));
        REV_DEPLOYER.autoIssueFor(REVNET_ID, firstStageId, multisig());

        assertEq(70_000 * decimalMultiplier, IJBToken(jbTokens().tokenOf(REVNET_ID)).balanceOf(multisig()));
    }

    function test_realize_autoissuance() public {
        uint256 perStageMintAmount = 70_000 * decimalMultiplier;

        vm.expectEmit();
        emit IREVDeployer.AutoIssue(REVNET_ID, firstStageId, multisig(), perStageMintAmount, address(this));
        REV_DEPLOYER.autoIssueFor(REVNET_ID, firstStageId, multisig());
        assertEq(REV_DEPLOYER.amountToAutoIssue(REVNET_ID, firstStageId, multisig()), 0);

        assertEq(perStageMintAmount, IJBToken(jbTokens().tokenOf(REVNET_ID)).balanceOf(multisig()));

        vm.warp(firstStageId + 720 days);
        assertEq(perStageMintAmount, REV_DEPLOYER.amountToAutoIssue(REVNET_ID, firstStageId + 1, multisig()));

        vm.expectEmit();
        emit IREVDeployer.AutoIssue(REVNET_ID, firstStageId + 1, multisig(), perStageMintAmount, address(this));
        REV_DEPLOYER.autoIssueFor(REVNET_ID, firstStageId + 1, multisig());

        assertEq(perStageMintAmount * 2, IJBToken(jbTokens().tokenOf(REVNET_ID)).balanceOf(multisig()));
    }

    function test_change_split_operator() public {
        vm.prank(multisig());
        REV_DEPLOYER.setSplitOperatorOf(REVNET_ID, address(this));

        bool isNewOperator = REV_DEPLOYER.isSplitOperatorOf(REVNET_ID, address(this));

        assertEq(isNewOperator, true);
    }

    function test_sucker_deploy() public {
        JBSuckerDeployerConfig[] memory suckerDeployerConfig = new JBSuckerDeployerConfig[](1);

        JBTokenMapping[] memory tokenMapping = new JBTokenMapping[](1);

        address token = makeAddr("someToken");
        tokenMapping[0] = JBTokenMapping({
            localToken: token,
            minGas: 200_000,
            remoteToken: bytes32(uint256(uint160(makeAddr("someOtherToken")))),
            minBridgeAmount: 100 // emoji
        });

        suckerDeployerConfig[0] = JBSuckerDeployerConfig({deployer: ARB_SUCKER_DEPLOYER, mappings: tokenMapping});

        REVSuckerDeploymentConfig memory revConfig =
            REVSuckerDeploymentConfig({deployerConfigurations: suckerDeployerConfig, salt: "SALTY"});

        // Arbitrum chainid so the deployer works
        vm.chainId(42_161);
        vm.prank(multisig());

        // As a safety measure the newly created sucker will check that it has not missed a crosschain call.
        // which wil call the balanceOf to check its own balance.
        vm.mockCall(address(token), abi.encodeWithSelector(IERC20.balanceOf.selector), abi.encode(0));

        address[] memory suckers = REV_DEPLOYER.deploySuckersFor(REVNET_ID, revConfig);

        // Ensure it's registered
        bool isSucker = SUCKER_REGISTRY.isSuckerOf(REVNET_ID, suckers[0]);
        assertEq(isSucker, true);
    }

    /// Test that ensures that the splits are being configured for the new project.
    function test_configure_split(address payable beneficiaryA, address payable beneficiaryB) public {
        JBSplit[] memory splitsA = new JBSplit[](1);
        splitsA[0].beneficiary = beneficiaryA;
        splitsA[0].percent = 10_000;

        JBSplit[] memory splitsB = new JBSplit[](1);
        splitsB[0].beneficiary = beneficiaryB;
        splitsB[0].percent = 10_000;

        // Deploy a new REVNET, it has two configurations, we give each its own split and then check if the splits were
        // set correctly for each of the stages.
        FeeProjectConfig memory projectConfig = getFeeProjectConfig();

        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](2);
        stageConfigurations[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 2000, // 20%
            splits: splitsA,
            initialIssuance: 1000e18,
            issuanceCutFrequency: 180 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 2000, // 20%
            extraMetadata: 0
        });

        stageConfigurations[1] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp + 720 days),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 2000, // 20%
            splits: splitsB,
            initialIssuance: 0, // inherit from previous cycle.
            issuanceCutFrequency: 180 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 0, // 40%
            extraMetadata: 0
        });

        // Replace the configuration.
        projectConfig.configuration.stageConfigurations = stageConfigurations;
        projectConfig.configuration.description.salt = "FeeChange";

        uint256 revnetProjectId = REV_DEPLOYER.deployFor({
            revnetId: 0, // Zero to deploy a new revnet
            configuration: projectConfig.configuration,
            terminalConfigurations: projectConfig.terminalConfigurations,
            suckerDeploymentConfiguration: projectConfig.suckerDeploymentConfiguration
        });

        {
            JBSplit[] memory configuredSplits = jbSplits()
                .splitsOf(revnetProjectId, jbRulesets().currentOf(revnetProjectId).id, JBSplitGroupIds.RESERVED_TOKENS);
            assertEq(keccak256(abi.encode(configuredSplits)), keccak256(abi.encode(splitsA)));
        }

        {
            JBSplit[] memory configuredSplits = jbSplits()
                .splitsOf(
                    revnetProjectId, jbRulesets().latestRulesetIdOf(revnetProjectId), JBSplitGroupIds.RESERVED_TOKENS
                );
            assertEq(keccak256(abi.encode(configuredSplits)), keccak256(abi.encode(splitsB)));
        }
    }

    function test_loans_has_use_allowance_permission() public view {
        // The loans contract should have USE_ALLOWANCE permission for any revnet via the wildcard grant.
        bool hasPermission = jbPermissions()
            .hasPermission({
                operator: address(REV_DEPLOYER.LOANS()),
                account: address(REV_DEPLOYER),
                projectId: REVNET_ID,
                permissionId: JBPermissionIds.USE_ALLOWANCE,
                includeRoot: false,
                includeWildcardProjectId: true
            });
        assertTrue(hasPermission, "LOANS should have USE_ALLOWANCE for deployed revnet");

        // Also holds for a revnet that doesn't exist yet — the wildcard covers all projects.
        bool hasPermissionForFuture = jbPermissions()
            .hasPermission({
                operator: address(REV_DEPLOYER.LOANS()),
                account: address(REV_DEPLOYER),
                projectId: 999,
                permissionId: JBPermissionIds.USE_ALLOWANCE,
                includeRoot: false,
                includeWildcardProjectId: true
            });
        assertTrue(hasPermissionForFuture, "LOANS should have USE_ALLOWANCE for any project via wildcard");
    }

    function test_deployer_not_owner() public {
        // Build the config.
        FeeProjectConfig memory feeProjectConfig = getFeeProjectConfig();

        vm.expectRevert(abi.encodeWithSelector(REVDeployer.REVDeployer_Unauthorized.selector, FEE_PROJECT_ID, address(this)));
        // Configure the project.
        REVNET_ID = REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID, // Zero to deploy a new revnet
            configuration: feeProjectConfig.configuration,
            terminalConfigurations: feeProjectConfig.terminalConfigurations,
            suckerDeploymentConfiguration: feeProjectConfig.suckerDeploymentConfiguration
        });
    }
}
