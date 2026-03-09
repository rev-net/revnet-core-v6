// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import /* {*} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import /* {*} from */ "./../../src/REVDeployer.sol";
import "@croptop/core-v6/src/CTPublisher.sol";
import {MockBuybackDataHook} from "./../mock/MockBuybackDataHook.sol";
import "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
import "@bananapus/721-hook-v6/script/helpers/Hook721DeploymentLib.sol";
import "@bananapus/suckers-v6/script/helpers/SuckerDeploymentLib.sol";
import "@croptop/core-v6/script/helpers/CroptopDeploymentLib.sol";
import "@bananapus/router-terminal-v6/script/helpers/RouterTerminalDeploymentLib.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";
import {MockPriceFeed} from "@bananapus/core-v6/test/mock/MockPriceFeed.sol";
import {MockERC20} from "@bananapus/core-v6/test/mock/MockERC20.sol";
import {REVLoans} from "../../src/REVLoans.sol";
import {REVLoan} from "../../src/structs/REVLoan.sol";
import {REVStageConfig, REVAutoIssuance} from "../../src/structs/REVStageConfig.sol";
import {REVLoanSource} from "../../src/structs/REVLoanSource.sol";
import {REVDescription} from "../../src/structs/REVDescription.sol";
import {IREVLoans} from "../../src/interfaces/IREVLoans.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";

/// @notice totalLoansBorrowedFor is a cumulative counter, not an active loan count.
/// @dev The rename from numberOfLoansFor to totalLoansBorrowedFor clarifies that the counter only increments
/// and never decrements. Repaying or liquidating a loan does NOT reduce the counter. This test verifies that
/// the counter remains at its high-water mark after loans are fully repaid and after loans are liquidated.
contract TestI20_CumulativeLoanCounter is TestBaseWorkflow, JBTest {
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";

    REVDeployer REV_DEPLOYER;
    JB721TiersHook EXAMPLE_HOOK;
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    IJB721TiersHookStore HOOK_STORE;
    IJBAddressRegistry ADDRESS_REGISTRY;
    REVLoans LOANS_CONTRACT;
    IJBSuckerRegistry SUCKER_REGISTRY;
    CTPublisher PUBLISHER;
    MockBuybackDataHook MOCK_BUYBACK;

    uint256 FEE_PROJECT_ID;
    uint256 REVNET_ID;

    address USER1 = makeAddr("user1");
    address USER2 = makeAddr("user2");
    address USER3 = makeAddr("user3");

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
        MockPriceFeed priceFeed = new MockPriceFeed(1e18, 18);
        vm.prank(multisig());
        jbPrices()
            .addPriceFeedFor(
                0, uint32(uint160(JBConstants.NATIVE_TOKEN)), uint32(uint160(JBConstants.NATIVE_TOKEN)), priceFeed
            );
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
        _deployFeeProject();
        _deployRevnet();
        vm.deal(USER1, 100e18);
        vm.deal(USER2, 100e18);
        vm.deal(USER3, 100e18);
    }

    function _deployFeeProject() internal {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});
        REVStageConfig[] memory stages = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;
        REVAutoIssuance[] memory ai = new REVAutoIssuance[](1);
        ai[0] = REVAutoIssuance({chainId: uint32(block.chainid), count: uint104(70_000e18), beneficiary: multisig()});
        stages[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: ai,
            splitPercent: 2000,
            splits: splits,
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: 0
        });
        REVConfig memory cfg = REVConfig({
            description: REVDescription("Revnet", "$REV", "ipfs://test", "REV_TOKEN"),
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
            })
        });
    }

    function _deployRevnet() internal {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});
        REVStageConfig[] memory stages = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;
        REVAutoIssuance[] memory ai = new REVAutoIssuance[](1);
        ai[0] = REVAutoIssuance({chainId: uint32(block.chainid), count: uint104(70_000e18), beneficiary: multisig()});
        stages[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: ai,
            splitPercent: 2000,
            splits: splits,
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: 0
        });
        REVConfig memory cfg = REVConfig({
            description: REVDescription("NANA", "$NANA", "ipfs://test2", "NANA_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });
        REVNET_ID = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: cfg,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("NANA")
            })
        });
    }

    function _setupLoan(address user, uint256 ethAmount) internal returns (uint256 loanId, uint256 tokenCount) {
        vm.prank(user);
        tokenCount =
            jbMultiTerminal().pay{value: ethAmount}(REVNET_ID, JBConstants.NATIVE_TOKEN, ethAmount, user, 0, "", "");
        uint256 borrowAmount =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokenCount, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        require(borrowAmount > 0, "Borrow amount should be > 0");
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), user, REVNET_ID, 11, true, true)),
            abi.encode(true)
        );
        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        vm.prank(user);
        (loanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(user), 25);
    }

    /// @notice Verifies totalLoansBorrowedFor never decrements after loan repayment.
    /// @dev Creates 3 loans, fully repays 2, then verifies the counter stays at 3 (not 1).
    /// This confirms that the rename correctly reflects cumulative semantics.
    function test_I20_counterNeverDecrementsAfterRepayment() public {
        // Counter starts at 0
        assertEq(LOANS_CONTRACT.totalLoansBorrowedFor(REVNET_ID), 0, "Counter should start at 0");

        // Create 3 loans
        (uint256 loanId1,) = _setupLoan(USER1, 3e18);
        (uint256 loanId2,) = _setupLoan(USER2, 3e18);
        (uint256 loanId3,) = _setupLoan(USER3, 3e18);

        // Counter should be 3
        assertEq(LOANS_CONTRACT.totalLoansBorrowedFor(REVNET_ID), 3, "Counter should be 3 after 3 loans");

        // Fully repay loan 1
        REVLoan memory loan1 = LOANS_CONTRACT.loanOf(loanId1);
        JBSingleAllowance memory allowance;
        vm.prank(USER1);
        LOANS_CONTRACT.repayLoan{value: loan1.amount}(
            loanId1, loan1.amount, loan1.collateral, payable(USER1), allowance
        );

        // Counter should still be 3 (NOT 2) -- repayment does not decrement
        assertEq(
            LOANS_CONTRACT.totalLoansBorrowedFor(REVNET_ID),
            3,
            "Counter should remain 3 after repaying loan 1 -- cumulative, never decrements"
        );

        // Fully repay loan 2
        REVLoan memory loan2 = LOANS_CONTRACT.loanOf(loanId2);
        vm.prank(USER2);
        LOANS_CONTRACT.repayLoan{value: loan2.amount}(
            loanId2, loan2.amount, loan2.collateral, payable(USER2), allowance
        );

        // Counter should still be 3 (NOT 1)
        assertEq(
            LOANS_CONTRACT.totalLoansBorrowedFor(REVNET_ID),
            3,
            "Counter should remain 3 after repaying loan 2 -- cumulative, never decrements"
        );

        // Verify the loans are actually deleted (createdAt == 0)
        assertEq(LOANS_CONTRACT.loanOf(loanId1).createdAt, 0, "Loan 1 should be deleted");
        assertEq(LOANS_CONTRACT.loanOf(loanId2).createdAt, 0, "Loan 2 should be deleted");
        assertTrue(LOANS_CONTRACT.loanOf(loanId3).createdAt > 0, "Loan 3 should still exist");
    }

    /// @notice Verifies totalLoansBorrowedFor never decrements after loan liquidation.
    /// @dev Creates 2 loans, liquidates both, then verifies the counter stays at 2.
    function test_I20_counterNeverDecrementsAfterLiquidation() public {
        // Create 2 loans
        (uint256 loanId1,) = _setupLoan(USER1, 5e18);
        (uint256 loanId2,) = _setupLoan(USER2, 5e18);

        assertEq(LOANS_CONTRACT.totalLoansBorrowedFor(REVNET_ID), 2, "Counter should be 2 after 2 loans");

        // Warp past liquidation duration
        vm.warp(block.timestamp + LOANS_CONTRACT.LOAN_LIQUIDATION_DURATION() + 1);

        // Liquidate both loans
        LOANS_CONTRACT.liquidateExpiredLoansFrom(REVNET_ID, 1, 2);

        // Both loans should be deleted
        assertEq(LOANS_CONTRACT.loanOf(loanId1).createdAt, 0, "Loan 1 should be liquidated");
        assertEq(LOANS_CONTRACT.loanOf(loanId2).createdAt, 0, "Loan 2 should be liquidated");

        // Counter should still be 2 -- liquidation does not decrement
        assertEq(
            LOANS_CONTRACT.totalLoansBorrowedFor(REVNET_ID),
            2,
            "Counter should remain 2 after liquidating both loans -- cumulative, never decrements"
        );
    }

    /// @notice Verifies that partial repayment (which creates a new loan) increments the counter.
    /// @dev When partially repaying, the old loan is burned and a new loan is minted for the remainder.
    /// This should increment the counter by 1 since a new loan ID is generated.
    function test_I20_partialRepaymentIncrementsCounter() public {
        // Create 1 loan
        (uint256 loanId1,) = _setupLoan(USER1, 5e18);
        assertEq(LOANS_CONTRACT.totalLoansBorrowedFor(REVNET_ID), 1, "Counter should be 1 after 1 loan");

        // Partially repay (repay half the borrow amount, return no collateral)
        REVLoan memory loan1 = LOANS_CONTRACT.loanOf(loanId1);
        uint256 halfAmount = loan1.amount / 2;
        JBSingleAllowance memory allowance;
        vm.prank(USER1);
        LOANS_CONTRACT.repayLoan{value: halfAmount}(loanId1, halfAmount, 0, payable(USER1), allowance);

        // Counter should be 2: original loan (burned) + replacement loan (new ID)
        assertEq(
            LOANS_CONTRACT.totalLoansBorrowedFor(REVNET_ID),
            2,
            "Counter should be 2 after partial repayment creates a replacement loan"
        );

        // Original loan should be deleted
        assertEq(LOANS_CONTRACT.loanOf(loanId1).createdAt, 0, "Original loan should be deleted after partial repay");
    }
}
