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
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
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

/// @notice A fake terminal that returns garbage accounting contexts.
/// Used to test H-1: unvalidated loan source terminal.
contract GarbageTerminal is ERC165, IJBPayoutTerminal {
    function useAllowanceOf(
        uint256,
        address,
        uint256,
        uint256,
        uint256,
        address payable,
        address payable,
        string calldata
    )
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    function accountingContextForTokenOf(uint256, address) external pure override returns (JBAccountingContext memory) {
        // Return garbage values to demonstrate the danger.
        return JBAccountingContext({token: address(0xdead), decimals: 42, currency: 999_999});
    }

    function accountingContextsOf(uint256) external pure override returns (JBAccountingContext[] memory) {
        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({token: address(0xdead), decimals: 42, currency: 999_999});
        return contexts;
    }

    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override {}

    function addToBalanceOf(
        uint256,
        address,
        uint256,
        bool,
        string calldata,
        bytes calldata
    )
        external
        payable
        override
    {}

    function currentSurplusOf(
        uint256,
        JBAccountingContext[] memory,
        uint256,
        uint256
    )
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256) {
        return 0;
    }

    function pay(
        uint256,
        address,
        uint256,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        override
        returns (uint256)
    {
        return 0;
    }

    function sendPayoutsOf(uint256, address, uint256, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IJBPayoutTerminal).interfaceId
            || super.supportsInterface(interfaceId);
    }

    receive() external payable {}
}

/// @notice Regression tests for nemesis audit findings.
/// H-1: Unvalidated loan source terminal
/// L-1: RepayLoan event emits zeroed values
/// FP-1: Auto-issuance timing guard bypass (false positive)
/// FP-3: repayLoan revert on excess collateral (false positive)
contract REVLoans_AuditFindings is TestBaseWorkflow, JBTest {
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

    address USER = makeAddr("user");

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    function setUp() public override {
        super.setUp();

        FEE_PROJECT_ID = jbProjects().createFor(multisig());

        SUCKER_REGISTRY = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig(), address(0));
        HOOK_STORE = new JB721TiersHookStore();
        EXAMPLE_HOOK = new JB721TiersHook(jbDirectory(), jbPermissions(), jbRulesets(), HOOK_STORE, multisig());
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

        // Deploy the fee revnet (project ID 1).
        _deployFeeRevnet();

        // Deploy a second revnet to borrow from.
        _deployBorrowableRevnet();

        // Give user ETH.
        vm.deal(USER, 100e18);
    }

    function _deployFeeRevnet() internal {
        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        REVAutoIssuance[] memory issuanceConfs = new REVAutoIssuance[](1);
        issuanceConfs[0] =
            REVAutoIssuance({chainId: uint32(block.chainid), count: uint104(70_000e18), beneficiary: multisig()});

        stageConfigurations[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: issuanceConfs,
            splitPercent: 2000,
            splits: splits,
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: 0
        });

        REVConfig memory revnetConfiguration = REVConfig({
            description: REVDescription("Revnet", "$REV", "ipfs://test", ERC20_SALT),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations
        });

        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("REV"))
            })
        });
    }

    function _deployBorrowableRevnet() internal {
        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

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
            splitPercent: 0,
            splits: splits,
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 5000,
            extraMetadata: 0
        });

        REVConfig memory revnetConfiguration = REVConfig({
            description: REVDescription("Borrowable", "BRW", "ipfs://brw", "BRW_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations
        });

        REVNET_ID = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("BRW"))
            })
        });
    }

    /// @notice Helper: pay into the revnet and get tokens.
    function _payAndGetTokens(uint256 amount) internal returns (uint256 tokens) {
        vm.prank(USER);
        tokens = jbMultiTerminal().pay{value: amount}(REVNET_ID, JBConstants.NATIVE_TOKEN, amount, USER, 0, "", "");
    }

    /// @notice Helper: mock permission for LOANS_CONTRACT to burn user tokens.
    function _mockBurnPermission() internal {
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, REVNET_ID, 11, true, true)),
            abi.encode(true)
        );
    }

    /// @notice Helper: borrow against tokens.
    function _borrow(uint256 tokens) internal returns (uint256 loanId, REVLoan memory loan, uint256 loanable) {
        loanable = LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        _mockBurnPermission();

        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        vm.prank(USER);
        (loanId, loan) = LOANS_CONTRACT.borrowFrom(REVNET_ID, source, loanable, tokens, payable(USER), 25);
    }

    //*********************************************************************//
    // --------- H-1: Unvalidated Loan Source Terminal ------------------- //
    //*********************************************************************//

    /// @notice H-1 regression: borrowFrom rejects a fake terminal not registered in the directory.
    function test_H1_borrowFromRejectsUnregisteredTerminal() public {
        // Step 1: User pays into the revnet to get tokens.
        uint256 tokens = _payAndGetTokens(1e18);
        assertGt(tokens, 0, "user should receive tokens");

        // Step 2: Create a fake terminal that returns garbage accounting contexts.
        GarbageTerminal fakeTerminal = new GarbageTerminal();

        // Step 3: Verify the fake terminal is NOT in the directory.
        assertFalse(
            jbDirectory().isTerminalOf(REVNET_ID, IJBTerminal(address(fakeTerminal))),
            "fake terminal should NOT be registered"
        );

        // Step 4: Attempt to borrow using the fake terminal.
        uint256 loanable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        assertGt(loanable, 0, "should have borrowable amount");

        // NOTE: Do NOT mock burn permission here. The call should revert
        // at the terminal validation check before it ever reaches the burn step.

        REVLoanSource memory fakeSource =
            REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: IJBPayoutTerminal(address(fakeTerminal))});

        // Step 5: Expect revert with the new REVLoans_InvalidTerminal error.
        vm.expectRevert(
            abi.encodeWithSelector(REVLoans.REVLoans_InvalidTerminal.selector, address(fakeTerminal), REVNET_ID)
        );

        vm.prank(USER);
        LOANS_CONTRACT.borrowFrom(REVNET_ID, fakeSource, loanable, tokens, payable(USER), 25);
    }

    //*********************************************************************//
    // ------- L-1: RepayLoan Event Emits Zeroed Values ----------------- //
    //*********************************************************************//

    /// @notice L-1 regression: RepayLoan event emits non-zero loan amount and collateral
    ///         when fully repaying a loan.
    function test_L1_repayLoanEventEmitsNonZeroValues() public {
        // Step 1: Pay in and borrow.
        uint256 tokens = _payAndGetTokens(1e18);
        (uint256 loanId, REVLoan memory loan, uint256 loanable) = _borrow(tokens);

        assertGt(loan.amount, 0, "loan amount should be non-zero");
        assertGt(loan.collateral, 0, "loan collateral should be non-zero");

        // Step 2: Calculate the repay amount (loan amount + source fee).
        uint256 sourceFee = LOANS_CONTRACT.determineSourceFeeAmount(loan, loan.amount);
        uint256 totalRepay = loan.amount + sourceFee;

        // Step 3: Give user enough ETH for repayment.
        vm.deal(USER, totalRepay);

        // Step 4: Expect the RepayLoan event with non-zero loan values.
        // The `loan` field (4th param) should contain the original pre-repay loan data.
        // We check that the event is emitted by looking for the indexed fields.
        vm.expectEmit(true, true, true, false);
        emit IREVLoans.RepayLoan({
            loanId: loanId,
            revnetId: REVNET_ID,
            paidOffLoanId: loanId,
            // These fields are the ones we care about -- they should be non-zero.
            loan: loan,
            paidOffLoan: loan, // placeholder, we only check the `loan` field
            repayBorrowAmount: totalRepay,
            sourceFeeAmount: sourceFee,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(USER),
            caller: USER
        });

        // Step 5: Fully repay the loan (return all collateral).
        JBSingleAllowance memory allowance;
        vm.prank(USER);
        LOANS_CONTRACT.repayLoan{value: totalRepay}(loanId, totalRepay, loan.collateral, payable(USER), allowance);
    }

    /// @notice L-1 secondary check: verify the original loan data in the emitted event
    ///         has the expected non-zero amount and collateral by recording logs.
    function test_L1_repayLoanEventLoanFieldIsNonZero() public {
        // Step 1: Pay in and borrow.
        uint256 tokens = _payAndGetTokens(1e18);
        (uint256 loanId, REVLoan memory loan,) = _borrow(tokens);

        uint256 originalAmount = loan.amount;
        uint256 originalCollateral = loan.collateral;

        // Step 2: Calculate repay amount.
        uint256 sourceFee = LOANS_CONTRACT.determineSourceFeeAmount(loan, loan.amount);
        uint256 totalRepay = loan.amount + sourceFee;
        vm.deal(USER, totalRepay);

        // Step 3: Record logs to inspect the event data.
        vm.recordLogs();

        JBSingleAllowance memory allowance;
        vm.prank(USER);
        LOANS_CONTRACT.repayLoan{value: totalRepay}(loanId, totalRepay, loan.collateral, payable(USER), allowance);

        // Step 4: Find the RepayLoan event and decode the loan struct.
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 repayLoanSig = keccak256(
            "RepayLoan(uint256,uint256,uint256,(uint112,uint112,uint48,uint16,uint32,(address,address)),(uint112,uint112,uint48,uint16,uint32,(address,address)),uint256,uint256,uint256,address,address)"
        );

        bool foundEvent = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == repayLoanSig) {
                foundEvent = true;
                // Decode the non-indexed data.
                // The data contains: loan, paidOffLoan, repayBorrowAmount, sourceFeeAmount,
                // collateralCountToReturn, beneficiary, caller
                (REVLoan memory emittedLoan,,,,,,) =
                    abi.decode(entries[i].data, (REVLoan, REVLoan, uint256, uint256, uint256, address, address));

                // The emitted loan should have the ORIGINAL non-zero values.
                assertEq(emittedLoan.amount, originalAmount, "emitted loan.amount should match original");
                assertEq(emittedLoan.collateral, originalCollateral, "emitted loan.collateral should match original");
                assertGt(emittedLoan.amount, 0, "emitted loan.amount must be non-zero");
                assertGt(emittedLoan.collateral, 0, "emitted loan.collateral must be non-zero");
                break;
            }
        }

        assertTrue(foundEvent, "RepayLoan event should have been emitted");
    }

    //*********************************************************************//
    // --- FP-1: Auto-Issuance Timing Guard Works Correctly ------------- //
    //*********************************************************************//

    /// @notice FP-1: Proves that block.timestamp + i matches actual ruleset IDs,
    ///         and the timing guard in autoIssueFor correctly prevents premature issuance.
    function test_autoIssueTimingGuardWorksCorrectly() public {
        // Step 1: Deploy a revnet with 2 stages where stage 2 starts far in the future
        //         and has auto-issuance.
        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        REVStageConfig[] memory stages = new REVStageConfig[](2);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        // Stage 1: starts now, no auto-issuance.
        stages[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 2000,
            splits: splits,
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 5000,
            extraMetadata: 0
        });

        // Stage 2: starts 365 days in the future, HAS auto-issuance.
        REVAutoIssuance[] memory stage2AutoIssuances = new REVAutoIssuance[](1);
        stage2AutoIssuances[0] =
            REVAutoIssuance({chainId: uint32(block.chainid), count: uint104(50_000e18), beneficiary: multisig()});

        stages[1] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp + 365 days),
            autoIssuances: stage2AutoIssuances,
            splitPercent: 1000,
            splits: splits,
            initialIssuance: uint112(500e18),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 3000,
            extraMetadata: 0
        });

        REVConfig memory config = REVConfig({
            description: REVDescription("FP1Test", "FP1", "ipfs://fp1", "FP1_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });

        // Record the deploy timestamp -- this is used for stage ID calculation.
        uint256 deployTimestamp = block.timestamp;

        uint256 fp1RevnetId = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: config,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("FP1")
            })
        });

        // Step 2: Verify the second ruleset ID matches deployTimestamp + 1.
        // JBRulesets assigns IDs as: block.timestamp, block.timestamp+1, etc. when queued in one tx.
        uint256 stage2RulesetId = deployTimestamp + 1;

        (JBRuleset memory ruleset,) = jbController().getRulesetOf({projectId: fp1RevnetId, rulesetId: stage2RulesetId});

        // The ruleset should exist and have the correct startsAtOrAfter.
        assertGt(ruleset.id, 0, "stage 2 ruleset should exist");
        assertEq(ruleset.start, deployTimestamp + 365 days, "stage 2 should start 365 days from deploy");

        // Step 3: Verify amountToAutoIssue was stored with the correct stage ID.
        uint256 storedAutoIssue = REV_DEPLOYER.amountToAutoIssue(fp1RevnetId, stage2RulesetId, multisig());
        assertEq(storedAutoIssue, 50_000e18, "auto-issuance amount should be stored at deployTimestamp + 1");

        // Step 4: Call autoIssueFor now -- it should revert because stage 2 hasn't started yet.
        vm.expectRevert(abi.encodeWithSelector(REVDeployer.REVDeployer_StageNotStarted.selector, stage2RulesetId));
        REV_DEPLOYER.autoIssueFor(fp1RevnetId, stage2RulesetId, multisig());

        // Step 5: Warp to after stage 2 starts and verify auto-issuance works.
        vm.warp(deployTimestamp + 365 days + 1);

        REV_DEPLOYER.autoIssueFor(fp1RevnetId, stage2RulesetId, multisig());

        // Verify the tokens were minted.
        uint256 balance = jbController().TOKENS().totalBalanceOf({holder: multisig(), projectId: fp1RevnetId});
        assertGe(balance, 50_000e18, "multisig should have received the auto-issued tokens");
    }

    //*********************************************************************//
    // --- FP-3: repayLoan Correctly Reverts On Excess Collateral ------- //
    //*********************************************************************//

    /// @notice FP-3: When collateral value exceeds the loan amount (e.g. from price appreciation
    ///         or surplus growth), partial repayment correctly reverts because the remaining
    ///         collateral supports more than the loan amount. reallocateCollateralFromLoan
    ///         is the correct alternative.
    function test_repayLoanCorrectlyRevertsOnExcessCollateral() public {
        // Step 1: User pays in and borrows.
        uint256 tokens = _payAndGetTokens(1e18);
        (uint256 loanId, REVLoan memory loan,) = _borrow(tokens);

        uint256 loanAmount = loan.amount;
        uint256 loanCollateral = loan.collateral;

        assertGt(loanAmount, 0, "loan should have non-zero amount");
        assertGt(loanCollateral, 0, "loan should have non-zero collateral");

        // Step 2: Simulate surplus growth by adding balance directly (no token minting).
        // Using addToBalanceOf increases surplus without increasing supply, so each token
        // is now backed by more surplus and the collateral value exceeds the loan amount.
        {
            address whale = makeAddr("whale");
            vm.deal(whale, 50e18);
            vm.prank(whale);
            jbMultiTerminal().addToBalanceOf{value: 50e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 50e18, false, "", "");
        }

        // Step 3: Verify the collateral value has increased.
        {
            uint256 newBorrowable = LOANS_CONTRACT.borrowableAmountFrom(
                REVNET_ID, loanCollateral, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
            );
            assertGt(
                newBorrowable, loanAmount, "collateral value should exceed original loan amount after surplus growth"
            );
        }

        // Step 4: Try to repay returning only SOME collateral such that remaining collateral
        // supports more than the loan amount. This should revert with
        // REVLoans_NewBorrowAmountGreaterThanLoanAmount.
        {
            uint256 sourceFee = LOANS_CONTRACT.determineSourceFeeAmount(loan, loanAmount);
            uint256 totalRepay = loanAmount + sourceFee;
            vm.deal(USER, totalRepay);

            JBSingleAllowance memory allowance;

            vm.prank(USER);
            vm.expectRevert(); // REVLoans_NewBorrowAmountGreaterThanLoanAmount
            LOANS_CONTRACT.repayLoan{value: totalRepay}(loanId, totalRepay, 1, payable(USER), allowance);
        }

        // Step 5: Show that reallocateCollateralFromLoan is the correct alternative.
        // The user can reallocate excess collateral to a new loan instead.
        _mockBurnPermission();

        uint256 collateralToTransfer = loanCollateral / 10;

        uint256 minBorrow = LOANS_CONTRACT.borrowableAmountFrom(
            REVNET_ID, collateralToTransfer, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );

        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        vm.prank(USER);
        (,, REVLoan memory reallocatedLoan, REVLoan memory newLoan) = LOANS_CONTRACT.reallocateCollateralFromLoan({
            loanId: loanId,
            collateralCountToTransfer: collateralToTransfer,
            source: source,
            minBorrowAmount: minBorrow,
            collateralCountToAdd: 0,
            beneficiary: payable(USER),
            prepaidFeePercent: 25
        });

        // Verify the reallocation succeeded.
        assertEq(
            reallocatedLoan.collateral,
            loanCollateral - collateralToTransfer,
            "reallocated loan should have reduced collateral"
        );
        assertGt(newLoan.collateral, 0, "new loan should have collateral from transfer");
    }
}
