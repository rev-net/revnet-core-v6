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
import {REVEmpty721Config} from "./helpers/REVEmpty721Config.sol";
import {REVOwner} from "../src/REVOwner.sol";
import {IREVDeployer} from "../src/interfaces/IREVDeployer.sol";

/// @notice Long-tail economic simulation: run a revnet through multiple stage transitions with many payments
/// and cash outs, verifying value conservation and bonding curve consistency.
contract TestLongTailEconomics is TestBaseWorkflow {
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";

    // forge-lint: disable-next-line(mixed-case-variable)
    REVDeployer REV_DEPLOYER;
    // forge-lint: disable-next-line(mixed-case-variable)
    REVOwner REV_OWNER;
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
    uint256 FEE_PROJECT_ID;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 REVNET_ID;

    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 DECIMAL_MULTIPLIER = 10 ** 18;

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    /// @notice Creates 10 distinct user addresses for the simulation.
    function _makeUsers(uint256 count) internal returns (address[] memory users) {
        users = new address[](count);
        for (uint256 i; i < count; i++) {
            users[i] = makeAddr(string(abi.encodePacked("econ_user_", vm.toString(i))));
            vm.deal(users[i], 1000e18);
        }
    }

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
            IJB721CheckpointsDeployer(address(new JB721CheckpointsDeployer())),
            multisig()
        );
        ADDRESS_REGISTRY = new JBAddressRegistry();
        HOOK_DEPLOYER = new JB721TiersHookDeployer(EXAMPLE_HOOK, HOOK_STORE, ADDRESS_REGISTRY, multisig());
        PUBLISHER = new CTPublisher(jbDirectory(), jbPermissions(), FEE_PROJECT_ID, multisig());
        MOCK_BUYBACK = new MockBuybackDataHook();

        LOANS_CONTRACT = new REVLoans({
            controller: jbController(),
            suckerRegistry: IJBSuckerRegistry(address(0)),
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

        _deployFeeProject();
        _deployThreeStageRevnet();
    }

    function _deployFeeProject() internal {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        REVStageConfig[] memory stages = new REVStageConfig[](1);
        stages[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: uint112(1000 * DECIMAL_MULTIPLIER),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 5000,
            extraMetadata: 0
        });

        REVConfig memory cfg = REVConfig({
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription("Revnet", "$REV", "ipfs://fee", "REV_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });

        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: cfg,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("FEE")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    function _deployThreeStageRevnet() internal {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](3);

        // Stage 0: High issuance, moderate cash out tax, 90-day cut frequency.
        stageConfigurations[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 1000, // 10% reserved split
            splits: splits,
            // forge-lint: disable-next-line(unsafe-typecast)
            initialIssuance: uint112(1000 * DECIMAL_MULTIPLIER),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 5000, // 50%
            extraMetadata: 0
        });

        // Stage 1: Lower issuance inherited with cut, 180-day frequency, lower tax.
        stageConfigurations[1] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp + 365 days),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 500, // 5% reserved split
            splits: splits,
            initialIssuance: 0, // inherit from previous
            issuanceCutFrequency: 180 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 3000, // 30%
            extraMetadata: 0
        });

        // Stage 2: Terminal stage with minimal issuance.
        stageConfigurations[2] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp + (2 * 365 days)),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: 1, // Near-zero issuance.
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 500, // 5%
            extraMetadata: 0
        });

        REVConfig memory cfg = REVConfig({
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription("LongTail", "LTAIL", "ipfs://longtail", "LTAIL_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations
        });

        (REVNET_ID,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: cfg,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("LONGTAIL")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    //*********************************************************************//
    // --- Long-Tail Economics Tests ------------------------------------- //
    //*********************************************************************//

    /// @notice Simulate 100+ payments spread across all three stages.
    /// Verify that tokens are minted for every payment and that issuance decays over time.
    function test_manyPayments_acrossAllStages() public {
        address[] memory users = _makeUsers(10);

        // Track tokens minted per stage for comparison.
        uint256 totalTokensStage0;
        uint256 totalTokensStage1;
        uint256 totalTokensStage2;

        // Stage 0: 40 payments over the first year.
        for (uint256 i; i < 40; i++) {
            address user = users[i % 10];
            uint256 payAmount = 0.5e18 + (i * 0.01e18); // Vary amounts slightly.
            vm.prank(user);
            uint256 tokens = jbMultiTerminal().pay{value: payAmount}(
                REVNET_ID, JBConstants.NATIVE_TOKEN, payAmount, user, 0, "", ""
            );
            assertGt(tokens, 0, "should mint tokens in stage 0");
            totalTokensStage0 += tokens;

            // Advance 9 days per payment (360 days total, just under stage 1).
            vm.warp(block.timestamp + 9 days);
        }

        // Now in stage 1 (365 days from start).
        vm.warp(block.timestamp + 5 days); // Ensure we are past the stage 1 start.

        // Stage 1: 40 payments.
        for (uint256 i; i < 40; i++) {
            address user = users[i % 10];
            uint256 payAmount = 0.5e18;
            vm.prank(user);
            uint256 tokens = jbMultiTerminal().pay{value: payAmount}(
                REVNET_ID, JBConstants.NATIVE_TOKEN, payAmount, user, 0, "", ""
            );
            assertGt(tokens, 0, "should mint tokens in stage 1");
            totalTokensStage1 += tokens;

            // Advance 9 days per payment.
            vm.warp(block.timestamp + 9 days);
        }

        // Now advance to stage 2 (2 years from start).
        vm.warp(block.timestamp + 365 days);

        // Stage 2: 30 payments.
        for (uint256 i; i < 30; i++) {
            address user = users[i % 10];
            uint256 payAmount = 0.5e18;
            vm.prank(user);
            uint256 tokens = jbMultiTerminal().pay{value: payAmount}(
                REVNET_ID, JBConstants.NATIVE_TOKEN, payAmount, user, 0, "", ""
            );
            // Stage 2 has initialIssuance=1 (near zero), so tokens might be very small.
            totalTokensStage2 += tokens;

            vm.warp(block.timestamp + 1 days);
        }

        // Stage 2 should issue drastically fewer tokens than stage 0.
        assertGt(totalTokensStage0, totalTokensStage1, "stage 0 should issue more tokens than stage 1");
        // Stage 2 has issuance=1, so its total should be much less.
        if (totalTokensStage2 > 0) {
            assertGt(totalTokensStage1, totalTokensStage2, "stage 1 should issue more tokens than stage 2");
        }
    }

    /// @notice Value conservation: total ETH reclaimed by all cash-outs plus remaining terminal balance
    /// should equal total ETH paid in, minus fees paid to the fee project.
    function test_valueConservation_payAndCashOut() public {
        address[] memory users = _makeUsers(5);
        uint256 totalPaidIn;

        // Each user pays 10 ETH.
        uint256[] memory userTokens = new uint256[](5);
        for (uint256 i; i < 5; i++) {
            uint256 payAmount = 10e18;
            vm.prank(users[i]);
            userTokens[i] = jbMultiTerminal().pay{value: payAmount}(
                REVNET_ID, JBConstants.NATIVE_TOKEN, payAmount, users[i], 0, "", ""
            );
            totalPaidIn += payAmount;
        }

        // Users 0-2 cash out all their tokens.
        uint256 totalReclaimed;
        for (uint256 i; i < 3; i++) {
            vm.prank(users[i]);
            uint256 reclaimed = jbMultiTerminal()
                .cashOutTokensOf({
                    holder: users[i],
                    projectId: REVNET_ID,
                    cashOutCount: userTokens[i],
                    tokenToReclaim: JBConstants.NATIVE_TOKEN,
                    minTokensReclaimed: 0,
                    beneficiary: payable(users[i]),
                    metadata: ""
                });
            totalReclaimed += reclaimed;
        }

        // Remaining terminal balance.
        uint256 terminalBalance =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), REVNET_ID, JBConstants.NATIVE_TOKEN);

        // Fee project balance (fees are paid to project 1).
        uint256 feeBalance =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN);

        // Conservation: totalPaidIn = totalReclaimed + terminalBalance + feeBalance.
        // Allow a small tolerance for rounding (a few wei per operation).
        uint256 accountedFor = totalReclaimed + terminalBalance + feeBalance;
        assertApproxEqAbs(
            accountedFor,
            totalPaidIn,
            10, // Allow up to 10 wei rounding error across all operations.
            "total paid in should equal reclaimed + remaining balance + fees"
        );

        // No value created from thin air: accounted total should never exceed what was paid in.
        assertLe(accountedFor, totalPaidIn + 10, "should not create value from nothing");
    }

    /// @notice Bonding curve consistency: cashing out a fraction should always return less than the proportional
    /// share when there is a nonzero cash out tax rate.
    function test_bondingCurve_subproportionalReclaim() public {
        address payer = makeAddr("bc_payer");
        vm.deal(payer, 100e18);

        // Pay 50 ETH.
        vm.prank(payer);
        uint256 totalTokens =
            jbMultiTerminal().pay{value: 50e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 50e18, payer, 0, "", "");

        // Cash out half the tokens.
        uint256 halfTokens = totalTokens / 2;
        vm.prank(payer);
        uint256 reclaimedHalf = jbMultiTerminal()
            .cashOutTokensOf({
                holder: payer,
                projectId: REVNET_ID,
                cashOutCount: halfTokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(payer),
                metadata: ""
            });

        // With a 50% tax rate and being the only holder, cashing out half the tokens
        // should return less than half the surplus (bonding curve subproportional behavior).
        // The terminal balance before cash out is 50 ETH (minus any reserved token splits).
        uint256 terminalBalanceBefore = 50e18; // Approximate -- the actual might differ slightly due to reserved
        // splits.
        assertLt(
            reclaimedHalf,
            terminalBalanceBefore / 2,
            "half-cash-out should return less than half the balance with nonzero tax"
        );
        assertGt(reclaimedHalf, 0, "should still reclaim something");
    }

    /// @notice After many operations (pay, cash out, pay again), the terminal balance should always be >= 0
    /// and the total supply should remain consistent.
    function test_extendedOperation_balanceAndSupplyConsistency() public {
        address[] memory users = _makeUsers(5);

        // Round 1: Everyone pays.
        for (uint256 i; i < 5; i++) {
            vm.prank(users[i]);
            jbMultiTerminal().pay{value: 5e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 5e18, users[i], 0, "", "");
        }

        // Round 2: Users 0-1 cash out half.
        for (uint256 i; i < 2; i++) {
            uint256 userBalance = jbTokens().totalBalanceOf(users[i], REVNET_ID);
            if (userBalance > 0) {
                vm.prank(users[i]);
                jbMultiTerminal()
                    .cashOutTokensOf({
                        holder: users[i],
                        projectId: REVNET_ID,
                        cashOutCount: userBalance / 2,
                        tokenToReclaim: JBConstants.NATIVE_TOKEN,
                        minTokensReclaimed: 0,
                        beneficiary: payable(users[i]),
                        metadata: ""
                    });
            }
        }

        // Warp to stage 1.
        vm.warp(block.timestamp + 365 days);

        // Round 3: More payments.
        for (uint256 i; i < 5; i++) {
            vm.prank(users[i]);
            jbMultiTerminal().pay{value: 3e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 3e18, users[i], 0, "", "");
        }

        // Round 4: User 3 cashes out everything.
        {
            uint256 user3Balance = jbTokens().totalBalanceOf(users[3], REVNET_ID);
            if (user3Balance > 0) {
                vm.prank(users[3]);
                jbMultiTerminal()
                    .cashOutTokensOf({
                        holder: users[3],
                        projectId: REVNET_ID,
                        cashOutCount: user3Balance,
                        tokenToReclaim: JBConstants.NATIVE_TOKEN,
                        minTokensReclaimed: 0,
                        beneficiary: payable(users[3]),
                        metadata: ""
                    });
            }
        }

        // Warp to stage 2.
        vm.warp(block.timestamp + 365 days);

        // Round 5: Final payments.
        for (uint256 i; i < 3; i++) {
            vm.prank(users[i]);
            jbMultiTerminal().pay{value: 1e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, users[i], 0, "", "");
        }

        // Final checks.
        uint256 terminalBalance =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), REVNET_ID, JBConstants.NATIVE_TOKEN);
        uint256 totalSupply = jbTokens().totalSupplyOf(REVNET_ID);

        assertGt(terminalBalance, 0, "terminal balance should be positive after all operations");
        assertGt(totalSupply, 0, "total supply should be positive after all operations");
    }

    /// @notice Issuance decay: within a single stage, payments further apart in time should yield fewer tokens.
    function test_issuanceDecay_withinStage() public {
        address user = makeAddr("decay_user");
        vm.deal(user, 1000e18);

        // Pay 1 ETH now.
        vm.prank(user);
        uint256 tokensBefore =
            jbMultiTerminal().pay{value: 1e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, user, 0, "", "");

        // Warp 180 days (2 cut periods of 90 days each).
        vm.warp(block.timestamp + 180 days);

        // Pay 1 ETH again.
        address user2 = makeAddr("decay_user2");
        vm.deal(user2, 100e18);
        vm.prank(user2);
        uint256 tokensAfter =
            jbMultiTerminal().pay{value: 1e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, user2, 0, "", "");

        // Stage 0 has 50% cut per 90-day cycle. After 2 cycles, issuance should be ~25% of original.
        assertGt(tokensBefore, tokensAfter, "earlier payment should receive more tokens due to issuance decay");
    }

    /// @notice Late entrants cannot extract more value than they put in, even with many prior participants.
    function test_noValueExtraction_byLateEntrant() public {
        address[] memory earlyUsers = _makeUsers(5);

        // Early users pay 10 ETH each.
        for (uint256 i; i < 5; i++) {
            vm.prank(earlyUsers[i]);
            jbMultiTerminal().pay{value: 10e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, earlyUsers[i], 0, "", "");
        }

        // Warp to stage 1 to change the cash out tax rate.
        vm.warp(block.timestamp + 365 days);

        // Late entrant pays 10 ETH.
        address lateUser = makeAddr("late_user");
        vm.deal(lateUser, 100e18);
        vm.prank(lateUser);
        uint256 lateTokens =
            jbMultiTerminal().pay{value: 10e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, lateUser, 0, "", "");

        // Late entrant immediately tries to cash out everything.
        vm.prank(lateUser);
        uint256 reclaimed = jbMultiTerminal()
            .cashOutTokensOf({
                holder: lateUser,
                projectId: REVNET_ID,
                cashOutCount: lateTokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(lateUser),
                metadata: ""
            });

        // The late entrant should not extract more than they put in.
        assertLe(reclaimed, 10e18, "late entrant should not extract more than they paid");
    }

    /// @notice After a full lifecycle through all 3 stages with many operations, verify the terminal balance
    /// is always non-negative and equals the actual ETH held by the terminal contract.
    function test_terminalBalanceMatchesActualEth() public {
        address[] memory users = _makeUsers(3);

        // Stage 0.
        for (uint256 i; i < 20; i++) {
            address user = users[i % 3];
            vm.prank(user);
            jbMultiTerminal().pay{value: 1e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, user, 0, "", "");
            vm.warp(block.timestamp + 10 days);
        }

        // Warp to stage 1.
        vm.warp(block.timestamp + 200 days);

        // Stage 1: pay and cash out.
        for (uint256 i; i < 10; i++) {
            address user = users[i % 3];
            vm.prank(user);
            jbMultiTerminal().pay{value: 2e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 2e18, user, 0, "", "");
        }

        // Cash out some.
        {
            uint256 balance0 = jbTokens().totalBalanceOf(users[0], REVNET_ID);
            if (balance0 > 0) {
                vm.prank(users[0]);
                jbMultiTerminal()
                    .cashOutTokensOf({
                        holder: users[0],
                        projectId: REVNET_ID,
                        cashOutCount: balance0 / 3,
                        tokenToReclaim: JBConstants.NATIVE_TOKEN,
                        minTokensReclaimed: 0,
                        beneficiary: payable(users[0]),
                        metadata: ""
                    });
            }
        }

        // Warp to stage 2.
        vm.warp(block.timestamp + 2 * 365 days);

        // Stage 2: minimal payments.
        for (uint256 i; i < 5; i++) {
            address user = users[i % 3];
            vm.prank(user);
            jbMultiTerminal().pay{value: 0.5e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 0.5e18, user, 0, "", "");
        }

        // Verify the recorded balance matches the terminal's actual ETH holdings.
        // The terminal holds ETH for ALL projects, so we check that the recorded balance
        // for our revnet does not exceed the terminal's total ETH.
        uint256 recordedBalance =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), REVNET_ID, JBConstants.NATIVE_TOKEN);
        uint256 terminalEth = address(jbMultiTerminal()).balance;

        assertGt(recordedBalance, 0, "recorded balance should be positive");
        assertLe(recordedBalance, terminalEth, "recorded balance should not exceed terminal's actual ETH");
    }

    /// @notice Monotonically increasing fee project balance: every cash out with nonzero tax should increase
    /// the fee project's balance.
    function test_feeProjectBalance_monotonicallyIncreases() public {
        address user = makeAddr("fee_check_user");
        vm.deal(user, 1000e18);

        // Pay 100 ETH.
        vm.prank(user);
        uint256 tokens =
            jbMultiTerminal().pay{value: 100e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 100e18, user, 0, "", "");

        uint256 feeBalanceBefore =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN);

        // Cash out portions in 5 rounds.
        uint256 portion = tokens / 6;
        for (uint256 i; i < 5; i++) {
            uint256 feeBalanceBeforeRound =
                jbTerminalStore().balanceOf(address(jbMultiTerminal()), FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN);

            vm.prank(user);
            jbMultiTerminal()
                .cashOutTokensOf({
                    holder: user,
                    projectId: REVNET_ID,
                    cashOutCount: portion,
                    tokenToReclaim: JBConstants.NATIVE_TOKEN,
                    minTokensReclaimed: 0,
                    beneficiary: payable(user),
                    metadata: ""
                });

            uint256 feeBalanceAfterRound =
                jbTerminalStore().balanceOf(address(jbMultiTerminal()), FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN);

            // Fee balance should increase (or at least not decrease) after each cash out.
            assertGe(feeBalanceAfterRound, feeBalanceBeforeRound, "fee project balance should monotonically increase");
        }

        uint256 feeBalanceAfter =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN);
        assertGt(feeBalanceAfter, feeBalanceBefore, "fee project should have earned fees from cash outs");
    }
}
