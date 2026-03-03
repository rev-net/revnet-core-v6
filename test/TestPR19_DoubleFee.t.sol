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
import {mulDiv} from "@prb/math/src/Common.sol";
import {JBConstants} from "@bananapus/core-v5/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v5/src/structs/JBAccountingContext.sol";
import {REVLoans} from "../src/REVLoans.sol";
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

/// @notice Tests for PR #19: fix/h1-double-fee
/// Verifies the gross-up formula for cash out fees.
/// The bug: the hook spec amount was set to `feeAmount`, but the terminal deducts its own fee
/// from hook spec amounts, so the actual fee received was `feeAmount * (MAX_FEE - FEE) / MAX_FEE`.
/// The fix: gross up via `feeAmount * MAX_FEE / (MAX_FEE - FEE)` so after the terminal's deduction
/// the correct fee amount arrives at the fee project.
contract TestPR19_DoubleFee is TestBaseWorkflow, JBTest {
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";

    REVDeployer REV_DEPLOYER;
    JB721TiersHook EXAMPLE_HOOK;
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    IJB721TiersHookStore HOOK_STORE;
    IJBAddressRegistry ADDRESS_REGISTRY;
    IREVLoans LOANS_CONTRACT;
    IJBSuckerRegistry SUCKER_REGISTRY;
    CTPublisher PUBLISHER;

    uint256 FEE_PROJECT_ID;
    uint256 TEST_REVNET_ID;

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;
    address USER = makeAddr("user");

    // Constants matching REVDeployer
    uint256 constant FEE = 25; // 2.5%
    uint256 constant MAX_FEE = 1000;

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
        LOANS_CONTRACT = new REVLoans({
            revnets: REV_DEPLOYER,
            revId: FEE_PROJECT_ID,
            owner: address(this),
            permit2: permit2(),
            trustedForwarder: TRUSTED_FORWARDER
        });
        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);

        // Deploy the fee project first
        (
            REVConfig memory feeCfg,
            JBTerminalConfig[] memory feeTc,
            REVBuybackHookConfig memory feeBbh,
            REVSuckerDeploymentConfig memory feeSdc
        ) = _buildConfig(5000, "FeeProject", "FEE", "FEE_SALT");

        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeCfg,
            terminalConfigurations: feeTc,
            buybackHookConfiguration: feeBbh,
            suckerDeploymentConfiguration: feeSdc
        });
    }

    function _buildConfig(
        uint16 cashOutTaxRate,
        string memory name,
        string memory ticker,
        bytes32 salt
    )
        internal
        view
        returns (
            REVConfig memory cfg,
            JBTerminalConfig[] memory tc,
            REVBuybackHookConfig memory bbh,
            REVSuckerDeploymentConfig memory sdc
        )
    {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
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
            cashOutTaxRate: cashOutTaxRate,
            extraMetadata: 0
        });

        cfg = REVConfig({
            description: REVDescription(name, ticker, "ipfs://test", salt),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages,
            loanSources: new REVLoanSource[](0),
            loans: address(0)
        });

        bbh = REVBuybackHookConfig({
            dataHook: IJBRulesetDataHook(address(0)),
            hookToConfigure: IJBBuybackHook(address(0)),
            poolConfigurations: new REVBuybackPoolConfig[](0)
        });

        sdc = REVSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0),
            salt: keccak256(abi.encodePacked("TEST"))
        });
    }

    /// @notice Pure math test: verify the gross-up formula is correct.
    /// grossUp = feeAmount * MAX_FEE / (MAX_FEE - FEE)
    /// After terminal deduction: grossUp * (MAX_FEE - FEE) / MAX_FEE ~= feeAmount (within 1 wei rounding)
    function test_grossUpFormula_isCorrect() public pure {
        uint256 feeAmount = 1 ether;
        uint256 grossFeeAmount = mulDiv(feeAmount, MAX_FEE, MAX_FEE - FEE);

        // grossFeeAmount = 1e18 * 1000 / 975 = 1025641025641025641 (approx 1.02564e18)
        assertEq(grossFeeAmount, mulDiv(1 ether, 1000, 975), "Gross fee should equal feeAmount * 1000 / 975");

        // The gross-up is strictly greater than the original fee amount
        assertGt(grossFeeAmount, feeAmount, "Gross fee should be larger than original fee");

        // After the terminal deducts its fee: grossFeeAmount * (MAX_FEE - FEE) / MAX_FEE
        // Due to mulDiv rounding down, the net may be up to 1 wei less than the original
        uint256 netAmount = mulDiv(grossFeeAmount, MAX_FEE - FEE, MAX_FEE);
        assertApproxEqAbs(netAmount, feeAmount, 1, "After terminal deduction, net should be within 1 wei of feeAmount");

        // Without the gross-up (the old buggy behavior), the loss would be significant
        uint256 buggyNet = mulDiv(feeAmount, MAX_FEE - FEE, MAX_FEE);
        uint256 loss = feeAmount - buggyNet;
        // Loss = feeAmount * FEE / MAX_FEE = 1e18 * 25 / 1000 = 0.025e18 (2.5%)
        assertEq(loss, mulDiv(feeAmount, FEE, MAX_FEE), "Without gross-up, loss is 2.5% of fee amount");
        assertGt(loss, 1, "Without gross-up, loss is much more than rounding dust");

        // Test with various amounts
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 0.1 ether;
        amounts[1] = 10 ether;
        amounts[2] = 100 ether;
        amounts[3] = 1000 ether;

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 gross = mulDiv(amounts[i], MAX_FEE, MAX_FEE - FEE);
            uint256 net = mulDiv(gross, MAX_FEE - FEE, MAX_FEE);
            assertApproxEqAbs(net, amounts[i], 1, "Net should be within 1 wei of original for all amounts");
        }
    }

    /// @notice Deploy a revnet with cashOutTaxRate > 0, pay in, cash out, and verify
    /// the fee project receives fees.
    function test_cashOutFeeAmount_feeProjectReceivesFees() public {
        // Deploy test revnet with 50% cash out tax rate
        (
            REVConfig memory cfg,
            JBTerminalConfig[] memory tc,
            REVBuybackHookConfig memory bbh,
            REVSuckerDeploymentConfig memory sdc
        ) = _buildConfig(5000, "TestRevnet", "TST", "TST_SALT"); // 50% tax rate

        TEST_REVNET_ID = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: cfg,
            terminalConfigurations: tc,
            buybackHookConfiguration: bbh,
            suckerDeploymentConfiguration: sdc
        });

        // Pay into the revnet
        vm.deal(USER, 10 ether);
        vm.prank(USER);
        jbMultiTerminal().pay{value: 10 ether}({
            projectId: TEST_REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            beneficiary: USER,
            minReturnedTokens: 0,
            memo: "funding",
            metadata: ""
        });

        uint256 tokenBalance = jbTokens().totalBalanceOf(USER, TEST_REVNET_ID);
        assertGt(tokenBalance, 0, "User should have tokens");

        // Record balances before cash out
        uint256 feeProjectBalanceBefore = jbTerminalStore().balanceOf(
            address(jbMultiTerminal()), FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN
        );

        // Cash out half of tokens
        uint256 cashOutCount = tokenBalance / 2;
        vm.prank(USER);
        uint256 reclaimedAmount = jbMultiTerminal().cashOutTokensOf({
            holder: USER,
            projectId: TEST_REVNET_ID,
            cashOutCount: cashOutCount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(USER),
            metadata: ""
        });

        assertGt(reclaimedAmount, 0, "Should have reclaimed some tokens");

        // Fee project should have received fee payment
        uint256 feeProjectBalanceAfter = jbTerminalStore().balanceOf(
            address(jbMultiTerminal()), FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN
        );

        uint256 feeReceived = feeProjectBalanceAfter - feeProjectBalanceBefore;
        assertGt(feeReceived, 0, "Fee project should have received fees from cash out");
    }

    /// @notice Deploy revnet with cashOutTaxRate=0 (100% redemption), cash out, verify no fee charged.
    /// When cashOutTaxRate is 0, beforeCashOutRecordedWith returns early with no hook specs.
    function test_zeroCashOutTaxRate_noFee() public {
        // Deploy test revnet with 0% cash out tax rate (no tax = full redemption value)
        (
            REVConfig memory cfg,
            JBTerminalConfig[] memory tc,
            REVBuybackHookConfig memory bbh,
            REVSuckerDeploymentConfig memory sdc
        ) = _buildConfig(0, "NoTaxRevnet", "NTX", "NTX_SALT"); // 0 tax rate

        uint256 noTaxRevnetId = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: cfg,
            terminalConfigurations: tc,
            buybackHookConfiguration: bbh,
            suckerDeploymentConfiguration: sdc
        });

        // Pay into the revnet
        vm.deal(USER, 10 ether);
        vm.prank(USER);
        jbMultiTerminal().pay{value: 10 ether}({
            projectId: noTaxRevnetId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            beneficiary: USER,
            minReturnedTokens: 0,
            memo: "funding",
            metadata: ""
        });

        uint256 tokenBalance = jbTokens().totalBalanceOf(USER, noTaxRevnetId);
        assertGt(tokenBalance, 0, "User should have tokens");

        // Record fee project balance before
        uint256 feeProjectBalanceBefore = jbTerminalStore().balanceOf(
            address(jbMultiTerminal()), FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN
        );

        // Cash out all tokens
        vm.prank(USER);
        uint256 reclaimedAmount = jbMultiTerminal().cashOutTokensOf({
            holder: USER,
            projectId: noTaxRevnetId,
            cashOutCount: tokenBalance,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(USER),
            metadata: ""
        });

        assertGt(reclaimedAmount, 0, "Should have reclaimed tokens");

        // Fee project balance should not have changed (no fee when cashOutTaxRate == 0)
        uint256 feeProjectBalanceAfter = jbTerminalStore().balanceOf(
            address(jbMultiTerminal()), FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN
        );

        assertEq(
            feeProjectBalanceAfter,
            feeProjectBalanceBefore,
            "Fee project should not receive fees when cashOutTaxRate is 0"
        );
    }
}
