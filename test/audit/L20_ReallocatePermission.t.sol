// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "../../src/REVDeployer.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@croptop/core-v6/src/CTPublisher.sol";
import {MockBuybackDataHook} from "../mock/MockBuybackDataHook.sol";
import {REVEmpty721Config} from "../helpers/REVEmpty721Config.sol";
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
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
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
import {JB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/JB721CheckpointsDeployer.sol";
import {IJB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721CheckpointsDeployer.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {REVOwner} from "../../src/REVOwner.sol";
import {IREVDeployer} from "../../src/interfaces/IREVDeployer.sol";
import {MockSuckerRegistry} from "../mock/MockSuckerRegistry.sol";

/// @notice L-20: Verify that reallocateCollateralFromLoan works with only REALLOCATE_LOAN permission,
/// without requiring OPEN_LOAN. Also verify that borrowFrom still requires OPEN_LOAN (regression).
contract L20_ReallocatePermissionTest is TestBaseWorkflow {
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
    address HOLDER = makeAddr("holder");
    // forge-lint: disable-next-line(mixed-case-variable)
    address OPERATOR = makeAddr("operator");

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

        vm.deal(HOLDER, 1000 ether);
        vm.deal(OPERATOR, 100 ether);
    }

    function _deployFeeProject() internal {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
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
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
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

    /// @notice Helper: Grant a specific permission to an operator for HOLDER on REVNET_ID using real JBPermissions.
    function _grantPermission(address operator, uint256 permissionId) internal {
        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = uint8(permissionId);
        vm.prank(HOLDER);
        jbPermissions()
            .setPermissionsFor({
            account: HOLDER,
            permissionsData: JBPermissionsData({
            operator: operator, projectId: uint64(REVNET_ID), permissionIds: permissionIds
        })
        });
    }

    /// @notice Helper: create an initial loan for the HOLDER.
    function _createInitialLoan() internal returns (uint256 loanId, uint256 tokenCount) {
        // HOLDER pays into the revnet to get tokens.
        vm.prank(HOLDER);
        tokenCount =
            jbMultiTerminal().pay{value: 10 ether}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10 ether, HOLDER, 0, "", "");

        // Grant LOANS_CONTRACT the BURN_TOKENS permission so it can burn HOLDER's tokens as collateral.
        _grantPermission(address(LOANS_CONTRACT), JBPermissionIds.BURN_TOKENS);

        // HOLDER calls borrowFrom directly (sender == holder, so OPEN_LOAN check is short-circuited).
        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        vm.prank(HOLDER);
        (loanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(HOLDER), 25, HOLDER);
    }

    /// @notice After fix: an operator with only REALLOCATE_LOAN permission can reallocate.
    /// @dev Before the fix, this would revert because the inner borrowFrom call required OPEN_LOAN.
    function test_L20_reallocate_succeeds_with_only_REALLOCATE_LOAN_permission() public {
        (uint256 loanId,) = _createInitialLoan();
        require(loanId != 0, "Loan setup failed");

        // Donate to inflate surplus so collateral reallocation is meaningful.
        address donor = makeAddr("donor");
        vm.deal(donor, 500 ether);
        vm.prank(donor);
        jbMultiTerminal().addToBalanceOf{value: 500 ether}(
            REVNET_ID, JBConstants.NATIVE_TOKEN, 500 ether, false, "", ""
        );

        // HOLDER pays more to get extra tokens for the new loan's additional collateral.
        vm.prank(HOLDER);
        uint256 extraTokens =
            jbMultiTerminal().pay{value: 50 ether}(REVNET_ID, JBConstants.NATIVE_TOKEN, 50 ether, HOLDER, 0, "", "");

        // Get the loan's collateral count.
        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);
        uint256 collateralToTransfer = loan.collateral / 10;

        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        // Grant OPERATOR only REALLOCATE_LOAN permission (NOT OPEN_LOAN).
        _grantPermission(OPERATOR, JBPermissionIds.REALLOCATE_LOAN);

        // This should succeed: OPERATOR has REALLOCATE_LOAN, and _borrowFrom skips OPEN_LOAN check.
        vm.prank(OPERATOR);
        (uint256 reallocatedLoanId, uint256 newLoanId,,) = LOANS_CONTRACT.reallocateCollateralFromLoan(
            loanId,
            collateralToTransfer,
            source,
            0, // minBorrowAmount
            extraTokens,
            payable(HOLDER),
            25 // prepaidFeePercent
        );

        // Verify both loans were created.
        assertTrue(reallocatedLoanId != 0, "Reallocated loan should exist");
        assertTrue(newLoanId != 0, "New loan should exist");
    }

    /// @notice Regression: borrowFrom still requires OPEN_LOAN permission.
    /// @dev An operator with only REALLOCATE_LOAN should NOT be able to call borrowFrom directly.
    function test_L20_borrowFrom_still_requires_OPEN_LOAN() public {
        // HOLDER pays into the revnet.
        vm.prank(HOLDER);
        uint256 tokenCount =
            jbMultiTerminal().pay{value: 10 ether}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10 ether, HOLDER, 0, "", "");

        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        // OPERATOR does NOT have OPEN_LOAN permission (no permission granted at all).
        vm.prank(OPERATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                HOLDER, // account
                OPERATOR, // sender
                REVNET_ID, // projectId
                JBPermissionIds.OPEN_LOAN // permissionId
            )
        );
        LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(HOLDER), 25, HOLDER);
    }

    /// @notice Verify that borrowFrom succeeds when the caller has OPEN_LOAN permission.
    function test_L20_borrowFrom_succeeds_with_OPEN_LOAN() public {
        // HOLDER pays into the revnet.
        vm.prank(HOLDER);
        uint256 tokenCount =
            jbMultiTerminal().pay{value: 10 ether}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10 ether, HOLDER, 0, "", "");

        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        // Grant OPERATOR the OPEN_LOAN permission.
        _grantPermission(OPERATOR, JBPermissionIds.OPEN_LOAN);
        // Grant LOANS_CONTRACT the BURN_TOKENS permission so it can burn tokens for collateral.
        _grantPermission(address(LOANS_CONTRACT), JBPermissionIds.BURN_TOKENS);

        vm.prank(OPERATOR);
        (uint256 loanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(HOLDER), 25, HOLDER);
        assertTrue(loanId != 0, "Loan should be created successfully");
    }
}
