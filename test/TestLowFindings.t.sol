// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
// import /* {*} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
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
import {REVLoan} from "../src/structs/REVLoan.sol";
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
import {REVEmpty721Config} from "./helpers/REVEmpty721Config.sol";

struct FeeProjectConfig {
    REVConfig configuration;
    JBTerminalConfig[] terminalConfigurations;
    REVSuckerDeploymentConfig suckerDeploymentConfiguration;
}

contract TestLowFindings is TestBaseWorkflow {
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 ERC20_SALT = "REV_TOKEN";

    // forge-lint: disable-next-line(mixed-case-variable)
    REVDeployer REV_DEPLOYER;
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
    address USER = makeAddr("user");

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    function getFeeProjectConfig() internal view returns (FeeProjectConfig memory) {
        uint8 decimals = 18;
        uint256 decimalMultiplier = 10 ** decimals;

        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](2);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
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
            // forge-lint: disable-next-line(unsafe-typecast)
            initialIssuance: uint112(1000 * decimalMultiplier),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: 0
        });

        REVConfig memory revnetConfiguration = REVConfig({
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription("Revnet", "$REV", "ipfs://test", ERC20_SALT),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations
        });

        return FeeProjectConfig({
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("REV"))
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
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
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
            // forge-lint: disable-next-line(unsafe-typecast)
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
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription("TwoStage", "$TWO", "ipfs://test", "TWO_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations
        });

        (revnetId,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("TWO"))
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    /// @notice Deploy a single-stage revnet with loans enabled.
    function _deploySingleStageRevnet() internal returns (uint256 revnetId) {
        uint8 decimals = 18;
        uint256 decimalMultiplier = 10 ** decimals;

        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](2);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
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
            // forge-lint: disable-next-line(unsafe-typecast)
            initialIssuance: uint112(1000 * decimalMultiplier),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 0, // 0% tax for simplicity
            extraMetadata: 0
        });

        REVLoanSource[] memory loanSources = new REVLoanSource[](1);
        loanSources[0] = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        REVConfig memory revnetConfiguration = REVConfig({
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription("Single", "$SGL", "ipfs://test", "SGL_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations
        });

        (revnetId,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("SGL"))
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

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
        MOCK_BUYBACK = new MockBuybackDataHook();
        TOKEN = new MockERC20("1/2 ETH", "1/2");

        MockPriceFeed priceFeed = new MockPriceFeed(1e21, 6);
        vm.prank(multisig());
        jbPrices()
            .addPriceFeedFor(0, uint32(uint160(address(TOKEN))), uint32(uint160(JBConstants.NATIVE_TOKEN)), priceFeed);

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

        // Deploy fee project.
        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);

        FeeProjectConfig memory feeProjectConfig = getFeeProjectConfig();
        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeProjectConfig.configuration,
            terminalConfigurations: feeProjectConfig.terminalConfigurations,
            suckerDeploymentConfiguration: feeProjectConfig.suckerDeploymentConfiguration,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
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
        uint256 borrowableStage0 =
            LOANS_CONTRACT.borrowableAmountFrom(revnetId, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        assertGt(borrowableStage0, 0, "Should have borrowable amount in stage 0");

        // Warp to stage 1 (60% tax).
        vm.warp(block.timestamp + 30 days + 1);

        // Check borrowable amount in stage 1 — should be lower due to higher tax.
        uint256 borrowableStage1 =
            LOANS_CONTRACT.borrowableAmountFrom(revnetId, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        assertLt(borrowableStage1, borrowableStage0, "Borrowable amount should decrease when cashOutTaxRate increases");
    }

    /// @notice After full repayment, loan data is deleted (storage cleared).
    function test_loanDataDeletedAfterRepay() public {
        uint256 revnetId = _deploySingleStageRevnet();

        // Pay ETH into revnet to get tokens.
        vm.prank(USER);
        uint256 tokens =
            jbMultiTerminal().pay{value: 10 ether}(revnetId, JBConstants.NATIVE_TOKEN, 10 ether, USER, 0, "", "");

        uint256 loanable =
            LOANS_CONTRACT.borrowableAmountFrom(revnetId, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        // Skip if nothing borrowable.
        vm.assume(loanable > 0);

        // Mock permission for BURN (permission ID 10).
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, revnetId, 11, true, true)),
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

        uint256 loanable =
            LOANS_CONTRACT.borrowableAmountFrom(revnetId, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        // Skip if nothing borrowable.
        vm.assume(loanable > 0);

        // Mock permission for BURN (permission ID 10).
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, revnetId, 11, true, true)),
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

        uint256 loanable =
            LOANS_CONTRACT.borrowableAmountFrom(revnetId, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        vm.assume(loanable > 0);

        // Mock permission for BURN (permission ID 10).
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, revnetId, 11, true, true)),
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

        uint256 loanable =
            LOANS_CONTRACT.borrowableAmountFrom(revnetId, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        vm.assume(loanable > 0);

        // Mock permission for BURN (permission ID 10).
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, revnetId, 11, true, true)),
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

        uint256 loanable =
            LOANS_CONTRACT.borrowableAmountFrom(revnetId, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        vm.assume(loanable > 0);

        // Mock permission for BURN (permission ID 10).
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, revnetId, 11, true, true)),
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
        // forge-lint: disable-next-line(mixed-case-variable)
        address DONOR = makeAddr("donor");
        vm.deal(DONOR, 100 ether);
        vm.prank(DONOR);
        jbMultiTerminal().addToBalanceOf{value: 50 ether}(revnetId, JBConstants.NATIVE_TOKEN, 50 ether, false, "", "");

        // Transfer a small amount of collateral (10%) to a new loan.
        uint256 collateralToTransfer = loanBefore.collateral / 10;
        assertGt(collateralToTransfer, 0, "Must transfer some collateral");

        vm.prank(USER);
        (uint256 reallocatedLoanId, uint256 newLoanId, REVLoan memory reallocatedLoan,) = LOANS_CONTRACT.reallocateCollateralFromLoan(
            loanId, collateralToTransfer, source, 0, 0, payable(USER), minPrepaid
        );

        // Old loan storage should be cleared.
        REVLoan memory oldLoan = LOANS_CONTRACT.loanOf(loanId);
        assertEq(oldLoan.amount, 0, "Old loan amount should be 0 after reallocation");
        assertEq(oldLoan.collateral, 0, "Old loan collateral should be 0 after reallocation");
        assertEq(oldLoan.createdAt, 0, "Old loan createdAt should be 0 after reallocation");

        // Reallocated loan should have reduced collateral but same amount.
        assertEq(reallocatedLoan.amount, loanBefore.amount, "Reallocated loan should keep original amount");
        assertLt(reallocatedLoan.collateral, loanBefore.collateral, "Reallocated loan should have less collateral");

        // New loan should exist.
        assertTrue(newLoanId != loanId, "New loan should have different ID");
        assertTrue(newLoanId != reallocatedLoanId, "New loan should differ from reallocated loan");
    }

    /// @notice Borrowing with a collateral count so small that the bonding curve rounds the borrow amount to zero
    /// should revert with `REVLoans_ZeroBorrowAmount`.
    function test_borrowFrom_revertsOnZeroBorrowAmount() public {
        uint256 revnetId = _deploySingleStageRevnet();

        // Pay ETH into revnet to create surplus and get tokens.
        vm.prank(USER);
        uint256 tokens =
            jbMultiTerminal().pay{value: 10 ether}(revnetId, JBConstants.NATIVE_TOKEN, 10 ether, USER, 0, "", "");
        assertGt(tokens, 0, "Should have received tokens");

        // Confirm that 1 wei of collateral produces a zero borrowable amount.
        // With surplus ~10e18 and totalSupply ~10_000e18, mulDiv(10e18, 1, 10_000e18) rounds to 0.
        uint256 borrowable =
            LOANS_CONTRACT.borrowableAmountFrom(revnetId, 1, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        assertEq(borrowable, 0, "Borrowable amount for 1 wei of collateral should be 0");

        // Mock the BURN permission (permission ID 11) for the loans contract.
        // Use vm.mockCall only (not mockExpect which also adds vm.expectCall) because
        // borrowFrom reverts with REVLoans_ZeroBorrowAmount before the permission check is reached.
        vm.mockCall(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, revnetId, 11, true, true)),
            abi.encode(true)
        );

        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        uint256 minPrepaid = LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT();

        // Attempt to borrow with 1 wei of collateral -- bonding curve returns 0, should revert.
        vm.prank(USER);
        vm.expectRevert(REVLoans.REVLoans_ZeroBorrowAmount.selector);
        LOANS_CONTRACT.borrowFrom(revnetId, source, 0, 1, payable(USER), minPrepaid);
    }
}
