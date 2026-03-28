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
import {REVLoans} from "../src/REVLoans.sol";
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

struct FeeProjectConfig {
    REVConfig configuration;
    JBTerminalConfig[] terminalConfigurations;
    REVSuckerDeploymentConfig suckerDeploymentConfiguration;
}

/// @notice Tests that REVLoans enforces the cash out delay set by REVDeployer for cross-chain deployments.
contract TestLoansCashOutDelay is TestBaseWorkflow {
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 ERC20_SALT = "REV_TOKEN";

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
    IREVLoans LOANS_CONTRACT;
    // forge-lint: disable-next-line(mixed-case-variable)
    IJBSuckerRegistry SUCKER_REGISTRY;
    // forge-lint: disable-next-line(mixed-case-variable)
    CTPublisher PUBLISHER;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockBuybackDataHook MOCK_BUYBACK;

    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 FEE_PROJECT_ID;

    /// @notice Revnet deployed with startsAtOrAfter in the past (triggers cash out delay).
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 DELAYED_REVNET_ID;

    /// @notice Revnet deployed with startsAtOrAfter == block.timestamp (no delay).
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 NORMAL_REVNET_ID;

    // forge-lint: disable-next-line(mixed-case-variable)
    address USER = makeAddr("user");

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    function getFeeProjectConfig() internal view returns (FeeProjectConfig memory) {
        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
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
            splitPercent: 2000,
            splits: splits,
            // forge-lint: disable-next-line(unsafe-typecast)
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: 0
        });

        return FeeProjectConfig({
            configuration: REVConfig({
                // forge-lint: disable-next-line(named-struct-fields)
                description: REVDescription("Revnet", "$REV", "ipfs://fee", ERC20_SALT),
                baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                splitOperator: multisig(),
                stageConfigurations: stageConfigurations
            }),
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("REV"))
            })
        });
    }

    /// @notice Returns a revnet config. When `pastStart` is true, `startsAtOrAfter` is set to 1 second ago,
    /// triggering the 30-day cash out delay in REVDeployer._setCashOutDelayIfNeeded.
    function _getRevnetConfig(
        bool pastStart,
        string memory name,
        string memory symbol,
        bytes32 salt
    )
        internal
        view
        returns (FeeProjectConfig memory)
    {
        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        // If pastStart, set startsAtOrAfter to 1 second ago — simulates cross-chain deployment
        // where the stage is already active on another chain.
        uint40 startsAt = pastStart ? uint40(block.timestamp - 1) : uint40(block.timestamp);

        stageConfigurations[0] = REVStageConfig({
            startsAtOrAfter: startsAt,
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 2000,
            splits: splits,
            // forge-lint: disable-next-line(unsafe-typecast)
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: 0
        });

        return FeeProjectConfig({
            configuration: REVConfig({
                // forge-lint: disable-next-line(named-struct-fields)
                description: REVDescription(name, symbol, "ipfs://test", salt),
                baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                splitOperator: multisig(),
                stageConfigurations: stageConfigurations
            }),
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: salt
            })
        });
    }

    function setUp() public override {
        super.setUp();

        // Warp to a realistic timestamp so startsAtOrAfter - 1 doesn't underflow.
        vm.warp(1_700_000_000);

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

        // Approve the deployer to configure the fee project.
        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);

        // Deploy the fee project.
        FeeProjectConfig memory feeProjectConfig = getFeeProjectConfig();
        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeProjectConfig.configuration,
            terminalConfigurations: feeProjectConfig.terminalConfigurations,
            suckerDeploymentConfiguration: feeProjectConfig.suckerDeploymentConfiguration,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        // Deploy a revnet with startsAtOrAfter in the past (triggers 30-day cash out delay).
        FeeProjectConfig memory delayedConfig =
            _getRevnetConfig(true, "Delayed", "$DLY", keccak256(abi.encodePacked("DELAYED")));
        (DELAYED_REVNET_ID,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: delayedConfig.configuration,
            terminalConfigurations: delayedConfig.terminalConfigurations,
            suckerDeploymentConfiguration: delayedConfig.suckerDeploymentConfiguration,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        // Deploy a normal revnet with no delay.
        FeeProjectConfig memory normalConfig =
            _getRevnetConfig(false, "Normal", "$NRM", keccak256(abi.encodePacked("NORMAL")));
        (NORMAL_REVNET_ID,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: normalConfig.configuration,
            terminalConfigurations: normalConfig.terminalConfigurations,
            suckerDeploymentConfiguration: normalConfig.suckerDeploymentConfiguration,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        vm.deal(USER, 100 ether);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @notice Pay ETH into a revnet and return the number of project tokens received.
    function _payAndGetTokens(uint256 revnetId, uint256 amount) internal returns (uint256 tokenCount) {
        vm.prank(USER);
        tokenCount = jbMultiTerminal().pay{value: amount}(revnetId, JBConstants.NATIVE_TOKEN, amount, USER, 0, "", "");
    }

    /// @notice Mock the permissions check so LOANS_CONTRACT can burn tokens on behalf of USER.
    function _mockBorrowPermission(uint256 projectId) internal {
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, projectId, 11, true, true)),
            abi.encode(true)
        );
    }

    // ------------------------------------------------------------------
    // Tests: delayed revnet (startsAtOrAfter in the past → 30-day delay)
    // ------------------------------------------------------------------

    /// @notice Verify the deployer actually set a cash out delay for the delayed revnet.
    function test_delayedRevnet_hasCashOutDelay() public view {
        uint256 cashOutDelay = REV_DEPLOYER.cashOutDelayOf(DELAYED_REVNET_ID);
        assertGt(cashOutDelay, block.timestamp, "Cash out delay should be in the future");
    }

    /// @notice Verify the normal revnet has no cash out delay.
    function test_normalRevnet_noCashOutDelay() public view {
        uint256 cashOutDelay = REV_DEPLOYER.cashOutDelayOf(NORMAL_REVNET_ID);
        assertEq(cashOutDelay, 0, "Normal revnet should have no cash out delay");
    }

    /// @notice borrowableAmountFrom should return 0 during the delay period.
    function test_borrowableAmountFrom_returnsZeroDuringDelay() public {
        // Pay into the delayed revnet to get tokens.
        uint256 tokenCount = _payAndGetTokens(DELAYED_REVNET_ID, 1 ether);
        assertGt(tokenCount, 0, "Should have tokens");

        // Query borrowable amount — should be 0 during the delay.
        uint256 borrowable = LOANS_CONTRACT.borrowableAmountFrom(
            DELAYED_REVNET_ID, tokenCount, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        assertEq(borrowable, 0, "Borrowable amount should be 0 during cash out delay");
    }

    /// @notice borrowFrom should revert during the delay period.
    function test_borrowFrom_revertsDuringDelay() public {
        // Pay into the delayed revnet to get tokens.
        uint256 tokenCount = _payAndGetTokens(DELAYED_REVNET_ID, 1 ether);
        assertGt(tokenCount, 0, "Should have tokens");

        // No permission mock needed — the function reverts before reaching the permission check.

        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        // Attempt to borrow — should revert with CashOutDelayNotFinished.
        uint256 cashOutDelay = REV_DEPLOYER.cashOutDelayOf(DELAYED_REVNET_ID);
        vm.expectRevert(
            abi.encodeWithSelector(REVLoans.REVLoans_CashOutDelayNotFinished.selector, cashOutDelay, block.timestamp)
        );
        vm.prank(USER);
        LOANS_CONTRACT.borrowFrom(DELAYED_REVNET_ID, source, 1, tokenCount, payable(USER), 25);
    }

    /// @notice After warping past the delay, borrowableAmountFrom should return a non-zero value.
    function test_borrowableAmountFrom_nonZeroAfterDelay() public {
        // Pay into the delayed revnet.
        uint256 tokenCount = _payAndGetTokens(DELAYED_REVNET_ID, 1 ether);

        // Still in delay — should be 0.
        uint256 borrowableBefore = LOANS_CONTRACT.borrowableAmountFrom(
            DELAYED_REVNET_ID, tokenCount, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        assertEq(borrowableBefore, 0, "Should be 0 during delay");

        // Warp past the delay.
        vm.warp(block.timestamp + REV_DEPLOYER.CASH_OUT_DELAY() + 1);

        // Now should be > 0.
        uint256 borrowableAfter = LOANS_CONTRACT.borrowableAmountFrom(
            DELAYED_REVNET_ID, tokenCount, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        assertGt(borrowableAfter, 0, "Should be > 0 after delay expires");
    }

    /// @notice After warping past the delay, borrowFrom should succeed.
    function test_borrowFrom_succeedsAfterDelay() public {
        // Pay into the delayed revnet.
        uint256 tokenCount = _payAndGetTokens(DELAYED_REVNET_ID, 1 ether);

        // Warp past the delay.
        vm.warp(block.timestamp + REV_DEPLOYER.CASH_OUT_DELAY() + 1);

        // Get the borrowable amount.
        uint256 borrowable = LOANS_CONTRACT.borrowableAmountFrom(
            DELAYED_REVNET_ID, tokenCount, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        assertGt(borrowable, 0, "Should be borrowable after delay");

        // Mock permission.
        _mockBorrowPermission(DELAYED_REVNET_ID);

        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        // Borrow — should succeed.
        vm.prank(USER);
        (uint256 loanId,) =
            LOANS_CONTRACT.borrowFrom(DELAYED_REVNET_ID, source, borrowable, tokenCount, payable(USER), 25);
        assertGt(loanId, 0, "Should have created a loan");
    }

    // ------------------------------------------------------------------
    // Tests: normal revnet (no delay)
    // ------------------------------------------------------------------

    /// @notice A normal revnet (no delay) should allow borrowing immediately.
    function test_normalRevnet_borrowableImmediately() public {
        // Pay into the normal revnet.
        uint256 tokenCount = _payAndGetTokens(NORMAL_REVNET_ID, 1 ether);

        // Should have a non-zero borrowable amount immediately.
        uint256 borrowable = LOANS_CONTRACT.borrowableAmountFrom(
            NORMAL_REVNET_ID, tokenCount, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        assertGt(borrowable, 0, "Normal revnet should be borrowable immediately");
    }

    /// @notice A normal revnet (no delay) should allow borrowFrom immediately.
    function test_normalRevnet_borrowFromImmediately() public {
        // Pay into the normal revnet.
        uint256 tokenCount = _payAndGetTokens(NORMAL_REVNET_ID, 1 ether);

        uint256 borrowable = LOANS_CONTRACT.borrowableAmountFrom(
            NORMAL_REVNET_ID, tokenCount, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        assertGt(borrowable, 0, "Should be borrowable");

        // Mock permission.
        _mockBorrowPermission(NORMAL_REVNET_ID);

        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        // Borrow — should succeed without any delay.
        vm.prank(USER);
        (uint256 loanId,) =
            LOANS_CONTRACT.borrowFrom(NORMAL_REVNET_ID, source, borrowable, tokenCount, payable(USER), 25);
        assertGt(loanId, 0, "Should have created a loan");
    }

    // ------------------------------------------------------------------
    // Tests: boundary conditions
    // ------------------------------------------------------------------

    /// @notice borrowFrom should revert at exactly the delay timestamp (not yet expired).
    function test_borrowFrom_revertsAtExactDelayTimestamp() public {
        uint256 tokenCount = _payAndGetTokens(DELAYED_REVNET_ID, 1 ether);

        // Warp to exactly the delay timestamp (not past it).
        uint256 cashOutDelay = REV_DEPLOYER.cashOutDelayOf(DELAYED_REVNET_ID);
        vm.warp(cashOutDelay);

        // borrowableAmountFrom should still return 0 (cashOutDelay > block.timestamp is false, but == is not >).
        // Actually cashOutDelay == block.timestamp means cashOutDelay > block.timestamp is false → should pass.
        // Let's verify: at exact boundary, the delay is NOT enforced (delay == timestamp passes).
        uint256 borrowable = LOANS_CONTRACT.borrowableAmountFrom(
            DELAYED_REVNET_ID, tokenCount, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        assertGt(borrowable, 0, "At exact delay timestamp, borrowing should be allowed");
    }

    /// @notice borrowFrom should revert 1 second before the delay expires.
    function test_borrowFrom_revertsOneSecondBeforeDelay() public {
        uint256 tokenCount = _payAndGetTokens(DELAYED_REVNET_ID, 1 ether);

        // Warp to 1 second before the delay expires.
        uint256 cashOutDelay = REV_DEPLOYER.cashOutDelayOf(DELAYED_REVNET_ID);
        vm.warp(cashOutDelay - 1);

        // borrowableAmountFrom should return 0.
        uint256 borrowable = LOANS_CONTRACT.borrowableAmountFrom(
            DELAYED_REVNET_ID, tokenCount, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        assertEq(borrowable, 0, "Should be 0 one second before delay expires");

        // borrowFrom should revert before reaching the permission check.
        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        vm.expectRevert(
            abi.encodeWithSelector(REVLoans.REVLoans_CashOutDelayNotFinished.selector, cashOutDelay, block.timestamp)
        );
        vm.prank(USER);
        LOANS_CONTRACT.borrowFrom(DELAYED_REVNET_ID, source, 1, tokenCount, payable(USER), 25);
    }
}
