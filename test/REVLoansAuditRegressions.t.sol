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
import {REVLoan} from "../src/structs/REVLoan.sol";
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
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

/// @notice A fake terminal that tracks whether useAllowanceOf was called.
/// @dev Used to prove H-6: REVLoans.borrowFrom does not validate source terminal registration.
contract FakeTerminal is ERC165, IJBPayoutTerminal {
    bool public useAllowanceCalled;
    uint256 public lastProjectId;

    function useAllowanceOf(
        uint256 projectId,
        address,
        uint256,
        uint256,
        uint256,
        address payable,
        address payable,
        string calldata
    )
        external
        override
        returns (uint256)
    {
        useAllowanceCalled = true;
        lastProjectId = projectId;
        // Return 0 - no actual funds sent
        return 0;
    }

    function accountingContextForTokenOf(uint256, address) external pure override returns (JBAccountingContext memory) {
        return JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
    }

    // Stub implementations for IJBTerminal
    function accountingContextsOf(uint256) external pure override returns (JBAccountingContext[] memory) {
        return new JBAccountingContext[](0);
    }

    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override {}

    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable override {}

    function currentSurplusOf(uint256, JBAccountingContext[] memory, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256) {
        return 0;
    }

    function pay(uint256, address, uint256, address, uint256, string calldata, bytes calldata) external payable override returns (uint256) {
        return 0;
    }

    function sendPayoutsOf(uint256, address, uint256, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId
            || interfaceId == type(IJBPayoutTerminal).interfaceId
            || super.supportsInterface(interfaceId);
    }
}

/// @notice Audit regression tests for REVLoans finding H-6: Unvalidated Source Terminal.
contract REVLoansAuditRegressions_Local is TestBaseWorkflow, JBTest {
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";
    bytes32 ERC20_SALT = "REV_TOKEN";

    REVDeployer REV_DEPLOYER;
    JB721TiersHook EXAMPLE_HOOK;
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    IJB721TiersHookStore HOOK_STORE;
    IJBAddressRegistry ADDRESS_REGISTRY;
    IREVLoans LOANS_CONTRACT;
    IJBSuckerRegistry SUCKER_REGISTRY;
    CTPublisher PUBLISHER;

    uint256 FEE_PROJECT_ID;
    uint256 REVNET_ID;

    address USER = makeAddr("user");

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

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

        // Deploy a revnet with loans enabled
        _deployRevnet();

        // Give user ETH
        vm.deal(USER, 100e18);
    }

    function _deployRevnet() internal {
        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        stageConfigurations[0] = REVStageConfig({
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

        // Configure loan sources to include the real terminal
        REVLoanSource[] memory loanSources = new REVLoanSource[](1);
        loanSources[0] = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: IJBPayoutTerminal(address(jbMultiTerminal()))});

        REVConfig memory revnetConfiguration = REVConfig({
            description: REVDescription("H6Test", "H6T", "ipfs://h6test", "H6_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations,
            loanSources: loanSources,
            loans: address(LOANS_CONTRACT)
        });

        REVBuybackHookConfig memory buybackHookConfiguration = REVBuybackHookConfig({
            dataHook: IJBRulesetDataHook(address(0)),
            hookToConfigure: IJBBuybackHook(address(0)),
            poolConfigurations: new REVBuybackPoolConfig[](0)
        });

        REVDeploy721TiersHookConfig memory empty721Config;
        vm.prank(multisig());
        (REVNET_ID, ) = REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            buybackHookConfiguration: buybackHookConfiguration,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0),
                salt: keccak256("H6_TEST")
            }),
            tiered721HookConfiguration: empty721Config,
            allowedPosts: new REVCroptopAllowedPost[](0)
        });
    }

    //*********************************************************************//
    // --- [H-6] Unvalidated Source Terminal in REVLoans ---------------- //
    //*********************************************************************//

    /// @notice Demonstrates H-6: borrowFrom accepts any terminal without validating
    ///         it is registered in the JBDirectory for the project.
    /// @dev The fake terminal's useAllowanceOf is called, proving no directory check occurs.
    ///      In production, a malicious terminal could return fake amounts or misroute funds.
    function test_H6_unvalidatedSourceTerminal() public {
        // Step 1: User pays into the revnet to get tokens (collateral)
        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: 1e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, USER, 0, "", "");
        assertGt(tokens, 0, "user should receive tokens");

        // Step 2: Create a fake terminal NOT registered in the directory
        FakeTerminal fakeTerminal = new FakeTerminal();

        // Verify the fake terminal is NOT in the directory
        IJBTerminal[] memory registeredTerminals = jbDirectory().terminalsOf(REVNET_ID);
        bool found = false;
        for (uint256 i = 0; i < registeredTerminals.length; i++) {
            if (address(registeredTerminals[i]) == address(fakeTerminal)) {
                found = true;
            }
        }
        assertFalse(found, "fake terminal should NOT be in the directory");

        // Step 3: Try to borrow using the fake terminal as the source
        // H-6 vulnerability: REVLoans.borrowFrom does NOT check if the terminal
        // is registered in the directory before calling useAllowanceOf on it.
        REVLoanSource memory fakeSource = REVLoanSource({
            token: JBConstants.NATIVE_TOKEN,
            terminal: IJBPayoutTerminal(address(fakeTerminal))
        });

        uint256 borrowable = LOANS_CONTRACT.borrowableAmountFrom(
            REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        assertGt(borrowable, 0, "should have borrowable amount");

        // H-6 PROOF: Use vm.expectCall to prove the fake terminal's useAllowanceOf
        // is called. This works even if the outer call reverts, because expectCall
        // records the call was made regardless.
        // The code calls accountingContextForTokenOf first, then useAllowanceOf.
        vm.expectCall(
            address(fakeTerminal),
            abi.encodeWithSelector(IJBTerminal.accountingContextForTokenOf.selector, REVNET_ID, JBConstants.NATIVE_TOKEN)
        );
        vm.expectCall(
            address(fakeTerminal),
            abi.encodeWithSelector(IJBPayoutTerminal.useAllowanceOf.selector)
        );

        // The borrow will reach the fake terminal (proving no validation),
        // but will revert downstream when trying to transfer 0 - fees (underflow).
        vm.prank(USER);
        vm.expectRevert();
        LOANS_CONTRACT.borrowFrom(REVNET_ID, fakeSource, borrowable, tokens, payable(USER), 500);

        // If we reach here, both vm.expectCall checks passed:
        // 1. accountingContextForTokenOf was called on the fake terminal
        // 2. useAllowanceOf was called on the fake terminal
        // This proves H-6: no directory validation before calling the source terminal
    }

    /// @notice Verify that the configured loan source (real terminal) is properly registered.
    function test_H6_configuredSourceIsRegistered() public {
        // The real terminal should be in the directory
        IJBTerminal[] memory terminals = jbDirectory().terminalsOf(REVNET_ID);
        bool found = false;
        for (uint256 i = 0; i < terminals.length; i++) {
            if (address(terminals[i]) == address(jbMultiTerminal())) {
                found = true;
            }
        }
        assertTrue(found, "real terminal should be in the directory");
    }
}
