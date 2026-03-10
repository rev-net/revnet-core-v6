// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
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

/// @notice Documents and verifies that stage transitions change the borrowable amount for the same collateral.
/// This is by design: loan value tracks the current bonding curve parameters (cashOutTaxRate),
/// just as cash-out value does.
contract TestStageTransitionBorrowable is TestBaseWorkflow {
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
    uint256 REVNET_ID;

    address USER = makeAddr("user");

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    /// @notice Stage 1 starts now with 60% cashOutTaxRate, stage 2 starts after 30 days with 20% cashOutTaxRate.
    function _buildConfig()
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

        REVStageConfig[] memory stages = new REVStageConfig[](2);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        // Stage 1: high cashOutTaxRate (60%)
        stages[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 6000, // 60%
            extraMetadata: 0
        });

        // Stage 2: low cashOutTaxRate (20%) — starts after 30 days
        stages[1] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp + 30 days),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 2000, // 20%
            extraMetadata: 0
        });

        cfg = REVConfig({
            description: REVDescription("StageTest", "STG", "ipfs://test", "STG_SALT"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });

        sdc = REVSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("STG"))
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

        // Deploy the fee project first.
        (REVConfig memory feeCfg, JBTerminalConfig[] memory feeTc, REVSuckerDeploymentConfig memory feeSdc) =
            _buildConfig();
        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeCfg,
            terminalConfigurations: feeTc,
            suckerDeploymentConfiguration: feeSdc
        });

        // Deploy the test revnet.
        (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc) = _buildConfig();
        cfg.description = REVDescription("StageTest2", "ST2", "ipfs://test2", "STG_SALT_2");
        REVNET_ID = REV_DEPLOYER.deployFor({
            revnetId: 0, configuration: cfg, terminalConfigurations: tc, suckerDeploymentConfiguration: sdc
        });

        vm.deal(USER, 100 ether);
    }

    /// @notice BY DESIGN: Borrowable amount increases when transitioning to a stage with lower cashOutTaxRate.
    /// This documents that loan value tracks the current bonding curve, just as cash-out value does.
    /// @dev The bonding curve only applies a tax discount when cashOutCount < totalSupply,
    /// so we need multiple payers to see the effect.
    function test_borrowableAmount_increasesWhenCashOutTaxRateDecreases() public {
        // Two payers so the bonding curve tax rate has a visible effect (count < supply).
        address otherPayer = makeAddr("otherPayer");
        vm.deal(otherPayer, 10 ether);
        vm.prank(otherPayer);
        jbMultiTerminal().pay{value: 10 ether}({
            projectId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            beneficiary: otherPayer,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: 10 ether}({
            projectId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            beneficiary: USER,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
        assertGt(tokens, 0, "Should receive tokens");

        // Check borrowable amount during stage 1 (60% cashOutTaxRate).
        uint256 borrowableStage1 =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        assertGt(borrowableStage1, 0, "Borrowable amount should be positive in stage 1");

        // Warp to stage 2 (20% cashOutTaxRate).
        vm.warp(block.timestamp + 31 days);

        // Check borrowable amount during stage 2.
        uint256 borrowableStage2 =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        // Borrowable amount should be HIGHER with a lower cashOutTaxRate — by design.
        assertGt(borrowableStage2, borrowableStage1, "Borrowable amount should increase with lower cashOutTaxRate");
    }

    /// @notice Verifies that the bonding curve formula applies the tax rate correctly when count < supply.
    function test_borrowableAmount_taxRateReducesPartialCashOut() public {
        // Two payers so USER holds a fraction of total supply.
        address otherPayer = makeAddr("otherPayer");
        vm.deal(otherPayer, 10 ether);
        vm.prank(otherPayer);
        jbMultiTerminal().pay{value: 10 ether}({
            projectId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            beneficiary: otherPayer,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: 10 ether}({
            projectId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            beneficiary: USER,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        // With 60% tax rate and ~50% of supply, borrowable should be meaningfully less than pro-rata share.
        uint256 borrowable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        assertGt(borrowable, 0, "Borrowable amount should be positive");
        // Pro-rata share would be ~10 ether (half of 20 ether surplus). With 60% tax, it should be less.
        assertLt(borrowable, 10 ether, "Borrowable should be less than pro-rata share due to tax rate");
    }
}
