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
import {REVEmpty721Config} from "./helpers/REVEmpty721Config.sol";
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
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {MockERC20} from "@bananapus/core-v6/test/mock/MockERC20.sol";
import {REVLoans} from "../src/REVLoans.sol";
import {REVHiddenTokens} from "../src/REVHiddenTokens.sol";
import {IREVHiddenTokens} from "../src/interfaces/IREVHiddenTokens.sol";
import {REVStageConfig, REVAutoIssuance} from "../src/structs/REVStageConfig.sol";
import {REVDescription} from "../src/structs/REVDescription.sol";
import {IREVLoans} from "./../src/interfaces/IREVLoans.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/JB721CheckpointsDeployer.sol";
import {IJB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721CheckpointsDeployer.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {REVOwner} from "../src/REVOwner.sol";
import {IREVDeployer} from "../src/interfaces/IREVDeployer.sol";

/// @notice Tests for the standalone REVHiddenTokens contract.
contract TestHiddenTokens is TestBaseWorkflow {
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 ERC20_SALT = "REV_TOKEN";

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
    REVHiddenTokens HIDDEN_TOKENS;
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
    // forge-lint: disable-next-line(mixed-case-variable)
    address BENEFICIARY = makeAddr("beneficiary");

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    function setUp() public override {
        super.setUp();
        FEE_PROJECT_ID = jbProjects().createFor(multisig());
        SUCKER_REGISTRY = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig(), address(0));
        HOOK_STORE = new JB721TiersHookStore();
        EXAMPLE_HOOK = new JB721TiersHook(
            jbDirectory(), jbPermissions(), jbPrices(), jbRulesets(), HOOK_STORE, jbSplits(), IJB721CheckpointsDeployer(address(new JB721CheckpointsDeployer())), multisig()
        );
        ADDRESS_REGISTRY = new JBAddressRegistry();
        HOOK_DEPLOYER = new JB721TiersHookDeployer(EXAMPLE_HOOK, HOOK_STORE, ADDRESS_REGISTRY, multisig());
        PUBLISHER = new CTPublisher(jbDirectory(), jbPermissions(), FEE_PROJECT_ID, multisig());
        MOCK_BUYBACK = new MockBuybackDataHook();

        LOANS_CONTRACT = new REVLoans({
            controller: jbController(),
            suckerRegistry: IJBSuckerRegistry(address(0)),
            revId: FEE_PROJECT_ID,
            owner: address(this),
            permit2: permit2(),
            trustedForwarder: TRUSTED_FORWARDER
        });

        HIDDEN_TOKENS = new REVHiddenTokens(jbController(), TRUSTED_FORWARDER);

        REV_OWNER = new REVOwner(
            IJBBuybackHookRegistry(address(MOCK_BUYBACK)),
            jbDirectory(),
            FEE_PROJECT_ID,
            SUCKER_REGISTRY,
            address(LOANS_CONTRACT),
            address(HIDDEN_TOKENS)
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
        REVNET_ID = _deployRevnet();
        vm.deal(USER, 100e18);
        _grantBurnPermission(USER, REVNET_ID);
    }

    // ──────────────────── Test: Hiding reduces totalSupply
    // ────────────────────

    function test_hideTokens_reducesTotalSupply() public {
        // Pay to get tokens.
        uint256 payAmount = 10e18;
        vm.prank(USER);
        jbMultiTerminal().pay{value: payAmount}({
            projectId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: USER,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        uint256 userTokens = jbController().TOKENS().totalBalanceOf(USER, REVNET_ID);
        assertGt(userTokens, 0, "User should have tokens after paying");

        uint256 totalSupplyBefore = jbController().TOKENS().totalSupplyOf(REVNET_ID);

        // Hide half the tokens.
        uint256 hideCount = userTokens / 2;
        vm.prank(USER);
        HIDDEN_TOKENS.hideTokensOf(REVNET_ID, hideCount, USER);

        uint256 totalSupplyAfter = jbController().TOKENS().totalSupplyOf(REVNET_ID);
        assertEq(totalSupplyAfter, totalSupplyBefore - hideCount, "Total supply should decrease by hidden amount");
        assertEq(HIDDEN_TOKENS.hiddenBalanceOf(USER, REVNET_ID), hideCount, "Hidden balance should match");
        assertEq(HIDDEN_TOKENS.totalHiddenOf(REVNET_ID), hideCount, "Total hidden should match");
    }

    // ──────────────────── Test: Revealing restores tokens
    // ────────────────────

    function test_revealTokens_restoresTokens() public {
        // Pay to get tokens.
        uint256 payAmount = 10e18;
        vm.prank(USER);
        jbMultiTerminal().pay{value: payAmount}({
            projectId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: USER,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        uint256 userTokensBefore = jbController().TOKENS().totalBalanceOf(USER, REVNET_ID);
        uint256 totalSupplyBefore = jbController().TOKENS().totalSupplyOf(REVNET_ID);

        // Hide tokens.
        uint256 hideCount = userTokensBefore / 2;
        vm.prank(USER);
        HIDDEN_TOKENS.hideTokensOf(REVNET_ID, hideCount, USER);

        // Reveal tokens to beneficiary.
        vm.prank(USER);
        HIDDEN_TOKENS.revealTokensOf(REVNET_ID, hideCount, BENEFICIARY, USER);

        uint256 totalSupplyAfter = jbController().TOKENS().totalSupplyOf(REVNET_ID);
        assertEq(totalSupplyAfter, totalSupplyBefore, "Total supply should be restored");
        assertEq(HIDDEN_TOKENS.hiddenBalanceOf(USER, REVNET_ID), 0, "Hidden balance should be zero");
        assertEq(HIDDEN_TOKENS.totalHiddenOf(REVNET_ID), 0, "Total hidden should be zero");
        assertEq(
            jbController().TOKENS().totalBalanceOf(BENEFICIARY, REVNET_ID),
            hideCount,
            "Beneficiary should receive tokens"
        );
    }

    // ──────────────────── Test: Insufficient hidden balance reverts
    // ────────────────────

    function test_revealTokens_revertsOnInsufficientBalance() public {
        // Pay to get tokens.
        uint256 payAmount = 10e18;
        vm.prank(USER);
        jbMultiTerminal().pay{value: payAmount}({
            projectId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: USER,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        uint256 userTokens = jbController().TOKENS().totalBalanceOf(USER, REVNET_ID);
        uint256 hideCount = userTokens / 4;

        // Hide some tokens.
        vm.prank(USER);
        HIDDEN_TOKENS.hideTokensOf(REVNET_ID, hideCount, USER);

        // Try to reveal more than hidden — should revert.
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                REVHiddenTokens.REVHiddenTokens_InsufficientHiddenBalance.selector, hideCount, hideCount + 1
            )
        );
        HIDDEN_TOKENS.revealTokensOf(REVNET_ID, hideCount + 1, USER, USER);
    }

    // ──────────────────── Test: Hidden tokens inflate cash out rate
    // ────────────────────

    function test_hiddenTokens_inflateCashOutRate() public {
        // Pay to get tokens for 2 users.
        uint256 payAmount = 10e18;
        vm.prank(USER);
        jbMultiTerminal().pay{value: payAmount}({
            projectId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: USER,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        uint256 userTokens = jbController().TOKENS().totalBalanceOf(USER, REVNET_ID);

        // Hide half the user's tokens.
        uint256 hideCount = userTokens / 2;
        vm.prank(USER);
        HIDDEN_TOKENS.hideTokensOf(REVNET_ID, hideCount, USER);

        // The remaining tokens now represent a larger share of totalSupply.
        uint256 totalSupply = jbController().TOKENS().totalSupplyOf(REVNET_ID);
        uint256 remainingBalance = jbController().TOKENS().totalBalanceOf(USER, REVNET_ID);
        assertEq(remainingBalance, userTokens - hideCount, "Remaining balance should be half");
        assertEq(totalSupply, userTokens - hideCount, "Total supply should equal remaining balance");
    }

    // ──────────────────── Test: Events emitted correctly
    // ────────────────────

    function test_hideTokens_emitsEvent() public {
        uint256 payAmount = 10e18;
        vm.prank(USER);
        jbMultiTerminal().pay{value: payAmount}({
            projectId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: USER,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        uint256 userTokens = jbController().TOKENS().totalBalanceOf(USER, REVNET_ID);

        vm.prank(USER);
        vm.expectEmit(true, false, false, true);
        emit IREVHiddenTokens.HideTokens(REVNET_ID, userTokens, USER, USER);
        HIDDEN_TOKENS.hideTokensOf(REVNET_ID, userTokens, USER);
    }

    function test_revealTokens_emitsEvent() public {
        uint256 payAmount = 10e18;
        vm.prank(USER);
        jbMultiTerminal().pay{value: payAmount}({
            projectId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: USER,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        uint256 userTokens = jbController().TOKENS().totalBalanceOf(USER, REVNET_ID);

        vm.prank(USER);
        HIDDEN_TOKENS.hideTokensOf(REVNET_ID, userTokens, USER);

        vm.prank(USER);
        vm.expectEmit(true, false, false, true);
        emit IREVHiddenTokens.RevealTokens(REVNET_ID, userTokens, BENEFICIARY, USER, USER);
        HIDDEN_TOKENS.revealTokensOf(REVNET_ID, userTokens, BENEFICIARY, USER);
    }

    // ──────────────────── Internal helpers
    // ────────────────────

    function _grantBurnPermission(address account, uint256 revnetId) internal {
        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = JBPermissionIds.BURN_TOKENS;
        JBPermissionsData memory permissionsData = JBPermissionsData({
            operator: address(HIDDEN_TOKENS),
            // forge-lint: disable-next-line(unsafe-typecast)
            projectId: uint56(revnetId),
            permissionIds: permissionIds
        });
        vm.prank(account);
        jbPermissions().setPermissionsFor(account, permissionsData);
    }

    function _deployFeeProject() internal {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});
        REVStageConfig[] memory stages = new REVStageConfig[](1);
        stages[0] = REVStageConfig({
            startsAtOrAfter: uint48(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: new JBSplit[](0),
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 0,
            extraMetadata: 0
        });
        // forge-lint: disable-next-line(named-struct-fields)
        REVConfig memory feeConfig = REVConfig({
            description: REVDescription("Fee Revnet", "FEE", "", ERC20_SALT),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });
        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeConfig,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("FEE")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    function _deployRevnet() internal returns (uint256) {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});
        REVStageConfig[] memory stages = new REVStageConfig[](1);
        stages[0] = REVStageConfig({
            startsAtOrAfter: uint48(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: new JBSplit[](0),
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 5000, // 50% cash out tax rate
            extraMetadata: 0
        });
        // forge-lint: disable-next-line(named-struct-fields)
        REVConfig memory revConfig = REVConfig({
            description: REVDescription("Test Revnet", "TEST", "", bytes32("TEST_TOKEN")),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });
        (uint256 revnetId,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: revConfig,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("NANA")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
        return revnetId;
    }
}
