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

/// @notice Regression tests for the empty buyback hook specifications fix.
/// When JBBuybackHook determines minting is cheaper than swapping, it returns an empty
/// hookSpecifications array. Before the fix, REVDeployer.beforePayRecordedWith would
/// Panic(0x32) (array out-of-bounds) when accessing buybackHookSpecifications[0].
contract TestEmptyBuybackSpecs is TestBaseWorkflow {
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";

    REVDeployer REV_DEPLOYER;
    JB721TiersHook EXAMPLE_HOOK;
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    IJB721TiersHookStore HOOK_STORE;
    IJBAddressRegistry ADDRESS_REGISTRY;
    IREVLoans LOANS_CONTRACT;
    IJBSuckerRegistry SUCKER_REGISTRY;
    CTPublisher PUBLISHER;
    MockBuybackDataHookMintPath MOCK_BUYBACK_MINT_PATH;

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
        MOCK_BUYBACK_MINT_PATH = new MockBuybackDataHookMintPath();
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
            IJBBuybackHookRegistry(address(MOCK_BUYBACK_MINT_PATH)),
            address(LOANS_CONTRACT),
            TRUSTED_FORWARDER
        );
        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);
    }

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

    function _deployFeeAndRevnet() internal returns (uint256 revnetId) {
        (REVConfig memory feeCfg, JBTerminalConfig[] memory feeTc, REVSuckerDeploymentConfig memory feeSdc) =
            _buildMinimalConfig();

        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeCfg,
            terminalConfigurations: feeTc,
            suckerDeploymentConfiguration: feeSdc
        });

        (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc) =
            _buildMinimalConfig();
        cfg.description = REVDescription("Test2", "TS2", "ipfs://test2", "TEST_SALT_2");

        revnetId = REV_DEPLOYER.deployFor({
            revnetId: 0, configuration: cfg, terminalConfigurations: tc, suckerDeploymentConfiguration: sdc
        });
    }

    /// @notice REGRESSION: Payment to revnet must succeed when buyback hook returns empty specs (mint path).
    /// Before the fix, this would Panic(0x32) due to accessing buybackHookSpecifications[0] on an empty array.
    function test_payRevnet_emptyBuybackSpecs_succeeds() public {
        uint256 revnetId = _deployFeeAndRevnet();

        vm.deal(USER, 1 ether);
        vm.prank(USER);
        jbMultiTerminal().pay{value: 1 ether}({
            projectId: revnetId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: USER,
            minReturnedTokens: 0,
            memo: "payment with mint path buyback",
            metadata: ""
        });

        uint256 balance = jbTokens().totalBalanceOf(USER, revnetId);
        assertGt(balance, 0, "Should have received tokens when buyback hook takes mint path");
    }

    /// @notice Payment with various amounts should work when buyback hook returns empty specs.
    function test_payRevnet_emptyBuybackSpecs_variousAmounts(uint96 amount) public {
        vm.assume(amount > 0.001 ether && amount < 100 ether);
        uint256 revnetId = _deployFeeAndRevnet();

        vm.deal(USER, amount);
        vm.prank(USER);
        jbMultiTerminal().pay{value: amount}({
            projectId: revnetId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: USER,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        uint256 balance = jbTokens().totalBalanceOf(USER, revnetId);
        assertGt(balance, 0, "Should have received tokens for any valid amount");
    }

    /// @notice Multiple sequential payments should work with empty buyback specs.
    function test_payRevnet_emptyBuybackSpecs_multiplePayments() public {
        uint256 revnetId = _deployFeeAndRevnet();

        for (uint256 i; i < 5; i++) {
            address payer = makeAddr(string(abi.encodePacked("payer", i)));
            vm.deal(payer, 1 ether);
            vm.prank(payer);
            jbMultiTerminal().pay{value: 1 ether}({
                projectId: revnetId,
                token: JBConstants.NATIVE_TOKEN,
                amount: 1 ether,
                beneficiary: payer,
                minReturnedTokens: 0,
                memo: "",
                metadata: ""
            });
            assertGt(jbTokens().totalBalanceOf(payer, revnetId), 0, "Each payer should receive tokens");
        }
    }

    /// @notice Verify beforePayRecordedWith returns empty hookSpecifications when buyback returns empty.
    function test_beforePayRecordedWith_emptyBuybackSpecs_returnsEmptyArray() public {
        uint256 revnetId = _deployFeeAndRevnet();

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

        assertEq(weight, context.weight, "Weight should pass through from buyback hook");
        assertEq(specs.length, 0, "Should return empty specs when buyback hook returns empty and no 721 hook");
    }
}
