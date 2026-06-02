// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
// import /* {*} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
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
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";
import {REVLoans} from "../src/REVLoans.sol";
import {REVLoan} from "../src/structs/REVLoan.sol";
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
import {MockEmptyTerminal} from "./mock/MockEmptyTerminal.sol";
import {MockSuckerRegistry} from "./mock/MockSuckerRegistry.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

/// @notice A test harness that exposes REVLoans internal functions for direct testing.
/// Used to test _totalBorrowedFrom without needing to set up a full borrow flow.
contract REVLoansHarness is REVLoans {
    constructor(
        IJBController controller,
        IJBPayoutTerminal terminal,
        IJBSuckerRegistry suckerRegistry,
        uint256 revId,
        address owner,
        IPermit2 permit2,
        address trustedForwarder
    )
        REVLoans(controller, terminal, suckerRegistry, revId, owner, permit2, trustedForwarder)
    {}

    /// @notice Expose _totalBorrowedFrom for testing.
    function exposed_totalBorrowedFrom(
        uint256 revnetId,
        uint256 decimals,
        uint256 currency,
        IJBTerminal terminal
    )
        external
        view
        returns (uint256)
    {
        return _totalBorrowedFrom(revnetId, decimals, currency, terminal);
    }

    /// @notice Set totalBorrowedFrom for testing.
    function setTotalBorrowedFrom(uint256 revnetId, address token, uint256 amount) external {
        totalBorrowedFrom[revnetId][token] = amount;
    }

    /// @notice Register a loan source for testing.
    function addLoanSource(uint256 revnetId, address token) external {
        _loanSourceTokensOf[revnetId].push(token);
        isLoanSourceOf[revnetId][token] = true;
    }
}

/// @notice Regression tests for REVLoans debt aggregation edge cases.
contract TestRevnetRegressions is TestBaseWorkflow {
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
    REVLoansHarness LOANS_CONTRACT;
    // forge-lint: disable-next-line(mixed-case-variable)
    IJBSuckerRegistry SUCKER_REGISTRY;
    // forge-lint: disable-next-line(mixed-case-variable)
    CTPublisher PUBLISHER;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockBuybackDataHook MOCK_BUYBACK;

    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 FEE_PROJECT_ID;
    // forge-lint: disable-next-line(mixed-case-variable)
    address USER = makeAddr("user");

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    function setUp() public override {
        super.setUp();

        FEE_PROJECT_ID = jbProjects().createFor(multisig());

        SUCKER_REGISTRY = new JBSuckerRegistry(jbDirectory(), jbPermissions(), jbPrices(), multisig(), address(0));
        HOOK_STORE = new JB721TiersHookStore();
        EXAMPLE_HOOK = new JB721TiersHook(
            jbDirectory(),
            jbPermissions(),
            jbPrices(),
            jbRulesets(),
            HOOK_STORE,
            jbSplits(),
            IJB721CheckpointsDeployer(address(new JB721CheckpointsDeployer(HOOK_STORE))),
            multisig()
        );
        ADDRESS_REGISTRY = new JBAddressRegistry();
        HOOK_DEPLOYER = new JB721TiersHookDeployer(EXAMPLE_HOOK, HOOK_STORE, ADDRESS_REGISTRY, multisig());
        PUBLISHER = new CTPublisher({
            directory: jbDirectory(),
            permissions: jbPermissions(),
            feeProjectId: FEE_PROJECT_ID,
            permit2: IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3),
            trustedForwarder: multisig()
        });
        MOCK_BUYBACK = new MockBuybackDataHook();

        LOANS_CONTRACT = new REVLoansHarness({
            controller: jbController(),
            terminal: jbMultiTerminal(),
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
            LOANS_CONTRACT,
            address(this)
        );

        REV_DEPLOYER = new REVDeployer{salt: REV_DEPLOYER_SALT}(
            jbController(),
            jbMultiTerminal(),
            IJBTerminal(address(new MockEmptyTerminal())),
            SUCKER_REGISTRY,
            FEE_PROJECT_ID,
            HOOK_DEPLOYER,
            PUBLISHER,
            IJBBuybackHookRegistry(address(MOCK_BUYBACK)),
            LOANS_CONTRACT,
            TRUSTED_FORWARDER,
            address(REV_OWNER)
        );

        REV_OWNER.setDeployer(REV_DEPLOYER);

        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);
    }

    //*********************************************************************//
    // ---- Zero price feed return fails closed in _totalBorrowedFrom --- //
    //*********************************************************************//

    /// @notice Demonstrates that `_totalBorrowedFrom` reverts when a price module returns 0 for a cross-currency
    /// loan source.
    /// @dev A zero price cannot be skipped: doing so would hide outstanding debt. Core `JBPrices` already rejects
    /// zero prices, and this harness-level mock proves REVLoans also rejects a nonconforming zero return directly.
    function test_zeroPriceFeedRevertsInTotalBorrowed() public {
        // Deploy the fee revnet (required by the system).
        _deployFeeRevnet();

        // Deploy a borrowable revnet.
        uint256 revnetId = _deployBorrowableRevnet();

        // Manually register a loan source with a DIFFERENT currency (fakeCurrency = 999).
        // This simulates having an outstanding loan in a token with a different accounting currency.
        uint32 fakeCurrency = 999;
        address fakeToken = address(0xDEAD);

        // Create a mock terminal that reports the fake accounting context.
        // We use vm.mockCall to make the terminal report the fake currency.
        address mockTerminal = makeAddr("mockTerminal");
        vm.mockCall(
            mockTerminal,
            abi.encodeWithSelector(IJBTerminal.accountingContextForTokenOf.selector, revnetId, fakeToken),
            abi.encode(JBAccountingContext({token: fakeToken, decimals: 18, currency: fakeCurrency}))
        );

        // Register the loan source and set a non-zero borrowed amount via the harness.
        LOANS_CONTRACT.addLoanSource(revnetId, fakeToken);
        LOANS_CONTRACT.setTotalBorrowedFrom(revnetId, fakeToken, 1e18);

        // Mock PRICES.pricePerUnitOf to return 0 for the cross-currency conversion. Core `JBPrices` reverts before
        // returning 0, so this direct mock covers the extra local guard in REVLoans.
        vm.mockCall(
            address(jbPrices()),
            abi.encodeWithSelector(
                IJBPrices.pricePerUnitOf.selector,
                revnetId,
                uint256(fakeCurrency),
                uint256(uint32(uint160(JBConstants.NATIVE_TOKEN))),
                uint256(18)
            ),
            abi.encode(uint256(0))
        );

        // Call _totalBorrowedFrom via the harness. It must fail closed instead of undercounting debt by ignoring the
        // fake source.
        vm.expectRevert(
            abi.encodeWithSelector(
                REVLoans.REVLoans_ZeroPrice.selector,
                revnetId,
                uint256(fakeCurrency),
                uint256(uint32(uint160(JBConstants.NATIVE_TOKEN)))
            )
        );
        LOANS_CONTRACT.exposed_totalBorrowedFrom(
            revnetId, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)), IJBTerminal(mockTerminal)
        );
    }

    //*********************************************************************//
    // ---- Helpers ------------------------------------------------------ //
    //*********************************************************************//

    function _deployFeeRevnet() internal {
        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBAccountingContext[] memory terminalConfigurations = accountingContextsToAccept;

        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        REVAutoIssuance[] memory issuanceConfs = new REVAutoIssuance[](1);
        issuanceConfs[0] =
            REVAutoIssuance({chainId: uint32(block.chainid), count: uint104(70_000e18), beneficiary: multisig()});

        stageConfigurations[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: issuanceConfs,
            splitPercent: 2000,
            splits: splits,
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: 0
        });

        REVConfig memory revnetConfiguration = REVConfig({
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription("Revnet", "$REV", "ipfs://test", ERC20_SALT),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            operator: multisig(),
            scopeCashOutsToLocalBalances: false,
            stageConfigurations: stageConfigurations
        });

        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: revnetConfiguration,
            accountingContextsToAccept: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("REV"))
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    function _deployBorrowableRevnet() internal returns (uint256 revnetId) {
        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBAccountingContext[] memory terminalConfigurations = accountingContextsToAccept;

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

        REVConfig memory revnetConfiguration = REVConfig({
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription("Borrowable", "BRW", "ipfs://brw", "BRW_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            operator: multisig(),
            scopeCashOutsToLocalBalances: false,
            stageConfigurations: stageConfigurations
        });

        (revnetId,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: revnetConfiguration,
            accountingContextsToAccept: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("BRW"))
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }
}
