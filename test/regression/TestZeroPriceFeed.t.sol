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
import {MockPriceFeed} from "@bananapus/core-v6/test/mock/MockPriceFeed.sol";
import {MockERC20} from "@bananapus/core-v6/test/mock/MockERC20.sol";
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
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {REVEmpty721Config} from "../helpers/REVEmpty721Config.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";

/// @notice Verifies that `_totalBorrowedFrom` gracefully handles zero-price feeds.
/// @dev When a cross-currency price feed returns 0 (e.g., inverse truncation at low decimals), the affected source
/// is skipped rather than reverting with division-by-zero. This prevents a stale or misconfigured price feed from
/// DoS-ing all loan operations. The tradeoff is that total borrowed is intentionally understated for the affected
/// source, which is conservative (reduces borrowable amount rather than inflating it).
contract TestZeroPriceFeed is TestBaseWorkflow {
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

    // forge-lint: disable-next-line(mixed-case-variable)
    address USER = makeAddr("user");

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    /// @notice The price feed address, stored so we can mock it after initial setup.
    MockPriceFeed priceFeed;

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

        // Deploy a 6-decimal ERC-20 token.
        TOKEN = new MockERC20("Stable Token", "STABLE");

        // Price feed: TOKEN -> ETH. 1 TOKEN (6 dec) = 0.0005 ETH.
        priceFeed = new MockPriceFeed(5e14, 18);
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

        vm.deal(USER, 1000e18);
    }

    function _deployFeeProject() internal {
        JBAccountingContext[] memory acc = new JBAccountingContext[](2);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        acc[1] = JBAccountingContext({token: address(TOKEN), decimals: 6, currency: uint32(uint160(address(TOKEN)))});
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

    /// @notice Helper: mock BURN_TOKENS permission for the loans contract.
    function _mockBurnPermission() internal {
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, REVNET_ID, 11, true, true)),
            abi.encode(true)
        );
    }

    /// @notice Computes the storage slot for balanceOf[terminal][projectId][token] in JBTerminalStore.
    /// @dev balanceOf is at slot 0: mapping(address => mapping(uint256 => mapping(address => uint256))).
    function _terminalStoreBalanceSlot(
        address terminal,
        uint256 projectId,
        address token
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(token, keccak256(abi.encode(projectId, keccak256(abi.encode(terminal, uint256(0))))))
        );
    }

    //*********************************************************************//
    // --- Zero Price Feed Tests ----------------------------------------- //
    //*********************************************************************//

    /// @notice When a cross-currency price feed returns 0, `_totalBorrowedFrom` skips the affected source
    /// rather than reverting. This prevents DoS of all loan operations when a price feed is stale or
    /// misconfigured. The result is an undercount of total borrowed (conservative: reduces borrowable amount).
    ///
    /// @dev Methodology: after creating a TOKEN loan source (which registers the source and sets a nonzero
    /// totalBorrowedFrom), we zero out the TOKEN balance in the terminal store via vm.store. This means:
    /// - The surplus calculation skips TOKEN (balance = 0, no price conversion needed)
    /// - But `_totalBorrowedFrom` still has the TOKEN entry and needs cross-currency conversion
    /// When the price feed returns 0, `_totalBorrowedFrom` skips it rather than reverting.
    function test_zeroPriceFeed_doesNotRevert_undercountsTotalBorrowed() public {
        // Step 1: Pay ETH to get revnet tokens BEFORE adding TOKEN liquidity.
        vm.prank(USER);
        uint256 revnetTokens =
            jbMultiTerminal().pay{value: 10e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, USER, 0, "", "");
        assertGt(revnetTokens, 0, "should receive revnet tokens");

        // Step 2: Take a small loan from the ETH source.
        uint256 ethCollateral = revnetTokens / 10;
        _mockBurnPermission();
        REVLoanSource memory ethSource = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        vm.prank(USER);
        LOANS_CONTRACT.borrowFrom(REVNET_ID, ethSource, 0, ethCollateral, payable(USER), 25);

        // Step 3: Fund the terminal with TOKEN and borrow from TOKEN source.
        uint256 tokenFunding = 1_000_000e6;
        TOKEN.mint(address(this), tokenFunding);
        TOKEN.approve(address(jbMultiTerminal()), tokenFunding);
        jbMultiTerminal().addToBalanceOf(REVNET_ID, address(TOKEN), tokenFunding, false, "", "");

        uint256 tokenCollateral = revnetTokens / 10;
        _mockBurnPermission();
        REVLoanSource memory tokenSource = REVLoanSource({token: address(TOKEN), terminal: jbMultiTerminal()});
        vm.prank(USER);
        LOANS_CONTRACT.borrowFrom(REVNET_ID, tokenSource, 0, tokenCollateral, payable(USER), 25);

        // Verify both sources have nonzero totalBorrowedFrom.
        uint256 borrowedFromEth =
            LOANS_CONTRACT.totalBorrowedFrom(REVNET_ID, jbMultiTerminal(), JBConstants.NATIVE_TOKEN);
        uint256 borrowedFromToken = LOANS_CONTRACT.totalBorrowedFrom(REVNET_ID, jbMultiTerminal(), address(TOKEN));
        assertGt(borrowedFromEth, 0, "ETH source should have nonzero borrowed amount");
        assertGt(borrowedFromToken, 0, "TOKEN source should have nonzero borrowed amount");

        // Step 4: Zero out the TOKEN balance in the terminal store so the surplus calculation
        // skips the TOKEN accounting context (balance == 0 -> no price conversion needed).
        // This isolates the test to only exercise `_totalBorrowedFrom`'s zero-price guard.
        bytes32 tokenBalanceSlot = _terminalStoreBalanceSlot(address(jbMultiTerminal()), REVNET_ID, address(TOKEN));
        vm.store(address(jbTerminalStore()), tokenBalanceSlot, bytes32(uint256(0)));

        // Verify the TOKEN balance is now 0.
        assertEq(
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), REVNET_ID, address(TOKEN)),
            0,
            "TOKEN balance should be zeroed out"
        );

        // Step 5: Record the borrowable amount WITH a working price feed.
        vm.prank(USER);
        uint256 freshTokens =
            jbMultiTerminal().pay{value: 1e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, USER, 0, "", "");
        assertGt(freshTokens, 0, "should receive fresh tokens");

        uint256 borrowableWithPrice =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, freshTokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        // Step 6: Mock the price feed to return 0 for the TOKEN -> ETH conversion.
        // This simulates an inverse price feed truncation scenario where the conversion
        // rounds down to zero (e.g., a feed returning 1e21 at 6 decimals inverts to 0).
        vm.mockCall(
            address(priceFeed),
            abi.encodeWithSignature("currentUnitPrice(uint256)"),
            abi.encode(uint256(0))
        );

        // Step 7: Verify borrowableAmountFrom still works (no revert).
        uint256 borrowableWithZeroPrice =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, freshTokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        // The call should succeed (not revert), proving the DoS protection works.
        // With zero price, the TOKEN-denominated borrowed amount is skipped in `_totalBorrowedFrom`.
        // This means `totalBorrowed` is understated (only includes ETH source), so
        // `totalSurplus + totalBorrowed` is lower, producing a lower borrowable amount.
        //
        // NOTE: borrowableWithZeroPrice <= borrowableWithPrice because the understated totalBorrowed
        // reduces the effective surplus-plus-debt pool used in the bonding curve calculation.
        // This is the "acceptable tradeoff vs. blocking every borrow/repay" documented in the source.
        assertLe(
            borrowableWithZeroPrice,
            borrowableWithPrice,
            "zero-price undercount should produce equal or lower borrowable amount (conservative)"
        );

        // Document the undercount: the two amounts should differ since TOKEN debt is omitted.
        emit log_named_uint("borrowable with working price feed", borrowableWithPrice);
        emit log_named_uint("borrowable with zero price feed", borrowableWithZeroPrice);
        emit log_named_uint("undercount delta", borrowableWithPrice - borrowableWithZeroPrice);
    }

    /// @notice When only one source exists and it matches the target currency (same currency),
    /// a zero price feed for OTHER currencies has no effect since no cross-currency conversion is needed.
    function test_zeroPriceFeed_noEffectOnSameCurrencySource() public {
        // Step 1: Pay ETH to get revnet tokens.
        vm.prank(USER);
        uint256 revnetTokens =
            jbMultiTerminal().pay{value: 10e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, USER, 0, "", "");

        // Step 2: Take a loan from the ETH source only (same currency as baseCurrency).
        _mockBurnPermission();
        REVLoanSource memory ethSource = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        vm.prank(USER);
        LOANS_CONTRACT.borrowFrom(REVNET_ID, ethSource, 0, revnetTokens / 2, payable(USER), 25);

        // Step 3: Get borrowable amount.
        vm.prank(USER);
        uint256 freshTokens =
            jbMultiTerminal().pay{value: 1e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 1e18, USER, 0, "", "");

        uint256 borrowableBefore =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, freshTokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        // Step 4: Mock the price feed to return 0 -- this should not affect anything
        // since the only loan source is ETH (same currency, no cross-currency conversion).
        vm.mockCall(
            address(priceFeed),
            abi.encodeWithSignature("currentUnitPrice(uint256)"),
            abi.encode(uint256(0))
        );

        uint256 borrowableAfter =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, freshTokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        // Same-currency source does not use the price feed, so the amounts should be identical.
        assertEq(
            borrowableAfter,
            borrowableBefore,
            "zero price feed should not affect same-currency loan source calculations"
        );
    }
}
