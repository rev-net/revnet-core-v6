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
import {MockPriceFeed} from "@bananapus/core-v5/test/mock/MockPriceFeed.sol";
import {MockERC20} from "@bananapus/core-v5/test/mock/MockERC20.sol";
import {REVLoans} from "../src/REVLoans.sol";
import {REVLoan} from "../src/structs/REVLoan.sol";
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

struct FeeProjectConfig {
    REVConfig configuration;
    JBTerminalConfig[] terminalConfigurations;
    REVBuybackHookConfig buybackHookConfiguration;
    REVSuckerDeploymentConfig suckerDeploymentConfiguration;
}

contract TestPR11_LowFindings is TestBaseWorkflow, JBTest {
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";
    bytes32 ERC20_SALT = "REV_TOKEN";

    REVDeployer REV_DEPLOYER;
    JB721TiersHook EXAMPLE_HOOK;
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    IJB721TiersHookStore HOOK_STORE;
    IJBAddressRegistry ADDRESS_REGISTRY;
    IREVLoans LOANS_CONTRACT;
    MockERC20 TOKEN;
    IJBSuckerRegistry SUCKER_REGISTRY;
    CTPublisher PUBLISHER;

    uint256 FEE_PROJECT_ID;
    uint256 REVNET_ID;

    address USER = makeAddr("user");

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    function getFeeProjectConfig() internal view returns (FeeProjectConfig memory) {
        uint8 decimals = 18;
        uint256 decimalMultiplier = 10 ** decimals;

        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](2);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        accountingContextsToAccept[1] =
            JBAccountingContext({token: address(TOKEN), decimals: 6, currency: uint32(uint160(address(TOKEN)))});

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
            splitPercent: 2000,
            splits: splits,
            initialIssuance: uint112(1000 * decimalMultiplier),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: 0
        });

        REVConfig memory revnetConfiguration = REVConfig({
            description: REVDescription("Revnet", "$REV", "ipfs://test", ERC20_SALT),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations,
            loanSources: new REVLoanSource[](0),
            loans: address(0)
        });

        REVBuybackPoolConfig[] memory buybackPoolConfigurations = new REVBuybackPoolConfig[](1);
        buybackPoolConfigurations[0] =
            REVBuybackPoolConfig({token: JBConstants.NATIVE_TOKEN, fee: 10_000, twapWindow: 2 days});
        REVBuybackHookConfig memory buybackHookConfiguration = REVBuybackHookConfig({
            dataHook: IJBRulesetDataHook(address(0)),
            hookToConfigure: IJBBuybackHook(address(0)),
            poolConfigurations: buybackPoolConfigurations
        });

        return FeeProjectConfig({
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            buybackHookConfiguration: buybackHookConfiguration,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0),
                salt: keccak256(abi.encodePacked("REV"))
            })
        });
    }

    /// @notice Deploy a revnet with two stages for testing stage transitions.
    /// Stage 0: cashOutTaxRate=2000 (20%), starts now
    /// Stage 1: cashOutTaxRate=6000 (60%), starts after 30 days
    function _deployTwoStageRevnet() internal returns (uint256 revnetId) {
        uint8 decimals = 18;
        uint256 decimalMultiplier = 10 ** decimals;

        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](2);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        accountingContextsToAccept[1] =
            JBAccountingContext({token: address(TOKEN), decimals: 6, currency: uint32(uint160(address(TOKEN)))});

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](2);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        // Stage 0: low tax rate (20%).
        stageConfigurations[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 2000,
            splits: splits,
            initialIssuance: uint112(1000 * decimalMultiplier),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 2000, // 20%
            extraMetadata: 0
        });

        // Stage 1: high tax rate (60%), starts after 30 days.
        stageConfigurations[1] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp + 30 days),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 2000,
            splits: splits,
            initialIssuance: 0, // inherit
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 6000, // 60%
            extraMetadata: 0
        });

        REVLoanSource[] memory loanSources = new REVLoanSource[](1);
        loanSources[0] = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        REVConfig memory revnetConfiguration = REVConfig({
            description: REVDescription("TwoStage", "$TWO", "ipfs://test", "TWO_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations,
            loanSources: loanSources,
            loans: address(LOANS_CONTRACT)
        });

        REVBuybackPoolConfig[] memory buybackPoolConfigurations = new REVBuybackPoolConfig[](1);
        buybackPoolConfigurations[0] =
            REVBuybackPoolConfig({token: JBConstants.NATIVE_TOKEN, fee: 10_000, twapWindow: 2 days});
        REVBuybackHookConfig memory buybackHookConfiguration = REVBuybackHookConfig({
            dataHook: IJBRulesetDataHook(address(0)),
            hookToConfigure: IJBBuybackHook(address(0)),
            poolConfigurations: buybackPoolConfigurations
        });

        revnetId = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            buybackHookConfiguration: buybackHookConfiguration,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0),
                salt: keccak256(abi.encodePacked("TWO"))
            })
        });
    }

    /// @notice Deploy a single-stage revnet with loans enabled.
    function _deploySingleStageRevnet() internal returns (uint256 revnetId) {
        uint8 decimals = 18;
        uint256 decimalMultiplier = 10 ** decimals;

        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](2);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        accountingContextsToAccept[1] =
            JBAccountingContext({token: address(TOKEN), decimals: 6, currency: uint32(uint160(address(TOKEN)))});

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
            splitPercent: 2000,
            splits: splits,
            initialIssuance: uint112(1000 * decimalMultiplier),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 0, // 0% tax for simplicity
            extraMetadata: 0
        });

        REVLoanSource[] memory loanSources = new REVLoanSource[](1);
        loanSources[0] = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        REVConfig memory revnetConfiguration = REVConfig({
            description: REVDescription("Single", "$SGL", "ipfs://test", "SGL_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations,
            loanSources: loanSources,
            loans: address(LOANS_CONTRACT)
        });

        REVBuybackPoolConfig[] memory buybackPoolConfigurations = new REVBuybackPoolConfig[](1);
        buybackPoolConfigurations[0] =
            REVBuybackPoolConfig({token: JBConstants.NATIVE_TOKEN, fee: 10_000, twapWindow: 2 days});
        REVBuybackHookConfig memory buybackHookConfiguration = REVBuybackHookConfig({
            dataHook: IJBRulesetDataHook(address(0)),
            hookToConfigure: IJBBuybackHook(address(0)),
            poolConfigurations: buybackPoolConfigurations
        });

        revnetId = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            buybackHookConfiguration: buybackHookConfiguration,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0),
                salt: keccak256(abi.encodePacked("SGL"))
            })
        });
    }

    function setUp() public override {
        super.setUp();

        FEE_PROJECT_ID = jbProjects().createFor(multisig());
        SUCKER_REGISTRY = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig(), address(0));
        HOOK_STORE = new JB721TiersHookStore();
        EXAMPLE_HOOK = new JB721TiersHook(jbDirectory(), jbPermissions(), jbRulesets(), HOOK_STORE, multisig());
        ADDRESS_REGISTRY = new JBAddressRegistry();
        HOOK_DEPLOYER = new JB721TiersHookDeployer(EXAMPLE_HOOK, HOOK_STORE, ADDRESS_REGISTRY, multisig());
        PUBLISHER = new CTPublisher(jbDirectory(), jbPermissions(), FEE_PROJECT_ID, multisig());
        TOKEN = new MockERC20("1/2 ETH", "1/2");

        MockPriceFeed priceFeed = new MockPriceFeed(1e21, 6);
        vm.prank(multisig());
        jbPrices().addPriceFeedFor(
            0, uint32(uint160(address(TOKEN))), uint32(uint160(JBConstants.NATIVE_TOKEN)), priceFeed
        );

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

        // Deploy fee project.
        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);

        FeeProjectConfig memory feeProjectConfig = getFeeProjectConfig();
        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeProjectConfig.configuration,
            terminalConfigurations: feeProjectConfig.terminalConfigurations,
            buybackHookConfiguration: feeProjectConfig.buybackHookConfiguration,
            suckerDeploymentConfiguration: feeProjectConfig.suckerDeploymentConfiguration
        });

        vm.deal(USER, 1000 ether);
    }

    /// @notice Stage transition reduces borrowable amount due to higher cashOutTaxRate.
    function test_stageTransition_reducesLoanHealth() public {
        uint256 revnetId = _deployTwoStageRevnet();

        // Pay ETH into revnet to create surplus and get tokens.
        vm.prank(USER);
        uint256 tokens =
            jbMultiTerminal().pay{value: 10 ether}(revnetId, JBConstants.NATIVE_TOKEN, 10 ether, USER, 0, "", "");
        assertGt(tokens, 0, "Should have received tokens");

        // Check borrowable amount in stage 0 (20% tax).
        uint256 borrowableStage0 = LOANS_CONTRACT.borrowableAmountFrom(
            revnetId, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        assertGt(borrowableStage0, 0, "Should have borrowable amount in stage 0");

        // Warp to stage 1 (60% tax).
        vm.warp(block.timestamp + 30 days + 1);

        // Check borrowable amount in stage 1 — should be lower due to higher tax.
        uint256 borrowableStage1 = LOANS_CONTRACT.borrowableAmountFrom(
            revnetId, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );

        assertLt(
            borrowableStage1, borrowableStage0, "Borrowable amount should decrease when cashOutTaxRate increases"
        );
    }

    /// @notice After full repayment, loan data is deleted (storage cleared).
    function test_loanDataDeletedAfterRepay() public {
        uint256 revnetId = _deploySingleStageRevnet();

        // Pay ETH into revnet to get tokens.
        vm.prank(USER);
        uint256 tokens =
            jbMultiTerminal().pay{value: 10 ether}(revnetId, JBConstants.NATIVE_TOKEN, 10 ether, USER, 0, "", "");

        uint256 loanable = LOANS_CONTRACT.borrowableAmountFrom(
            revnetId, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        // Skip if nothing borrowable.
        vm.assume(loanable > 0);

        // Mock permission for BURN (permission ID 10).
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, revnetId, 10, true, true)),
            abi.encode(true)
        );

        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        uint256 minPrepaid = LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT();

        vm.prank(USER);
        (uint256 loanId,) = LOANS_CONTRACT.borrowFrom(revnetId, source, loanable, tokens, payable(USER), minPrepaid);

        REVLoan memory loanBefore = LOANS_CONTRACT.loanOf(loanId);
        assertGt(loanBefore.amount, 0, "Loan should have an amount");
        assertGt(loanBefore.collateral, 0, "Loan should have collateral");

        // Fully repay the loan — return all collateral.
        JBSingleAllowance memory allowance;

        vm.prank(USER);
        LOANS_CONTRACT.repayLoan{value: loanBefore.amount * 2}(
            loanId, loanBefore.amount * 2, loanBefore.collateral, payable(USER), allowance
        );

        // After repayment, loan storage should be cleared.
        REVLoan memory loanAfter = LOANS_CONTRACT.loanOf(loanId);
        assertEq(loanAfter.amount, 0, "Loan amount should be 0 after repay");
        assertEq(loanAfter.collateral, 0, "Loan collateral should be 0 after repay");
        assertEq(loanAfter.createdAt, 0, "Loan createdAt should be 0 after repay");
    }

    /// @notice After liquidation, loan data is deleted (storage cleared).
    function test_loanDataDeletedAfterLiquidation() public {
        uint256 revnetId = _deploySingleStageRevnet();

        // Pay ETH into revnet to get tokens.
        vm.prank(USER);
        uint256 tokens =
            jbMultiTerminal().pay{value: 10 ether}(revnetId, JBConstants.NATIVE_TOKEN, 10 ether, USER, 0, "", "");

        uint256 loanable = LOANS_CONTRACT.borrowableAmountFrom(
            revnetId, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        // Skip if nothing borrowable.
        vm.assume(loanable > 0);

        // Mock permission for BURN (permission ID 10).
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, revnetId, 10, true, true)),
            abi.encode(true)
        );

        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        uint256 minPrepaid = LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT();

        vm.prank(USER);
        (uint256 loanId,) = LOANS_CONTRACT.borrowFrom(revnetId, source, loanable, tokens, payable(USER), minPrepaid);

        REVLoan memory loanBefore = LOANS_CONTRACT.loanOf(loanId);
        assertGt(loanBefore.amount, 0, "Loan should exist before liquidation");

        // Warp past LOAN_LIQUIDATION_DURATION (3650 days).
        vm.warp(block.timestamp + 3650 days + 1);

        // Get the loan number from the ID (loanId = revnetId * 1_000_000_000_000 + loanNumber).
        // For the first loan, loanNumber is 1.
        LOANS_CONTRACT.liquidateExpiredLoansFrom(revnetId, 1, 1);

        // After liquidation, loan storage should be cleared.
        REVLoan memory loanAfter = LOANS_CONTRACT.loanOf(loanId);
        assertEq(loanAfter.amount, 0, "Loan amount should be 0 after liquidation");
        assertEq(loanAfter.collateral, 0, "Loan collateral should be 0 after liquidation");
        assertEq(loanAfter.createdAt, 0, "Loan createdAt should be 0 after liquidation");
    }

    /// @notice Partial repay (return some but not all collateral) clears old loan storage
    /// and creates a replacement loan. Exercises the `else` branch in `_repayLoan`.
    function test_partialRepay_clearsOldLoanStorage() public {
        uint256 revnetId = _deploySingleStageRevnet();

        // Pay ETH into revnet to get tokens.
        vm.prank(USER);
        uint256 tokens =
            jbMultiTerminal().pay{value: 10 ether}(revnetId, JBConstants.NATIVE_TOKEN, 10 ether, USER, 0, "", "");

        uint256 loanable = LOANS_CONTRACT.borrowableAmountFrom(
            revnetId, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        vm.assume(loanable > 0);

        // Mock permission for BURN (permission ID 10).
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, revnetId, 10, true, true)),
            abi.encode(true)
        );

        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        uint256 minPrepaid = LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT();

        vm.prank(USER);
        (uint256 loanId,) = LOANS_CONTRACT.borrowFrom(revnetId, source, loanable, tokens, payable(USER), minPrepaid);

        REVLoan memory loanBefore = LOANS_CONTRACT.loanOf(loanId);
        assertGt(loanBefore.collateral, 1, "Need >1 collateral for partial return");

        // Partial repay: return HALF the collateral (triggers else branch in _repayLoan).
        uint256 halfCollateral = loanBefore.collateral / 2;
        JBSingleAllowance memory allowance;

        // Send loan.amount as maxRepay — more than enough for partial repay.
        vm.prank(USER);
        (uint256 newLoanId, REVLoan memory newLoan) = LOANS_CONTRACT.repayLoan{value: loanBefore.amount}(
            loanId, loanBefore.amount, halfCollateral, payable(USER), allowance
        );

        // Old loan storage should be cleared (the delete we're testing).
        REVLoan memory oldLoan = LOANS_CONTRACT.loanOf(loanId);
        assertEq(oldLoan.amount, 0, "Old loan amount should be 0 after partial repay");
        assertEq(oldLoan.collateral, 0, "Old loan collateral should be 0 after partial repay");
        assertEq(oldLoan.createdAt, 0, "Old loan createdAt should be 0 after partial repay");

        // New replacement loan should exist with remaining values.
        assertGt(newLoan.amount, 0, "New loan should have amount");
        assertGt(newLoan.collateral, 0, "New loan should have collateral");
        assertLt(newLoan.amount, loanBefore.amount, "New loan amount should be less than original");

        // Verify via storage read too (not just return value).
        REVLoan memory newLoanFromStorage = LOANS_CONTRACT.loanOf(newLoanId);
        assertEq(newLoanFromStorage.amount, newLoan.amount, "Storage should match return value");
    }

    /// @notice Repaying with excess ETH correctly refunds the difference.
    /// This tests the sourceToken caching fix — before the fix, `loan.source.token` was read
    /// after `_repayLoan` deleted the storage, yielding `address(0)` and reverting.
    function test_repayLoan_refundsExcessWithCorrectToken() public {
        uint256 revnetId = _deploySingleStageRevnet();

        // Pay ETH into revnet to get tokens.
        vm.prank(USER);
        uint256 tokens =
            jbMultiTerminal().pay{value: 10 ether}(revnetId, JBConstants.NATIVE_TOKEN, 10 ether, USER, 0, "", "");

        uint256 loanable = LOANS_CONTRACT.borrowableAmountFrom(
            revnetId, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        vm.assume(loanable > 0);

        // Mock permission for BURN (permission ID 10).
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, revnetId, 10, true, true)),
            abi.encode(true)
        );

        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        uint256 minPrepaid = LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT();

        vm.prank(USER);
        (uint256 loanId,) = LOANS_CONTRACT.borrowFrom(revnetId, source, loanable, tokens, payable(USER), minPrepaid);

        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);

        // Partial repay returning half collateral. Send 2x the loan amount — guaranteed excess.
        uint256 halfCollateral = loan.collateral / 2;
        uint256 excessivePayment = loan.amount * 2;

        uint256 balBefore = USER.balance;
        JBSingleAllowance memory allowance;

        vm.prank(USER);
        LOANS_CONTRACT.repayLoan{value: excessivePayment}(
            loanId, excessivePayment, halfCollateral, payable(USER), allowance
        );

        uint256 balAfter = USER.balance;

        // User sent `excessivePayment` but should get excess back.
        // Net cost = repayBorrowAmount (includes fee). Must be less than loan.amount.
        uint256 netCost = balBefore - balAfter;
        assertLt(netCost, excessivePayment, "User should have been refunded excess ETH");
        assertGt(netCost, 0, "User should have paid something");
    }

    /// @notice Reallocation clears old loan storage after creating replacement.
    /// Exercises the `delete _loanOf[loanId]` in `_reallocateCollateralFromLoan`.
    function test_reallocateCollateral_clearsOldLoanStorage() public {
        uint256 revnetId = _deploySingleStageRevnet();

        // Pay ETH into revnet to get tokens.
        vm.prank(USER);
        uint256 tokens =
            jbMultiTerminal().pay{value: 10 ether}(revnetId, JBConstants.NATIVE_TOKEN, 10 ether, USER, 0, "", "");

        uint256 loanable = LOANS_CONTRACT.borrowableAmountFrom(
            revnetId, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        vm.assume(loanable > 0);

        // Mock permission for BURN (permission ID 10).
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, revnetId, 10, true, true)),
            abi.encode(true)
        );

        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        uint256 minPrepaid = LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT();

        // Borrow the full max against all tokens.
        vm.prank(USER);
        (uint256 loanId,) = LOANS_CONTRACT.borrowFrom(revnetId, source, loanable, tokens, payable(USER), minPrepaid);

        REVLoan memory loanBefore = LOANS_CONTRACT.loanOf(loanId);
        assertGt(loanBefore.collateral, 0, "Loan should have collateral");

        // Increase surplus WITHOUT minting new tokens — makes existing collateral worth more.
        // This allows reallocating collateral since borrowable(reduced collateral) > loan.amount.
        address DONOR = makeAddr("donor");
        vm.deal(DONOR, 100 ether);
        vm.prank(DONOR);
        jbMultiTerminal().addToBalanceOf{value: 50 ether}(
            revnetId, JBConstants.NATIVE_TOKEN, 50 ether, false, "", ""
        );

        // Transfer a small amount of collateral (10%) to a new loan.
        uint256 collateralToTransfer = loanBefore.collateral / 10;
        assertGt(collateralToTransfer, 0, "Must transfer some collateral");

        vm.prank(USER);
        (uint256 reallocatedLoanId, uint256 newLoanId, REVLoan memory reallocatedLoan,) = LOANS_CONTRACT
            .reallocateCollateralFromLoan(
            loanId, collateralToTransfer, source, 0, 0, payable(USER), minPrepaid
        );

        // Old loan storage should be cleared.
        REVLoan memory oldLoan = LOANS_CONTRACT.loanOf(loanId);
        assertEq(oldLoan.amount, 0, "Old loan amount should be 0 after reallocation");
        assertEq(oldLoan.collateral, 0, "Old loan collateral should be 0 after reallocation");
        assertEq(oldLoan.createdAt, 0, "Old loan createdAt should be 0 after reallocation");

        // Reallocated loan should have reduced collateral but same amount.
        assertEq(reallocatedLoan.amount, loanBefore.amount, "Reallocated loan should keep original amount");
        assertLt(
            reallocatedLoan.collateral, loanBefore.collateral, "Reallocated loan should have less collateral"
        );

        // New loan should exist.
        assertTrue(newLoanId != loanId, "New loan should have different ID");
        assertTrue(newLoanId != reallocatedLoanId, "New loan should differ from reallocated loan");
    }
}
