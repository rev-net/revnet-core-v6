// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "./../../src/REVDeployer.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@croptop/core-v6/src/CTPublisher.sol";

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBDirectory} from "@bananapus/core-v6/src/JBDirectory.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/JB721CheckpointsDeployer.sol";
import {IJB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721CheckpointsDeployer.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";

import {REVLoans} from "../../src/REVLoans.sol";
import {REVOwner} from "../../src/REVOwner.sol";
import {REVStageConfig, REVAutoIssuance} from "../../src/structs/REVStageConfig.sol";
import {REVDescription} from "../../src/structs/REVDescription.sol";
import {REVConfig} from "../../src/structs/REVConfig.sol";
import {REVSuckerDeploymentConfig} from "../../src/structs/REVSuckerDeploymentConfig.sol";
import {REVDeploy721TiersHookConfig} from "../../src/structs/REVDeploy721TiersHookConfig.sol";
import {REVCroptopAllowedPost} from "../../src/structs/REVCroptopAllowedPost.sol";
import {IREVDeployer} from "../../src/interfaces/IREVDeployer.sol";
import {IREVLoans} from "../../src/interfaces/IREVLoans.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {REVEmpty721Config} from "../helpers/REVEmpty721Config.sol";
import {MockBuybackDataHook} from "../mock/MockBuybackDataHook.sol";
import {MockSuckerRegistry} from "../mock/MockSuckerRegistry.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

/// @notice The PR removed the `hasDistinctRouterTerminalRegistry` dedup branch from `_makeTerminalConfigurations`.
/// @dev If a deploy script configures `routerTerminalRegistry == multiTerminal`, the deployer's first project launch
/// must revert. This test locks that contract; if the JBDirectory dedup behavior ever changes (or if the deployer
/// re-introduces a dedup branch), this test will break loudly.
contract SameAddressDeployerLaunchReverts is TestBaseWorkflow {
    bytes32 private constant _REV_DEPLOYER_SALT = "SameAddrTest";
    address private constant _TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    REVDeployer internal REV_DEPLOYER;
    REVOwner internal REV_OWNER;
    IREVLoans internal LOANS_CONTRACT;
    JBSuckerRegistry internal SUCKER_REGISTRY;
    CTPublisher internal PUBLISHER;
    JB721TiersHookDeployer internal HOOK_DEPLOYER;
    MockBuybackDataHook internal MOCK_BUYBACK;
    uint256 internal FEE_PROJECT_ID;

    function setUp() public override {
        super.setUp();
        FEE_PROJECT_ID = jbProjects().createFor(multisig());
        SUCKER_REGISTRY = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig(), address(0));
        JB721TiersHookStore hookStore = new JB721TiersHookStore();
        JB721TiersHook exampleHook = new JB721TiersHook(
            jbDirectory(),
            jbPermissions(),
            jbPrices(),
            jbRulesets(),
            hookStore,
            jbSplits(),
            IJB721CheckpointsDeployer(address(new JB721CheckpointsDeployer(hookStore))),
            multisig()
        );
        IJBAddressRegistry addressRegistry = new JBAddressRegistry();
        HOOK_DEPLOYER = new JB721TiersHookDeployer(exampleHook, hookStore, addressRegistry, multisig());
        PUBLISHER = new CTPublisher({
            directory: jbDirectory(),
            permissions: jbPermissions(),
            feeProjectId: FEE_PROJECT_ID,
            permit2: IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3),
            trustedForwarder: multisig()
        });
        MOCK_BUYBACK = new MockBuybackDataHook();

        LOANS_CONTRACT = new REVLoans({
            controller: jbController(),
            terminal: jbMultiTerminal(),
            suckerRegistry: SUCKER_REGISTRY,
            revId: FEE_PROJECT_ID,
            owner: address(this),
            permit2: permit2(),
            trustedForwarder: _TRUSTED_FORWARDER
        });
        REV_OWNER = new REVOwner(
            IJBBuybackHookRegistry(address(MOCK_BUYBACK)),
            jbDirectory(),
            FEE_PROJECT_ID,
            SUCKER_REGISTRY,
            LOANS_CONTRACT,
            address(this)
        );

        // Deliberately pass `jbMultiTerminal()` for BOTH `multiTerminal` and `routerTerminalRegistry`.
        // This is the misconfiguration we want to prove fails loudly.
        REV_DEPLOYER = new REVDeployer{salt: _REV_DEPLOYER_SALT}(
            jbController(),
            jbMultiTerminal(),
            IJBTerminal(address(jbMultiTerminal())),
            SUCKER_REGISTRY,
            FEE_PROJECT_ID,
            HOOK_DEPLOYER,
            PUBLISHER,
            IJBBuybackHookRegistry(address(MOCK_BUYBACK)),
            LOANS_CONTRACT,
            _TRUSTED_FORWARDER,
            address(REV_OWNER)
        );
        REV_OWNER.setDeployer(REV_DEPLOYER);

        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);
    }

    /// @notice Misconfigured deployer (same address in both terminal slots) must revert at first project launch
    /// because the directory rejects duplicate terminals in `setTerminalsOf`.
    function test_sameAddressDeployer_revertsAtFirstLaunch() public {
        REVStageConfig[] memory stages = new REVStageConfig[](1);
        stages[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp + 1),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: new JBSplit[](0),
            initialIssuance: 1000e18,
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 5000,
            extraMetadata: 0
        });

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        REVConfig memory config = REVConfig({
            description: REVDescription({name: "Same", ticker: "SAME", uri: "ipfs://x", salt: bytes32(uint256(1))}),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            operator: address(this),
            scopeCashOutsToLocalBalances: false,
            stageConfigurations: stages
        });

        // Directory rejects duplicate terminals; `setTerminalsOf` reverts with the specific selector mid-launch.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBDirectory.JBDirectory_DuplicateTerminals.selector, IJBTerminal(address(jbMultiTerminal()))
            )
        );
        REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: config,
            accountingContextsToAccept: contexts,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32(uint256(1))
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }
}
