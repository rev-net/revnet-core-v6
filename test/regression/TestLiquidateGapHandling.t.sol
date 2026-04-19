// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
// import /* {*} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "./../../src/REVDeployer.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@croptop/core-v6/src/CTPublisher.sol";
import {MockBuybackDataHook} from "./../mock/MockBuybackDataHook.sol";
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
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";
import {MockPriceFeed} from "@bananapus/core-v6/test/mock/MockPriceFeed.sol";
import {MockERC20} from "@bananapus/core-v6/test/mock/MockERC20.sol";
import {REVLoans} from "../../src/REVLoans.sol";
import {REVLoan} from "../../src/structs/REVLoan.sol";
import {REVStageConfig, REVAutoIssuance} from "../../src/structs/REVStageConfig.sol";
import {REVLoanSource} from "../../src/structs/REVLoanSource.sol";
import {REVDescription} from "../../src/structs/REVDescription.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/JB721CheckpointsDeployer.sol";
import {IJB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721CheckpointsDeployer.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {REVEmpty721Config} from "../helpers/REVEmpty721Config.sol";
import {REVOwner} from "../../src/REVOwner.sol";
import {IREVDeployer} from "../../src/interfaces/IREVDeployer.sol";
import {MockSuckerRegistry} from "../mock/MockSuckerRegistry.sol";

/// @notice liquidateExpiredLoansFrom halts on deleted loan gaps.
/// @dev Before the fix, the function used `break` when encountering a deleted loan (createdAt == 0),
/// which stopped the entire iteration. Expired loans after the gap were never liquidated.
/// After the fix, `continue` is used instead, so the loop skips gaps and keeps processing.
contract TestLiquidateGapHandling is TestBaseWorkflow {
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";

    // forge-lint: disable-next-line(mixed-case-variable)
    REVDeployer REV_DEPLOYER;
    // forge-lint: disable-next-line(mixed-case-variable)
    REVOwner REV_OWNER;
    // forge-lint: disable-next-line(mixed-case-variable)
    JB721TiersHook EXAMPLE_HOOK;
    // forge-lint: disable-next-line(mixed-case-variable)
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    // forge-lint: disable-next-line(mixed-case-variable)
    IJB721TiersHookStore HOOK_STORE;
    // forge-lint: disable-next-line(mixed-case-variable)
    IJBAddressRegistry ADDRESS_REGISTRY;
    // forge-lint: disable-next-line(mixed-case-variable)
    REVLoans LOANS_CONTRACT;
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
    address USER1 = makeAddr("user1");
    // forge-lint: disable-next-line(mixed-case-variable)
    address USER2 = makeAddr("user2");
    // forge-lint: disable-next-line(mixed-case-variable)
    address USER3 = makeAddr("user3");

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    function setUp() public override {
        super.setUp();
        FEE_PROJECT_ID = jbProjects().createFor(multisig());
        SUCKER_REGISTRY = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig(), address(0));
        HOOK_STORE = new JB721TiersHookStore();
        EXAMPLE_HOOK = new JB721TiersHook(
            jbDirectory(),
            jbPermissions(),
            jbPrices(),
            jbRulesets(),
            HOOK_STORE,
            jbSplits(),
            IJB721CheckpointsDeployer(address(new JB721CheckpointsDeployer())),
            multisig()
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
            suckerRegistry: IJBSuckerRegistry(address(new MockSuckerRegistry())),
            revId: FEE_PROJECT_ID,
            owner: address(this),
            permit2: permit2(),
            trustedForwarder: TRUSTED_FORWARDER
        });
        REV_OWNER = new REVOwner(
            IJBBuybackHookRegistry(address(MOCK_BUYBACK)),
            jbDirectory(),
            FEE_PROJECT_ID,
            SUCKER_REGISTRY,
            address(LOANS_CONTRACT),
            address(0)
        );

        REV_DEPLOYER = new REVDeployer{salt: REV_DEPLOYER_SALT}(
            jbController(),
            SUCKER_REGISTRY,
            FEE_PROJECT_ID,
            HOOK_DEPLOYER,
            PUBLISHER,
            IJBBuybackHookRegistry(address(MOCK_BUYBACK)),
            address(LOANS_CONTRACT),
            TRUSTED_FORWARDER,
            address(REV_OWNER)
        );

        REV_OWNER.setDeployer(REV_DEPLOYER);

        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);
        _deployFeeProject();
        _deployRevnet();
        vm.deal(USER1, 100e18);
        vm.deal(USER2, 100e18);
        vm.deal(USER3, 100e18);
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
            // forge-lint: disable-next-line(named-struct-fields)
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
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
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
        REVConfig memory cfg = REVConfig({
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription("NANA", "$NANA", "ipfs://test2", "NANA_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });
        (REVNET_ID,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: cfg,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("NANA")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
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
        (loanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(user), 25, user);
    }

    /// @notice Liquidation should continue past deleted loan gaps.
    /// @dev Steps:
    ///   1. Create 3 loans (loan numbers 1, 2, 3)
    ///   2. Fully repay loan 2, which deletes it (createdAt == 0), creating a gap
    ///   3. Warp past the liquidation duration
    ///   4. Call liquidateExpiredLoansFrom(revnetId, 1, 3) to try liquidating all 3
    ///   5. Verify that loan 3 (after the gap) IS liquidated
    ///
    /// Before the fix (break): Loan 1 liquidated, loan 2 gap causes break, loan 3 skipped.
    /// After the fix (continue): Loan 1 liquidated, loan 2 gap skipped, loan 3 liquidated.
    function test_liquidationContinuesPastDeletedLoanGaps() public {
        // Step 1: Create 3 loans
        (uint256 loanId1,) = _setupLoan(USER1, 5e18);
        (uint256 loanId2,) = _setupLoan(USER2, 5e18);
        (uint256 loanId3,) = _setupLoan(USER3, 5e18);

        require(loanId1 != 0 && loanId2 != 0 && loanId3 != 0, "All loans should be created");

        // Verify all 3 loans exist
        REVLoan memory loan1 = LOANS_CONTRACT.loanOf(loanId1);
        REVLoan memory loan2 = LOANS_CONTRACT.loanOf(loanId2);
        REVLoan memory loan3 = LOANS_CONTRACT.loanOf(loanId3);
        assertTrue(loan1.createdAt > 0, "Loan 1 should exist");
        assertTrue(loan2.createdAt > 0, "Loan 2 should exist");
        assertTrue(loan3.createdAt > 0, "Loan 3 should exist");

        // Step 2: Fully repay loan 2 to create a gap
        JBSingleAllowance memory allowance;
        vm.prank(USER2);
        LOANS_CONTRACT.repayLoan{value: loan2.amount}(
            loanId2,
            loan2.amount,
            loan2.collateral, // return all collateral to fully close the loan
            payable(USER2),
            allowance
        );

        // Verify loan 2 is now deleted (createdAt == 0)
        REVLoan memory deletedLoan2 = LOANS_CONTRACT.loanOf(loanId2);
        assertEq(deletedLoan2.createdAt, 0, "Loan 2 should be deleted after full repayment");

        // Verify loans 1 and 3 still exist
        REVLoan memory stillLoan1 = LOANS_CONTRACT.loanOf(loanId1);
        REVLoan memory stillLoan3 = LOANS_CONTRACT.loanOf(loanId3);
        assertTrue(stillLoan1.createdAt > 0, "Loan 1 should still exist");
        assertTrue(stillLoan3.createdAt > 0, "Loan 3 should still exist");

        // Record collateral and borrowed amounts before liquidation
        uint256 totalCollateralBefore = LOANS_CONTRACT.totalCollateralOf(REVNET_ID);
        uint256 totalBorrowedBefore =
            LOANS_CONTRACT.totalBorrowedFrom(REVNET_ID, jbMultiTerminal(), JBConstants.NATIVE_TOKEN);
        assertTrue(totalCollateralBefore > 0, "Should have collateral from loans 1 and 3");
        assertTrue(totalBorrowedBefore > 0, "Should have borrowed amount from loans 1 and 3");

        // Step 3: Warp past the liquidation duration
        vm.warp(block.timestamp + LOANS_CONTRACT.LOAN_LIQUIDATION_DURATION() + 1);

        // Step 4: Call liquidateExpiredLoansFrom starting from loan 1, iterating over 3 loans
        // Loan numbers are 1, 2, 3 (not the full loanIds which include revnetId prefix)
        LOANS_CONTRACT.liquidateExpiredLoansFrom(REVNET_ID, 1, 3);

        // Step 5: Verify BOTH loan 1 and loan 3 were liquidated (not just loan 1)

        // Loan 1 should be liquidated (NFT burned, data deleted)
        REVLoan memory liquidatedLoan1 = LOANS_CONTRACT.loanOf(loanId1);
        assertEq(liquidatedLoan1.createdAt, 0, "Loan 1 should be liquidated (data deleted)");

        // Loan 3 should ALSO be liquidated -- this is the critical assertion.
        // Before the fix, this would fail because the `break` at loan 2's gap stopped iteration.
        REVLoan memory liquidatedLoan3 = LOANS_CONTRACT.loanOf(loanId3);
        assertEq(liquidatedLoan3.createdAt, 0, "Loan 3 should be liquidated despite gap at loan 2");

        // All collateral and borrowed tracking should be zeroed out
        uint256 totalCollateralAfter = LOANS_CONTRACT.totalCollateralOf(REVNET_ID);
        assertEq(totalCollateralAfter, 0, "All collateral tracking should be zero after full liquidation");

        uint256 totalBorrowedAfter =
            LOANS_CONTRACT.totalBorrowedFrom(REVNET_ID, jbMultiTerminal(), JBConstants.NATIVE_TOKEN);
        assertEq(totalBorrowedAfter, 0, "All borrowed tracking should be zero after full liquidation");
    }

    /// @notice Verify that liquidation handles multiple consecutive gaps correctly.
    /// @dev Creates 4 loans, repays loans 2 and 3, then liquidates the range.
    ///   Loan 1 and 4 should both be liquidated despite the double gap.
    function test_liquidationHandlesMultipleConsecutiveGaps() public {
        // Create 4 loans from the same user (simpler)
        // forge-lint: disable-next-line(mixed-case-variable)
        address USER4 = makeAddr("user4");
        vm.deal(USER4, 100e18);

        (uint256 loanId1,) = _setupLoan(USER1, 3e18);
        (uint256 loanId2,) = _setupLoan(USER2, 3e18);
        (uint256 loanId3,) = _setupLoan(USER3, 3e18);
        (uint256 loanId4,) = _setupLoan(USER4, 3e18);

        // Fully repay loans 2 and 3 to create consecutive gaps
        REVLoan memory loan2 = LOANS_CONTRACT.loanOf(loanId2);
        REVLoan memory loan3 = LOANS_CONTRACT.loanOf(loanId3);

        JBSingleAllowance memory allowance;
        vm.prank(USER2);
        LOANS_CONTRACT.repayLoan{value: loan2.amount}(
            loanId2, loan2.amount, loan2.collateral, payable(USER2), allowance
        );
        vm.prank(USER3);
        LOANS_CONTRACT.repayLoan{value: loan3.amount}(
            loanId3, loan3.amount, loan3.collateral, payable(USER3), allowance
        );

        // Verify the gaps exist
        assertEq(LOANS_CONTRACT.loanOf(loanId2).createdAt, 0, "Loan 2 should be deleted");
        assertEq(LOANS_CONTRACT.loanOf(loanId3).createdAt, 0, "Loan 3 should be deleted");

        // Warp past liquidation duration
        vm.warp(block.timestamp + LOANS_CONTRACT.LOAN_LIQUIDATION_DURATION() + 1);

        // Liquidate the range
        LOANS_CONTRACT.liquidateExpiredLoansFrom(REVNET_ID, 1, 4);

        // Both loan 1 and loan 4 should be liquidated
        assertEq(LOANS_CONTRACT.loanOf(loanId1).createdAt, 0, "Loan 1 should be liquidated");
        assertEq(LOANS_CONTRACT.loanOf(loanId4).createdAt, 0, "Loan 4 should be liquidated despite double gap");

        // All tracking should be zeroed
        assertEq(LOANS_CONTRACT.totalCollateralOf(REVNET_ID), 0, "All collateral should be zero");
        assertEq(
            LOANS_CONTRACT.totalBorrowedFrom(REVNET_ID, jbMultiTerminal(), JBConstants.NATIVE_TOKEN),
            0,
            "All borrowed should be zero"
        );
    }
}
