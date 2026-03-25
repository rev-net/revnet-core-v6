// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
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
// Core constants and structs used throughout the test.
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";
// Price feed mock for native-token-to-native-token identity pricing.
import {MockPriceFeed} from "@bananapus/core-v6/test/mock/MockPriceFeed.sol";
// REVLoans contract and its supporting types.
import {REVLoans} from "../../src/REVLoans.sol";
import {REVLoan} from "../../src/structs/REVLoan.sol";
import {REVStageConfig, REVAutoIssuance} from "../../src/structs/REVStageConfig.sol";
import {REVLoanSource} from "../../src/structs/REVLoanSource.sol";
import {REVDescription} from "../../src/structs/REVDescription.sol";
// Deployment dependencies for suckers, 721 hooks, and address registry.
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
// Helper that provides empty 721 tier configs for revnet deployment.
import {REVEmpty721Config} from "../helpers/REVEmpty721Config.sol";

/// @notice Regression tests for the loan ID overflow guard in REVLoans.
/// @dev The totalLoansBorrowedFor counter must never exceed _ONE_TRILLION (1e12).
/// When it reaches that limit, borrowFrom, _reallocateCollateralFromLoan, and
/// the partial-repay branch of repayLoan must all revert with REVLoans_LoanIdOverflow().
/// These tests use vm.store to set the counter to the limit, then verify the revert.
contract LoanIdOverflowGuard is TestBaseWorkflow {
    // ---------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------

    /// @dev Salt for deterministic REVDeployer deployment.
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";

    /// @dev The overflow boundary -- must match _ONE_TRILLION in REVLoans.sol.
    uint256 private constant _ONE_TRILLION = 1_000_000_000_000;

    /// @dev Storage slot of the totalLoansBorrowedFor mapping in REVLoans (slot 8).
    /// Determined via `forge inspect REVLoans storage-layout`.
    uint256 private constant TOTAL_LOANS_BORROWED_FOR_SLOT = 8;

    /// @dev The address that is allowed to forward meta-transactions.
    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    // ---------------------------------------------------------------
    // State variables
    // ---------------------------------------------------------------

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
    REVLoans LOANS_CONTRACT;
    // forge-lint: disable-next-line(mixed-case-variable)
    IJBSuckerRegistry SUCKER_REGISTRY;
    // forge-lint: disable-next-line(mixed-case-variable)
    CTPublisher PUBLISHER;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockBuybackDataHook MOCK_BUYBACK;

    /// @dev The fee project ID (project 1).
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 FEE_PROJECT_ID;

    /// @dev The revnet project ID used by all tests.
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 REVNET_ID;

    /// @dev Test user address with ETH for paying into the revnet.
    // forge-lint: disable-next-line(mixed-case-variable)
    address USER = makeAddr("user");

    /// @dev Second test user used to increase revnet surplus between loan creation and reallocation.
    // forge-lint: disable-next-line(mixed-case-variable)
    address USER2 = makeAddr("user2");

    // ---------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------

    function setUp() public override {
        // Initialize the base test workflow (deploys core contracts).
        super.setUp();

        // Create the fee project owned by multisig.
        FEE_PROJECT_ID = jbProjects().createFor(multisig());

        // Deploy the sucker registry (no deployers, no initial suckers).
        SUCKER_REGISTRY = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig(), address(0));

        // Deploy the 721 hook store.
        HOOK_STORE = new JB721TiersHookStore();

        // Deploy the example 721 hook (needed as the implementation for the deployer).
        EXAMPLE_HOOK = new JB721TiersHook(
            jbDirectory(), jbPermissions(), jbPrices(), jbRulesets(), HOOK_STORE, jbSplits(), multisig()
        );

        // Deploy the address registry (used by the hook deployer).
        ADDRESS_REGISTRY = new JBAddressRegistry();

        // Deploy the 721 hook deployer.
        HOOK_DEPLOYER = new JB721TiersHookDeployer(EXAMPLE_HOOK, HOOK_STORE, ADDRESS_REGISTRY, multisig());

        // Deploy the croptop publisher.
        PUBLISHER = new CTPublisher(jbDirectory(), jbPermissions(), FEE_PROJECT_ID, multisig());

        // Deploy the mock buyback data hook (satisfies the IJBBuybackHookRegistry interface).
        MOCK_BUYBACK = new MockBuybackDataHook();

        // Add a 1:1 native token price feed so bonding curve math works.
        MockPriceFeed priceFeed = new MockPriceFeed(1e18, 18);
        vm.prank(multisig());
        jbPrices()
            .addPriceFeedFor(
                0, uint32(uint160(JBConstants.NATIVE_TOKEN)), uint32(uint160(JBConstants.NATIVE_TOKEN)), priceFeed
            );

        // Deploy the REVLoans contract.
        LOANS_CONTRACT = new REVLoans({
            controller: jbController(),
            projects: jbProjects(),
            revId: FEE_PROJECT_ID,
            owner: address(this),
            permit2: permit2(),
            trustedForwarder: TRUSTED_FORWARDER
        });

        // Deploy the REVDeployer with a deterministic salt.
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

        // Approve the deployer to configure the fee project.
        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);

        // Deploy the fee project's revnet configuration.
        _deployFeeProject();

        // Deploy the test revnet that loans will be issued against.
        _deployRevnet();

        // Give the test users 100 ETH each.
        vm.deal(USER, 100e18);
        vm.deal(USER2, 100e18);
    }

    // ---------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------

    /// @dev Deploys the fee project (project 1) with a single stage.
    function _deployFeeProject() internal {
        // Accept native token through the multi terminal.
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        // Configure a single terminal.
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});

        // A single stage with auto-issuance for the multisig.
        REVStageConfig[] memory stages = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        // Auto-issue 70k tokens to multisig on this chain.
        REVAutoIssuance[] memory ai = new REVAutoIssuance[](1);
        ai[0] = REVAutoIssuance({chainId: uint32(block.chainid), count: uint104(70_000e18), beneficiary: multisig()});

        // Build the stage configuration.
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

        // Build the revnet configuration for the fee project.
        REVConfig memory cfg = REVConfig({
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription("Revnet", "$REV", "ipfs://test", "REV_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });

        // Deploy the fee project revnet.
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

    /// @dev Deploys the test revnet (project 2) with a single stage and 60% cash-out tax.
    function _deployRevnet() internal {
        // Accept native token through the multi terminal.
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        // Configure a single terminal.
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});

        // A single stage with auto-issuance for the multisig.
        REVStageConfig[] memory stages = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        // Auto-issue 70k tokens to multisig on this chain.
        REVAutoIssuance[] memory ai = new REVAutoIssuance[](1);
        ai[0] = REVAutoIssuance({chainId: uint32(block.chainid), count: uint104(70_000e18), beneficiary: multisig()});

        // Build the stage configuration.
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

        // Build the revnet configuration for the test project.
        REVConfig memory cfg = REVConfig({
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription("NANA", "$NANA", "ipfs://test2", "NANA_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });

        // Deploy the test revnet (revnetId 0 means "create new").
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

    /// @dev Creates a loan for the given user by paying ETH into the revnet then borrowing.
    /// @param user The address that will own the loan.
    /// @param ethAmount The amount of ETH to pay into the revnet as collateral.
    /// @return loanId The ID of the created loan.
    /// @return tokenCount The number of revnet tokens received from paying.
    function _setupLoan(address user, uint256 ethAmount) internal returns (uint256 loanId, uint256 tokenCount) {
        // Pay ETH into the revnet and receive tokens.
        vm.prank(user);
        tokenCount =
            jbMultiTerminal().pay{value: ethAmount}(REVNET_ID, JBConstants.NATIVE_TOKEN, ethAmount, user, 0, "", "");

        // Compute the borrowable amount from the tokens received.
        uint256 borrowAmount =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokenCount, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        // Sanity check: the user should be able to borrow something.
        require(borrowAmount > 0, "Borrow amount should be > 0");

        // Mock the permissions check so LOANS_CONTRACT can burn the user's tokens.
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), user, REVNET_ID, 11, true, true)),
            abi.encode(true)
        );

        // Build the loan source pointing at the real multi terminal and native token.
        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        // Borrow with minimum fee percent (25 = 2.5%).
        vm.prank(user);
        (loanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(user), 25);
    }

    /// @dev Computes the storage slot for totalLoansBorrowedFor[revnetId].
    /// @param revnetId The revnet ID to compute the mapping slot for.
    /// @return The keccak256 slot for the mapping entry.
    function _totalLoansBorrowedSlot(uint256 revnetId) internal pure returns (bytes32) {
        // Solidity mapping slot: keccak256(abi.encode(key, baseSlot)).
        return keccak256(abi.encode(revnetId, TOTAL_LOANS_BORROWED_FOR_SLOT));
    }

    // ---------------------------------------------------------------
    // Test 1: borrowFrom overflow guard
    // ---------------------------------------------------------------

    /// @notice Verifies that borrowFrom reverts with REVLoans_LoanIdOverflow when
    /// the totalLoansBorrowedFor counter has reached _ONE_TRILLION.
    function test_borrowFrom_revertsAtOverflowBoundary() public {
        // Pay ETH into the revnet so the user has tokens for collateral.
        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: 5e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 5e18, USER, 0, "", "");

        // Verify the user received tokens.
        assertGt(tokens, 0, "user should receive tokens from paying");

        // Compute the borrowable amount from the user's tokens.
        uint256 borrowAmount =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        // Sanity check: there should be a borrowable amount.
        assertGt(borrowAmount, 0, "borrowable amount should be > 0");

        // No permission mock needed: the overflow guard fires before any permission/burn check.

        // Use vm.store to set totalLoansBorrowedFor[REVNET_ID] to _ONE_TRILLION.
        vm.store(address(LOANS_CONTRACT), _totalLoansBorrowedSlot(REVNET_ID), bytes32(_ONE_TRILLION));

        // Confirm the counter is now at the overflow boundary.
        assertEq(
            LOANS_CONTRACT.totalLoansBorrowedFor(REVNET_ID),
            _ONE_TRILLION,
            "counter should be at _ONE_TRILLION after vm.store"
        );

        // Build the loan source pointing at the real terminal and native token.
        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        // Expect the overflow revert.
        vm.expectRevert(REVLoans.REVLoans_LoanIdOverflow.selector);

        // Attempt to borrow -- should revert because the counter is at the limit.
        vm.prank(USER);
        LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokens, payable(USER), 25);
    }

    // ---------------------------------------------------------------
    // Test 2: reallocateCollateralFromLoan overflow guard
    // ---------------------------------------------------------------

    /// @notice Verifies that reallocateCollateralFromLoan reverts with REVLoans_LoanIdOverflow
    /// when the totalLoansBorrowedFor counter has reached _ONE_TRILLION.
    /// @dev A second user injects surplus after the loan is created so that removing a small
    /// amount of collateral still leaves borrowable value >= the original loan amount (otherwise
    /// the ReallocatingMoreCollateralThanBorrowedAmountAllows check fires first).
    function test_reallocateCollateral_revertsAtOverflowBoundary() public {
        // Create a loan with enough collateral that we can split off some for reallocation.
        (uint256 loanId,) = _setupLoan(USER, 10e18);

        // Verify the loan was created successfully.
        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);
        assertGt(loan.collateral, 0, "loan should have collateral");
        assertGt(loan.amount, 0, "loan should have a borrow amount");

        // Add surplus to the revnet WITHOUT minting tokens (addToBalanceOf, not pay).
        // This increases the per-token borrowable value so that after removing a small
        // amount of collateral, the borrowable amount still exceeds the original loan
        // amount (avoiding the ReallocatingMoreCollateralThanBorrowedAmountAllows check
        // at line 1181 and reaching the overflow guard at line 1186).
        vm.prank(USER2);
        jbMultiTerminal().addToBalanceOf{value: 50e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 50e18, false, "", "");

        // No permission mock needed: the overflow guard in _reallocateCollateralFromLoan fires
        // before any permission/burn check is reached.

        // Use vm.store to set totalLoansBorrowedFor[REVNET_ID] to _ONE_TRILLION.
        vm.store(address(LOANS_CONTRACT), _totalLoansBorrowedSlot(REVNET_ID), bytes32(_ONE_TRILLION));

        // Confirm the counter is at the overflow boundary.
        assertEq(
            LOANS_CONTRACT.totalLoansBorrowedFor(REVNET_ID),
            _ONE_TRILLION,
            "counter should be at _ONE_TRILLION after vm.store"
        );

        // Build the loan source matching the existing loan's source.
        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        // Transfer only 1 token of collateral to trigger the reallocation path.
        uint256 collateralToTransfer = 1;

        // Expect the overflow revert from _reallocateCollateralFromLoan.
        vm.expectRevert(REVLoans.REVLoans_LoanIdOverflow.selector);

        // Attempt to reallocate -- should revert because the counter is at the limit.
        vm.prank(USER);
        LOANS_CONTRACT.reallocateCollateralFromLoan(
            loanId,
            collateralToTransfer,
            source,
            0, // minBorrowAmount for the new loan
            0, // no additional collateral to add
            payable(USER),
            25 // prepaidFeePercent (2.5%)
        );
    }

    // ---------------------------------------------------------------
    // Test 3: repayLoan (partial) overflow guard
    // ---------------------------------------------------------------

    /// @notice Verifies that a partial repayLoan reverts with REVLoans_LoanIdOverflow
    /// when the totalLoansBorrowedFor counter has reached _ONE_TRILLION.
    /// @dev A partial repayment creates a replacement loan with a new ID, which requires
    /// incrementing the counter. If the counter is at the limit, this must revert.
    function test_partialRepay_revertsAtOverflowBoundary() public {
        // Create a loan for partial repayment testing.
        (uint256 loanId,) = _setupLoan(USER, 5e18);

        // Verify the loan exists and has a borrow amount.
        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);
        assertGt(loan.amount, 0, "loan should have a borrow amount");
        assertGt(loan.collateral, 0, "loan should have collateral");

        // Calculate a partial repayment (half the borrow amount, return no collateral).
        uint256 halfAmount = loan.amount / 2;

        // Sanity check: half amount must be non-zero for a meaningful partial repay.
        assertGt(halfAmount, 0, "half amount should be > 0");

        // Use vm.store to set totalLoansBorrowedFor[REVNET_ID] to _ONE_TRILLION.
        vm.store(address(LOANS_CONTRACT), _totalLoansBorrowedSlot(REVNET_ID), bytes32(_ONE_TRILLION));

        // Confirm the counter is at the overflow boundary.
        assertEq(
            LOANS_CONTRACT.totalLoansBorrowedFor(REVNET_ID),
            _ONE_TRILLION,
            "counter should be at _ONE_TRILLION after vm.store"
        );

        // Build an empty allowance (no permit2 needed for native token repayment).
        JBSingleAllowance memory allowance;

        // Expect the overflow revert from the partial-repay branch.
        vm.expectRevert(REVLoans.REVLoans_LoanIdOverflow.selector);

        // Attempt a partial repayment -- should revert because creating the replacement loan
        // would exceed the _ONE_TRILLION loan ID namespace.
        vm.prank(USER);
        LOANS_CONTRACT.repayLoan{value: halfAmount}(loanId, halfAmount, 0, payable(USER), allowance);
    }
}
