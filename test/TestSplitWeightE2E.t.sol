// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import /* {*} from */ "./../src/REVDeployer.sol";
import "@croptop/core-v6/src/CTPublisher.sol";
import {MockBuybackDataHookMintPath} from "./mock/MockBuybackDataHookMintPath.sol";
import {MockBuybackDataHook} from "./mock/MockBuybackDataHook.sol";
import "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
import "@bananapus/721-hook-v6/script/helpers/Hook721DeploymentLib.sol";
import "@bananapus/suckers-v6/script/helpers/SuckerDeploymentLib.sol";
import "@croptop/core-v6/script/helpers/CroptopDeploymentLib.sol";
import "@bananapus/router-terminal-v6/script/helpers/RouterTerminalDeploymentLib.sol";

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
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
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JB721InitTiersConfig} from "@bananapus/721-hook-v6/src/structs/JB721InitTiersConfig.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {REVDeploy721TiersHookConfig} from "../src/structs/REVDeploy721TiersHookConfig.sol";
import {REVBaseline721HookConfig} from "../src/structs/REVBaseline721HookConfig.sol";
import {REV721TiersHookFlags} from "../src/structs/REV721TiersHookFlags.sol";
import {REVCroptopAllowedPost} from "../src/structs/REVCroptopAllowedPost.sol";
import {REVEmpty721Config} from "./helpers/REVEmpty721Config.sol";

/// @notice E2E tests verifying that the split weight adjustment in REVDeployer produces correct token counts
/// when payments flow through the full terminal → store → dataHook → mint pipeline.
/// Tests both mint path (buyback decides to mint) and AMM path (buyback decides to swap).
contract TestSplitWeightE2E is TestBaseWorkflow {
    using JBMetadataResolver for bytes;

    bytes32 REV_DEPLOYER_SALT = "REVDeployer_E2E";

    REVDeployer REV_DEPLOYER;
    JB721TiersHook EXAMPLE_HOOK;
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    IJB721TiersHookStore HOOK_STORE;
    IJBAddressRegistry ADDRESS_REGISTRY;
    IREVLoans LOANS_CONTRACT;
    IJBSuckerRegistry SUCKER_REGISTRY;
    CTPublisher PUBLISHER;
    MockBuybackDataHookMintPath MOCK_BUYBACK_MINT;

    uint256 FEE_PROJECT_ID;

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;
    address PAYER = makeAddr("payer");
    address SPLIT_BENEFICIARY = makeAddr("splitBeneficiary");

    // Tier configuration: 1 ETH tier with 30% split.
    uint104 constant TIER_PRICE = 1 ether;
    uint32 constant SPLIT_PERCENT = 300_000_000; // 30% of SPLITS_TOTAL_PERCENT (1_000_000_000)
    uint112 constant INITIAL_ISSUANCE = 1000e18; // 1000 tokens per ETH

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
        MOCK_BUYBACK_MINT = new MockBuybackDataHookMintPath();

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
            IJBBuybackHookRegistry(address(MOCK_BUYBACK_MINT)),
            address(LOANS_CONTRACT),
            TRUSTED_FORWARDER
        );

        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);

        // Fund the payer.
        vm.deal(PAYER, 100 ether);
    }

    // ───────────────────────── Helpers
    // ─────────────────────────

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
            initialIssuance: INITIAL_ISSUANCE,
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 5000,
            extraMetadata: 0
        });

        cfg = REVConfig({
            description: REVDescription("E2E Test", "E2E", "ipfs://e2e", "E2E_SALT"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });

        sdc = REVSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("E2E_TEST"))
        });
    }

    function _build721Config() internal view returns (REVDeploy721TiersHookConfig memory) {
        // Create a tier: 1 ETH, 30% split to SPLIT_BENEFICIARY.
        JB721TierConfig[] memory tiers = new JB721TierConfig[](1);
        JBSplit[] memory tierSplits = new JBSplit[](1);
        tierSplits[0] = JBSplit({
            preferAddToBalance: false,
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT), // 100% of the split portion goes to this beneficiary
            projectId: 0,
            beneficiary: payable(SPLIT_BENEFICIARY),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        tiers[0] = JB721TierConfig({
            price: TIER_PRICE,
            initialSupply: 100,
            votingUnits: 0,
            reserveFrequency: 0,
            reserveBeneficiary: address(0),
            encodedIPFSUri: bytes32("tier1"),
            category: 1,
            discountPercent: 0,
            allowOwnerMint: false,
            useReserveBeneficiaryAsDefault: false,
            transfersPausable: false,
            useVotingUnits: false,
            cannotBeRemoved: false,
            cannotIncreaseDiscountPercent: false,
            splitPercent: SPLIT_PERCENT,
            splits: tierSplits
        });

        return REVDeploy721TiersHookConfig({
            baseline721HookConfiguration: REVBaseline721HookConfig({
                name: "E2E NFT",
                symbol: "E2ENFT",
                baseUri: "ipfs://",
                tokenUriResolver: IJB721TokenUriResolver(address(0)),
                contractUri: "ipfs://contract",
                tiersConfig: JB721InitTiersConfig({
                    tiers: tiers, currency: uint32(uint160(JBConstants.NATIVE_TOKEN)), decimals: 18
                }),
                reserveBeneficiary: address(0),
                flags: REV721TiersHookFlags({
                    noNewTiersWithReserves: false,
                    noNewTiersWithVotes: false,
                    noNewTiersWithOwnerMinting: false,
                    preventOverspending: false
                })
            }),
            salt: bytes32("E2E_721"),
            preventSplitOperatorAdjustingTiers: false,
            preventSplitOperatorUpdatingMetadata: false,
            preventSplitOperatorMinting: false,
            preventSplitOperatorIncreasingDiscountPercent: false
        });
    }

    /// @notice Deploy the fee project, then deploy a revnet with 721 tiers.
    function _deployRevnetWith721() internal returns (uint256 revnetId, IJB721TiersHook hook) {
        // Deploy fee project first.
        (REVConfig memory feeCfg, JBTerminalConfig[] memory feeTc, REVSuckerDeploymentConfig memory feeSdc) =
            _buildMinimalConfig();
        feeCfg.description = REVDescription("Fee", "FEE", "ipfs://fee", "FEE_SALT");

        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeCfg,
            terminalConfigurations: feeTc,
            suckerDeploymentConfiguration: feeSdc,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        // Deploy the revnet with 721 hook.
        (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc) =
            _buildMinimalConfig();
        REVDeploy721TiersHookConfig memory hookConfig = _build721Config();

        (revnetId, hook) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: cfg,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: sdc,
            tiered721HookConfiguration: hookConfig,
            allowedPosts: new REVCroptopAllowedPost[](0)
        });
    }

    /// @notice Build payment metadata that tells the 721 hook to mint from tier 1.
    function _buildPayMetadata(address hookAddress) internal pure returns (bytes memory) {
        // The 721 hook uses getId("pay", METADATA_ID_TARGET).
        // For clones, METADATA_ID_TARGET = address(implementation), but for our test the hook
        // is deployed via deployer and METADATA_ID_TARGET is set in the constructor.
        // We'll use the hook address as target since that's what `address(this)` resolves to
        // in a clone's delegatecall context... Actually for the JB721TiersHookDeployer,
        // METADATA_ID_TARGET is the implementation address. Let's compute it directly.

        // Actually, we need to read METADATA_ID_TARGET from the deployed hook.
        // For now, let's compute the metadata ID using the hook's METADATA_ID_TARGET.
        // We'll handle this in the test function where we have access to the hook instance.

        // Tier IDs to mint: [1] (first tier is ID 1)
        uint16[] memory tierIds = new uint16[](1);
        tierIds[0] = 1;

        // Encode: (allowOverspending, tierIdsToMint)
        bytes memory tierData = abi.encode(true, tierIds);

        // Build the metadata ID.
        bytes4 metadataId = JBMetadataResolver.getId("pay", hookAddress);

        // Build full metadata using createMetadata.
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = metadataId;
        bytes[] memory datas = new bytes[](1);
        datas[0] = tierData;

        return JBMetadataResolver.createMetadata(ids, datas);
    }

    // ───────────────────────── Tests
    // ─────────────────────────

    /// @notice Mint path: pay 1 ETH for tier with 30% split.
    /// Verifies tokens minted == 700 (not 1000), confirming the weight scaling is correct.
    ///
    /// The core question this settles: does the terminal mint tokens based on the FULL payment amount?
    /// YES — JBTerminalStore.recordPaymentFrom line 410: tokenCount = mulDiv(amount.value, weight, weightRatio)
    /// where amount.value is the full 1 ETH, NOT the reduced 0.7 ETH.
    ///
    /// So the weight MUST be scaled down. Without scaling:
    ///   tokenCount = mulDiv(1e18, 1000e18, 1e18) = 1000e18 → 1000 tokens for 0.7 ETH of actual value = WRONG
    /// With scaling:
    ///   tokenCount = mulDiv(1e18, 700e18, 1e18) = 700e18 → 700 tokens for 0.7 ETH of actual value = CORRECT
    function test_e2e_mintPath_splitReducesTokens() public {
        (uint256 revnetId, IJB721TiersHook hook) = _deployRevnetWith721();

        // Build metadata targeting the hook's METADATA_ID_TARGET.
        address metadataTarget = hook.METADATA_ID_TARGET();
        bytes memory metadata = _buildPayMetadata(metadataTarget);

        // Pay 1 ETH through the terminal.
        vm.prank(PAYER);
        uint256 tokensReceived = jbMultiTerminal().pay{value: 1 ether}({
            projectId: revnetId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: PAYER,
            minReturnedTokens: 0,
            memo: "E2E split weight test",
            metadata: metadata
        });

        // Expected: 1 ETH payment, 0.3 ETH split (30% of 1 ETH tier price).
        // projectAmount = 0.7 ETH.
        // Buyback hook (mint path) returns context.weight unchanged.
        // REVDeployer scales: weight = 1000e18 * 0.7e18 / 1e18 = 700e18.
        // Terminal mints: mulDiv(1e18, 700e18, 1e18) = 700e18 = 700 tokens.
        uint256 expectedTokens = 700e18;

        assertEq(tokensReceived, expectedTokens, "tokens should be 700 (weight scaled for 30% split)");

        // Confirm payer's actual token balance matches.
        uint256 payerBalance = jbTokens().totalBalanceOf(PAYER, revnetId);
        assertEq(payerBalance, expectedTokens, "payer balance matches expected tokens");
    }

    /// @notice Mint path without splits: pay 1 ETH with no tier metadata.
    /// Baseline: all tokens should be minted at full weight.
    function test_e2e_mintPath_noSplits_fullTokens() public {
        (uint256 revnetId,) = _deployRevnetWith721();

        // Pay 1 ETH with NO tier metadata (no NFT purchase, no splits).
        vm.prank(PAYER);
        uint256 tokensReceived = jbMultiTerminal().pay{value: 1 ether}({
            projectId: revnetId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: PAYER,
            minReturnedTokens: 0,
            memo: "E2E no split test",
            metadata: ""
        });

        // No splits → no weight reduction. Full 1000 tokens.
        uint256 expectedTokens = 1000e18;
        assertEq(tokensReceived, expectedTokens, "tokens should be 1000 (no splits, full weight)");
    }

    /// @notice Mint path: pay 2 ETH for 1 ETH tier with 30% split.
    /// 0.3 ETH goes to split, 1.7 ETH enters project.
    /// Weight should be scaled to 1.7/2.0 of the original.
    function test_e2e_mintPath_overpay_splitReducesTokens() public {
        (uint256 revnetId, IJB721TiersHook hook) = _deployRevnetWith721();

        address metadataTarget = hook.METADATA_ID_TARGET();
        bytes memory metadata = _buildPayMetadata(metadataTarget);

        vm.prank(PAYER);
        uint256 tokensReceived = jbMultiTerminal().pay{value: 2 ether}({
            projectId: revnetId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 2 ether,
            beneficiary: PAYER,
            minReturnedTokens: 0,
            memo: "E2E overpay split test",
            metadata: metadata
        });

        // 2 ETH payment, 1 tier at 1 ETH with 30% split → 0.3 ETH split.
        // projectAmount = 2 - 0.3 = 1.7 ETH.
        // weight = 1000e18 * 1.7 / 2.0 = 850e18.
        // tokenCount = mulDiv(2e18, 850e18, 1e18) = 1700e18 = 1700 tokens.
        uint256 expectedTokens = 1700e18;
        assertEq(tokensReceived, expectedTokens, "tokens should be 1700 (weight scaled for 0.3 ETH split on 2 ETH)");
    }

    /// @notice AMM path: buyback hook returns weight=0 (swapping).
    /// With splits, weight should still be 0 (no tokens minted by terminal).
    function test_e2e_ammPath_splitWithBuyback_zeroWeight() public {
        // Deploy a separate REVDeployer with the AMM buyback mock.
        MockBuybackDataHook ammBuyback = new MockBuybackDataHook();

        vm.prank(multisig());
        jbProjects().approve(address(0), FEE_PROJECT_ID); // Clear old approval.

        REVDeployer ammDeployer = new REVDeployer{salt: "REVDeployer_AMM_E2E"}(
            jbController(),
            SUCKER_REGISTRY,
            FEE_PROJECT_ID,
            HOOK_DEPLOYER,
            PUBLISHER,
            IJBBuybackHookRegistry(address(ammBuyback)),
            address(LOANS_CONTRACT),
            TRUSTED_FORWARDER
        );

        vm.prank(multisig());
        jbProjects().approve(address(ammDeployer), FEE_PROJECT_ID);

        // Deploy fee project.
        (REVConfig memory feeCfg, JBTerminalConfig[] memory feeTc, REVSuckerDeploymentConfig memory feeSdc) =
            _buildMinimalConfig();
        feeCfg.description = REVDescription("Fee AMM", "FEEA", "ipfs://feeamm", "FEEA_SALT");

        vm.prank(multisig());
        ammDeployer.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeCfg,
            terminalConfigurations: feeTc,
            suckerDeploymentConfiguration: feeSdc,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        // Deploy revnet with 721 hook.
        (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc) =
            _buildMinimalConfig();
        cfg.description = REVDescription("AMM E2E", "AMME", "ipfs://amme2e", "AMME_SALT");
        REVDeploy721TiersHookConfig memory hookConfig = _build721Config();

        (uint256 revnetId, IJB721TiersHook hook) = ammDeployer.deployFor({
            revnetId: 0,
            configuration: cfg,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: sdc,
            tiered721HookConfiguration: hookConfig,
            allowedPosts: new REVCroptopAllowedPost[](0)
        });

        // Build metadata.
        address metadataTarget = hook.METADATA_ID_TARGET();
        bytes memory metadata = _buildPayMetadata(metadataTarget);

        // The AMM mock buyback returns weight=context.weight + a hook spec (simulates swap decision).
        // But wait — when projectAmount < context.amount.value, REVDeployer scales the weight.
        // The AMM mock doesn't return weight=0 like the real buyback would for a swap.
        // It returns context.weight with a hook spec.
        //
        // For the real buyback in swap mode:
        //   - Returns weight=0 (line 279 of JBBuybackHook.sol)
        //   - Returns hookSpec with amountToSwapWith
        //   - Terminal mints 0 tokens (weight=0)
        //   - Buyback hook's afterPay handles the swap and mints tokens directly via controller
        //
        // The mock doesn't replicate this behavior exactly.
        // Let's verify the mock's behavior: it returns context.weight + a spec with amount=0.
        // So this test really shows the mint path with an extra hook spec, not true AMM.
        //
        // For a true AMM test we'd need a real Uniswap pool. For now, verify that
        // when the buyback hook returns weight=0 (which we can mock), tokens = 0.

        // Mock the buyback to return weight=0 (swap mode) for any call.
        vm.mockCall(
            address(ammBuyback),
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(
                uint256(0), // weight = 0 (buying back from AMM)
                new JBPayHookSpecification[](0)
            )
        );

        vm.prank(PAYER);
        uint256 tokensReceived = jbMultiTerminal().pay{value: 1 ether}({
            projectId: revnetId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: PAYER,
            minReturnedTokens: 0,
            memo: "E2E AMM + split test",
            metadata: metadata
        });

        // Buyback returns weight=0 → REVDeployer preserves 0 (both branches: projectAmount==0 → 0, else
        // mulDiv(0,...) → 0). Terminal: tokenCount = mulDiv(1e18, 0, 1e18) = 0.
        // No tokens minted by terminal. In production, the buyback hook's afterPay would handle the swap.
        assertEq(tokensReceived, 0, "AMM path: terminal should mint 0 tokens (buyback handles swap)");
    }

    /// @notice Verify the invariant: tokens / projectAmount is the same rate regardless of split percentage.
    /// This proves the weight scaling keeps the token-per-ETH rate consistent.
    ///
    /// With splits:  700 tokens for 0.7 ETH entering project = 1000 tokens/ETH
    /// Without splits: 1000 tokens for 1.0 ETH entering project = 1000 tokens/ETH
    function test_e2e_invariant_tokenPerEthConsistent() public {
        // --- Revnet 1: with 721 splits (30%) ---
        (uint256 revnetId1, IJB721TiersHook hook1) = _deployRevnetWith721();
        address metadataTarget1 = hook1.METADATA_ID_TARGET();
        bytes memory metadata1 = _buildPayMetadata(metadataTarget1);

        vm.prank(PAYER);
        uint256 tokens1 = jbMultiTerminal().pay{value: 1 ether}({
            projectId: revnetId1,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: PAYER,
            minReturnedTokens: 0,
            memo: "invariant test: with splits",
            metadata: metadata1
        });

        // --- Revnet 2: no splits (plain payment, no tier metadata) ---
        (REVConfig memory cfg2, JBTerminalConfig[] memory tc2, REVSuckerDeploymentConfig memory sdc2) =
            _buildMinimalConfig();
        cfg2.description = REVDescription("NoSplit", "NS", "ipfs://nosplit", "NOSPLIT_SALT");

        (uint256 revnetId2,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: cfg2,
            terminalConfigurations: tc2,
            suckerDeploymentConfiguration: sdc2,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        vm.prank(PAYER);
        uint256 tokens2 = jbMultiTerminal().pay{value: 1 ether}({
            projectId: revnetId2,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: PAYER,
            minReturnedTokens: 0,
            memo: "invariant test: no splits",
            metadata: ""
        });

        // Invariant: tokens / projectAmount should produce the same rate.
        // Revnet 1: 700e18 tokens / 0.7 ETH = 1000 tokens/ETH
        // Revnet 2: 1000e18 tokens / 1.0 ETH = 1000 tokens/ETH
        uint256 projectAmount1 = 0.7 ether; // 1 ETH - 30% split
        uint256 projectAmount2 = 1 ether; // no splits

        uint256 rate1 = (tokens1 * 1e18) / projectAmount1;
        uint256 rate2 = (tokens2 * 1e18) / projectAmount2;

        assertEq(rate1, rate2, "token-per-ETH rate should be identical with and without splits");
    }
}
