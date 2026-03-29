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
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
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
import {REVOwner} from "../src/REVOwner.sol";
import {IREVDeployer} from "../src/interfaces/IREVDeployer.sol";

/// @notice Deterministic test for the reallocation sandwich at stage boundaries.
/// Documents that a borrower can extract additional value by calling `reallocateCollateralFromLoan` immediately
/// after a stage transition that lowers the `cashOutTaxRate`. This is intentional design behavior:
/// loan value tracks the current bonding curve parameters, and stage boundaries are immutable and predictable.
/// See RISKS.md section 3 ("reallocateCollateralFromLoan sandwich potential") for details.
contract TestReallocationSandwich is TestBaseWorkflow {
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
    address BORROWER = makeAddr("borrower");
    // forge-lint: disable-next-line(mixed-case-variable)
    address OTHER_PAYER = makeAddr("otherPayer");

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    /// @notice Stage 1 starts now with 60% cashOutTaxRate, stage 2 starts after 30 days with 20% cashOutTaxRate.
    function _buildConfig()
        internal
        view
        returns (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc)
    {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});

        REVStageConfig[] memory stages = new REVStageConfig[](2);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        // Stage 1: high cashOutTaxRate (60%)
        stages[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 6000, // 60%
            extraMetadata: 0
        });

        // Stage 2: low cashOutTaxRate (20%) -- starts after 30 days
        stages[1] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp + 30 days),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 2000, // 20%
            extraMetadata: 0
        });

        cfg = REVConfig({
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription("SandwichTest", "SWT", "ipfs://sandwich", "SWT_SALT"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });

        sdc = REVSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("SWT"))
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

        // Deploy the fee project first.
        (REVConfig memory feeCfg, JBTerminalConfig[] memory feeTc, REVSuckerDeploymentConfig memory feeSdc) =
            _buildConfig();
        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeCfg,
            terminalConfigurations: feeTc,
            suckerDeploymentConfiguration: feeSdc,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        // Deploy the test revnet.
        (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc) = _buildConfig();
        // forge-lint: disable-next-line(named-struct-fields)
        cfg.description = REVDescription("SandwichTest2", "SW2", "ipfs://sandwich2", "SWT_SALT_2");
        (REVNET_ID,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: cfg,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: sdc,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        vm.deal(BORROWER, 100 ether);
        vm.deal(OTHER_PAYER, 100 ether);
    }

    /// @notice Helper: grant BURN_TOKENS permission to the loans contract for a given account and revnet.
    function _grantBurnPermission(address account, uint256 revnetId) internal {
        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = JBPermissionIds.BURN_TOKENS;

        JBPermissionsData memory permissionsData = JBPermissionsData({
            // forge-lint: disable-next-line(unsafe-typecast)
            operator: address(LOANS_CONTRACT),
            // forge-lint: disable-next-line(unsafe-typecast)
            projectId: uint56(revnetId),
            permissionIds: permissionIds
        });

        vm.prank(account);
        jbPermissions().setPermissionsFor(account, permissionsData);
    }

    /// @notice BY DESIGN: A borrower can extract additional value by reallocating collateral immediately after
    /// a stage transition that lowers the cashOutTaxRate.
    ///
    /// The sandwich works as follows:
    /// 1. Borrower takes a loan in Stage 1 (60% cashOutTaxRate) — collateral is locked at Stage 1's rate
    /// 2. Time warps past the stage boundary to Stage 2 (20% cashOutTaxRate)
    /// 3. At Stage 2 rates, the same collateral is worth MORE on the bonding curve, so LESS collateral is
    ///    needed to support the original loan amount. The borrower frees the excess collateral.
    /// 4. The freed collateral is used to open a NEW loan at Stage 2 rates — extracting additional funds.
    /// 5. The borrower now holds TWO loans: the original (with reduced collateral) and a new one (with the
    ///    freed collateral). The total borrowed across both loans exceeds what was possible at Stage 1.
    ///
    /// This is intentional: stage boundaries are immutable and predictable, and loan value tracks
    /// the current bonding curve parameters. See RISKS.md section 3.
    function test_reallocationSandwich_extractsValueAtStageBoundary() public {
        // -- Step 1: Create liquidity from another payer so the bonding curve tax rate has a visible effect.
        vm.prank(OTHER_PAYER);
        jbMultiTerminal().pay{value: 10 ether}({
            projectId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            beneficiary: OTHER_PAYER,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        // -- Step 2: Borrower pays in and receives tokens during Stage 1.
        vm.prank(BORROWER);
        uint256 borrowerTokens = jbMultiTerminal().pay{value: 10 ether}({
            projectId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            beneficiary: BORROWER,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
        assertGt(borrowerTokens, 0, "Borrower should receive tokens");

        // -- Step 3: Grant BURN_TOKENS permission and take a loan during Stage 1.
        _grantBurnPermission(BORROWER, REVNET_ID);

        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        // Use the minimum prepaid fee (2.5%) so fees don't obscure the comparison.
        uint256 prepaidFeePercent = LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT();

        vm.prank(BORROWER);
        (uint256 stage1LoanId, REVLoan memory stage1Loan) = LOANS_CONTRACT.borrowFrom({
            revnetId: REVNET_ID,
            source: source,
            minBorrowAmount: 0,
            collateralCount: borrowerTokens,
            beneficiary: payable(BORROWER),
            prepaidFeePercent: prepaidFeePercent
        });

        uint256 stage1BorrowedAmount = stage1Loan.amount;
        uint256 stage1Collateral = stage1Loan.collateral;
        assertGt(stage1BorrowedAmount, 0, "Stage 1 loan should have positive borrowed amount");
        assertEq(stage1Collateral, borrowerTokens, "All tokens should be collateral");

        // Record the borrowable amount for the same collateral count at Stage 1 rates (for comparison).
        uint256 borrowableStage1 = LOANS_CONTRACT.borrowableAmountFrom(
            REVNET_ID, borrowerTokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );

        // -- Step 4: Warp past the stage boundary to Stage 2 (lower cashOutTaxRate).
        vm.warp(block.timestamp + 31 days);

        // Verify borrowable amount increased at Stage 2 rates.
        uint256 borrowableStage2 = LOANS_CONTRACT.borrowableAmountFrom(
            REVNET_ID, borrowerTokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        assertGt(borrowableStage2, borrowableStage1, "Borrowable should increase with lower cashOutTaxRate");

        // -- Step 5: Determine how much collateral can be freed.
        // At Stage 2's lower cashOutTaxRate, less collateral is needed to support the original loan amount.
        // Use binary search to find the maximum transferable collateral: the largest amount that can be
        // removed while leaving enough for the remaining collateral to cover the original loan amount.
        uint256 collateralToTransfer;
        {
            uint256 lo = 0;
            uint256 hi = stage1Collateral;
            uint256 currency = uint32(uint160(JBConstants.NATIVE_TOKEN));
            while (lo < hi) {
                uint256 mid = (lo + hi + 1) / 2;
                uint256 remaining = stage1Collateral - mid;
                uint256 borrowable = LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, remaining, 18, currency);
                if (borrowable >= stage1BorrowedAmount) {
                    lo = mid;
                } else {
                    hi = mid - 1;
                }
            }
            collateralToTransfer = lo;
        }
        assertGt(collateralToTransfer, 0, "Should be able to free some collateral after tax rate decrease");

        // Verify that the remaining collateral at Stage 2 rates supports the original loan amount.
        uint256 borrowableWithRemaining = LOANS_CONTRACT.borrowableAmountFrom(
            REVNET_ID, stage1Collateral - collateralToTransfer, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        assertGe(
            borrowableWithRemaining,
            stage1BorrowedAmount,
            "Remaining collateral should cover original loan at Stage 2 rates"
        );

        // -- Step 6: Borrower reallocates collateral from the Stage 1 loan to extract the increased value.
        // Transfer half the collateral from the old loan. The remaining half still covers the original
        // loan amount at Stage 2's improved rates. The freed collateral goes into a new loan.
        vm.prank(BORROWER);
        (
            , // reallocatedLoanId
            , // newLoanId
            REVLoan memory reallocatedLoan,
            REVLoan memory newLoan
        ) = LOANS_CONTRACT.reallocateCollateralFromLoan({
            loanId: stage1LoanId,
            collateralCountToTransfer: collateralToTransfer,
            source: source,
            minBorrowAmount: 0,
            collateralCountToAdd: 0,
            beneficiary: payable(BORROWER),
            prepaidFeePercent: prepaidFeePercent
        });

        // -- Step 7: Verify the sandwich extracted additional value.

        // The reallocated loan retains the original borrowed amount with reduced collateral.
        assertEq(reallocatedLoan.amount, stage1BorrowedAmount, "Reallocated loan should keep original amount");
        assertEq(
            reallocatedLoan.collateral,
            stage1Collateral - collateralToTransfer,
            "Reallocated loan should have reduced collateral"
        );

        // The new loan was created from the freed collateral at Stage 2 rates.
        uint256 newBorrowedAmount = newLoan.amount;
        assertGt(newBorrowedAmount, 0, "New loan should have positive borrowed amount");
        assertEq(newLoan.collateral, collateralToTransfer, "New loan should hold the transferred collateral");

        // The total borrowed across both loans exceeds the original Stage 1 borrowed amount.
        // This is the sandwich profit: the borrower extracted additional value from the same total collateral.
        uint256 totalBorrowedAfterSandwich = uint256(reallocatedLoan.amount) + uint256(newLoan.amount);
        assertGt(
            totalBorrowedAfterSandwich,
            stage1BorrowedAmount,
            "Total borrowed after sandwich should exceed original Stage 1 amount"
        );

        // Quantify the extracted delta.
        uint256 extractedDelta = totalBorrowedAfterSandwich - stage1BorrowedAmount;
        assertGt(extractedDelta, 0, "Extracted delta should be positive");

        // Log the sandwich economics for visibility.
        emit log_named_uint("Stage 1 borrowed amount", stage1BorrowedAmount);
        emit log_named_uint("Reallocated loan amount (unchanged)", reallocatedLoan.amount);
        emit log_named_uint("New loan amount (from freed collateral)", newBorrowedAmount);
        emit log_named_uint("Total borrowed after sandwich", totalBorrowedAfterSandwich);
        emit log_named_uint("Extracted delta (sandwich profit)", extractedDelta);
        emit log_named_uint("Borrowable at Stage 1 rates (full collateral)", borrowableStage1);
        emit log_named_uint("Borrowable at Stage 2 rates (full collateral)", borrowableStage2);
    }
}
