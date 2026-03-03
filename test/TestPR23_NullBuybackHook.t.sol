// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import /* {*} from */ "@bananapus/core-v5/test/helpers/TestBaseWorkflow.sol";
import /* {*} from "@bananapus/721-hook-v5/src/JB721TiersHookDeployer.sol";
    import /* {*} from */ "./../src/REVDeployer.sol";
import "@croptop/core-v5/src/CTPublisher.sol";
import "@bananapus/core-v5/script/helpers/CoreDeploymentLib.sol";
import "@bananapus/721-hook-v5/script/helpers/Hook721DeploymentLib.sol";
import "@bananapus/suckers-v5/script/helpers/SuckerDeploymentLib.sol";
import "@croptop/core-v5/script/helpers/CroptopDeploymentLib.sol";
import "@bananapus/swap-terminal-v5/script/helpers/SwapTerminalDeploymentLib.sol";
import "@bananapus/buyback-hook-v5/script/helpers/BuybackDeploymentLib.sol";
import {JBConstants} from "@bananapus/core-v5/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v5/src/structs/JBAccountingContext.sol";
import {REVLoans} from "../src/REVLoans.sol";
import {REVStageConfig, REVAutoIssuance} from "../src/structs/REVStageConfig.sol";
import {REVLoanSource} from "../src/structs/REVLoanSource.sol";
import {REVDescription} from "../src/structs/REVDescription.sol";
import {REVBuybackPoolConfig} from "../src/structs/REVBuybackPoolConfig.sol";
import {IREVLoans} from "./../src/interfaces/IREVLoans.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v5/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v5/src/JBSuckerRegistry.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v5/src/JB721TiersHookDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v5/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v5/src/JB721TiersHookStore.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v5/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v5/src/interfaces/IJBAddressRegistry.sol";
import {JBRuleset} from "@bananapus/core-v5/src/structs/JBRuleset.sol";

/// @notice Tests for PR #23: fix/c4-null-buyback-hook
/// Verifies that `hasMintPermissionFor` does not revert when buybackHookOf is address(0).
/// The bug: `buybackHook.hasMintPermissionFor(...)` would call address(0), causing a revert.
/// The fix: guards with `address(buybackHook) != address(0) &&` before calling the method.
contract TestPR23_NullBuybackHook is TestBaseWorkflow, JBTest {
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";

    REVDeployer REV_DEPLOYER;
    JB721TiersHook EXAMPLE_HOOK;
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    IJB721TiersHookStore HOOK_STORE;
    IJBAddressRegistry ADDRESS_REGISTRY;
    IREVLoans LOANS_CONTRACT;
    IJBSuckerRegistry SUCKER_REGISTRY;
    CTPublisher PUBLISHER;

    uint256 FEE_PROJECT_ID;
    uint256 TEST_REVNET_ID;

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;
    address USER = makeAddr("user");

    function setUp() public override {
        super.setUp();
        FEE_PROJECT_ID = jbProjects().createFor(multisig());
        SUCKER_REGISTRY = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig(), address(0));
        HOOK_STORE = new JB721TiersHookStore();
        EXAMPLE_HOOK = new JB721TiersHook(jbDirectory(), jbPermissions(), jbRulesets(), HOOK_STORE, multisig());
        ADDRESS_REGISTRY = new JBAddressRegistry();
        HOOK_DEPLOYER = new JB721TiersHookDeployer(EXAMPLE_HOOK, HOOK_STORE, ADDRESS_REGISTRY, multisig());
        PUBLISHER = new CTPublisher(jbDirectory(), jbPermissions(), FEE_PROJECT_ID, multisig());
        REV_DEPLOYER = new REVDeployer{salt: REV_DEPLOYER_SALT}(
            jbController(), SUCKER_REGISTRY, FEE_PROJECT_ID, HOOK_DEPLOYER, PUBLISHER, TRUSTED_FORWARDER
        );
        LOANS_CONTRACT = new REVLoans({
            revnets: REV_DEPLOYER,
            revId: FEE_PROJECT_ID,
            owner: address(this),
            permit2: permit2(),
            trustedForwarder: TRUSTED_FORWARDER
        });
        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);

        // Deploy the fee project as a revnet
        (
            REVConfig memory feeCfg,
            JBTerminalConfig[] memory feeTc,
            REVBuybackHookConfig memory feeBbh,
            REVSuckerDeploymentConfig memory feeSdc
        ) = _buildConfig(address(0), "FeeProject", "FEE", "FEE_SALT");

        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeCfg,
            terminalConfigurations: feeTc,
            buybackHookConfiguration: feeBbh,
            suckerDeploymentConfiguration: feeSdc
        });
    }

    function _buildConfig(
        address loans,
        string memory name,
        string memory ticker,
        bytes32 salt
    )
        internal
        view
        returns (
            REVConfig memory cfg,
            JBTerminalConfig[] memory tc,
            REVBuybackHookConfig memory bbh,
            REVSuckerDeploymentConfig memory sdc
        )
    {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});

        REVStageConfig[] memory stages = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;
        stages[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 5000,
            extraMetadata: 0
        });

        cfg = REVConfig({
            description: REVDescription(name, ticker, "ipfs://test", salt),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages,
            loanSources: new REVLoanSource[](0),
            loans: loans
        });

        bbh = REVBuybackHookConfig({
            dataHook: IJBRulesetDataHook(address(0)),
            hookToConfigure: IJBBuybackHook(address(0)),
            poolConfigurations: new REVBuybackPoolConfig[](0)
        });

        sdc = REVSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0),
            salt: keccak256(abi.encodePacked("TEST"))
        });
    }

    /// @notice Deploy a test revnet and return its ID.
    function _deployTestRevnet(address loans) internal returns (uint256 revnetId) {
        (
            REVConfig memory cfg,
            JBTerminalConfig[] memory tc,
            REVBuybackHookConfig memory bbh,
            REVSuckerDeploymentConfig memory sdc
        ) = _buildConfig(loans, "TestRevnet", "TST", "TST_SALT");

        revnetId = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: cfg,
            terminalConfigurations: tc,
            buybackHookConfiguration: bbh,
            suckerDeploymentConfiguration: sdc
        });
    }

    /// @notice hasMintPermissionFor should return false (not revert) when no buyback hook is configured.
    /// Before the fix, this would revert because it tried to call hasMintPermissionFor on address(0).
    function test_hasMintPermission_noBuybackHook_doesNotRevert() public {
        uint256 revnetId = _deployTestRevnet(address(0));

        // Verify no buyback hook is set
        assertEq(
            address(REV_DEPLOYER.buybackHookOf(revnetId)),
            address(0),
            "Buyback hook should be address(0)"
        );

        // Get the current ruleset
        (JBRuleset memory ruleset,) = jbController().currentRulesetOf(revnetId);

        // This should NOT revert with the fix, but would revert before the fix
        bool result = REV_DEPLOYER.hasMintPermissionFor(revnetId, ruleset, makeAddr("random"));
        assertFalse(result, "Random address should not have mint permission");
    }

    /// @notice hasMintPermissionFor should return true when the loans contract is set and queried.
    function test_hasMintPermission_loansContract_returnsTrue() public {
        uint256 revnetId = _deployTestRevnet(address(LOANS_CONTRACT));

        // Verify loans contract is stored
        assertEq(
            REV_DEPLOYER.loansOf(revnetId),
            address(LOANS_CONTRACT),
            "Loans contract should be set"
        );

        // Get the current ruleset
        (JBRuleset memory ruleset,) = jbController().currentRulesetOf(revnetId);

        // Loans contract should have mint permission
        bool result = REV_DEPLOYER.hasMintPermissionFor(revnetId, ruleset, address(LOANS_CONTRACT));
        assertTrue(result, "Loans contract should have mint permission");
    }

    /// @notice hasMintPermissionFor should return false for a random address.
    function test_hasMintPermission_randomAddress_returnsFalse() public {
        uint256 revnetId = _deployTestRevnet(address(0));

        // Get the current ruleset
        (JBRuleset memory ruleset,) = jbController().currentRulesetOf(revnetId);

        address randomAddr = makeAddr("totallyRandom");
        bool result = REV_DEPLOYER.hasMintPermissionFor(revnetId, ruleset, randomAddr);
        assertFalse(result, "Random address should not have mint permission");
    }
}
