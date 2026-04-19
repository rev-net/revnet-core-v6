// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
import "@bananapus/721-hook-v6/script/helpers/Hook721DeploymentLib.sol";
import "@bananapus/suckers-v6/script/helpers/SuckerDeploymentLib.sol";
import "@croptop/core-v6/script/helpers/CroptopDeploymentLib.sol";
import "@bananapus/router-terminal-v6/script/helpers/RouterTerminalDeploymentLib.sol";
import "@croptop/core-v6/src/CTPublisher.sol";
import "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import "@bananapus/721-hook-v6/src/JB721CheckpointsDeployer.sol";
import {IJB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721CheckpointsDeployer.sol";
import "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import "@bananapus/core-v6/src/libraries/JBConstants.sol";
import "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import "@bananapus/core-v6/src/structs/JBSplit.sol";
import "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";

import {MockBuybackDataHook} from "../mock/MockBuybackDataHook.sol";
import {REVEmpty721Config} from "../helpers/REVEmpty721Config.sol";
import {REVDeployer} from "../../src/REVDeployer.sol";
import {REVHiddenTokens} from "../../src/REVHiddenTokens.sol";
import {REVLoans} from "../../src/REVLoans.sol";
import {REVOwner} from "../../src/REVOwner.sol";
import {IREVLoans} from "../../src/interfaces/IREVLoans.sol";
import {IREVHiddenTokens} from "../../src/interfaces/IREVHiddenTokens.sol";
import {REVConfig} from "../../src/structs/REVConfig.sol";
import {REVDescription} from "../../src/structs/REVDescription.sol";
import {REVLoanSource} from "../../src/structs/REVLoanSource.sol";
import {REVStageConfig} from "../../src/structs/REVStageConfig.sol";
import {REVAutoIssuance} from "../../src/structs/REVAutoIssuance.sol";
import {REVSuckerDeploymentConfig} from "../../src/structs/REVSuckerDeploymentConfig.sol";
import {IREVDeployer} from "../../src/interfaces/IREVDeployer.sol";

contract NemesisOperatorDelegationTest is TestBaseWorkflow {
    bytes32 internal constant REV_DEPLOYER_SALT = "REVDeployer";
    bytes32 internal constant ERC20_SALT = "REV_TOKEN";

    address internal constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    address internal USER = makeAddr("user");
    address internal OPERATOR = makeAddr("operator");

    REVDeployer internal REV_DEPLOYER;
    REVOwner internal REV_OWNER;
    REVHiddenTokens internal HIDDEN_TOKENS;
    REVLoans internal LOANS;
    JB721TiersHook internal EXAMPLE_HOOK;
    IJB721TiersHookDeployer internal HOOK_DEPLOYER;
    IJB721TiersHookStore internal HOOK_STORE;
    IJBAddressRegistry internal ADDRESS_REGISTRY;
    IJBSuckerRegistry internal SUCKER_REGISTRY;
    CTPublisher internal PUBLISHER;
    MockBuybackDataHook internal MOCK_BUYBACK;

    uint256 internal FEE_PROJECT_ID;
    uint256 internal REVNET_ID;

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

        LOANS = new REVLoans({
            controller: jbController(),
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
            address(LOANS),
            address(HIDDEN_TOKENS)
        );
        REV_DEPLOYER = new REVDeployer{salt: REV_DEPLOYER_SALT}(
            jbController(),
            SUCKER_REGISTRY,
            FEE_PROJECT_ID,
            HOOK_DEPLOYER,
            PUBLISHER,
            IJBBuybackHookRegistry(address(MOCK_BUYBACK)),
            address(LOANS),
            TRUSTED_FORWARDER,
            address(REV_OWNER)
        );

        REV_OWNER.setDeployer(IREVDeployer(REV_DEPLOYER));

        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);

        _deployFeeProject();
        REVNET_ID = _deployRevnet();

        vm.deal(USER, 100e18);
    }

    function test_openLoanOperatorCanRedirectBorrowedFunds() public {
        uint256 userTokens = _payUserIntoRevnet(10e18);
        _grantPermission(USER, REVNET_ID, address(LOANS), JBPermissionIds.BURN_TOKENS);
        _grantPermission(USER, REVNET_ID, OPERATOR, JBPermissionIds.OPEN_LOAN);

        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        uint256 operatorBalanceBefore = OPERATOR.balance;

        vm.prank(OPERATOR);
        (uint256 loanId,) = LOANS.borrowFrom(REVNET_ID, source, 0, userTokens / 2, payable(OPERATOR), 25, USER);

        assertEq(LOANS.ownerOf(loanId), USER, "loan NFT stays with the holder");
        assertGt(OPERATOR.balance, operatorBalanceBefore, "operator receives the borrowed funds");
        assertLt(
            jbController().TOKENS().totalBalanceOf(USER, REVNET_ID),
            userTokens,
            "holder lost collateral even though proceeds were redirected"
        );
    }

    function test_revealTokensOperatorCanRedirectHiddenTokens() public {
        uint256 userTokens = _payUserIntoRevnet(10e18);
        uint256 hiddenCount = userTokens / 2;

        _grantPermission(USER, REVNET_ID, address(HIDDEN_TOKENS), JBPermissionIds.BURN_TOKENS);
        _grantPermission(USER, REVNET_ID, OPERATOR, JBPermissionIds.REVEAL_TOKENS);

        vm.prank(USER);
        HIDDEN_TOKENS.hideTokensOf(REVNET_ID, hiddenCount, USER);

        vm.prank(OPERATOR);
        HIDDEN_TOKENS.revealTokensOf(REVNET_ID, hiddenCount, OPERATOR, USER);

        assertEq(HIDDEN_TOKENS.hiddenBalanceOf(USER, REVNET_ID), 0, "holder hidden balance was consumed");
        assertEq(
            jbController().TOKENS().totalBalanceOf(OPERATOR, REVNET_ID),
            hiddenCount,
            "operator receives the holder's revealed tokens"
        );
        assertEq(
            jbController().TOKENS().totalBalanceOf(USER, REVNET_ID),
            userTokens - hiddenCount,
            "holder does not get the revealed tokens back"
        );
    }

    function _grantPermission(address account, uint256 revnetId, address operator, uint8 permissionId) internal {
        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = permissionId;

        vm.prank(account);
        jbPermissions()
            .setPermissionsFor(
                account,
                JBPermissionsData({operator: operator, projectId: uint56(revnetId), permissionIds: permissionIds})
            );
    }

    function _payUserIntoRevnet(uint256 amount) internal returns (uint256 tokenCount) {
        vm.prank(USER);
        tokenCount = jbMultiTerminal().pay{value: amount}({
            projectId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: USER,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
        assertGt(tokenCount, 0, "payment should mint revnet tokens");
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
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: new JBSplit[](0),
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 0,
            extraMetadata: 0
        });

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

    function _deployRevnet() internal returns (uint256 revnetId) {
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

        stages[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 2000,
            splits: splits,
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: 0
        });

        REVConfig memory config = REVConfig({
            description: REVDescription("Revnet", "REV", "", bytes32("REV_TOKEN_2")),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });

        (revnetId,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: config,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("REV")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }
}
