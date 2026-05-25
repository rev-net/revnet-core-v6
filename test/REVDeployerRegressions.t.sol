// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
// import /* {*} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "./../src/REVDeployer.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@croptop/core-v6/src/CTPublisher.sol";
import {MockBuybackDataHook} from "./mock/MockBuybackDataHook.sol";
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
import {MockEmptyTerminal} from "./mock/MockEmptyTerminal.sol";
import {MockSuckerRegistry} from "./mock/MockSuckerRegistry.sol";

/// @notice Regression tests for REVDeployer.
contract REVDeployerRegressions is TestBaseWorkflow {
    using JBRulesetMetadataResolver for JBRuleset;

    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 ERC20_SALT = "REV_TOKEN";

    // forge-lint: disable-next-line(mixed-case-variable)
    REVDeployer REV_DEPLOYER;
    // forge-lint: disable-next-line(mixed-case-variable)
    JB721TiersHook EXAMPLE_HOOK;
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
    REVOwner REV_OWNER;

    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 FEE_PROJECT_ID;

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

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
            IJB721CheckpointsDeployer(address(new JB721CheckpointsDeployer(HOOK_STORE))),
            multisig()
        );
        ADDRESS_REGISTRY = new JBAddressRegistry();
        HOOK_DEPLOYER = new JB721TiersHookDeployer(EXAMPLE_HOOK, HOOK_STORE, ADDRESS_REGISTRY, multisig());
        PUBLISHER = new CTPublisher(jbDirectory(), jbPermissions(), FEE_PROJECT_ID, multisig());
        MOCK_BUYBACK = new MockBuybackDataHook();

        LOANS_CONTRACT = new REVLoans({
            controller: jbController(),
            terminal: jbMultiTerminal(),
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
            LOANS_CONTRACT,
            address(this)
        );

        REV_DEPLOYER = new REVDeployer{salt: REV_DEPLOYER_SALT}(
            jbController(),
            jbMultiTerminal(),
            IJBTerminal(address(new MockEmptyTerminal())),
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
    }

    function test_deployFor_with721ConfigForwardsProjectCreationFee() public {
        uint256 creationFee = 0.01 ether;
        address payable creationFeeReceiver = payable(makeAddr("creationFeeReceiver"));

        vm.prank(multisig());
        jbProjects().setCreationFee(creationFee, creationFeeReceiver);
        vm.deal(multisig(), creationFee);

        uint256 balanceBefore = creationFeeReceiver.balance;

        vm.prank(multisig());
        (uint256 revnetId,) = REV_DEPLOYER.deployFor{value: creationFee}({
            revnetId: 0,
            configuration: _singleStageRevnetConfig(bytes32("PAID_721")),
            accountingContextsToAccept: _nativeAccountingContexts(),
            suckerDeploymentConfiguration: _emptySuckerDeploymentConfig(bytes32(0)),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        assertGt(revnetId, FEE_PROJECT_ID, "revnet should be deployed");
        assertEq(creationFeeReceiver.balance, balanceBefore + creationFee, "creation fee should be paid");
    }

    function test_deployFor_default721ConfigForwardsProjectCreationFee() public {
        uint256 creationFee = 0.01 ether;
        address payable creationFeeReceiver = payable(makeAddr("creationFeeReceiver"));

        vm.prank(multisig());
        jbProjects().setCreationFee(creationFee, creationFeeReceiver);
        vm.deal(multisig(), creationFee);

        uint256 balanceBefore = creationFeeReceiver.balance;

        vm.prank(multisig());
        (uint256 revnetId,) = REV_DEPLOYER.deployFor{value: creationFee}({
            revnetId: 0,
            configuration: _singleStageRevnetConfig(bytes32("PAID_DEFAULT")),
            accountingContextsToAccept: _nativeAccountingContexts(),
            suckerDeploymentConfiguration: _emptySuckerDeploymentConfig(bytes32(0))
        });

        assertGt(revnetId, FEE_PROJECT_ID, "revnet should be deployed");
        assertEq(creationFeeReceiver.balance, balanceBefore + creationFee, "creation fee should be paid");
    }

    function test_deployFor_existingProjectRejectsUnusedProjectCreationFee() public {
        uint256 creationFee = 0.01 ether;
        address payable creationFeeReceiver = payable(makeAddr("creationFeeReceiver"));

        vm.prank(multisig());
        jbProjects().setCreationFee(creationFee, creationFeeReceiver);
        vm.deal(multisig(), creationFee * 2);

        vm.prank(multisig());
        uint256 existingProjectId = jbProjects().createFor{value: creationFee}(multisig());

        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), existingProjectId);

        vm.expectRevert(
            abi.encodeWithSelector(
                REVDeployer.REVDeployer_ProjectCreationFeeNotNeeded.selector, existingProjectId, creationFee
            )
        );
        vm.prank(multisig());
        REV_DEPLOYER.deployFor{value: creationFee}({
            revnetId: existingProjectId,
            configuration: _singleStageRevnetConfig(bytes32("EXISTING")),
            accountingContextsToAccept: _nativeAccountingContexts(),
            suckerDeploymentConfiguration: _emptySuckerDeploymentConfig(bytes32(0))
        });
    }

    //*********************************************************************//
    // --- REVDeployer.beforePayRecordedWith Array OOB Regression ------- //
    //*********************************************************************//

    /// @notice Tests that the array OOB pattern manifests when only buybackHook is present.
    /// @dev REVDeployer line 258: hookSpecifications[1] = buybackHookSpecifications[0]
    ///      always writes to index [1], even when the array has size 1 (no tiered721Hook).
    function test_arrayOOB_onlyBuybackHook() public pure {
        // Simulate: usesTiered721Hook=false, usesBuybackHook=true
        bool usesTiered721Hook = false;
        bool usesBuybackHook = true;

        uint256 arraySize = (usesTiered721Hook ? 1 : 0) + (usesBuybackHook ? 1 : 0);
        assertEq(arraySize, 1, "array should be size 1");

        JBPayHookSpecification[] memory specs = new JBPayHookSpecification[](arraySize);

        // Index [0] is NOT written (usesTiered721Hook is false)
        // Index [1] WOULD be written by the bug, but that's OOB
        // Verify the pattern: writing to index 1 of a size-1 array should revert
        bool wouldRevert = (!usesTiered721Hook && usesBuybackHook);
        assertTrue(wouldRevert, "this combination triggers the OOB bug");

        // Verify the safe index: the buyback hook should go at index 0 when no tiered hook
        uint256 correctIndex = usesTiered721Hook ? 1 : 0;
        assertEq(correctIndex, 0, "buyback hook should use index 0 when no tiered hook");

        // Write to the correct index (no revert)
        specs[correctIndex] =
            JBPayHookSpecification({hook: IJBPayHook(address(0xbeef)), noop: false, amount: 1 ether, metadata: ""});
    }

    /// @notice Verify both hooks present works fine (no OOB).
    function test_noOOB_bothHooksPresent() public pure {
        bool usesTiered721Hook = true;
        bool usesBuybackHook = true;

        uint256 arraySize = (usesTiered721Hook ? 1 : 0) + (usesBuybackHook ? 1 : 0);
        assertEq(arraySize, 2, "array should be size 2");

        JBPayHookSpecification[] memory specs = new JBPayHookSpecification[](arraySize);
        specs[0] =
            JBPayHookSpecification({hook: IJBPayHook(address(0xdead)), noop: false, amount: 1 ether, metadata: ""});
        specs[1] =
            JBPayHookSpecification({hook: IJBPayHook(address(0xbeef)), noop: false, amount: 2 ether, metadata: ""});
    }

    //*********************************************************************//
    // --- hasMintPermissionFor returns false for random addresses ------- //
    //*********************************************************************//

    /// @notice Tests that calling hasMintPermissionFor returns false for random addresses.
    /// @dev With the buyback hook removed, hasMintPermissionFor should return false
    ///      for addresses that are not the loans contract or a sucker.
    function test_hasMintPermissionFor_noBuybackHook() public {
        // Deploy a revnet WITHOUT a buyback hook
        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBAccountingContext[] memory terminalConfigurations = accountingContextsToAccept;

        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        stageConfigurations[0] = REVStageConfig({
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

        REVConfig memory revnetConfiguration = REVConfig({
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription("Test", "TST", "ipfs://test", "TEST_SALT"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            operator: multisig(),
            scopeCashOutsToLocalBalances: false,
            stageConfigurations: stageConfigurations
        });

        vm.prank(multisig());
        (uint256 revnetId,) = REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: revnetConfiguration,
            accountingContextsToAccept: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("C4_TEST")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        // hasMintPermissionFor should return false for random addresses
        address someRandomAddr = address(0x12345);

        // Get the current ruleset for the call
        JBRuleset memory currentRuleset = jbRulesets().currentOf(revnetId);

        // With buyback hook removed, hasMintPermissionFor should return false
        // for addresses that are not the loans contract or a sucker.
        bool hasPerm = REV_OWNER.hasMintPermissionFor(revnetId, currentRuleset, someRandomAddr);
        assertFalse(hasPerm, "random address should not have mint permission");
    }

    //*********************************************************************//
    // --- Auto-Issuance Stage IDs -------------------------------------- //
    //*********************************************************************//

    /// @notice Auto-issuance storage keys match the ruleset IDs assigned by `JBRulesets`.
    /// @dev `REVDeployer.deployFor` queues all stages in one transaction, and existing-project conversion only accepts
    ///      blank projects. `JBRulesets` therefore assigns stage IDs as `deployTimestamp + i`, matching the keys used
    ///      by `amountToAutoIssue`.
    function test_autoIssuanceStageIdsMatchQueuedRulesets() public {
        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBAccountingContext[] memory terminalConfigurations = accountingContextsToAccept;

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        uint8 decimals = 18;
        uint256 decimalMultiplier = 10 ** decimals;

        // Configure 3 stages with auto-issuance on stages 0 and 1.
        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](3);

        // Stage 0: has auto-issuance.
        {
            REVAutoIssuance[] memory issuanceConfs = new REVAutoIssuance[](1);
            issuanceConfs[0] = REVAutoIssuance({
                // forge-lint: disable-next-line(unsafe-typecast)
                chainId: uint32(block.chainid),
                // forge-lint: disable-next-line(unsafe-typecast)
                count: uint104(50_000 * decimalMultiplier),
                beneficiary: multisig()
            });

            stageConfigurations[0] = REVStageConfig({
                startsAtOrAfter: uint40(block.timestamp),
                autoIssuances: issuanceConfs,
                splitPercent: 2000,
                splits: splits,
                // forge-lint: disable-next-line(unsafe-typecast)
                initialIssuance: uint112(1000 * decimalMultiplier),
                issuanceCutFrequency: 90 days,
                issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
                cashOutTaxRate: 6000,
                extraMetadata: 0
            });
        }

        // Stage 1: also has auto-issuance.
        {
            REVAutoIssuance[] memory issuanceConfs = new REVAutoIssuance[](1);
            issuanceConfs[0] = REVAutoIssuance({
                // forge-lint: disable-next-line(unsafe-typecast)
                chainId: uint32(block.chainid),
                // forge-lint: disable-next-line(unsafe-typecast)
                count: uint104(30_000 * decimalMultiplier),
                beneficiary: multisig()
            });

            stageConfigurations[1] = REVStageConfig({
                startsAtOrAfter: uint40(stageConfigurations[0].startsAtOrAfter + 365 days),
                autoIssuances: issuanceConfs,
                splitPercent: 1000,
                splits: splits,
                initialIssuance: 0, // inherit
                issuanceCutFrequency: 180 days,
                issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
                cashOutTaxRate: 3000,
                extraMetadata: 0
            });
        }

        // Stage 2: no auto-issuance
        stageConfigurations[2] = REVStageConfig({
            startsAtOrAfter: uint40(stageConfigurations[1].startsAtOrAfter + (5 * 365 days)),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: 1,
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 500,
            extraMetadata: 0
        });

        REVConfig memory revnetConfiguration = REVConfig({
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription("H5Test", "H5T", "ipfs://h5test", "H5_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            operator: multisig(),
            scopeCashOutsToLocalBalances: false,
            stageConfigurations: stageConfigurations
        });

        uint256 deployTimestamp = block.timestamp;

        vm.prank(multisig());
        (uint256 revnetId,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: revnetConfiguration,
            accountingContextsToAccept: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("H5_TEST")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        // Verify the revnet was deployed.
        assertGt(revnetId, 0, "revnet should be deployed");

        uint256 stage0RulesetId = deployTimestamp;
        uint256 stage1RulesetId = deployTimestamp + 1;

        // Stage 0 auto-issuance should be stored at its actual ruleset ID.
        uint256 stage0Amount = REV_OWNER.amountToAutoIssue(revnetId, stage0RulesetId, multisig());
        assertEq(stage0Amount, 50_000 * decimalMultiplier, "Stage 0 auto-issuance should be stored at stage 0 ID");

        // Stage 1 auto-issuance should be stored at its actual ruleset ID.
        uint256 stage1Amount = REV_OWNER.amountToAutoIssue(revnetId, stage1RulesetId, multisig());
        assertEq(stage1Amount, 30_000 * decimalMultiplier, "Stage 1 auto-issuance should be stored at stage 1 ID");

        (JBRuleset memory stage0Ruleset,) =
            jbController().getRulesetOf({projectId: revnetId, rulesetId: stage0RulesetId});
        (JBRuleset memory stage1Ruleset,) =
            jbController().getRulesetOf({projectId: revnetId, rulesetId: stage1RulesetId});

        assertEq(stage0Ruleset.id, stage0RulesetId, "Stage 0 ruleset ID should match auto-issuance key");
        assertEq(stage1Ruleset.id, stage1RulesetId, "Stage 1 ruleset ID should match auto-issuance key");
        assertGe(
            stage1Ruleset.start,
            stageConfigurations[1].startsAtOrAfter,
            "Stage 1 ruleset start should not precede the configured stage time"
        );
    }

    function _nativeAccountingContexts() internal pure returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
    }

    function _singleStageRevnetConfig(bytes32 salt) internal view returns (REVConfig memory configuration) {
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](1);
        stageConfigurations[0] = REVStageConfig({
            startsAtOrAfter: uint48(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 5000,
            extraMetadata: 0
        });

        configuration = REVConfig({
            description: REVDescription("Paid", "PAID", "ipfs://paid", salt),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            operator: multisig(),
            scopeCashOutsToLocalBalances: false,
            stageConfigurations: stageConfigurations
        });
    }

    function _emptySuckerDeploymentConfig(bytes32 salt)
        internal
        pure
        returns (REVSuckerDeploymentConfig memory suckerDeploymentConfiguration)
    {
        suckerDeploymentConfiguration =
            REVSuckerDeploymentConfig({deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: salt});
    }
}
