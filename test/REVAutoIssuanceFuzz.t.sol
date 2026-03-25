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
import {REVStageConfig, REVAutoIssuance} from "../src/structs/REVStageConfig.sol";
import {REVDescription} from "../src/structs/REVDescription.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {REVEmpty721Config} from "./helpers/REVEmpty721Config.sol";

/// @notice Fuzz tests for REVDeployer multi-stage auto-issuance.
/// Tests stage ID computation consistency and multi-stage claiming behavior.
/// Stage IDs use block.timestamp + i which may mismatch actual ruleset IDs.
contract REVAutoIssuanceFuzz_Local is TestBaseWorkflow {
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";

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
    IJBSuckerRegistry SUCKER_REGISTRY;
    // forge-lint: disable-next-line(mixed-case-variable)
    CTPublisher PUBLISHER;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockBuybackDataHook MOCK_BUYBACK;

    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 FEE_PROJECT_ID;
    uint256 decimals = 18;
    uint256 decimalMultiplier = 10 ** decimals;

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    function setUp() public override {
        super.setUp();

        FEE_PROJECT_ID = jbProjects().createFor(multisig());

        SUCKER_REGISTRY = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig(), address(0));
        HOOK_STORE = new JB721TiersHookStore();
        EXAMPLE_HOOK = new JB721TiersHook(
            jbDirectory(), jbPermissions(), jbPrices(), jbRulesets(), HOOK_STORE, jbSplits(), multisig()
        );
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
            IJBBuybackHookRegistry(address(MOCK_BUYBACK)),
            makeAddr("loans"),
            TRUSTED_FORWARDER
        );

        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);
    }

    /// @dev Deploy a revnet with N stages, each with auto-issuance.
    function _deployMultiStageRevnet(uint256 numStages) internal returns (uint256 revnetId, uint256[] memory stageIds) {
        require(numStages >= 1 && numStages <= 5, "1-5 stages");

        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: tokensToAccept});

        REVStageConfig[] memory stages = new REVStageConfig[](numStages);
        stageIds = new uint256[](numStages);

        for (uint256 i; i < numStages; i++) {
            REVAutoIssuance[] memory autoIssuances = new REVAutoIssuance[](1);
            autoIssuances[0] = REVAutoIssuance({
                chainId: uint32(block.chainid),
                // forge-lint: disable-next-line(unsafe-typecast)
                count: uint104((10_000 + i * 1000) * decimalMultiplier),
                beneficiary: multisig()
            });

            JBSplit[] memory splits = new JBSplit[](1);
            splits[0].beneficiary = payable(multisig());
            splits[0].percent = 10_000;

            uint40 startsAt;
            if (i == 0) {
                startsAt = uint40(block.timestamp);
            } else {
                startsAt = uint40(stages[i - 1].startsAtOrAfter + 180 days);
            }

            stages[i] = REVStageConfig({
                startsAtOrAfter: startsAt,
                autoIssuances: autoIssuances,
                splitPercent: 2000,
                splits: splits,
                // forge-lint: disable-next-line(unsafe-typecast)
                initialIssuance: uint112(1000 * decimalMultiplier),
                issuanceCutFrequency: 90 days,
                issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
                cashOutTaxRate: 6000,
                extraMetadata: 0
            });

            // Stage IDs are stored as block.timestamp + i.
            stageIds[i] = block.timestamp + i;
        }

        REVConfig memory config = REVConfig({
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription("TestRevnet", "TREV", "ipfs://test", bytes32(uint256(numStages))),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });

        vm.prank(multisig());
        (revnetId,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: config,
            terminalConfigurations: terminalConfigs,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0),
                salt: keccak256(abi.encodePacked("AUTOISSUE", numStages))
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    // ───────────────── Stage ID computation
    // ─────────────────────

    /// @notice Verify all auto-issuance storage keys match block.timestamp + i for 3 stages.
    function test_stageIdComputation_3stages() external {
        (uint256 revnetId, uint256[] memory stageIds) = _deployMultiStageRevnet(3);

        // Verify storage keys.
        for (uint256 i; i < 3; i++) {
            uint256 storedAmount = REV_DEPLOYER.amountToAutoIssue(revnetId, stageIds[i], multisig());
            uint256 expectedAmount = (10_000 + i * 1000) * decimalMultiplier;
            assertEq(storedAmount, expectedAmount, string.concat("Stage ", vm.toString(i), " storage mismatch"));
        }
    }

    // ───────────────── Multi-stage claiming
    // ─────────────────────

    /// @notice Deploy 3-stage revnet, advance time, claim auto-issuance from each stage.
    function test_multiStage_allStagesClaimable() external {
        // Save the deploy timestamp for absolute warp targets.
        uint256 deployTs = block.timestamp;

        (uint256 revnetId, uint256[] memory stageIds) = _deployMultiStageRevnet(3);

        // Stage 0 starts at deploy time — immediately claimable.
        REV_DEPLOYER.autoIssueFor(revnetId, stageIds[0], multisig());

        uint256 stage0Amount = (10_000) * decimalMultiplier;
        assertEq(
            IJBToken(jbTokens().tokenOf(revnetId)).balanceOf(multisig()), stage0Amount, "Stage 0 auto-issuance claimed"
        );

        // Stage 1 starts at deployTs + 180 days.
        vm.warp(deployTs + 180 days);
        REV_DEPLOYER.autoIssueFor(revnetId, stageIds[1], multisig());

        uint256 stage1Amount = (11_000) * decimalMultiplier;
        assertEq(
            IJBToken(jbTokens().tokenOf(revnetId)).balanceOf(multisig()),
            stage0Amount + stage1Amount,
            "Stage 1 auto-issuance claimed"
        );

        // Stage 2 starts at deployTs + 360 days.
        vm.warp(deployTs + 360 days);
        REV_DEPLOYER.autoIssueFor(revnetId, stageIds[2], multisig());

        uint256 stage2Amount = (12_000) * decimalMultiplier;
        assertEq(
            IJBToken(jbTokens().tokenOf(revnetId)).balanceOf(multisig()),
            stage0Amount + stage1Amount + stage2Amount,
            "Stage 2 auto-issuance claimed"
        );
    }

    // ───────────────── Wrong stageId reverts
    // ─────────────────────

    /// @notice Calling autoIssueFor with wrong stageId reverts with NothingToAutoIssue.
    function test_stageIdMismatch_nothingToAutoIssue() external {
        (uint256 revnetId,) = _deployMultiStageRevnet(1);

        // Use a wrong stageId.
        uint256 wrongStageId = block.timestamp + 999;

        vm.expectRevert(REVDeployer.REVDeployer_NothingToAutoIssue.selector);
        REV_DEPLOYER.autoIssueFor(revnetId, wrongStageId, multisig());
    }

    // ───────────────── Double claim prevented
    // ─────────────────────

    /// @notice Claiming once zeroes storage; second claim reverts.
    function test_autoIssue_doubleClaimPrevented() external {
        (uint256 revnetId, uint256[] memory stageIds) = _deployMultiStageRevnet(1);

        // First claim succeeds.
        REV_DEPLOYER.autoIssueFor(revnetId, stageIds[0], multisig());

        // Storage should be zeroed.
        assertEq(
            REV_DEPLOYER.amountToAutoIssue(revnetId, stageIds[0], multisig()), 0, "Storage should be zeroed after claim"
        );

        // Second claim reverts.
        vm.expectRevert(REVDeployer.REVDeployer_NothingToAutoIssue.selector);
        REV_DEPLOYER.autoIssueFor(revnetId, stageIds[0], multisig());
    }

    // ───────────────── Stage not started
    // ─────────────────────

    /// @notice Calling autoIssueFor before stage start time reverts.
    function test_stageNotStarted_reverts() external {
        (uint256 revnetId, uint256[] memory stageIds) = _deployMultiStageRevnet(2);

        // Stage 1 starts at block.timestamp + 180 days.
        // Try to claim it now (before it starts).
        vm.expectRevert(abi.encodeWithSelector(REVDeployer.REVDeployer_StageNotStarted.selector, stageIds[1]));
        REV_DEPLOYER.autoIssueFor(revnetId, stageIds[1], multisig());
    }

    // ───────────────── Stage ID vs Ruleset ID comparison
    // ─────────────────────

    /// @notice Compare stored stageIds with actual ruleset IDs.
    /// Stage IDs use block.timestamp + i during deployment.
    /// If actual ruleset IDs differ (e.g., on cross-chain deployment), auto-issuance breaks.
    function test_stageId_vs_rulesetId_comparison() external {
        (uint256 revnetId, uint256[] memory stageIds) = _deployMultiStageRevnet(3);

        // Get the actual rulesets from the controller.
        (JBRuleset memory currentRuleset,) = jbController().currentRulesetOf(revnetId);

        // The first ruleset's ID should match stageIds[0] (both are block.timestamp).
        assertEq(currentRuleset.id, stageIds[0], "First ruleset ID should match stage 0 ID (both block.timestamp)");

        // For stage 1, the stored key is block.timestamp + 1.
        // The actual ruleset ID depends on when JBRulesets creates it.
        // If the ruleset hasn't started yet, getRulesetOf will use the queued ruleset.
        // The actual ID may differ from block.timestamp + 1.
        uint256 stage1StoredKey = stageIds[1]; // block.timestamp + 1
        uint256 storedAmount = REV_DEPLOYER.amountToAutoIssue(revnetId, stage1StoredKey, multisig());
        assertGt(storedAmount, 0, "Auto-issuance stored at block.timestamp + 1");

        // Check if the stored key actually corresponds to a valid ruleset.
        // On the same chain/deployment tx, getRulesetOf(block.timestamp + 1) typically works
        // because JBRulesets stores the queued ruleset with that ID.
        // But on a different chain, block.timestamp would differ entirely.
    }
}
