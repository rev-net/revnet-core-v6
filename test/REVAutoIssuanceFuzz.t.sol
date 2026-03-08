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
import "@croptop/core-v5/script/helpers/CroptopDeploymentLib.sol";
import "@bananapus/swap-terminal-v5/script/helpers/SwapTerminalDeploymentLib.sol";
import "@bananapus/buyback-hook-v5/script/helpers/BuybackDeploymentLib.sol";

import {JBConstants} from "@bananapus/core-v5/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v5/src/structs/JBAccountingContext.sol";
import {REVStageConfig, REVAutoIssuance} from "../src/structs/REVStageConfig.sol";
import {REVLoanSource} from "../src/structs/REVLoanSource.sol";
import {REVDescription} from "../src/structs/REVDescription.sol";
import {REVBuybackPoolConfig} from "../src/structs/REVBuybackPoolConfig.sol";
import {IREVLoans} from "./../src/interfaces/IREVLoans.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v5/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v5/src/JBSuckerRegistry.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v5/src/JB721TiersHookDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v5/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v5/src/JB721TiersHookStore.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v5/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v5/src/interfaces/IJBAddressRegistry.sol";

/// @notice Fuzz tests for REVDeployer multi-stage auto-issuance.
/// Tests stage ID computation consistency and multi-stage claiming behavior.
/// Related to H-5: stage IDs use block.timestamp + i which may mismatch actual ruleset IDs.
contract REVAutoIssuanceFuzz_Local is TestBaseWorkflow, JBTest {
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";

    REVDeployer REV_DEPLOYER;
    JB721TiersHook EXAMPLE_HOOK;
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    IJB721TiersHookStore HOOK_STORE;
    IJBAddressRegistry ADDRESS_REGISTRY;
    IJBSuckerRegistry SUCKER_REGISTRY;
    CTPublisher PUBLISHER;

    uint256 FEE_PROJECT_ID;
    uint256 decimals = 18;
    uint256 decimalMultiplier = 10 ** decimals;

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    function setUp() public override {
        super.setUp();

        FEE_PROJECT_ID = jbProjects().createFor(multisig());

        SUCKER_REGISTRY = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig(), address(0));
        HOOK_STORE = new JB721TiersHookStore();
        EXAMPLE_HOOK = new JB721TiersHook(jbDirectory(), jbPermissions(), jbRulesets(), HOOK_STORE, multisig());
        ADDRESS_REGISTRY = new JBAddressRegistry();
        HOOK_DEPLOYER = new JB721TiersHookDeployer(EXAMPLE_HOOK, HOOK_STORE, ADDRESS_REGISTRY, multisig());
        PUBLISHER = new CTPublisher(jbDirectory(), jbPermissions(), FEE_PROJECT_ID, multisig());

        REV_DEPLOYER = new REVDeployer{salt: REV_DEPLOYER_SALT}(
            jbController(), SUCKER_REGISTRY, FEE_PROJECT_ID, HOOK_DEPLOYER, PUBLISHER, TRUSTED_FORWARDER
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
            description: REVDescription("TestRevnet", "TREV", "ipfs://test", bytes32(uint256(numStages))),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages,
            loanSources: new REVLoanSource[](0),
            loans: address(0)
        });

        REVBuybackPoolConfig[] memory pools = new REVBuybackPoolConfig[](1);
        pools[0] = REVBuybackPoolConfig({token: JBConstants.NATIVE_TOKEN, fee: 10_000, twapWindow: 2 days});

        vm.prank(multisig());
        revnetId = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: config,
            terminalConfigurations: terminalConfigs,
            buybackHookConfiguration: REVBuybackHookConfig({
                dataHook: IJBRulesetDataHook(address(0)),
                hookToConfigure: IJBBuybackHook(address(0)),
                poolConfigurations: pools
            }),
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0),
                salt: keccak256(abi.encodePacked("AUTOISSUE", numStages))
            })
        });
    }

    // ───────────────────── Stage ID computation
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

    // ───────────────────── Multi-stage claiming
    // ─────────────────────

    /// @notice Deploy 3-stage revnet, advance time, claim auto-issuance from each stage.
    function test_multiStage_allStagesClaimable() external {
        (uint256 revnetId, uint256[] memory stageIds) = _deployMultiStageRevnet(3);

        // Stage 0 starts at block.timestamp — immediately claimable.
        REV_DEPLOYER.autoIssueFor(revnetId, stageIds[0], multisig());

        uint256 stage0Amount = (10_000) * decimalMultiplier;
        assertEq(
            IJBToken(jbTokens().tokenOf(revnetId)).balanceOf(multisig()), stage0Amount, "Stage 0 auto-issuance claimed"
        );

        // Stage 1 starts at block.timestamp + 180 days.
        vm.warp(block.timestamp + 180 days);
        REV_DEPLOYER.autoIssueFor(revnetId, stageIds[1], multisig());

        uint256 stage1Amount = (11_000) * decimalMultiplier;
        assertEq(
            IJBToken(jbTokens().tokenOf(revnetId)).balanceOf(multisig()),
            stage0Amount + stage1Amount,
            "Stage 1 auto-issuance claimed"
        );

        // Stage 2 starts at block.timestamp + 360 days.
        vm.warp(block.timestamp + 180 days);
        REV_DEPLOYER.autoIssueFor(revnetId, stageIds[2], multisig());

        uint256 stage2Amount = (12_000) * decimalMultiplier;
        assertEq(
            IJBToken(jbTokens().tokenOf(revnetId)).balanceOf(multisig()),
            stage0Amount + stage1Amount + stage2Amount,
            "Stage 2 auto-issuance claimed"
        );
    }

    // ───────────────────── Wrong stageId reverts
    // ─────────────────────

    /// @notice Calling autoIssueFor with wrong stageId reverts with NothingToAutoIssue.
    function test_stageIdMismatch_nothingToAutoIssue() external {
        (uint256 revnetId,) = _deployMultiStageRevnet(1);

        // Use a wrong stageId.
        uint256 wrongStageId = block.timestamp + 999;

        vm.expectRevert(REVDeployer.REVDeployer_NothingToAutoIssue.selector);
        REV_DEPLOYER.autoIssueFor(revnetId, wrongStageId, multisig());
    }

    // ───────────────────── Double claim prevented
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

    // ───────────────────── Stage not started
    // ─────────────────────

    /// @notice Calling autoIssueFor before stage start time reverts.
    function test_stageNotStarted_reverts() external {
        (uint256 revnetId, uint256[] memory stageIds) = _deployMultiStageRevnet(2);

        // Stage 1 starts at block.timestamp + 180 days.
        // Try to claim it now (before it starts).
        vm.expectRevert(abi.encodeWithSelector(REVDeployer.REVDeployer_StageNotStarted.selector, stageIds[1]));
        REV_DEPLOYER.autoIssueFor(revnetId, stageIds[1], multisig());
    }

    // ───────────────────── H-5: Stage ID vs Ruleset ID comparison
    // ─────────────────────

    /// @notice H-5 EXPLORATION: Compare stored stageIds with actual ruleset IDs.
    /// Stage IDs use block.timestamp + i during deployment.
    /// If actual ruleset IDs differ (e.g., on cross-chain deployment), auto-issuance breaks.
    function test_H5_stageId_vs_rulesetId_comparison() external {
        (uint256 revnetId, uint256[] memory stageIds) = _deployMultiStageRevnet(3);

        // Get the actual rulesets from the controller.
        (JBRuleset memory currentRuleset,) = jbController().currentRulesetOf(revnetId);

        // The first ruleset's ID should match stageIds[0] (both are block.timestamp).
        assertEq(currentRuleset.id, stageIds[0], "First ruleset ID should match stage 0 ID (both block.timestamp)");

        // For stage 1, the stored key is block.timestamp + 1.
        // The actual ruleset ID depends on when JBRulesets creates it.
        // If the ruleset hasn't started yet, getRulesetOf will use the queued ruleset.
        // This is where H-5 manifests: the actual ID may differ from block.timestamp + 1.
        uint256 stage1StoredKey = stageIds[1]; // block.timestamp + 1
        uint256 storedAmount = REV_DEPLOYER.amountToAutoIssue(revnetId, stage1StoredKey, multisig());
        assertGt(storedAmount, 0, "Auto-issuance stored at block.timestamp + 1");

        // Check if the stored key actually corresponds to a valid ruleset.
        // On the same chain/deployment tx, getRulesetOf(block.timestamp + 1) typically works
        // because JBRulesets stores the queued ruleset with that ID.
        // But on a different chain, block.timestamp would differ entirely.
    }
}
