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
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";

/// @notice Tests for the split weight adjustment in REVDeployer.beforePayRecordedWith.
contract TestSplitWeightAdjustment is TestBaseWorkflow {
    bytes32 REV_DEPLOYER_SALT = "REVDeployer_SWA";

    REVDeployer REV_DEPLOYER;
    JB721TiersHook EXAMPLE_HOOK;
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    IJB721TiersHookStore HOOK_STORE;
    IJBAddressRegistry ADDRESS_REGISTRY;
    IREVLoans LOANS_CONTRACT;
    IJBSuckerRegistry SUCKER_REGISTRY;
    CTPublisher PUBLISHER;
    MockBuybackDataHookMintPath MOCK_BUYBACK;

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
        MOCK_BUYBACK = new MockBuybackDataHookMintPath();
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

    function _deployRevnet() internal returns (uint256 revnetId) {
        // Deploy fee project first.
        (REVConfig memory feeCfg, JBTerminalConfig[] memory feeTc, REVSuckerDeploymentConfig memory feeSdc) =
            _buildMinimalConfig();
        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeCfg,
            terminalConfigurations: feeTc,
            suckerDeploymentConfiguration: feeSdc
        });

        // Deploy the revnet.
        (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc) =
            _buildMinimalConfig();
        cfg.description = REVDescription("Test2", "TS2", "ipfs://test2", "TEST_SALT_2");
        revnetId = REV_DEPLOYER.deployFor({
            revnetId: 0, configuration: cfg, terminalConfigurations: tc, suckerDeploymentConfiguration: sdc
        });
    }

    /// @notice No 721 hook = no split adjustment, weight from buyback passes through.
    function test_beforePay_no721_noAdjustment() public {
        uint256 revnetId = _deployRevnet();

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

        // No 721 hook deployed, buyback returns context.weight with empty specs.
        (uint256 weight, JBPayHookSpecification[] memory specs) = REV_DEPLOYER.beforePayRecordedWith(context);

        assertEq(weight, context.weight, "weight should pass through unchanged");
        assertEq(specs.length, 0, "no specs when no 721 hook and empty buyback");
    }

    /// @notice When 721 hook returns splits, weight is adjusted proportionally.
    function test_beforePay_splitAdjustsWeight() public {
        uint256 revnetId = _deployRevnet();

        // Mock a 721 hook for this project.
        address mock721 = makeAddr("mock721");
        vm.etch(mock721, bytes("0x01"));

        // Store the mock 721 hook.
        // tiered721HookOf is internal, so we use vm.store.
        // Slot for tiered721HookOf[revnetId]: keccak256(abi.encode(revnetId, slot))
        // Need to find the storage slot for tiered721HookOf mapping.
        bytes32 slot = keccak256(abi.encode(revnetId, uint256(3))); // slot 9 for tiered721HookOf in REVDeployer
        vm.store(address(REV_DEPLOYER), slot, bytes32(uint256(uint160(mock721))));

        // Verify the store worked.
        assertEq(address(REV_DEPLOYER.tiered721HookOf(revnetId)), mock721, "721 hook stored");

        // Mock 721 hook returning 0.3 ETH split on 1 ETH payment.
        JBPayHookSpecification[] memory hookSpecs = new JBPayHookSpecification[](1);
        hookSpecs[0] = JBPayHookSpecification({hook: IJBPayHook(mock721), amount: 0.3 ether, metadata: bytes("")});
        vm.mockCall(
            mock721,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(700e18), hookSpecs)
        );

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

        (uint256 weight,) = REV_DEPLOYER.beforePayRecordedWith(context);

        // Buyback returns context.weight (1000e18) since mock buyback passes through.
        // Weight adjusted for 0.3 ETH split on 1 ETH: 1000e18 * 0.7 = 700e18.
        assertEq(weight, 700e18, "weight = buybackWeight * (amount - split) / amount");
    }

    /// @notice When 721 splits take the full amount, weight is zero.
    function test_beforePay_fullSplit_weightZero() public {
        uint256 revnetId = _deployRevnet();

        address mock721 = makeAddr("mock721_full");
        vm.etch(mock721, bytes("0x01"));
        bytes32 slot = keccak256(abi.encode(revnetId, uint256(3)));
        vm.store(address(REV_DEPLOYER), slot, bytes32(uint256(uint160(mock721))));

        // Mock 721 hook returning full 1 ETH split.
        JBPayHookSpecification[] memory hookSpecs = new JBPayHookSpecification[](1);
        hookSpecs[0] = JBPayHookSpecification({hook: IJBPayHook(mock721), amount: 1 ether, metadata: bytes("")});
        vm.mockCall(
            mock721,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(0), hookSpecs)
        );

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

        (uint256 weight,) = REV_DEPLOYER.beforePayRecordedWith(context);

        assertEq(weight, 0, "full split = zero weight");
    }

    /// @notice 721 with splits + buyback (AMM swap path) — weight adjusted, both specs present.
    function test_beforePay_splitPlusBuybackAMM_correctWeight() public {
        // Deploy with the AMM-path buyback hook.
        (REVConfig memory feeCfg, JBTerminalConfig[] memory feeTc, REVSuckerDeploymentConfig memory feeSdc) =
            _buildMinimalConfig();
        vm.prank(multisig());
        jbProjects().approve(address(0), FEE_PROJECT_ID); // clear old approval

        // Deploy a new REVDeployer with the AMM buyback mock.
        MockBuybackDataHook ammBuyback = new MockBuybackDataHook();
        REVDeployer ammDeployer = new REVDeployer{salt: "REVDeployer_AMM"}(
            jbController(),
            SUCKER_REGISTRY,
            FEE_PROJECT_ID,
            HOOK_DEPLOYER,
            PUBLISHER,
            IJBRulesetDataHook(address(ammBuyback)),
            address(LOANS_CONTRACT),
            TRUSTED_FORWARDER
        );

        vm.prank(multisig());
        jbProjects().approve(address(ammDeployer), FEE_PROJECT_ID);

        vm.prank(multisig());
        ammDeployer.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeCfg,
            terminalConfigurations: feeTc,
            suckerDeploymentConfiguration: feeSdc
        });

        (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc) =
            _buildMinimalConfig();
        cfg.description = REVDescription("AMM", "AMM", "ipfs://amm", "AMM_SALT");
        uint256 revnetId = ammDeployer.deployFor({
            revnetId: 0, configuration: cfg, terminalConfigurations: tc, suckerDeploymentConfiguration: sdc
        });

        // Mock a 721 hook for this project.
        address mock721 = makeAddr("mock721_amm");
        vm.etch(mock721, bytes("0x01"));
        bytes32 slot = keccak256(abi.encode(revnetId, uint256(3)));
        vm.store(address(ammDeployer), slot, bytes32(uint256(uint160(mock721))));

        // Mock 721 hook returning 0.4 ETH split on 1 ETH payment.
        JBPayHookSpecification[] memory hookSpecs = new JBPayHookSpecification[](1);
        hookSpecs[0] = JBPayHookSpecification({hook: IJBPayHook(mock721), amount: 0.4 ether, metadata: bytes("")});
        vm.mockCall(
            mock721,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(600e18), hookSpecs)
        );

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

        (uint256 weight, JBPayHookSpecification[] memory specs) = ammDeployer.beforePayRecordedWith(context);

        // AMM buyback returns context.weight (passes through the reduced weight from context).
        // The buyback mock receives a reduced context with 0.6 ETH and returns that weight.
        // Then weight is adjusted: weight * 0.6 = 600e18.
        assertEq(weight, 600e18, "weight = buybackWeight * (amount - split) / amount");

        // Specs: [721 hook with split, buyback spec].
        assertEq(specs.length, 2, "721 spec + buyback spec");
        assertEq(address(specs[0].hook), mock721, "first = 721 hook");
        assertEq(specs[0].amount, 0.4 ether, "721 split amount preserved");
        assertEq(address(specs[1].hook), address(ammBuyback), "second = buyback hook");
    }

    /// @notice 721 with splits + buyback (mint path, no AMM trigger) — weight adjusted, only 721 spec.
    function test_beforePay_splitPlusBuybackMintPath_correctWeight() public {
        uint256 revnetId = _deployRevnet();

        address mock721 = makeAddr("mock721_mint");
        vm.etch(mock721, bytes("0x01"));
        bytes32 slot = keccak256(abi.encode(revnetId, uint256(3)));
        vm.store(address(REV_DEPLOYER), slot, bytes32(uint256(uint160(mock721))));

        // Mock 721 hook returning 0.2 ETH split.
        JBPayHookSpecification[] memory hookSpecs = new JBPayHookSpecification[](1);
        hookSpecs[0] = JBPayHookSpecification({hook: IJBPayHook(mock721), amount: 0.2 ether, metadata: bytes("")});
        vm.mockCall(
            mock721,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(800e18), hookSpecs)
        );

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

        // Buyback mint path: returns context.weight (1000e18 from reduced context = 0.8 ETH context).
        // Actually MockBuybackDataHookMintPath returns context.weight with empty specs.
        // Weight adjusted: 1000e18 * 0.8 = 800e18.
        assertEq(weight, 800e18, "weight adjusted for split with mint-path buyback");

        // Only 721 spec (buyback mint path returns empty).
        assertEq(specs.length, 1, "only 721 spec (buyback empty)");
        assertEq(address(specs[0].hook), mock721, "spec = 721 hook");
        assertEq(specs[0].amount, 0.2 ether, "split amount");
    }

    /// @notice Splits forward actual 721 hook specs (not hardcoded amount: 0).
    function test_beforePay_splitForwardsActualSpecs() public {
        uint256 revnetId = _deployRevnet();

        address mock721 = makeAddr("mock721_specs");
        vm.etch(mock721, bytes("0x01"));
        bytes32 slot = keccak256(abi.encode(revnetId, uint256(3)));
        vm.store(address(REV_DEPLOYER), slot, bytes32(uint256(uint160(mock721))));

        // Mock 721 hook returning split amount with metadata.
        bytes memory splitMeta = abi.encode(uint256(42));
        JBPayHookSpecification[] memory hookSpecs = new JBPayHookSpecification[](1);
        hookSpecs[0] = JBPayHookSpecification({hook: IJBPayHook(mock721), amount: 0.5 ether, metadata: splitMeta});
        vm.mockCall(
            mock721,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(uint256(500e18), hookSpecs)
        );

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

        (, JBPayHookSpecification[] memory specs) = REV_DEPLOYER.beforePayRecordedWith(context);

        // Should have 721 hook spec (buyback empty).
        assertEq(specs.length, 1, "should have 1 spec (721 hook, buyback empty)");
        assertEq(address(specs[0].hook), mock721, "spec points to 721 hook");
        assertEq(specs[0].amount, 0.5 ether, "split amount forwarded");
        assertEq(specs[0].metadata, splitMeta, "split metadata forwarded");
    }
}
