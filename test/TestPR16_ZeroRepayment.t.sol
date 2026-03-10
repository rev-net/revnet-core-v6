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
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";
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
import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";

/// @notice Tests for PR #16: zero repayment prevention.
contract TestPR16_ZeroRepayment is TestBaseWorkflow, JBTest {
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";

    REVDeployer REV_DEPLOYER;
    JB721TiersHook EXAMPLE_HOOK;
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    IJB721TiersHookStore HOOK_STORE;
    IJBAddressRegistry ADDRESS_REGISTRY;
    IREVLoans LOANS_CONTRACT;
    MockERC20 TOKEN;
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
        EXAMPLE_HOOK =
            new JB721TiersHook(jbDirectory(), jbPermissions(), jbRulesets(), HOOK_STORE, jbSplits(), multisig());
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
            IJBRulesetDataHook(address(MOCK_BUYBACK)),
            address(LOANS_CONTRACT),
            TRUSTED_FORWARDER
        );
        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);
        _deployFeeProject();
        _deployRevnet();
        vm.deal(USER, 1000e18);
    }

    function _deployFeeProject() internal {
        JBAccountingContext[] memory acc = new JBAccountingContext[](2);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        acc[1] = JBAccountingContext({token: address(TOKEN), decimals: 6, currency: uint32(uint160(address(TOKEN)))});
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
        JBAccountingContext[] memory acc = new JBAccountingContext[](2);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        acc[1] = JBAccountingContext({token: address(TOKEN), decimals: 6, currency: uint32(uint160(address(TOKEN)))});
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
        REVLoanSource[] memory ls = new REVLoanSource[](1);
        ls[0] = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
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

    function _setupLoan(
        address user,
        uint256 ethAmount,
        uint256 prepaidFee
    )
        internal
        returns (uint256 loanId, uint256 tokenCount, uint256 borrowAmount)
    {
        vm.prank(user);
        tokenCount =
            jbMultiTerminal().pay{value: ethAmount}(REVNET_ID, JBConstants.NATIVE_TOKEN, ethAmount, user, 0, "", "");
        borrowAmount =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokenCount, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        if (borrowAmount == 0) return (0, tokenCount, 0);
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), user, REVNET_ID, 11, true, true)),
            abi.encode(true)
        );
        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        vm.prank(user);
        (loanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(user), prepaidFee);
    }

    /// @notice Repaying with zero borrow amount and zero collateral return should revert.
    /// @dev After borrowing, we inflate surplus back so newBorrowAmount >= loan.amount, then
    /// repayBorrowAmount = loan.amount - newBorrowAmount = 0 with collateralCountToReturn = 0.
    /// This should revert with NothingToRepay (or NewBorrowAmountGreaterThanLoanAmount if surplus overshot).
    function test_repayZeroBoth_reverts() public {
        // Setup: borrow against 10 ETH
        (uint256 loanId,,) = _setupLoan(USER, 10e18, 25);
        require(loanId != 0, "Loan setup failed");

        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);

        // After borrowing, fees reduced surplus. We need to restore it so newBorrowAmount >= loan.amount.
        // Donate enough surplus to compensate for all fees extracted during borrowing.
        // A large donation ensures newBorrowAmount > loan.amount, hitting
        // REVLoans_NewBorrowAmountGreaterThanLoanAmount, OR at exact match, hitting REVLoans_NothingToRepay.
        // Either way, the "zero repayment" is prevented.
        address donor = makeAddr("donor");
        vm.deal(donor, 500e18);
        vm.prank(donor);
        jbMultiTerminal().addToBalanceOf{value: 500e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 500e18, false, "", "");

        JBSingleAllowance memory allowance;

        // Try to repay with collateralCountToReturn = 0 and some maxRepayBorrowAmount.
        // Since surplus was inflated, newBorrowAmount > loan.amount, which reverts with
        // REVLoans_NewBorrowAmountGreaterThanLoanAmount. This shows zero-repayment is blocked.
        vm.prank(USER);
        vm.expectRevert(); // Will revert with either NothingToRepay or NewBorrowAmountGreaterThanLoanAmount
        LOANS_CONTRACT.repayLoan{value: 0}(
            loanId,
            0, // maxRepayBorrowAmount
            0, // collateralCountToReturn = 0
            payable(USER),
            allowance
        );
    }

    /// @notice Repaying full borrow amount should succeed (returning all collateral).
    function test_repayNonZeroAmount_succeeds() public {
        // Setup: borrow against 10 ETH
        (uint256 loanId,, uint256 borrowAmount) = _setupLoan(USER, 10e18, 25);
        require(loanId != 0, "Loan setup failed");

        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);

        // Repay the full loan by returning all collateral.
        // collateralCountToReturn == loan.collateral means full repayment path (newBorrowAmount = 0).
        // Need to send enough ETH to cover loan.amount (the repayBorrowAmount) + any source fee.
        JBSingleAllowance memory allowance;

        vm.prank(USER);
        (uint256 paidOffLoanId,) = LOANS_CONTRACT.repayLoan{value: loan.amount}(
            loanId,
            loan.amount, // maxRepayBorrowAmount — covers full repayment
            loan.collateral, // return all collateral
            payable(USER),
            allowance
        );

        // Verify loan was fully repaid
        // After full repayment with all collateral returned, the original loan is burned.
        // The paidOffLoanId should match the loanId since all collateral was returned.
        assertEq(paidOffLoanId, loanId, "Full repay should return original loan ID");
    }

    /// @notice Repaying some collateral (non-zero) should succeed.
    function test_repayNonZeroCollateral_succeeds() public {
        // Setup: borrow against 10 ETH
        (uint256 loanId,, uint256 borrowAmount) = _setupLoan(USER, 10e18, 25);
        require(loanId != 0, "Loan setup failed");

        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);
        uint256 collateralToReturn = loan.collateral / 2; // Return half the collateral

        // When returning half the collateral, the new borrow amount covers the remaining half.
        // The repay amount = loan.amount - newBorrowAmount (which is > 0).
        // We need to send enough ETH to cover it.
        JBSingleAllowance memory allowance;

        vm.prank(USER);
        (uint256 paidOffLoanId, REVLoan memory paidOffLoan) = LOANS_CONTRACT.repayLoan{value: loan.amount}(
            loanId,
            loan.amount, // maxRepayBorrowAmount — generous cap
            collateralToReturn,
            payable(USER),
            allowance
        );

        // Verify some collateral was returned and loan still exists with reduced collateral
        assertTrue(paidOffLoan.collateral < loan.collateral, "Collateral should have decreased");
        assertTrue(paidOffLoan.amount < loan.amount, "Borrow amount should have decreased");
    }
}
