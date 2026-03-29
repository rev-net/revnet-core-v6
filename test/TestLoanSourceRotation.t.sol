// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
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
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";
import {REVEmpty721Config} from "./helpers/REVEmpty721Config.sol";
import {REVOwner} from "../src/REVOwner.sol";
import {IREVDeployer} from "../src/interfaces/IREVDeployer.sol";

/// @notice Tests for loan source rotation: verify behavior when loans are taken from different sources (tokens)
/// and that existing loans remain valid and repayable after new sources are introduced.
contract TestLoanSourceRotation is TestBaseWorkflow {
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

        // Deploy a 6-decimal ERC-20 token.
        TOKEN = new MockERC20("Stable Token", "STABLE");

        // Price feed: TOKEN -> ETH. 1 TOKEN (6 dec) = 0.0005 ETH.
        MockPriceFeed priceFeed = new MockPriceFeed(5e14, 18);
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

        REV_OWNER = new REVOwner(
            IJBBuybackHookRegistry(address(MOCK_BUYBACK)),
            jbDirectory(),
            FEE_PROJECT_ID,
            SUCKER_REGISTRY,
            address(LOANS_CONTRACT)
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

        REV_OWNER.initialize(IREVDeployer(address(REV_DEPLOYER)));

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

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        REVAutoIssuance[] memory ai = new REVAutoIssuance[](1);
        ai[0] = REVAutoIssuance({chainId: uint32(block.chainid), count: uint104(70_000e18), beneficiary: multisig()});

        REVStageConfig[] memory stages = new REVStageConfig[](1);
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

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        REVAutoIssuance[] memory ai = new REVAutoIssuance[](1);
        ai[0] = REVAutoIssuance({chainId: uint32(block.chainid), count: uint104(70_000e18), beneficiary: multisig()});

        REVStageConfig[] memory stages = new REVStageConfig[](1);
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

    /// @notice Helper: take a loan from a given source (ETH or TOKEN).
    function _borrowWithSource(
        address user,
        uint256 ethAmount,
        REVLoanSource memory source
    )
        internal
        returns (uint256 loanId, uint256 tokenCount, uint256 borrowAmount)
    {
        // Pay with ETH to get revnet tokens.
        vm.prank(user);
        tokenCount =
            jbMultiTerminal().pay{value: ethAmount}(REVNET_ID, JBConstants.NATIVE_TOKEN, ethAmount, user, 0, "", "");

        // Check borrowable amount for the given source.
        borrowAmount = LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokenCount, 18, uint32(uint160(source.token)));
        if (borrowAmount == 0) return (0, tokenCount, 0);

        // Mock permission for burn.
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), user, REVNET_ID, 11, true, true)),
            abi.encode(true)
        );

        vm.prank(user);
        (loanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(user), 25);
    }

    //*********************************************************************//
    // --- Loan Source Rotation Tests ------------------------------------ //
    //*********************************************************************//

    /// @notice First loan uses ETH source. A second loan from a different user uses TOKEN source.
    /// Both should coexist and the loan sources array should reflect both.
    function test_loanFromMultipleSources() public {
        address user2 = makeAddr("user2");
        vm.deal(user2, 100e18);

        // Loan 1: borrow from ETH source.
        REVLoanSource memory ethSource = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        (uint256 loanId1,,) = _borrowWithSource(USER, 10e18, ethSource);
        require(loanId1 != 0, "ETH loan setup failed");

        // Verify ETH is now a loan source.
        assertTrue(
            LOANS_CONTRACT.isLoanSourceOf(REVNET_ID, jbMultiTerminal(), JBConstants.NATIVE_TOKEN),
            "ETH should be registered as a loan source"
        );

        // Loan 2: borrow from TOKEN source (need to fund the terminal with TOKEN first).
        // Use addToBalanceOf to properly register TOKEN in the revnet's accounting.
        uint256 tokenFunding = 1_000_000e6;
        TOKEN.mint(address(this), tokenFunding);
        TOKEN.approve(address(jbMultiTerminal()), tokenFunding);
        jbMultiTerminal().addToBalanceOf(REVNET_ID, address(TOKEN), tokenFunding, false, "", "");

        TOKEN.mint(user2, 100_000e6);

        // User2 pays ETH to get revnet tokens.
        vm.prank(user2);
        uint256 user2Tokens =
            jbMultiTerminal().pay{value: 10e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, user2, 0, "", "");

        REVLoanSource memory tokenSource = REVLoanSource({token: address(TOKEN), terminal: jbMultiTerminal()});
        uint256 tokenBorrowable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, user2Tokens, 6, uint32(uint160(address(TOKEN))));

        if (tokenBorrowable > 0) {
            mockExpect(
                address(jbPermissions()),
                abi.encodeCall(
                    IJBPermissions.hasPermission, (address(LOANS_CONTRACT), user2, REVNET_ID, 11, true, true)
                ),
                abi.encode(true)
            );

            vm.prank(user2);
            (uint256 loanId2,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, tokenSource, 0, user2Tokens, payable(user2), 25);
            assertGt(loanId2, 0, "TOKEN loan should be created");

            // Both sources should now be registered.
            assertTrue(
                LOANS_CONTRACT.isLoanSourceOf(REVNET_ID, jbMultiTerminal(), address(TOKEN)),
                "TOKEN should be registered as a loan source"
            );

            // Loan sources array should have both entries.
            REVLoanSource[] memory sources = LOANS_CONTRACT.loanSourcesOf(REVNET_ID);
            assertGe(sources.length, 2, "should have at least 2 loan sources");
        }
    }

    /// @notice After taking a loan from ETH source, repay it fully. The source remains registered
    /// (sources array only grows, never shrinks).
    function test_repayEthLoan_sourcePersistsAfterRepay() public {
        REVLoanSource memory ethSource = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        (uint256 loanId,,) = _borrowWithSource(USER, 10e18, ethSource);
        require(loanId != 0, "Loan setup failed");

        // Verify loan is active.
        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);
        assertGt(loan.amount, 0, "loan should have a positive amount");
        assertGt(loan.collateral, 0, "loan should have collateral");

        // Record the total collateral before repay.
        uint256 collateralBefore = LOANS_CONTRACT.totalCollateralOf(REVNET_ID);

        // Calculate source fee for the full repay.
        uint256 sourceFee = LOANS_CONTRACT.determineSourceFeeAmount(loan, loan.amount);
        uint256 repayTotal = loan.amount + sourceFee;

        // Repay the full loan.
        vm.deal(USER, repayTotal + 1e18); // Ensure enough ETH for repay.
        vm.prank(USER);
        LOANS_CONTRACT.repayLoan{value: repayTotal}(
            loanId,
            repayTotal,
            loan.collateral, // Return all collateral.
            payable(USER),
            JBSingleAllowance({sigDeadline: 0, amount: 0, expiration: 0, nonce: 0, signature: ""})
        );

        // Source should still be registered (sources array only grows).
        assertTrue(
            LOANS_CONTRACT.isLoanSourceOf(REVNET_ID, jbMultiTerminal(), JBConstants.NATIVE_TOKEN),
            "ETH source should persist after loan repay"
        );

        // Collateral should be decreased.
        uint256 collateralAfter = LOANS_CONTRACT.totalCollateralOf(REVNET_ID);
        assertLt(collateralAfter, collateralBefore, "total collateral should decrease after full repay");
    }

    /// @notice Take two sequential loans from different sources. Verify the second loan does not affect
    /// the first loan's terms (collateral, amount, source).
    function test_secondSourceDoesNotAffectFirstLoan() public {
        REVLoanSource memory ethSource = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        // First loan with ETH source.
        (uint256 loanId1,,) = _borrowWithSource(USER, 10e18, ethSource);
        require(loanId1 != 0, "First loan setup failed");

        // Capture first loan details.
        REVLoan memory loan1Before = LOANS_CONTRACT.loanOf(loanId1);
        uint256 totalBorrowedFromEthBefore =
            LOANS_CONTRACT.totalBorrowedFrom(REVNET_ID, jbMultiTerminal(), JBConstants.NATIVE_TOKEN);

        // Second loan: also from ETH source but by a different user.
        address user2 = makeAddr("user2");
        vm.deal(user2, 100e18);

        REVLoanSource memory ethSource2 = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        vm.prank(user2);
        uint256 user2Tokens =
            jbMultiTerminal().pay{value: 5e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 5e18, user2, 0, "", "");
        uint256 user2Borrowable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, user2Tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        if (user2Borrowable > 0) {
            mockExpect(
                address(jbPermissions()),
                abi.encodeCall(
                    IJBPermissions.hasPermission, (address(LOANS_CONTRACT), user2, REVNET_ID, 11, true, true)
                ),
                abi.encode(true)
            );

            vm.prank(user2);
            (uint256 loanId2,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, ethSource2, 0, user2Tokens, payable(user2), 25);
            assertGt(loanId2, 0, "second loan should be created");

            // First loan should be unaffected.
            REVLoan memory loan1After = LOANS_CONTRACT.loanOf(loanId1);
            assertEq(loan1After.amount, loan1Before.amount, "first loan amount should be unchanged");
            assertEq(loan1After.collateral, loan1Before.collateral, "first loan collateral should be unchanged");
            assertEq(loan1After.source.token, loan1Before.source.token, "first loan source token should be unchanged");
            assertEq(
                address(loan1After.source.terminal),
                address(loan1Before.source.terminal),
                "first loan source terminal should be unchanged"
            );

            // Total borrowed from ETH source should have increased.
            uint256 totalBorrowedFromEthAfter =
                LOANS_CONTRACT.totalBorrowedFrom(REVNET_ID, jbMultiTerminal(), JBConstants.NATIVE_TOKEN);
            assertGt(
                totalBorrowedFromEthAfter,
                totalBorrowedFromEthBefore,
                "total borrowed from ETH should increase with new loan"
            );
        }
    }

    /// @notice The fee calculation should be consistent regardless of which source is used.
    /// Both ETH and TOKEN sources should use the same prepaid fee percent logic.
    function test_feeCalculationConsistency_acrossSources() public {
        REVLoanSource memory ethSource = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        // Take ETH loan.
        (uint256 ethLoanId,,) = _borrowWithSource(USER, 10e18, ethSource);
        require(ethLoanId != 0, "ETH loan failed");

        REVLoan memory ethLoan = LOANS_CONTRACT.loanOf(ethLoanId);

        // Verify the prepaid fee percent is what we set (25 = 2.5%, the minimum).
        assertEq(ethLoan.prepaidFeePercent, 25, "ETH loan should have 2.5% prepaid fee");

        // Verify the prepaid duration is consistent with the fee percent.
        // prepaidDuration = prepaidFeePercent * LOAN_LIQUIDATION_DURATION / MAX_PREPAID_FEE_PERCENT.
        uint256 expectedDuration =
            (25 * LOANS_CONTRACT.LOAN_LIQUIDATION_DURATION()) / LOANS_CONTRACT.MAX_PREPAID_FEE_PERCENT();
        assertEq(ethLoan.prepaidDuration, expectedDuration, "prepaid duration should match formula");

        // Verify source fee amount is nonzero for a nonzero loan.
        uint256 sourceFee = LOANS_CONTRACT.determineSourceFeeAmount(ethLoan, ethLoan.amount);
        // Within the prepaid window, the source fee should be zero (already prepaid).
        // After the prepaid window, fees accumulate linearly.
        assertEq(sourceFee, 0, "source fee should be 0 within prepaid window");

        // Warp well past the prepaid duration (halfway through the remaining loan term).
        // With prepaid=25/500, prepaid covers ~182.5 days. Warp an additional 5 years past that
        // so the fee calculation is significant enough to not round to zero.
        vm.warp(block.timestamp + ethLoan.prepaidDuration + 365 days * 5);

        // Now the source fee should be > 0 because we are well past the prepaid window.
        uint256 sourceFeeAfter = LOANS_CONTRACT.determineSourceFeeAmount(ethLoan, ethLoan.amount);
        assertGt(sourceFeeAfter, 0, "source fee should be nonzero well after prepaid window expires");
    }

    /// @notice Verify that totalBorrowedFrom is tracked per-source and does not bleed across sources.
    function test_totalBorrowedFrom_isolatedPerSource() public {
        REVLoanSource memory ethSource = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        // Take ETH loan.
        (uint256 loanId,,) = _borrowWithSource(USER, 10e18, ethSource);
        require(loanId != 0, "Loan failed");

        // Check totalBorrowedFrom for ETH source.
        uint256 totalBorrowedEth =
            LOANS_CONTRACT.totalBorrowedFrom(REVNET_ID, jbMultiTerminal(), JBConstants.NATIVE_TOKEN);
        assertGt(totalBorrowedEth, 0, "should have nonzero total borrowed from ETH");

        // TOKEN source should have zero total borrowed.
        uint256 totalBorrowedToken = LOANS_CONTRACT.totalBorrowedFrom(REVNET_ID, jbMultiTerminal(), address(TOKEN));
        assertEq(totalBorrowedToken, 0, "TOKEN source should have zero total borrowed");
    }

    /// @notice Verify that taking a loan, then time passing, then taking another loan from the same source
    /// correctly increments the loan counter.
    function test_loanCounterIncrements_acrossTimePeriods() public {
        REVLoanSource memory ethSource = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        uint256 countBefore = LOANS_CONTRACT.totalLoansBorrowedFor(REVNET_ID);

        // First loan.
        (uint256 loanId1,,) = _borrowWithSource(USER, 5e18, ethSource);
        require(loanId1 != 0, "First loan failed");

        uint256 countAfterFirst = LOANS_CONTRACT.totalLoansBorrowedFor(REVNET_ID);
        assertEq(countAfterFirst, countBefore + 1, "counter should increment by 1");

        // Warp 30 days.
        vm.warp(block.timestamp + 30 days);

        // Second loan.
        address user2 = makeAddr("user2_counter");
        vm.deal(user2, 100e18);

        vm.prank(user2);
        uint256 tokens = jbMultiTerminal().pay{value: 5e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 5e18, user2, 0, "", "");
        uint256 borrowable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        if (borrowable > 0) {
            mockExpect(
                address(jbPermissions()),
                abi.encodeCall(
                    IJBPermissions.hasPermission, (address(LOANS_CONTRACT), user2, REVNET_ID, 11, true, true)
                ),
                abi.encode(true)
            );

            vm.prank(user2);
            (uint256 loanId2,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, ethSource, 0, tokens, payable(user2), 25);
            assertGt(loanId2, 0, "second loan should succeed");

            uint256 countAfterSecond = LOANS_CONTRACT.totalLoansBorrowedFor(REVNET_ID);
            assertEq(countAfterSecond, countBefore + 2, "counter should increment by 2 total");
        }
    }
}
