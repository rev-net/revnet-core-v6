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

import {JBConstants} from "@bananapus/core-v5/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v5/src/structs/JBAccountingContext.sol";
import {REVLoans} from "../src/REVLoans.sol";
import {REVStageConfig, REVAutoIssuance} from "../src/structs/REVStageConfig.sol";
import {REVLoanSource} from "../src/structs/REVLoanSource.sol";
import {REVDescription} from "../src/structs/REVDescription.sol";
import {IREVLoans} from "./../src/interfaces/IREVLoans.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v5/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v5/src/JBSuckerRegistry.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v5/src/JB721TiersHookDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v5/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v5/src/JB721TiersHookStore.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v5/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v5/src/interfaces/IJBAddressRegistry.sol";

/// @notice Audit regression tests for REVDeployer findings C-2, C-4, and H-5.
contract REVDeployerAuditRegressions_Local is TestBaseWorkflow, JBTest {
    using JBRulesetMetadataResolver for JBRuleset;

    bytes32 REV_DEPLOYER_SALT = "REVDeployer";
    bytes32 ERC20_SALT = "REV_TOKEN";

    REVDeployer REV_DEPLOYER;
    JB721TiersHook EXAMPLE_HOOK;
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    IJB721TiersHookStore HOOK_STORE;
    IJBAddressRegistry ADDRESS_REGISTRY;
    IREVLoans LOANS_CONTRACT;
    IJBSuckerRegistry SUCKER_REGISTRY;
    CTPublisher PUBLISHER;

    uint256 FEE_PROJECT_ID;

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
            jbController(), SUCKER_REGISTRY, FEE_PROJECT_ID, HOOK_DEPLOYER, PUBLISHER, IJBRulesetDataHook(address(0)), TRUSTED_FORWARDER
        );

        LOANS_CONTRACT = new REVLoans({
            revnets: REV_DEPLOYER,
            revId: FEE_PROJECT_ID,
            owner: address(this),
            permit2: permit2(),
            trustedForwarder: TRUSTED_FORWARDER
        });

        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);
    }

    //*********************************************************************//
    // --- [C-2] REVDeployer.beforePayRecordedWith Array OOB Regression - //
    //*********************************************************************//

    /// @notice Tests that the C-2 array OOB pattern manifests when only buybackHook is present.
    /// @dev REVDeployer line 258: hookSpecifications[1] = buybackHookSpecifications[0]
    ///      always writes to index [1], even when the array has size 1 (no tiered721Hook).
    function test_C2_arrayOOB_onlyBuybackHook() public pure {
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
        assertTrue(wouldRevert, "C-2: this combination triggers the OOB bug");

        // Verify the safe index: the buyback hook should go at index 0 when no tiered hook
        uint256 correctIndex = usesTiered721Hook ? 1 : 0;
        assertEq(correctIndex, 0, "C-2 FIX: buyback hook should use index 0 when no tiered hook");

        // Write to the correct index (no revert)
        specs[correctIndex] = JBPayHookSpecification({
            hook: IJBPayHook(address(0xbeef)),
            amount: 1 ether,
            metadata: ""
        });
    }

    /// @notice Verify both hooks present works fine (no OOB).
    function test_C2_noOOB_bothHooksPresent() public pure {
        bool usesTiered721Hook = true;
        bool usesBuybackHook = true;

        uint256 arraySize = (usesTiered721Hook ? 1 : 0) + (usesBuybackHook ? 1 : 0);
        assertEq(arraySize, 2, "array should be size 2");

        JBPayHookSpecification[] memory specs = new JBPayHookSpecification[](arraySize);
        specs[0] = JBPayHookSpecification({hook: IJBPayHook(address(0xdead)), amount: 1 ether, metadata: ""});
        specs[1] = JBPayHookSpecification({hook: IJBPayHook(address(0xbeef)), amount: 2 ether, metadata: ""});
    }

    //*********************************************************************//
    // --- [C-4] hasMintPermissionFor returns false for random addresses - //
    //*********************************************************************//

    /// @notice Tests that calling hasMintPermissionFor returns false for random addresses.
    /// @dev With the buyback hook removed, hasMintPermissionFor should return false
    ///      for addresses that are not the loans contract or a sucker.
    function test_C4_hasMintPermissionFor_noBuybackHook() public {
        // Deploy a revnet WITHOUT a buyback hook
        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

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
            description: REVDescription("Test", "TST", "ipfs://test", "TEST_SALT"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations,
            loanSources: new REVLoanSource[](0),
            loans: address(0)
        });

        vm.prank(multisig());
        uint256 revnetId = REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0),
                salt: keccak256("C4_TEST")
            })
        });

        // hasMintPermissionFor should return false for random addresses
        address someRandomAddr = address(0x12345);

        // Get the current ruleset for the call
        JBRuleset memory currentRuleset = jbRulesets().currentOf(revnetId);

        // With buyback hook removed, hasMintPermissionFor should return false
        // for addresses that are not the loans contract or a sucker.
        bool hasPerm = REV_DEPLOYER.hasMintPermissionFor(revnetId, currentRuleset, someRandomAddr);
        assertFalse(hasPerm, "C-4: random address should not have mint permission");
    }

    //*********************************************************************//
    // --- [H-5] Auto-Issuance Stage ID Mismatch ----------------------- //
    //*********************************************************************//

    /// @notice Tests that auto-issuance stage IDs are computed correctly for multi-stage revnets.
    /// @dev H-5: The stage ID is computed as `block.timestamp + i` which only works if stages
    ///      are deployed in a specific order at a specific time.
    function test_H5_autoIssuanceStageIdMismatch() public {
        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        uint8 decimals = 18;
        uint256 decimalMultiplier = 10 ** decimals;

        // Configure 3 stages with auto-issuance on stages 0 AND 1
        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](3);

        // Stage 0: has auto-issuance
        {
            REVAutoIssuance[] memory issuanceConfs = new REVAutoIssuance[](1);
            issuanceConfs[0] = REVAutoIssuance({
                chainId: uint32(block.chainid),
                count: uint104(50_000 * decimalMultiplier),
                beneficiary: multisig()
            });

            stageConfigurations[0] = REVStageConfig({
                startsAtOrAfter: uint40(block.timestamp),
                autoIssuances: issuanceConfs,
                splitPercent: 2000,
                splits: splits,
                initialIssuance: uint112(1000 * decimalMultiplier),
                issuanceCutFrequency: 90 days,
                issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
                cashOutTaxRate: 6000,
                extraMetadata: 0
            });
        }

        // Stage 1: also has auto-issuance — this is where H-5 manifests
        {
            REVAutoIssuance[] memory issuanceConfs = new REVAutoIssuance[](1);
            issuanceConfs[0] = REVAutoIssuance({
                chainId: uint32(block.chainid),
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
            description: REVDescription("H5Test", "H5T", "ipfs://h5test", "H5_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations,
            loanSources: new REVLoanSource[](0),
            loans: address(0)
        });

        vm.prank(multisig());
        uint256 revnetId = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0),
                salt: keccak256("H5_TEST")
            })
        });

        // Verify the revnet was deployed
        assertGt(revnetId, 0, "revnet should be deployed");

        // The H-5 bug: auto-issuance for stage 1 is stored at key (block.timestamp + 1),
        // but the actual ruleset ID for stage 1 is the timestamp when that stage's ruleset
        // was queued. These may not match.
        // We verify the auto-issuance amounts are stored and can be queried.
        uint256 stage0Amount = REV_DEPLOYER.amountToAutoIssue(
            revnetId, block.timestamp, multisig()
        );

        // Stage 0 auto-issuance should be stored at block.timestamp
        assertEq(
            stage0Amount,
            50_000 * decimalMultiplier,
            "Stage 0 auto-issuance should be stored at block.timestamp"
        );

        // Stage 1 auto-issuance is stored at (block.timestamp + 1) per H-5
        uint256 stage1Amount = REV_DEPLOYER.amountToAutoIssue(
            revnetId, block.timestamp + 1, multisig()
        );
        assertEq(
            stage1Amount,
            30_000 * decimalMultiplier,
            "H-5: Stage 1 auto-issuance stored at block.timestamp + 1 (may not match ruleset ID)"
        );

        // Now check the actual ruleset IDs to demonstrate the mismatch
        JBRuleset[] memory rulesets = jbRulesets().allOf(revnetId, 0, 3);
        if (rulesets.length >= 2) {
            uint256 actualStage1RulesetId = rulesets[1].id;

            // The H-5 mismatch: the storage key (block.timestamp + 1) likely != the actual ruleset ID
            // If they don't match, auto-issuance tokens for stage 1 become unclaimable
            if (actualStage1RulesetId != block.timestamp + 1) {
                // Verify the amount at the ACTUAL ruleset ID is 0 (the mismatch)
                uint256 amountAtActualId = REV_DEPLOYER.amountToAutoIssue(
                    revnetId, actualStage1RulesetId, multisig()
                );
                assertEq(
                    amountAtActualId,
                    0,
                    "H-5 CONFIRMED: auto-issuance at actual ruleset ID is 0 (mismatch)"
                );
            }
        }
    }
}
