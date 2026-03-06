// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

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
import "@bananapus/swap-terminal-v6/script/helpers/SwapTerminalDeploymentLib.sol";
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
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice Tests for PR #10: liquidation behavior documentation and collateral burn mechanics.
contract TestPR10_LiquidationBehavior is TestBaseWorkflow, JBTest {
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";

    REVDeployer REV_DEPLOYER;
    JB721TiersHook EXAMPLE_HOOK;
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    IJB721TiersHookStore HOOK_STORE;
    IJBAddressRegistry ADDRESS_REGISTRY;
    REVLoans LOANS_CONTRACT;
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
        EXAMPLE_HOOK = new JB721TiersHook(jbDirectory(), jbPermissions(), jbRulesets(), HOOK_STORE, multisig());
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

    /// @notice Verify that collateral is burned (not escrowed) — totalCollateralOf increases and loans contract holds
    /// no tokens.
    function test_collateralBurnedNotEscrowed() public {
        uint256 totalCollateralBefore = LOANS_CONTRACT.totalCollateralOf(REVNET_ID);
        assertEq(totalCollateralBefore, 0, "No collateral before any loans");

        // User pays to get tokens
        vm.prank(USER);
        uint256 tokenCount =
            jbMultiTerminal().pay{value: 10e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, USER, 0, "", "");

        // Now borrow (which burns collateral tokens)
        uint256 borrowAmount =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokenCount, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        require(borrowAmount > 0, "Borrow amount should be > 0");

        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, REVNET_ID, 11, true, true)),
            abi.encode(true)
        );
        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        vm.prank(USER);
        LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(USER), 25);

        uint256 totalCollateralAfterBorrow = LOANS_CONTRACT.totalCollateralOf(REVNET_ID);

        // totalCollateralOf should have increased by tokenCount (bookkeeping for burned collateral)
        assertEq(
            totalCollateralAfterBorrow,
            totalCollateralBefore + tokenCount,
            "Total collateral tracking should increase by the collateral amount"
        );

        // The loans contract should NOT hold any project tokens — they are burned, not escrowed.
        // Check that the REVLoans contract has zero balance of the project's ERC20 token.
        uint256 loansTokenBalance = jbTokens().totalBalanceOf(address(LOANS_CONTRACT), REVNET_ID);
        assertEq(loansTokenBalance, 0, "Loans contract should hold zero project tokens (burned, not escrowed)");

        // Note: The user may hold some project tokens received as fee payment beneficiary during borrowing.
        // The key point is that the LOANS CONTRACT holds zero — collateral is burned, not escrowed.
    }

    /// @notice Verify borrower receives ETH from borrowing.
    function test_borrowerKeepsBorrowedFunds() public {
        uint256 userBalanceBefore = USER.balance;

        (uint256 loanId,, uint256 borrowAmount) = _setupLoan(USER, 10e18, 25);
        require(loanId != 0, "Loan setup failed");

        uint256 userBalanceAfter = USER.balance;

        // User spent 10 ETH paying in, then received borrowAmount minus fees.
        // The net balance change: -10 ETH (payment) + borrowed funds received
        // Borrowed funds = borrowAmount minus protocol fee (2.5%) minus REV fee (1%) minus prepaid source fee (2.5%)
        // The user's balance should have increased relative to the post-payment balance.
        // Since _setupLoan sends ETH to pay AND receives borrow, let's just check:
        // userBalanceAfter should be > (userBalanceBefore - 10e18) because they received borrowed funds
        assertTrue(userBalanceAfter > userBalanceBefore - 10e18, "Borrower should have received ETH from the loan");

        // Furthermore, the amount received should be meaningful (not zero)
        // The borrow amount minus all fees should still be positive
        assertTrue(userBalanceAfter > userBalanceBefore - 10e18, "Borrower keeps borrowed funds");
    }

    /// @notice Repay before expiry returns collateral (re-mints tokens).
    function test_repayBeforeExpiry_collateralReminted() public {
        (uint256 loanId,, uint256 borrowAmount) = _setupLoan(USER, 10e18, 25);
        require(loanId != 0, "Loan setup failed");

        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);
        uint256 totalCollateralAfterBorrow = LOANS_CONTRACT.totalCollateralOf(REVNET_ID);
        assertTrue(totalCollateralAfterBorrow > 0, "Should have collateral tracking after borrow");

        // Repay the full loan (returning all collateral)
        JBSingleAllowance memory allowance;
        vm.prank(USER);
        LOANS_CONTRACT.repayLoan{value: loan.amount}(
            loanId,
            loan.amount,
            loan.collateral, // return all collateral
            payable(USER),
            allowance
        );

        // After full repayment, totalCollateralOf should return to 0
        uint256 totalCollateralAfterRepay = LOANS_CONTRACT.totalCollateralOf(REVNET_ID);
        assertEq(totalCollateralAfterRepay, 0, "Total collateral should be 0 after full repay (collateral re-minted)");
    }

    /// @notice After liquidation, the loan NFT is burned and collateral/borrow tracking is decremented.
    function test_loanDataDeletedAfterLiquidation() public {
        (uint256 loanId,, uint256 borrowAmount) = _setupLoan(USER, 10e18, 25);
        require(loanId != 0, "Loan setup failed");

        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);
        uint256 totalCollateralBefore = LOANS_CONTRACT.totalCollateralOf(REVNET_ID);
        uint256 totalBorrowedBefore =
            LOANS_CONTRACT.totalBorrowedFrom(REVNET_ID, jbMultiTerminal(), JBConstants.NATIVE_TOKEN);

        assertTrue(totalCollateralBefore > 0, "Should have collateral before liquidation");
        assertTrue(totalBorrowedBefore > 0, "Should have borrowed amount before liquidation");

        // Warp past the liquidation duration
        vm.warp(loan.createdAt + LOANS_CONTRACT.LOAN_LIQUIDATION_DURATION() + 1);

        // Get the loan number (loanId = revnetId * 1_000_000_000_000 + loanNumber)
        uint256 loanNumber = loanId - (REVNET_ID * 1_000_000_000_000);

        // Liquidate the loan
        LOANS_CONTRACT.liquidateExpiredLoansFrom(REVNET_ID, loanNumber, 1);

        // After liquidation:
        // 1. The NFT should be burned (ownerOf should revert)
        vm.expectRevert();
        IERC721(address(LOANS_CONTRACT)).ownerOf(loanId);

        // 2. totalCollateralOf should be decremented
        uint256 totalCollateralAfter = LOANS_CONTRACT.totalCollateralOf(REVNET_ID);
        assertEq(totalCollateralAfter, 0, "Collateral tracking should be 0 after liquidation");

        // 3. totalBorrowedFrom should be decremented
        uint256 totalBorrowedAfter =
            LOANS_CONTRACT.totalBorrowedFrom(REVNET_ID, jbMultiTerminal(), JBConstants.NATIVE_TOKEN);
        assertEq(totalBorrowedAfter, 0, "Borrowed tracking should be 0 after liquidation");

        // 4. The loan data in _loanOf[loanId] is NOT deleted (no `delete` statement),
        //    but the loan is effectively dead since the NFT is burned and tracking is zeroed.
        REVLoan memory loanAfter = LOANS_CONTRACT.loanOf(loanId);
        // The loan struct data is deleted for a gas refund (delete _loanOf[loanId]).
        assertEq(loanAfter.amount, 0, "Loan data should be cleared after liquidation");
        assertEq(loanAfter.collateral, 0, "Loan collateral should be cleared after liquidation");
        assertEq(loanAfter.createdAt, 0, "Loan createdAt should be cleared after liquidation");
    }
}
