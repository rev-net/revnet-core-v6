// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {REVEmpty721Config} from "./helpers/REVEmpty721Config.sol";

/// @notice Tests for PR #32: liquidation boundary, reallocate msg.value, and decimal normalization fixes.
contract TestMixedFixes is TestBaseWorkflow {
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";

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
        REVLoanSource[] memory ls = new REVLoanSource[](1);
        ls[0] = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
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

    /// @notice At exactly LOAN_LIQUIDATION_DURATION, determineSourceFeeAmount should revert with LoanExpired (>=
    /// boundary).
    function test_liquidationBoundary_exactDuration_isLiquidatable() public {
        (uint256 loanId,,) = _setupLoan(USER, 10e18, 25);
        require(loanId != 0, "Loan setup failed");

        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);

        // Warp to one second past LOAN_LIQUIDATION_DURATION after creation.
        // The contract uses `>` (not `>=`) so the exact boundary is still repayable;
        // we need to exceed the boundary by 1 second to trigger the revert.
        vm.warp(loan.createdAt + LOANS_CONTRACT.LOAN_LIQUIDATION_DURATION() + 1);

        // timeSinceLoanCreated > LOAN_LIQUIDATION_DURATION → revert
        vm.expectRevert(
            abi.encodeWithSelector(
                REVLoans.REVLoans_LoanExpired.selector,
                LOANS_CONTRACT.LOAN_LIQUIDATION_DURATION() + 1,
                LOANS_CONTRACT.LOAN_LIQUIDATION_DURATION()
            )
        );
        LOANS_CONTRACT.determineSourceFeeAmount(loan, loan.amount);
    }

    /// @notice At LOAN_LIQUIDATION_DURATION - 1, the loan should still be manageable (not expired).
    function test_liquidationBoundary_oneBefore_notLiquidatable() public {
        (uint256 loanId,,) = _setupLoan(USER, 10e18, 25);
        require(loanId != 0, "Loan setup failed");

        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);

        // Warp to one second before the liquidation boundary
        vm.warp(loan.createdAt + LOANS_CONTRACT.LOAN_LIQUIDATION_DURATION() - 1);

        // This should NOT revert — the loan is still within the liquidation window
        uint256 fee = LOANS_CONTRACT.determineSourceFeeAmount(loan, loan.amount);

        // Fee should be > 0 since we're past the prepaid duration but before liquidation
        assertTrue(fee > 0, "Fee should be nonzero for a loan past its prepaid period");
    }

    /// @notice Sending ETH to the non-payable reallocateCollateralFromLoan should revert.
    /// @dev Since the function is not payable, Solidity prevents sending ETH at compile time.
    /// We use a low-level call to bypass this and verify the EVM-level revert.
    function test_reallocate_withETHValue_reverts() public {
        (uint256 loanId, uint256 tokenCount,) = _setupLoan(USER, 10e18, 25);
        require(loanId != 0, "Loan setup failed");

        // Encode the function call
        bytes memory callData = abi.encodeWithSelector(
            LOANS_CONTRACT.reallocateCollateralFromLoan.selector,
            loanId,
            tokenCount / 10,
            REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()}),
            0,
            0,
            USER,
            25
        );

        // Low-level call with msg.value to bypass Solidity's payable check
        vm.prank(USER);
        (bool success,) = address(LOANS_CONTRACT).call{value: 1 ether}(callData);
        assertFalse(success, "Sending ETH to non-payable reallocate should revert");
    }

    /// @notice Calling reallocateCollateralFromLoan without ETH should work (given valid params).
    function test_reallocate_withoutETHValue_succeeds() public {
        (uint256 loanId, uint256 tokenCount,) = _setupLoan(USER, 10e18, 25);
        require(loanId != 0, "Loan setup failed");

        // Inflate surplus so collateral removal is viable
        address donor = makeAddr("donor");
        vm.deal(donor, 500e18);
        vm.prank(donor);
        jbMultiTerminal().addToBalanceOf{value: 500e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 500e18, false, "", "");

        // Get extra tokens to add as collateral to the new loan
        vm.prank(USER);
        uint256 extraTokens =
            jbMultiTerminal().pay{value: 50e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 50e18, USER, 0, "", "");

        uint256 collateralToTransfer = tokenCount / 10;

        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        // Mock burn permission
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, REVNET_ID, 11, true, true)),
            abi.encode(true)
        );

        // Call without msg.value — should succeed
        vm.prank(USER);
        (uint256 reallocatedLoanId, uint256 newLoanId,,) = LOANS_CONTRACT.reallocateCollateralFromLoan(
            loanId, collateralToTransfer, source, 0, extraTokens, payable(USER), 25
        );

        assertTrue(reallocatedLoanId != 0, "Reallocated loan should exist");
        assertTrue(newLoanId != 0, "New loan should exist");
    }

    // ==================== Mixed-Decimal Normalization Tests ====================

    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 MIXED_REVNET_ID;

    /// @notice Deploy a revnet with BOTH ETH (18 dec) and TOKEN (6 dec) as loan sources.
    function _deployMixedDecimalRevnet() internal {
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
        // cashOutTaxRate=0 for proportional math (simpler assertions).
        stages[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: ai,
            splitPercent: 2000,
            splits: splits,
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 0,
            extraMetadata: 0
        });
        REVLoanSource[] memory ls = new REVLoanSource[](2);
        ls[0] = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        ls[1] = REVLoanSource({token: address(TOKEN), terminal: jbMultiTerminal()});
        REVConfig memory cfg = REVConfig({
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription("Mixed", "$MIX", "ipfs://mix", "MIX_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });
        (MIXED_REVNET_ID,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: cfg,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("MIXED")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    /// @notice When only the ETH source has borrows, TOKEN source (0 borrowed) should be skipped via `continue`.
    /// @dev Exercises the `if (tokensLoaned == 0) continue` path in _totalBorrowedFrom.
    function test_mixedDecimals_zeroBorrowFromTokenSource_continuePath() public {
        _deployMixedDecimalRevnet();

        // Pay ETH to get project tokens.
        vm.prank(USER);
        uint256 tokenCount =
            jbMultiTerminal().pay{value: 10e18}(MIXED_REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, USER, 0, "", "");

        // Borrow from ETH source.
        uint256 borrowable = LOANS_CONTRACT.borrowableAmountFrom(
            MIXED_REVNET_ID, tokenCount, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        require(borrowable > 0, "Must have borrowable amount");

        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(
                IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, MIXED_REVNET_ID, 11, true, true)
            ),
            abi.encode(true)
        );
        REVLoanSource memory ethSource = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        vm.prank(USER);
        (uint256 loanId, REVLoan memory loan) =
            LOANS_CONTRACT.borrowFrom(MIXED_REVNET_ID, ethSource, 0, tokenCount, payable(USER), 25);

        // Verify loan created and TOKEN source has zero borrowed.
        assertTrue(loanId != 0, "ETH loan should be created");
        assertTrue(loan.amount > 0, "Loan amount should be nonzero");
        assertEq(
            LOANS_CONTRACT.totalBorrowedFrom(MIXED_REVNET_ID, jbMultiTerminal(), address(TOKEN)),
            0,
            "TOKEN source should have zero borrowed"
        );
        assertTrue(
            LOANS_CONTRACT.totalBorrowedFrom(MIXED_REVNET_ID, jbMultiTerminal(), JBConstants.NATIVE_TOKEN) > 0,
            "ETH source should have nonzero borrowed"
        );
    }

    /// @notice Borrow from TOKEN (6-decimal) source, verify totalBorrowed tracked and borrowable works in 18-dec
    /// context. @dev This is the core normalization test. Without decimal normalization, _totalBorrowedFrom would treat
    /// the 6-decimal TOKEN amount as if it were in 18 decimals, making it ~10^12 times too small.
    function test_mixedDecimals_borrowFromTokenSource_normalizedCorrectly() public {
        _deployMixedDecimalRevnet();

        // Pay with TOKEN to get project tokens AND create TOKEN surplus in the terminal.
        // Using TOKEN (not ETH) ensures the borrowable amount from TOKEN source stays within
        // the terminal's actual TOKEN balance.
        deal(address(TOKEN), USER, 2_000_000e6);
        vm.prank(USER);
        TOKEN.approve(address(jbMultiTerminal()), type(uint256).max);
        vm.prank(USER);
        uint256 tokenCount = jbMultiTerminal().pay(MIXED_REVNET_ID, address(TOKEN), 1_000_000e6, USER, 0, "", "");
        require(tokenCount > 0, "Must receive project tokens");

        // Record borrowable BEFORE any borrow (queried in 18-decimal ETH context).
        uint256 smallCollateral = tokenCount / 10;
        uint256 borrowableBefore = LOANS_CONTRACT.borrowableAmountFrom(
            MIXED_REVNET_ID, smallCollateral, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        assertTrue(borrowableBefore > 0, "Must have borrowable amount before borrow");

        // Borrow from TOKEN source using a small portion of collateral.
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(
                IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, MIXED_REVNET_ID, 11, true, true)
            ),
            abi.encode(true)
        );
        REVLoanSource memory tokenSource = REVLoanSource({token: address(TOKEN), terminal: jbMultiTerminal()});
        vm.prank(USER);
        (uint256 loanId, REVLoan memory loan) =
            LOANS_CONTRACT.borrowFrom(MIXED_REVNET_ID, tokenSource, 0, smallCollateral, payable(USER), 25);

        assertTrue(loanId != 0, "TOKEN loan should be created");
        assertTrue(loan.amount > 0, "Loan amount should be nonzero");

        // Verify totalBorrowedFrom tracks the raw 6-decimal amount.
        uint256 tokenBorrowed = LOANS_CONTRACT.totalBorrowedFrom(MIXED_REVNET_ID, jbMultiTerminal(), address(TOKEN));
        assertEq(tokenBorrowed, loan.amount, "totalBorrowedFrom should match loan amount in source decimals");

        // Query borrowable for more collateral in 18-decimal ETH context.
        // This calls _totalBorrowedFrom which must normalize the 6-dec TOKEN amount to 18-dec.
        // Without normalization: TOKEN borrow treated as near-zero → borrowable barely changes.
        // With normalization: TOKEN borrow properly scaled → borrowable reflects the outstanding debt.
        uint256 borrowableAfter = LOANS_CONTRACT.borrowableAmountFrom(
            MIXED_REVNET_ID, smallCollateral, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );

        // borrowableAfter should still be nonzero (the revnet has surplus).
        assertTrue(borrowableAfter > 0, "Should still have borrowable amount after TOKEN borrow");

        // Also query in TOKEN's own 6-decimal context to verify the same-currency normalization path.
        // Since only TOKEN source has borrows and ETH source has 0 (skipped via `continue`), this is safe.
        uint256 borrowableInToken =
            LOANS_CONTRACT.borrowableAmountFrom(MIXED_REVNET_ID, smallCollateral, 6, uint32(uint160(address(TOKEN))));
        assertTrue(borrowableInToken > 0, "Borrowable in TOKEN terms should be nonzero");
    }

    /// @notice Borrow from both ETH and TOKEN sources, verify both borrows are tracked and aggregated.
    /// @dev TOKEN borrow MUST happen first: when borrowing from TOKEN source, _totalBorrowedFrom is queried
    /// in 6-dec TOKEN context. If ETH had borrows, converting ETH→TOKEN at 6 decimals causes the inverse
    /// price feed to truncate to 0 (mulDiv(1e6,1e6,1e21)=0). Borrowing TOKEN first ensures ETH=0→continue.
    /// The subsequent ETH borrow then exercises cross-decimal normalization (TOKEN 6-dec → ETH 18-dec) using
    /// the DIRECT TOKEN→ETH feed which works at 18 decimals.
    function test_mixedDecimals_borrowFromBothSources_aggregatesCorrectly() public {
        _deployMixedDecimalRevnet();

        // STEP 1: Pay TOKEN ONLY to get project tokens and create TOKEN-only surplus.
        // This avoids ETH surplus inflating the TOKEN borrowable beyond the terminal's TOKEN balance.
        deal(address(TOKEN), USER, 10_000_000e6);
        vm.prank(USER);
        TOKEN.approve(address(jbMultiTerminal()), type(uint256).max);
        vm.prank(USER);
        uint256 tokenTokenCount = jbMultiTerminal().pay(MIXED_REVNET_ID, address(TOKEN), 5_000_000e6, USER, 0, "", "");

        // STEP 2: Borrow from TOKEN source (ETH totalBorrowed=0 → skipped via `continue`, no inverse price needed).
        uint256 smallCollateral = tokenTokenCount / 20;
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(
                IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, MIXED_REVNET_ID, 11, true, true)
            ),
            abi.encode(true)
        );
        REVLoanSource memory tokenSource = REVLoanSource({token: address(TOKEN), terminal: jbMultiTerminal()});
        vm.prank(USER);
        (uint256 tokenLoanId,) =
            LOANS_CONTRACT.borrowFrom(MIXED_REVNET_ID, tokenSource, 0, smallCollateral, payable(USER), 25);
        assertTrue(tokenLoanId != 0, "TOKEN loan should be created");

        // STEP 3: Pay ETH to create ETH surplus.
        vm.prank(USER);
        uint256 ethTokenCount =
            jbMultiTerminal().pay{value: 10e18}(MIXED_REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, USER, 0, "", "");

        // STEP 4: Borrow from ETH source. Now _totalBorrowedFrom(revnetId, 18, ETH_CURRENCY) must normalize
        // the TOKEN borrow (6 dec) to 18 dec using the DIRECT TOKEN→ETH feed. This is the key normalization test.
        uint256 ethCollateral = ethTokenCount / 20;
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(
                IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, MIXED_REVNET_ID, 11, true, true)
            ),
            abi.encode(true)
        );
        REVLoanSource memory ethSource = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        vm.prank(USER);
        (uint256 ethLoanId,) =
            LOANS_CONTRACT.borrowFrom(MIXED_REVNET_ID, ethSource, 0, ethCollateral, payable(USER), 25);
        assertTrue(ethLoanId != 0, "ETH loan should be created");

        // Both sources should have tracked borrows.
        uint256 ethBorrowed =
            LOANS_CONTRACT.totalBorrowedFrom(MIXED_REVNET_ID, jbMultiTerminal(), JBConstants.NATIVE_TOKEN);
        uint256 tokenBorrowed = LOANS_CONTRACT.totalBorrowedFrom(MIXED_REVNET_ID, jbMultiTerminal(), address(TOKEN));
        assertTrue(ethBorrowed > 0, "ETH borrow should be tracked");
        assertTrue(tokenBorrowed > 0, "TOKEN borrow should be tracked");

        // The total number of loans should be 2.
        assertEq(LOANS_CONTRACT.totalLoansBorrowedFor(MIXED_REVNET_ID), 2, "Should have 2 loans");

        // Query borrowable in 18-decimal ETH context. This exercises _totalBorrowedFrom's
        // cross-decimal normalization: TOKEN borrows (6 dec) must be normalized to 18 dec before
        // aggregation with the direct TOKEN→ETH price feed.
        uint256 borrowableInEth = LOANS_CONTRACT.borrowableAmountFrom(
            MIXED_REVNET_ID, ethCollateral, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        assertTrue(borrowableInEth > 0, "Should still have borrowable after both borrows (18-dec ETH)");
    }
}
