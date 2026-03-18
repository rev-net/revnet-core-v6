// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {REVEmpty721Config} from "../helpers/REVEmpty721Config.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";

/// @notice Validates that borrowFrom() reverts with a clear error when the caller hasn't granted BURN_TOKENS
/// permission to the REVLoans contract.
/// @dev Without this upfront check, the transaction would revert deep in JBController.burnTokensOf with a
/// less informative JBPermissioned_Unauthorized error.
contract TestBurnPermissionRequired is TestBaseWorkflow {
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

    address user = makeAddr("user");

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
        vm.deal(user, 100e18);
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

    /// @notice borrowFrom should revert when the caller hasn't granted BURN_TOKENS permission.
    /// @dev The controller enforces this with JBPermissioned_Unauthorized when burnTokensOf is called.
    function test_borrowFrom_revertsWithoutBurnPermission() public {
        // Pay into the revnet to get tokens.
        vm.prank(user);
        uint256 tokenCount =
            jbMultiTerminal().pay{value: 5e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 5e18, user, 0, "", "");
        require(tokenCount > 0, "Should have received tokens");

        // Attempt to borrow WITHOUT granting BURN_TOKENS permission → should revert.
        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                user, // account (the token holder)
                address(LOANS_CONTRACT), // sender (the contract trying to burn)
                REVNET_ID, // projectId
                JBPermissionIds.BURN_TOKENS // permissionId
            )
        );
        LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(user), 25);
    }

    /// @notice borrowFrom should succeed when the caller has granted BURN_TOKENS permission.
    function test_borrowFrom_succeedsWithBurnPermission() public {
        // Pay into the revnet to get tokens.
        vm.prank(user);
        uint256 tokenCount =
            jbMultiTerminal().pay{value: 5e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 5e18, user, 0, "", "");
        require(tokenCount > 0, "Should have received tokens");

        // Grant BURN_TOKENS permission to the loans contract via the real permissions system.
        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = JBPermissionIds.BURN_TOKENS;
        vm.prank(user);
        jbPermissions()
            .setPermissionsFor({
                account: user,
                permissionsData: JBPermissionsData({
                    operator: address(LOANS_CONTRACT), projectId: uint64(REVNET_ID), permissionIds: permissionIds
                })
            });

        // Borrow should now succeed.
        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        vm.prank(user);
        (uint256 loanId, REVLoan memory loan) =
            LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(user), 25);

        assertTrue(loanId > 0, "Loan ID should be non-zero");
        assertTrue(loan.createdAt > 0, "Loan should be created");
        assertTrue(loan.amount > 0, "Loan amount should be non-zero");
    }
}
