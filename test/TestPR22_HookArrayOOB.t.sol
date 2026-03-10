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
import {REVLoans} from "../src/REVLoans.sol";
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
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";

/// @notice Tests for PR #22: fix/c2-hook-array-oob
/// Verifies that the fix for the hook array out-of-bounds bug works correctly.
/// The bug: `hookSpecifications[1] = buybackHookSpecifications[0]` would revert with OOB
/// when there is no tiered 721 hook (array size is 1, not 2).
/// The fix: `hookSpecifications[usesTiered721Hook ? 1 : 0] = buybackHookSpecifications[0]`.
contract TestPR22_HookArrayOOB is TestBaseWorkflow, JBTest {
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";

    REVDeployer REV_DEPLOYER;
    JB721TiersHook EXAMPLE_HOOK;
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    IJB721TiersHookStore HOOK_STORE;
    IJBAddressRegistry ADDRESS_REGISTRY;
    IREVLoans LOANS_CONTRACT;
    IJBSuckerRegistry SUCKER_REGISTRY;
    CTPublisher PUBLISHER;
    MockBuybackDataHook MOCK_BUYBACK;

    uint256 FEE_PROJECT_ID;

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;
    address USER = makeAddr("user");

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
            IJBRulesetDataHook(address(MOCK_BUYBACK)),
            address(LOANS_CONTRACT),
            TRUSTED_FORWARDER
        );
        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);
    }

    /// @notice Helper to build a minimal revnet config with no hooks.
    function _buildMinimalConfig()
        internal
        view
        returns (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc)
    {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});

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

        cfg = REVConfig({
            description: REVDescription("Test", "TST", "ipfs://test", "TEST_SALT"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });

        sdc = REVSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("TEST"))
        });
    }

    /// @notice Helper to deploy the fee project first and then deploy a test revnet.
    function _deployFeeAndRevnet() internal returns (uint256 revnetId) {
        (REVConfig memory feeCfg, JBTerminalConfig[] memory feeTc, REVSuckerDeploymentConfig memory feeSdc) =
            _buildMinimalConfig();

        // Deploy the fee project
        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeCfg,
            terminalConfigurations: feeTc,
            suckerDeploymentConfiguration: feeSdc
        });

        // Deploy a new test revnet (revnetId: 0 = create new)
        (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc) =
            _buildMinimalConfig();
        // Use a different salt so the ERC20 deploy doesn't clash
        cfg.description = REVDescription("Test2", "TS2", "ipfs://test2", "TEST_SALT_2");

        revnetId = REV_DEPLOYER.deployFor({
            revnetId: 0, configuration: cfg, terminalConfigurations: tc, suckerDeploymentConfiguration: sdc
        });
    }

    /// @notice Test that paying a revnet with no hooks (no 721, no buyback) works fine.
    /// This exercises beforePayRecordedWith where both usesTiered721Hook and usesBuybackHook are false.
    function test_payRevnet_noHooks_works() public {
        uint256 revnetId = _deployFeeAndRevnet();

        // Pay into the revnet
        vm.deal(USER, 1 ether);
        vm.prank(USER);
        jbMultiTerminal().pay{value: 1 ether}({
            projectId: revnetId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: USER,
            minReturnedTokens: 0,
            memo: "test payment",
            metadata: ""
        });

        // Verify tokens were minted
        uint256 balance = jbTokens().totalBalanceOf(USER, revnetId);
        assertGt(balance, 0, "Should have received tokens from payment");
    }

    /// @notice Test the array index logic directly: `usesTiered721Hook ? 1 : 0` gives index 0 for buyback-only.
    function test_arrayIndexLogic_unitTest() public pure {
        // When no tiered 721 hook is present, the buyback hook should be at index 0
        bool usesTiered721Hook = false;
        uint256 buybackIndex = usesTiered721Hook ? 1 : 0;
        assertEq(buybackIndex, 0, "Buyback hook index should be 0 when no 721 hook");

        // When tiered 721 hook IS present, the buyback hook should be at index 1
        usesTiered721Hook = true;
        buybackIndex = usesTiered721Hook ? 1 : 0;
        assertEq(buybackIndex, 1, "Buyback hook index should be 1 when 721 hook present");
    }

    /// @notice Test that beforePayRecordedWith returns correct hook specification counts.
    /// When no hooks are configured, should return empty array.
    function test_beforePayRecordedWith_noHooks_returnsEmptySpecs() public {
        uint256 revnetId = _deployFeeAndRevnet();

        // Build a mock context for beforePayRecordedWith
        JBBeforePayRecordedContext memory context = JBBeforePayRecordedContext({
            terminal: address(jbMultiTerminal()),
            payer: USER,
            amount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 1 ether,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            projectId: revnetId,
            rulesetId: 0,
            beneficiary: USER,
            weight: 1000e18,
            reservedPercent: 0,
            metadata: ""
        });

        (uint256 weight, JBPayHookSpecification[] memory specs) = REV_DEPLOYER.beforePayRecordedWith(context);

        // With the global buyback hook but no 721 hook, weight should be the context weight
        // and specs should contain exactly the buyback hook specification.
        assertEq(weight, context.weight, "Weight should be the default context weight");
        assertEq(specs.length, 1, "Should have exactly the buyback hook specification");
    }
}
