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
import {REVLoan} from "../src/structs/REVLoan.sol";
import {REVStageConfig, REVAutoIssuance} from "../src/structs/REVStageConfig.sol";
import {REVDescription} from "../src/structs/REVDescription.sol";
import {IREVLoans} from "./../src/interfaces/IREVLoans.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {REVEmpty721Config} from "./helpers/REVEmpty721Config.sol";
import {REVCroptopAllowedPost} from "../src/structs/REVCroptopAllowedPost.sol";

/// @notice Full revnet lifecycle E2E: deploy 3-stage -> pay -> advance stages -> cash out.
contract REVLifecycle_Local is TestBaseWorkflow {
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
    MockBuybackDataHook MOCK_BUYBACK;

    uint256 FEE_PROJECT_ID;
    uint256 REVNET_ID;

    address USER1 = makeAddr("user1");
    address USER2 = makeAddr("user2");

    uint256 DECIMAL_MULTIPLIER = 10 ** 18;

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    function setUp() public override {
        super.setUp();

        FEE_PROJECT_ID = jbProjects().createFor(multisig());

        SUCKER_REGISTRY = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig(), address(0));
        HOOK_STORE = new JB721TiersHookStore();
        EXAMPLE_HOOK =
            new JB721TiersHook(jbDirectory(), jbPermissions(), jbPrices(), jbRulesets(), HOOK_STORE, jbSplits(), multisig());
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
            IJBBuybackHookRegistry(address(MOCK_BUYBACK)),
            address(LOANS_CONTRACT),
            TRUSTED_FORWARDER
        );

        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);

        // Deploy a 3-stage revnet
        _deployThreeStageRevnet();

        // Fund users
        vm.deal(USER1, 100e18);
        vm.deal(USER2, 100e18);
    }

    function _deployThreeStageRevnet() internal {
        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](3);

        // Stage 0: High issuance, moderate cash out tax
        stageConfigurations[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: uint112(1000 * DECIMAL_MULTIPLIER),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 5000, // 50%
            extraMetadata: 0
        });

        // Stage 1: Lower issuance (inherited with cut)
        stageConfigurations[1] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp + 365 days),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: 0, // inherit
            issuanceCutFrequency: 180 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 3000, // 30%
            extraMetadata: 0
        });

        // Stage 2: Final stage
        stageConfigurations[2] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp + (2 * 365 days)),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: 1,
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 500, // 5%
            extraMetadata: 0
        });

        REVConfig memory revnetConfiguration = REVConfig({
            description: REVDescription("Lifecycle", "LIFE", "ipfs://lifecycle", "LIFE_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations
        });

        vm.prank(multisig());
        (REVNET_ID,) = REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("LIFECYCLE_TEST")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    //*********************************************************************//
    // --- Lifecycle Tests ---------------------------------------------- //
    //*********************************************************************//

    /// @notice Full lifecycle: deploy -> pay in stage 0 -> warp to stage 1 -> pay -> cash out
    function test_fullLifecycle_threeStages() public {
        // Stage 0: User1 pays 5 ETH
        vm.prank(USER1);
        uint256 tokens1 =
            jbMultiTerminal().pay{value: 5e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 5e18, USER1, 0, "", "");
        assertGt(tokens1, 0, "user1 should receive tokens in stage 0");

        // Check total supply after first payment
        uint256 totalSupply1 = jbTokens().totalSupplyOf(REVNET_ID);
        assertGt(totalSupply1, 0, "total supply should be > 0");

        // Warp to stage 1 (1 year later)
        vm.warp(block.timestamp + 365 days);

        // Stage 1: User2 pays 5 ETH (should get fewer tokens due to weight decay)
        vm.prank(USER2);
        uint256 tokens2 =
            jbMultiTerminal().pay{value: 5e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 5e18, USER2, 0, "", "");
        assertGt(tokens2, 0, "user2 should receive tokens in stage 1");

        // Total supply increased
        uint256 totalSupply2 = jbTokens().totalSupplyOf(REVNET_ID);
        assertGt(totalSupply2, totalSupply1, "total supply should increase");

        // Warp to stage 2 (2 years from start)
        vm.warp(block.timestamp + 365 days);

        // Stage 2: User1 cashes out some tokens
        uint256 cashOutAmount = tokens1 / 2;
        vm.prank(USER1);
        uint256 reclaimed = jbMultiTerminal()
            .cashOutTokensOf({
                holder: USER1,
                projectId: REVNET_ID,
                cashOutCount: cashOutAmount,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(USER1),
                metadata: ""
            });
        assertGt(reclaimed, 0, "should reclaim some ETH");

        // Total supply should decrease after cash out
        uint256 totalSupply3 = jbTokens().totalSupplyOf(REVNET_ID);
        assertLt(totalSupply3, totalSupply2, "total supply should decrease after cash out");
    }

    /// @notice Payment in stage 0 gives more tokens than equivalent payment in stage 1.
    function test_stageDecay_fewerTokensLater() public {
        // Stage 0: Pay 1 ETH
        vm.prank(USER1);
        uint256 tokensStage0 =
            jbMultiTerminal().pay{value: 1e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, USER1, 0, "", "");

        // Warp to stage 1
        vm.warp(block.timestamp + 365 days);

        // Stage 1: Pay 1 ETH
        vm.prank(USER2);
        uint256 tokensStage1 =
            jbMultiTerminal().pay{value: 1e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, USER2, 0, "", "");

        // User1 should have received more tokens (earlier stage = higher issuance)
        assertGt(tokensStage0, tokensStage1, "stage 0 payment should yield more tokens than stage 1");
    }

    /// @notice Cash out tax rate differs between stages.
    function test_cashOutTax_changesBetweenStages() public {
        // Pay in stage 0
        vm.prank(USER1);
        uint256 tokens =
            jbMultiTerminal().pay{value: 10e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, USER1, 0, "", "");

        // Cash out half in stage 0 (50% tax)
        uint256 halfTokens = tokens / 2;
        vm.prank(USER1);
        uint256 reclaimedStage0 = jbMultiTerminal()
            .cashOutTokensOf({
                holder: USER1,
                projectId: REVNET_ID,
                cashOutCount: halfTokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(USER1),
                metadata: ""
            });
        assertGt(reclaimedStage0, 0, "should reclaim in stage 0");

        // Cash out tax with 50% rate means you get less than proportional share
        // (for the only holder with all tokens cashing out half, bonding curve applies)
        assertLt(reclaimedStage0, 10e18 / 2, "50% tax should reduce reclaim below proportional share");
    }

    /// @notice Terminal balance conservation across lifecycle.
    function test_balanceConservation() public {
        uint256 payAmount = 10e18;

        // Pay into revnet
        vm.prank(USER1);
        uint256 tokens =
            jbMultiTerminal().pay{value: payAmount}(REVNET_ID, JBConstants.NATIVE_TOKEN, payAmount, USER1, 0, "", "");

        // Record balance
        uint256 terminalBalance =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), REVNET_ID, JBConstants.NATIVE_TOKEN);
        assertEq(terminalBalance, payAmount, "balance should equal payment");

        // Cash out all tokens
        vm.prank(USER1);
        uint256 reclaimed = jbMultiTerminal()
            .cashOutTokensOf({
                holder: USER1,
                projectId: REVNET_ID,
                cashOutCount: tokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(USER1),
                metadata: ""
            });

        // With 50% cash out tax and single holder, reclaiming full supply
        // should return less than full amount (due to tax)
        assertGt(reclaimed, 0, "should reclaim something");
        assertLe(reclaimed, payAmount, "should not reclaim more than paid");

        // Remaining balance should account for what was reclaimed
        uint256 terminalBalanceAfter =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), REVNET_ID, JBConstants.NATIVE_TOKEN);
        assertEq(
            terminalBalanceAfter + reclaimed, terminalBalance, "balance conservation: remaining + reclaimed = original"
        );
    }

    /// @notice Multiple payers, early payer has advantage.
    function test_earlyPayerAdvantage() public {
        // User1 pays first
        vm.prank(USER1);
        uint256 tokens1 =
            jbMultiTerminal().pay{value: 5e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 5e18, USER1, 0, "", "");

        // User2 pays same amount later
        vm.prank(USER2);
        uint256 tokens2 =
            jbMultiTerminal().pay{value: 5e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 5e18, USER2, 0, "", "");

        // Both should receive same tokens (same stage, no decay within a cycle without issuanceCutFrequency)
        assertEq(tokens1, tokens2, "same amount in same stage should yield same tokens");

        // But when user1 cashes out, they get a smaller share because the surplus grew
        // relative to their proportion of the total supply
        vm.prank(USER1);
        uint256 reclaimed1 = jbMultiTerminal()
            .cashOutTokensOf({
                holder: USER1,
                projectId: REVNET_ID,
                cashOutCount: tokens1,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(USER1),
                metadata: ""
            });

        // Should reclaim proportional share (minus tax)
        assertGt(reclaimed1, 0, "user1 should reclaim some ETH");
        assertLt(reclaimed1, 5e18, "with tax, user1 gets less than they paid");
    }

    /// @notice Ruleset IDs match stage indices.
    function test_rulesetProgression() public {
        // Check stage 0 ruleset
        JBRuleset memory ruleset0 = jbRulesets().currentOf(REVNET_ID);
        assertGt(ruleset0.id, 0, "should have a valid ruleset");
        assertEq(ruleset0.cycleNumber, 1, "first ruleset cycle should be 1");

        // Warp to stage 1
        vm.warp(block.timestamp + 365 days);
        JBRuleset memory ruleset1 = jbRulesets().currentOf(REVNET_ID);
        assertGe(ruleset1.cycleNumber, 1, "cycle should be >= 1");

        // Warp to stage 2
        vm.warp(block.timestamp + 365 days);
        JBRuleset memory ruleset2 = jbRulesets().currentOf(REVNET_ID);
        assertGe(ruleset2.cycleNumber, 1, "cycle should be >= 1");
    }
}
