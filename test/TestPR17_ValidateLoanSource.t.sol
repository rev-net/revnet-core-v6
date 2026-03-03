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
import {MockPriceFeed} from "@bananapus/core-v5/test/mock/MockPriceFeed.sol";
import {MockERC20} from "@bananapus/core-v5/test/mock/MockERC20.sol";
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
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice A fake terminal that is NOT registered in the directory.
contract FakeTerminal is ERC165, IJBPayoutTerminal {
    bool public useAllowanceCalled;

    function pay(uint256, address, uint256, address, uint256, string calldata, bytes calldata) external payable override returns (uint256) { return 0; }
    function accountingContextForTokenOf(uint256, address) external pure override returns (JBAccountingContext memory) {
        return JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
    }
    function accountingContextsOf(uint256) external pure override returns (JBAccountingContext[] memory) { return new JBAccountingContext[](0); }
    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override {}
    function addToBalanceOf(uint256, address, uint256, bool, string calldata, bytes calldata) external payable override {}
    function currentSurplusOf(uint256, JBAccountingContext[] memory, uint256, uint256) external pure override returns (uint256) { return 100e18; }
    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256) { return 0; }
    function sendPayoutsOf(uint256, address, uint256, uint256, uint256) external pure override returns (uint256) { return 0; }
    function useAllowanceOf(uint256, address, uint256, uint256, uint256, address payable, address payable, string calldata) external override returns (uint256) {
        useAllowanceCalled = true;
        return 0;
    }
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IJBPayoutTerminal).interfaceId || super.supportsInterface(interfaceId);
    }
    receive() external payable {}
}

/// @title TestPR17_ValidateLoanSource
/// @notice Tests for PR #17 — H-6 validate loan source terminal
contract TestPR17_ValidateLoanSource is TestBaseWorkflow, JBTest {
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";

    REVDeployer REV_DEPLOYER;
    JB721TiersHook EXAMPLE_HOOK;
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    IJB721TiersHookStore HOOK_STORE;
    IJBAddressRegistry ADDRESS_REGISTRY;
    IREVLoans LOANS_CONTRACT;
    MockERC20 TOKEN;
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
        TOKEN = new MockERC20("1/2 ETH", "1/2");
        MockPriceFeed priceFeed = new MockPriceFeed(1e21, 6);
        vm.prank(multisig());
        jbPrices().addPriceFeedFor(0, uint32(uint160(address(TOKEN))), uint32(uint160(JBConstants.NATIVE_TOKEN)), priceFeed);
        REV_DEPLOYER = new REVDeployer{salt: REV_DEPLOYER_SALT}(jbController(), SUCKER_REGISTRY, FEE_PROJECT_ID, HOOK_DEPLOYER, PUBLISHER, TRUSTED_FORWARDER);
        LOANS_CONTRACT = new REVLoans({revnets: REV_DEPLOYER, revId: FEE_PROJECT_ID, owner: address(this), permit2: permit2(), trustedForwarder: TRUSTED_FORWARDER});
        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);
        _deployFeeProject();
        _deployRevnet();
        vm.deal(USER, 1000e18);
    }

    function _deployFeeProject() internal {
        JBAccountingContext[] memory acc = new JBAccountingContext[](2);
        acc[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
        acc[1] = JBAccountingContext({token: address(TOKEN), decimals: 6, currency: uint32(uint160(address(TOKEN)))});
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});
        REVStageConfig[] memory stages = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;
        REVAutoIssuance[] memory ai = new REVAutoIssuance[](1);
        ai[0] = REVAutoIssuance({chainId: uint32(block.chainid), count: uint104(70_000e18), beneficiary: multisig()});
        stages[0] = REVStageConfig({startsAtOrAfter: uint40(block.timestamp), autoIssuances: ai, splitPercent: 2000, splits: splits, initialIssuance: uint112(1000e18), issuanceCutFrequency: 90 days, issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2, cashOutTaxRate: 6000, extraMetadata: 0});
        REVConfig memory cfg = REVConfig({description: REVDescription("Revnet", "$REV", "ipfs://test", "REV_TOKEN"), baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)), splitOperator: multisig(), stageConfigurations: stages, loanSources: new REVLoanSource[](0), loans: address(0)});
        REVBuybackHookConfig memory bbh = REVBuybackHookConfig({dataHook: IJBRulesetDataHook(address(0)), hookToConfigure: IJBBuybackHook(address(0)), poolConfigurations: new REVBuybackPoolConfig[](0)});
        vm.prank(multisig());
        REV_DEPLOYER.deployFor({revnetId: FEE_PROJECT_ID, configuration: cfg, terminalConfigurations: tc, buybackHookConfiguration: bbh, suckerDeploymentConfiguration: REVSuckerDeploymentConfig({deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("FEE")})});
    }

    function _deployRevnet() internal {
        JBAccountingContext[] memory acc = new JBAccountingContext[](2);
        acc[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
        acc[1] = JBAccountingContext({token: address(TOKEN), decimals: 6, currency: uint32(uint160(address(TOKEN)))});
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});
        REVStageConfig[] memory stages = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;
        REVAutoIssuance[] memory ai = new REVAutoIssuance[](1);
        ai[0] = REVAutoIssuance({chainId: uint32(block.chainid), count: uint104(70_000e18), beneficiary: multisig()});
        stages[0] = REVStageConfig({startsAtOrAfter: uint40(block.timestamp), autoIssuances: ai, splitPercent: 2000, splits: splits, initialIssuance: uint112(1000e18), issuanceCutFrequency: 90 days, issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2, cashOutTaxRate: 6000, extraMetadata: 0});
        REVLoanSource[] memory ls = new REVLoanSource[](1);
        ls[0] = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        REVConfig memory cfg = REVConfig({description: REVDescription("NANA", "$NANA", "ipfs://test2", "NANA_TOKEN"), baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)), splitOperator: multisig(), stageConfigurations: stages, loanSources: ls, loans: address(LOANS_CONTRACT)});
        REVBuybackHookConfig memory bbh = REVBuybackHookConfig({dataHook: IJBRulesetDataHook(address(0)), hookToConfigure: IJBBuybackHook(address(0)), poolConfigurations: new REVBuybackPoolConfig[](0)});
        REVNET_ID = REV_DEPLOYER.deployFor({revnetId: 0, configuration: cfg, terminalConfigurations: tc, buybackHookConfiguration: bbh, suckerDeploymentConfiguration: REVSuckerDeploymentConfig({deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("NANA")})});
    }

    /// @notice Borrowing from the registered terminal succeeds.
    function test_borrowFromRegisteredTerminal_succeeds() public {
        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: 10e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, USER, 0, "", "");
        uint256 borrowable = LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        assertTrue(borrowable > 0, "Should have borrowable amount");

        mockExpect(address(jbPermissions()), abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, REVNET_ID, 10, true, true)), abi.encode(true));
        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        vm.prank(USER);
        (uint256 loanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokens, payable(USER), 25);
        assertTrue(loanId > 0, "Loan should be created");
    }

    /// @notice Borrowing from an unregistered terminal reverts with REVLoans_InvalidSource.
    function test_borrowFromUnregisteredTerminal_reverts() public {
        FakeTerminal fakeTerminal = new FakeTerminal();

        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: 10e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, USER, 0, "", "");

        // Use vm.mockCall (not mockExpect) because the permission check is never reached — the InvalidSource revert
        // happens first, so expectCall would fail.
        vm.mockCall(address(jbPermissions()), abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, REVNET_ID, 10, true, true)), abi.encode(true));

        REVLoanSource memory fakeSource = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: IJBPayoutTerminal(address(fakeTerminal))});

        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(REVLoans.REVLoans_InvalidSource.selector, address(fakeTerminal), JBConstants.NATIVE_TOKEN));
        LOANS_CONTRACT.borrowFrom(REVNET_ID, fakeSource, 0, tokens, payable(USER), 25);
    }

    /// @notice A fake terminal's useAllowanceOf is never called because the source validation happens first.
    function test_fakeTerminal_neverReachesUseAllowance() public {
        FakeTerminal fakeTerminal = new FakeTerminal();

        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: 10e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, USER, 0, "", "");

        // Use vm.mockCall (not mockExpect) because the permission check is never reached.
        vm.mockCall(address(jbPermissions()), abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, REVNET_ID, 10, true, true)), abi.encode(true));

        REVLoanSource memory fakeSource = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: IJBPayoutTerminal(address(fakeTerminal))});

        vm.prank(USER);
        vm.expectRevert(); // Will revert before reaching useAllowance
        LOANS_CONTRACT.borrowFrom(REVNET_ID, fakeSource, 0, tokens, payable(USER), 25);

        // Verify the fake terminal was never called (its useAllowanceCalled flag should be false)
        assertFalse(fakeTerminal.useAllowanceCalled(), "Fake terminal should never be called");
    }
}
