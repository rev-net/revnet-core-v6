// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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
import "@bananapus/router-terminal-v6/script/helpers/RouterTerminalDeploymentLib.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {MockPriceFeed} from "@bananapus/core-v6/test/mock/MockPriceFeed.sol";
import {MockERC20} from "@bananapus/core-v6/test/mock/MockERC20.sol";
import {REVLoans} from "../src/REVLoans.sol";
import {REVLoan} from "../src/structs/REVLoan.sol";
import {REVStageConfig, REVAutoIssuance} from "../src/structs/REVStageConfig.sol";
import {REVLoanSource} from "../src/structs/REVLoanSource.sol";
import {REVDescription} from "../src/structs/REVDescription.sol";
import {IREVLoans} from "./../src/interfaces/IREVLoans.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";

contract TestConversionDocumentation is TestBaseWorkflow {
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";
    bytes32 ERC20_SALT = "REV_TOKEN";

    REVDeployer REV_DEPLOYER;
    JB721TiersHook EXAMPLE_HOOK;
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    IJB721TiersHookStore HOOK_STORE;
    IJBAddressRegistry ADDRESS_REGISTRY;
    IREVLoans LOANS_CONTRACT;
    MockERC20 TOKEN;
    IJBSuckerRegistry SUCKER_REGISTRY;
    CTPublisher PUBLISHER;
    MockBuybackDataHook MOCK_BUYBACK;

    uint256 FEE_PROJECT_ID;

    address USER = makeAddr("user");

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    function _getRevnetConfig(
        string memory name,
        string memory symbol,
        bytes32 salt
    )
        internal
        view
        returns (
            REVConfig memory configuration,
            JBTerminalConfig[] memory terminalConfigurations,
            REVSuckerDeploymentConfig memory suckerDeploymentConfiguration
        )
    {
        uint8 decimals = 18;
        uint256 decimalMultiplier = 10 ** decimals;

        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        stageConfigurations[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 2000,
            splits: splits,
            initialIssuance: uint112(1000 * decimalMultiplier),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: 0
        });

        configuration = REVConfig({
            description: REVDescription(name, symbol, "ipfs://test", salt),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations
        });

        suckerDeploymentConfiguration = REVSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked(salt))
        });
    }

    function setUp() public override {
        super.setUp();

        FEE_PROJECT_ID = jbProjects().createFor(multisig());
        SUCKER_REGISTRY = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig(), address(0));
        HOOK_STORE = new JB721TiersHookStore();
        EXAMPLE_HOOK =
            new JB721TiersHook(jbDirectory(), jbPermissions(), jbRulesets(), HOOK_STORE, jbSplits(), multisig());
        ADDRESS_REGISTRY = new JBAddressRegistry();
        HOOK_DEPLOYER = new JB721TiersHookDeployer(EXAMPLE_HOOK, HOOK_STORE, ADDRESS_REGISTRY, multisig());
        PUBLISHER = new CTPublisher(jbDirectory(), jbPermissions(), FEE_PROJECT_ID, multisig());
        MOCK_BUYBACK = new MockBuybackDataHook();
        TOKEN = new MockERC20("1/2 ETH", "1/2");

        LOANS_CONTRACT = new REVLoans({
            controller: jbController(),
            projects: jbProjects(),
            revId: FEE_PROJECT_ID,
            owner: address(this),
            permit2: permit2(),
            trustedForwarder: TRUSTED_FORWARDER
        });

        REV_DEPLOYER = new REVDeployer{salt: REV_DEPLOYER_SALT}(
            jbController(),
            SUCKER_REGISTRY,
            FEE_PROJECT_ID,
            HOOK_DEPLOYER,
            PUBLISHER,
            IJBBuybackHookRegistry(address(MOCK_BUYBACK)),
            address(LOANS_CONTRACT),
            TRUSTED_FORWARDER
        );

        // Deploy fee project as revnet.
        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);

        (REVConfig memory cfg, JBTerminalConfig[] memory terms, REVSuckerDeploymentConfig memory suckerCfg) =
            _getRevnetConfig("Revnet", "$REV", ERC20_SALT);

        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: cfg,
            terminalConfigurations: terms,
            suckerDeploymentConfiguration: suckerCfg
        });
    }

    /// @notice Converting a blank project (no controller, no rulesets) into a revnet succeeds.
    function test_convertBlankProject_succeeds() public {
        // Create blank project owned by USER.
        vm.prank(USER);
        uint256 blankId = jbProjects().createFor(USER);

        // Approve NFT transfer to REV_DEPLOYER.
        vm.prank(USER);
        jbProjects().approve(address(REV_DEPLOYER), blankId);

        // Get revnet config.
        (REVConfig memory cfg, JBTerminalConfig[] memory terms, REVSuckerDeploymentConfig memory suckerCfg) =
            _getRevnetConfig("BlankConvert", "$BLK", "BLANK_TOKEN");

        // Deploy as revnet — should succeed since project is blank.
        vm.prank(USER);
        uint256 deployed = REV_DEPLOYER.deployFor({
            revnetId: blankId,
            configuration: cfg,
            terminalConfigurations: terms,
            suckerDeploymentConfiguration: suckerCfg
        });

        assertEq(deployed, blankId, "Should return the same project ID");
    }

    /// @notice Converting a project that already has a controller/rulesets reverts.
    function test_convertProjectWithController_reverts() public {
        // Create a project owned by USER (an EOA that can receive ERC721s).
        vm.prank(USER);
        uint256 projectId = jbProjects().createFor(USER);

        // Launch rulesets on it directly via the controller (setting a controller + rulesets).
        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        JBTerminalConfig[] memory termConfigs = new JBTerminalConfig[](1);
        termConfigs[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0] = JBRulesetConfig({
            mustStartAtOrAfter: uint48(block.timestamp),
            duration: uint32(90 days),
            weight: uint112(1000e18),
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadata({
                reservedPercent: 0,
                cashOutTaxRate: 0,
                baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
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
                useTotalSurplusForCashOuts: false,
                useDataHookForPay: false,
                useDataHookForCashOut: false,
                dataHook: address(0),
                metadata: 0
            }),
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        vm.prank(USER);
        jbController()
            .launchRulesetsFor({
                projectId: projectId,
                rulesetConfigurations: rulesetConfigs,
                terminalConfigurations: termConfigs,
                memo: ""
            });

        // Now try to convert this project to a revnet — should revert.
        // Approve NFT to REV_DEPLOYER.
        vm.prank(USER);
        jbProjects().approve(address(REV_DEPLOYER), projectId);

        (REVConfig memory cfg, JBTerminalConfig[] memory terms2, REVSuckerDeploymentConfig memory suckerCfg) =
            _getRevnetConfig("FailConvert", "$FAIL", "FAIL_TOKEN");

        // Should revert because rulesets already launched.
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSignature("JBController_RulesetsAlreadyLaunched(uint256)", projectId));
        REV_DEPLOYER.deployFor({
            revnetId: projectId,
            configuration: cfg,
            terminalConfigurations: terms2,
            suckerDeploymentConfiguration: suckerCfg
        });
    }

    /// @notice After deploying a revnet from an existing project, the owner is REVDeployer (irreversible).
    function test_conversionIsIrreversible() public {
        // Create blank project owned by USER.
        vm.prank(USER);
        uint256 blankId = jbProjects().createFor(USER);

        // Approve NFT transfer.
        vm.prank(USER);
        jbProjects().approve(address(REV_DEPLOYER), blankId);

        // Get config.
        (REVConfig memory cfg, JBTerminalConfig[] memory terms, REVSuckerDeploymentConfig memory suckerCfg) =
            _getRevnetConfig("Irreversible", "$IRR", "IRR_TOKEN");

        // Deploy as revnet.
        vm.prank(USER);
        REV_DEPLOYER.deployFor({
            revnetId: blankId,
            configuration: cfg,
            terminalConfigurations: terms,
            suckerDeploymentConfiguration: suckerCfg
        });

        // Verify the project's owner is now the REVDeployer (NFT transferred permanently).
        assertEq(jbProjects().ownerOf(blankId), address(REV_DEPLOYER), "Owner should be REVDeployer after conversion");

        // Verify the original user is no longer the owner.
        assertTrue(jbProjects().ownerOf(blankId) != USER, "Original user should no longer own the project");
    }

    /// @notice Deploy with revnetId=0 creates a new project.
    function test_deployNewRevnet_zeroRevnetId() public {
        (REVConfig memory cfg, JBTerminalConfig[] memory terms, REVSuckerDeploymentConfig memory suckerCfg) =
            _getRevnetConfig("NewRevnet", "$NEW", "NEW_TOKEN");

        uint256 newId = REV_DEPLOYER.deployFor({
            revnetId: 0, configuration: cfg, terminalConfigurations: terms, suckerDeploymentConfiguration: suckerCfg
        });

        // Verify the project was created (ID > fee project).
        assertGt(newId, FEE_PROJECT_ID, "New project ID should be greater than fee project ID");

        // Verify the owner is the REVDeployer.
        assertEq(jbProjects().ownerOf(newId), address(REV_DEPLOYER), "New revnet owner should be REVDeployer");
    }
}
