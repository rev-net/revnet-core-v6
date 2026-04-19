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
import {MockPriceFeed} from "@bananapus/core-v6/test/mock/MockPriceFeed.sol";
import {MockERC20} from "@bananapus/core-v6/test/mock/MockERC20.sol";
import {REVLoans} from "../src/REVLoans.sol";
import {REVStageConfig, REVAutoIssuance} from "../src/structs/REVStageConfig.sol";
import {REVDescription} from "../src/structs/REVDescription.sol";
import {IREVLoans} from "./../src/interfaces/IREVLoans.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import "@bananapus/721-hook-v6/src/JB721CheckpointsDeployer.sol";
import {IJB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721CheckpointsDeployer.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {REVEmpty721Config} from "./helpers/REVEmpty721Config.sol";
import {REVOwner} from "../src/REVOwner.sol";
import {IREVDeployer} from "../src/interfaces/IREVDeployer.sol";

/// @notice Cross-currency reclaim tests: verify cash-out behavior when a revnet's baseCurrency differs from the
/// terminal token currency, and when price feeds return various values.
contract TestCrossCurrencyReclaim is TestBaseWorkflow {
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
    MockERC20 TOKEN;
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
    address USER1 = makeAddr("user1");
    // forge-lint: disable-next-line(mixed-case-variable)
    address USER2 = makeAddr("user2");

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
            IJB721CheckpointsDeployer(address(new JB721CheckpointsDeployer())),
            multisig()
        );
        ADDRESS_REGISTRY = new JBAddressRegistry();
        HOOK_DEPLOYER = new JB721TiersHookDeployer(EXAMPLE_HOOK, HOOK_STORE, ADDRESS_REGISTRY, multisig());
        PUBLISHER = new CTPublisher(jbDirectory(), jbPermissions(), FEE_PROJECT_ID, multisig());
        MOCK_BUYBACK = new MockBuybackDataHook();

        // Deploy a 6-decimal ERC-20 token that will be used as a terminal token.
        TOKEN = new MockERC20("USD Coin", "USDC");

        LOANS_CONTRACT = new REVLoans({
            controller: jbController(),
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

        // Fund users.
        vm.deal(USER1, 100e18);
        vm.deal(USER2, 100e18);
    }

    /// @notice Deploy the fee project (required as revnet ID 1 to receive fees).
    function _deployFeeProject() internal {
        JBAccountingContext[] memory acc = new JBAccountingContext[](2);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        acc[1] = JBAccountingContext({token: address(TOKEN), decimals: 6, currency: uint32(uint160(address(TOKEN)))});
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
            initialIssuance: uint112(1000e18),
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

    /// @notice Deploy a revnet that uses ETH as baseCurrency and accepts both ETH and TOKEN.
    function _deployEthBasedRevnet(uint16 cashOutTaxRate) internal returns (uint256 revnetId) {
        JBAccountingContext[] memory acc = new JBAccountingContext[](2);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        acc[1] = JBAccountingContext({token: address(TOKEN), decimals: 6, currency: uint32(uint160(address(TOKEN)))});
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
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: cashOutTaxRate,
            extraMetadata: 0
        });

        REVConfig memory cfg = REVConfig({
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription("CrossCurrency", "XCRCY", "ipfs://cross", "XCRCY_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });

        (revnetId,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: cfg,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("CROSS")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    //*********************************************************************//
    // --- Cross-Currency Reclaim Tests --------------------------------- //
    //*********************************************************************//

    /// @notice Pay with ETH (matching baseCurrency), then cash out. Baseline: no cross-currency conversion needed.
    function test_cashOut_sameAsBaseCurrency() public {
        // Set up a price feed so the TOKEN is recognized.
        MockPriceFeed priceFeed = new MockPriceFeed(2000e18, 18); // 1 ETH = 2000 TOKEN
        vm.prank(multisig());
        jbPrices()
            .addPriceFeedFor(0, uint32(uint160(JBConstants.NATIVE_TOKEN)), uint32(uint160(address(TOKEN))), priceFeed);

        _deployFeeProject();
        REVNET_ID = _deployEthBasedRevnet(5000); // 50% cash out tax

        // User1 pays 5 ETH.
        vm.prank(USER1);
        uint256 tokens = jbMultiTerminal().pay{value: 5e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 5e18, USER1, 0, "", "");
        assertGt(tokens, 0, "should receive tokens");

        // Cash out all tokens.
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

        assertGt(reclaimed, 0, "should reclaim some ETH");
        // With 50% tax and single holder cashing out everything, the bonding curve returns the full surplus.
        // But the fee (2.5%) is deducted from the cash out count, so the reclaimed amount is less.
        assertLe(reclaimed, 5e18, "should not exceed total paid in");
    }

    /// @notice Pay with TOKEN (different from baseCurrency=ETH), then cash out in TOKEN.
    /// The surplus is aggregated cross-currency via price feeds.
    function test_cashOut_crossCurrency_payWithToken_cashOutToken() public {
        // Price feed: 1 TOKEN (6 dec) = 0.0005 ETH (18 dec). Meaning 2000 TOKEN = 1 ETH.
        MockPriceFeed priceFeed = new MockPriceFeed(5e14, 18); // 0.0005 ETH per TOKEN unit
        vm.prank(multisig());
        jbPrices()
            .addPriceFeedFor(0, uint32(uint160(address(TOKEN))), uint32(uint160(JBConstants.NATIVE_TOKEN)), priceFeed);

        _deployFeeProject();
        REVNET_ID = _deployEthBasedRevnet(5000); // 50% cash out tax

        // Mint TOKEN to USER1 and approve.
        uint256 tokenAmount = 10_000e6; // 10,000 USDC-like
        TOKEN.mint(USER1, tokenAmount);
        vm.prank(USER1);
        TOKEN.approve(address(jbMultiTerminal()), tokenAmount);

        // Pay with TOKEN.
        vm.prank(USER1);
        uint256 revTokens = jbMultiTerminal().pay(REVNET_ID, address(TOKEN), tokenAmount, USER1, 0, "", "");
        assertGt(revTokens, 0, "should receive revnet tokens from TOKEN payment");

        // Cash out in TOKEN.
        vm.prank(USER1);
        uint256 reclaimedToken = jbMultiTerminal()
            .cashOutTokensOf({
                holder: USER1,
                projectId: REVNET_ID,
                cashOutCount: revTokens,
                tokenToReclaim: address(TOKEN),
                minTokensReclaimed: 0,
                beneficiary: payable(USER1),
                metadata: ""
            });

        assertGt(reclaimedToken, 0, "should reclaim some TOKEN");
        assertLe(reclaimedToken, tokenAmount, "should not exceed total TOKEN paid in");
    }

    /// @notice Pay with ETH, then try to cash out in TOKEN. When the cross-currency surplus (ETH converted to TOKEN
    /// terms) exceeds the actual TOKEN balance in the terminal, the cash out reverts with
    /// InadequateTerminalStoreBalance. This is correct behavior: you cannot withdraw more of a token than the
    /// terminal actually holds, even if the aggregated surplus in that currency is higher.
    function test_cashOut_crossCurrency_payEth_cashOutToken_insufficientBalance_reverts() public {
        // Price feed: 1 ETH = 2000 TOKEN (6 dec units).
        MockPriceFeed priceFeed = new MockPriceFeed(2000e6, 6); // 2000 TOKEN per ETH
        vm.prank(multisig());
        jbPrices()
            .addPriceFeedFor(0, uint32(uint160(JBConstants.NATIVE_TOKEN)), uint32(uint160(address(TOKEN))), priceFeed);

        _deployFeeProject();
        REVNET_ID = _deployEthBasedRevnet(5000); // 50% cash out tax

        // Seed the terminal with exactly enough TOKEN to just barely cover the surplus.
        // After 5 ETH payment, the surplus in TOKEN terms includes both the TOKEN balance and the
        // ETH balance converted to TOKEN (5 ETH * 2000 = 10,000 TOKEN), which when combined with
        // fee overhead will exceed what we seed.
        uint256 tokenSeed = 100e6; // Small seed -- deliberately insufficient.
        TOKEN.mint(address(this), tokenSeed);
        TOKEN.approve(address(jbMultiTerminal()), tokenSeed);
        jbMultiTerminal().addToBalanceOf(REVNET_ID, address(TOKEN), tokenSeed, false, "", "");

        // User1 pays 5 ETH.
        vm.prank(USER1);
        uint256 revTokens =
            jbMultiTerminal().pay{value: 5e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 5e18, USER1, 0, "", "");
        assertGt(revTokens, 0, "should receive revnet tokens");

        // Trying to cash out in TOKEN should revert because the bonding curve reclaim amount
        // (based on cross-currency total surplus) exceeds the actual TOKEN balance.
        vm.prank(USER1);
        vm.expectRevert();
        jbMultiTerminal()
            .cashOutTokensOf({
                holder: USER1,
                projectId: REVNET_ID,
                cashOutCount: revTokens,
                tokenToReclaim: address(TOKEN),
                minTokensReclaimed: 0,
                beneficiary: payable(USER1),
                metadata: ""
            });
    }

    /// @notice Pay with TOKEN (so the surplus is in TOKEN), then pay with ETH too.
    /// Cash out in TOKEN should succeed because the TOKEN balance in the terminal is sufficient
    /// to cover the reclaim amount.
    function test_cashOut_crossCurrency_payBothThenCashOutInToken() public {
        // Price feed: TOKEN -> ETH. 1 TOKEN (6 dec) = 0.0005 ETH. So 2000 TOKEN = 1 ETH.
        MockPriceFeed priceFeed = new MockPriceFeed(5e14, 18);
        vm.prank(multisig());
        jbPrices()
            .addPriceFeedFor(0, uint32(uint160(address(TOKEN))), uint32(uint160(JBConstants.NATIVE_TOKEN)), priceFeed);

        _deployFeeProject();
        REVNET_ID = _deployEthBasedRevnet(5000); // 50% cash out tax

        // User1 pays with TOKEN (provides actual TOKEN liquidity to the terminal).
        uint256 tokenPayment = 100_000e6; // 100,000 TOKEN = 50 ETH equivalent.
        TOKEN.mint(USER1, tokenPayment);
        vm.prank(USER1);
        TOKEN.approve(address(jbMultiTerminal()), tokenPayment);
        vm.prank(USER1);
        uint256 revTokens = jbMultiTerminal().pay(REVNET_ID, address(TOKEN), tokenPayment, USER1, 0, "", "");
        assertGt(revTokens, 0, "should receive revnet tokens from TOKEN payment");

        // Cash out a small portion in TOKEN. Since the TOKEN was paid in, the terminal has the balance.
        uint256 cashOutCount = revTokens / 10; // Only cash out 10% to ensure balance sufficiency.
        vm.prank(USER1);
        uint256 reclaimedToken = jbMultiTerminal()
            .cashOutTokensOf({
                holder: USER1,
                projectId: REVNET_ID,
                cashOutCount: cashOutCount,
                tokenToReclaim: address(TOKEN),
                minTokensReclaimed: 0,
                beneficiary: payable(USER1),
                metadata: ""
            });

        assertGt(reclaimedToken, 0, "should reclaim some TOKEN");
        assertLe(reclaimedToken, tokenPayment, "should not exceed total TOKEN paid in");
    }

    /// @notice Pay with both ETH and TOKEN from two users, then one cashes out.
    /// Ensures both token types generate tokens and the cross-currency surplus contributes to reclaim.
    function test_cashOut_crossCurrency_mixedPayments() public {
        // Price feed: TOKEN -> ETH (for surplus aggregation).
        // 1 TOKEN (6 dec) = 0.0005 ETH (18 dec). So 2000 TOKEN = 1 ETH.
        MockPriceFeed priceFeed = new MockPriceFeed(5e14, 18);
        vm.prank(multisig());
        jbPrices()
            .addPriceFeedFor(0, uint32(uint160(address(TOKEN))), uint32(uint160(JBConstants.NATIVE_TOKEN)), priceFeed);

        _deployFeeProject();
        REVNET_ID = _deployEthBasedRevnet(5000); // 50% cash out tax

        // User1 pays 5 ETH.
        vm.prank(USER1);
        uint256 tokens1 =
            jbMultiTerminal().pay{value: 5e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 5e18, USER1, 0, "", "");
        assertGt(tokens1, 0, "ETH payment should mint tokens");

        // User2 pays 10,000 TOKEN (= 5 ETH at the feed rate).
        uint256 tokenAmount = 10_000e6;
        TOKEN.mint(USER2, tokenAmount);
        vm.prank(USER2);
        TOKEN.approve(address(jbMultiTerminal()), tokenAmount);
        vm.prank(USER2);
        uint256 tokens2 = jbMultiTerminal().pay(REVNET_ID, address(TOKEN), tokenAmount, USER2, 0, "", "");
        assertGt(tokens2, 0, "TOKEN payment should mint tokens");

        // Both payments should have contributed to the surplus.
        // When User1 cashes out in ETH, the reclaimed amount should reflect the total surplus
        // including the TOKEN contribution (converted via price feed).
        vm.prank(USER1);
        uint256 reclaimed = jbMultiTerminal()
            .cashOutTokensOf({
                holder: USER1,
                projectId: REVNET_ID,
                cashOutCount: tokens1,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(USER1),
                metadata: ""
            });
        assertGt(reclaimed, 0, "should reclaim ETH from mixed-currency surplus");

        // The reclaimed amount should be less than the original payment (due to bonding curve tax).
        assertLt(reclaimed, 5e18, "with 50% tax and other holders, reclaim should be less than paid");
    }

    /// @notice Rounding sanity: a tiny payment (1 wei) should not produce disproportionate reclaim.
    function test_cashOut_crossCurrency_tinyPayment_noRoundingExploit() public {
        // Price feed: TOKEN -> ETH.
        MockPriceFeed priceFeed = new MockPriceFeed(5e14, 18);
        vm.prank(multisig());
        jbPrices()
            .addPriceFeedFor(0, uint32(uint160(address(TOKEN))), uint32(uint160(JBConstants.NATIVE_TOKEN)), priceFeed);

        _deployFeeProject();
        REVNET_ID = _deployEthBasedRevnet(5000); // 50% tax

        // User1 pays 1 wei of ETH.
        vm.prank(USER1);
        uint256 tokens = jbMultiTerminal().pay{value: 1}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1, USER1, 0, "", "");

        if (tokens == 0) {
            // No tokens minted for dust payment -- this is acceptable.
            return;
        }

        // Cash out should not return more than 1 wei.
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

        assertLe(reclaimed, 1, "tiny payment should not yield more than original amount");
    }

    /// @notice With a very high price feed (1 TOKEN = 1,000,000 ETH), verify the system handles extreme conversion
    /// without overflow or unexpected results.
    function test_cashOut_crossCurrency_extremeHighPriceFeed() public {
        // 1 TOKEN unit (6 dec) = 1,000,000 ETH (18 dec). This is an extreme price.
        MockPriceFeed priceFeed = new MockPriceFeed(1_000_000e18, 18);
        vm.prank(multisig());
        jbPrices()
            .addPriceFeedFor(0, uint32(uint160(address(TOKEN))), uint32(uint160(JBConstants.NATIVE_TOKEN)), priceFeed);

        _deployFeeProject();
        REVNET_ID = _deployEthBasedRevnet(5000);

        // Pay a small amount of TOKEN.
        uint256 tokenAmount = 1e6; // 1 TOKEN
        TOKEN.mint(USER1, tokenAmount);
        vm.prank(USER1);
        TOKEN.approve(address(jbMultiTerminal()), tokenAmount);
        vm.prank(USER1);
        uint256 revTokens = jbMultiTerminal().pay(REVNET_ID, address(TOKEN), tokenAmount, USER1, 0, "", "");
        assertGt(revTokens, 0, "should mint tokens even with extreme price feed");

        // Cash out in TOKEN.
        vm.prank(USER1);
        uint256 reclaimed = jbMultiTerminal()
            .cashOutTokensOf({
                holder: USER1,
                projectId: REVNET_ID,
                cashOutCount: revTokens,
                tokenToReclaim: address(TOKEN),
                minTokensReclaimed: 0,
                beneficiary: payable(USER1),
                metadata: ""
            });

        // Should reclaim some TOKEN (bounded by the original payment amount).
        assertLe(reclaimed, tokenAmount, "should not exceed original TOKEN payment");
    }

    /// @notice With a low price feed (1 TOKEN = 0.000001 ETH), verify cash out works.
    /// Below a certain threshold, the price-to-surplus conversion can cause arithmetic issues.
    function test_cashOut_crossCurrency_lowPriceFeed() public {
        // 1 TOKEN unit (6 dec) = 0.000001 ETH (1e12 wei). Low value token.
        MockPriceFeed priceFeed = new MockPriceFeed(1e12, 18);
        vm.prank(multisig());
        jbPrices()
            .addPriceFeedFor(0, uint32(uint160(address(TOKEN))), uint32(uint160(JBConstants.NATIVE_TOKEN)), priceFeed);

        _deployFeeProject();
        REVNET_ID = _deployEthBasedRevnet(3000); // 30% cash out tax

        // Pay a large amount of TOKEN.
        uint256 tokenAmount = 1_000_000e6; // 1M TOKEN
        TOKEN.mint(USER1, tokenAmount);
        vm.prank(USER1);
        TOKEN.approve(address(jbMultiTerminal()), tokenAmount);
        vm.prank(USER1);
        uint256 revTokens = jbMultiTerminal().pay(REVNET_ID, address(TOKEN), tokenAmount, USER1, 0, "", "");

        if (revTokens == 0) {
            // Token is so cheap that zero tokens were minted. Valid behavior.
            return;
        }

        // Cash out in TOKEN.
        vm.prank(USER1);
        uint256 reclaimed = jbMultiTerminal()
            .cashOutTokensOf({
                holder: USER1,
                projectId: REVNET_ID,
                cashOutCount: revTokens,
                tokenToReclaim: address(TOKEN),
                minTokensReclaimed: 0,
                beneficiary: payable(USER1),
                metadata: ""
            });

        assertLe(reclaimed, tokenAmount, "should not exceed total TOKEN paid");
    }

    /// @notice Cash out with zero tax rate. Single holder should reclaim the full surplus minus fees.
    function test_cashOut_crossCurrency_zeroTax() public {
        // Price feed: TOKEN -> ETH.
        MockPriceFeed priceFeed = new MockPriceFeed(5e14, 18); // 0.0005 ETH per TOKEN
        vm.prank(multisig());
        jbPrices()
            .addPriceFeedFor(0, uint32(uint160(address(TOKEN))), uint32(uint160(JBConstants.NATIVE_TOKEN)), priceFeed);

        _deployFeeProject();
        REVNET_ID = _deployEthBasedRevnet(0); // 0% cash out tax

        // User1 pays 10 ETH.
        vm.prank(USER1);
        uint256 tokens =
            jbMultiTerminal().pay{value: 10e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, USER1, 0, "", "");

        // Record terminal balance before cash out.
        uint256 balanceBefore =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), REVNET_ID, JBConstants.NATIVE_TOKEN);

        // Cash out all tokens. With 0% tax + sole holder, the bonding curve returns full surplus.
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

        // With 0% cash out tax, no fee is charged on cash outs (per REVDeployer.beforeCashOutRecordedWith).
        assertEq(reclaimed, balanceBefore, "0% tax, single holder should reclaim full balance");
    }
}
