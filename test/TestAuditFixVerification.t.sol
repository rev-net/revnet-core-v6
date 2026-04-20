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
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
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
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {MockERC20} from "@bananapus/core-v6/test/mock/MockERC20.sol";
import {MockPriceFeed} from "@bananapus/core-v6/test/mock/MockPriceFeed.sol";
import {REVLoans} from "../src/REVLoans.sol";
import {REVHiddenTokens} from "../src/REVHiddenTokens.sol";
import {IREVHiddenTokens} from "../src/interfaces/IREVHiddenTokens.sol";
import {REVStageConfig, REVAutoIssuance} from "../src/structs/REVStageConfig.sol";
import {REVDescription} from "../src/structs/REVDescription.sol";
import {IREVLoans} from "./../src/interfaces/IREVLoans.sol";
import {REVLoanSource} from "../src/structs/REVLoanSource.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/JB721CheckpointsDeployer.sol";
import {IJB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721CheckpointsDeployer.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {JBSuckersPair} from "@bananapus/suckers-v6/src/structs/JBSuckersPair.sol";
import {REVOwner} from "../src/REVOwner.sol";
import {IREVDeployer} from "../src/interfaces/IREVDeployer.sol";
import {MockSuckerRegistry} from "./mock/MockSuckerRegistry.sol";

/// @notice A mock buyback hook that records the context passed to `beforeCashOutRecordedWith`
/// so that tests can verify the cross-chain-adjusted values (H-3 fix).
contract MockBuybackContextRecorder is IJBRulesetDataHook, IJBPayHook {
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        override
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        weight = context.weight;
        hookSpecifications = new JBPayHookSpecification[](1);
        hookSpecifications[0] =
            JBPayHookSpecification({hook: IJBPayHook(address(this)), noop: false, amount: 0, metadata: ""});
    }

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        pure
        override
        returns (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        // Echo selected context values back through the return data so the caller can assert
        // which values were forwarded into the hook without mutating state in a `view` function.
        cashOutTaxRate = context.totalSupply;
        cashOutCount = context.surplus.value;
        totalSupply = context.totalSupply;
        effectiveSurplusValue = 0;
        hookSpecifications = new JBCashOutHookSpecification[](0);
    }

    function hasMintPermissionFor(uint256, JBRuleset calldata, address) external pure override returns (bool) {
        return false;
    }

    function afterPayRecordedWith(JBAfterPayRecordedContext calldata) external payable override {}

    /// @notice No-op pool configuration for tests.
    function setPoolFor(uint256, PoolKey calldata, uint256, address) external pure {}

    /// @notice No-op pool configuration for tests (simplified overload).
    function setPoolFor(uint256, uint24, int24, uint256, address) external pure {}

    /// @notice No-op pool initialization for tests.
    function initializePoolFor(uint256, uint24, int24, uint256, address, uint160) external pure {}

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IJBRulesetDataHook).interfaceId || interfaceId == type(IJBPayHook).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice A mock sucker registry that returns configurable non-zero remote supply and surplus.
/// Used to verify that cross-chain values flow correctly to the buyback hook (H-3).
contract MockSuckerRegistryWithRemote {
    uint256 public remoteSupply;
    uint256 public remoteSurplus;

    function DIRECTORY() external pure returns (IJBDirectory) {
        return IJBDirectory(address(0));
    }

    function MAX_TO_REMOTE_FEE() external pure returns (uint256) {
        return 0;
    }

    function PROJECTS() external pure returns (IJBProjects) {
        return IJBProjects(address(0));
    }

    function setRemoteValues(uint256 supply, uint256 surplus) external {
        remoteSupply = supply;
        remoteSurplus = surplus;
    }

    function isSuckerOf(uint256, address) external pure returns (bool) {
        return false;
    }

    function remoteTotalSupplyOf(uint256) external view returns (uint256) {
        return remoteSupply;
    }

    function remoteSurplusOf(uint256, uint256, uint256) external view returns (uint256) {
        return remoteSurplus;
    }

    function suckerDeployerIsAllowed(address) external pure returns (bool) {
        return false;
    }

    function suckerPairsOf(uint256) external pure returns (JBSuckersPair[] memory pairs) {
        return new JBSuckersPair[](0);
    }

    function suckersOf(uint256) external pure returns (address[] memory suckers) {
        return new address[](0);
    }

    function remoteBalanceOf(uint256, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function toRemoteFee() external pure returns (uint256) {
        return 0;
    }

    function allowSuckerDeployer(address) external pure {}

    function allowSuckerDeployers(address[] calldata) external pure {}

    function deploySuckersFor(
        uint256,
        bytes32,
        JBSuckerDeployerConfig[] calldata
    )
        external
        pure
        returns (address[] memory suckers)
    {
        return new address[](0);
    }

    function removeDeprecatedSucker(uint256, address) external pure {}

    function removeSuckerDeployer(address) external pure {}

    function setToRemoteFee(uint256) external pure {}
}

/// @notice Tests verifying audit fix correctness for C-1, H-3, and C-5/A14.
/// C-1: `_borrowableAmountFrom` passes `decimals` parameter (not hardcoded 18) to `remoteSurplusOf`.
/// H-3: `REVOwner.beforeCashOutRecordedWith` forwards cross-chain-adjusted context to buyback hook.
/// A14: `REVHiddenTokens` has operator gating and hidden tokens reduce economic supply until revealed.
contract TestAuditFixVerification is TestBaseWorkflow {
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
    MockBuybackContextRecorder MOCK_BUYBACK;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockSuckerRegistryWithRemote MOCK_SUCKER_REGISTRY;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockERC20 USDC_TOKEN;

    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 FEE_PROJECT_ID;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 REVNET_ID;

    // forge-lint: disable-next-line(mixed-case-variable)
    address USER = makeAddr("user");
    // forge-lint: disable-next-line(mixed-case-variable)
    address UNAUTHORIZED = makeAddr("unauthorized");

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    function setUp() public override {
        super.setUp();
        FEE_PROJECT_ID = jbProjects().createFor(multisig());
        MOCK_SUCKER_REGISTRY = new MockSuckerRegistryWithRemote();
        SUCKER_REGISTRY = IJBSuckerRegistry(address(MOCK_SUCKER_REGISTRY));
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
        MOCK_BUYBACK = new MockBuybackContextRecorder();

        // Deploy a 6-decimal ERC20 token (simulates USDC).
        USDC_TOKEN = new MockERC20("USD Coin", "USDC");

        // Add a price feed: USDC/ETH at 1 USDC = 0.0005 ETH (i.e. 2000 USDC per ETH).
        // Feed returns price in 6 decimals.
        MockPriceFeed priceFeed = new MockPriceFeed(5e14, 18);
        vm.prank(multisig());
        jbPrices()
            .addPriceFeedFor(
                0, uint32(uint160(address(USDC_TOKEN))), uint32(uint160(JBConstants.NATIVE_TOKEN)), priceFeed
            );

        LOANS_CONTRACT = new REVLoans({
            controller: jbController(),
            suckerRegistry: SUCKER_REGISTRY,
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

    //*********************************************************************//
    // ────────── C-1: _borrowableAmountFrom decimal correctness ────────── //
    //*********************************************************************//

    /// @notice C-1 fix: `borrowableAmountFrom` with 6-decimal token produces
    /// a correctly scaled (non-inflated) result.
    function test_C1_borrowableAmount_6decimals_notInflated() public {
        // Pay into the revnet to create surplus and get tokens.
        uint256 payAmount = 10e18;
        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: payAmount}({
            projectId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: USER,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
        assertGt(tokens, 0, "User should have tokens");

        // Query borrowable amount in 6 decimals (USDC-like).
        uint256 borrowable6 =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 6, uint32(uint160(address(USDC_TOKEN))));

        // Query borrowable amount in 18 decimals (ETH).
        uint256 borrowable18 =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        // The 6-decimal result must be scaled to 6 decimals, NOT 18.
        // If the bug existed (hardcoded 18), borrowable6 would be inflated by 1e12.
        // A 6-decimal result for 10 ETH worth of collateral at 2000 USDC/ETH with 50% tax
        // should be on the order of thousands of USDC (millions in 6-decimal units).
        // The 18-decimal ETH result should be on the order of 10e18 (with bonding curve tax).
        assertLt(borrowable6, 1e18, "6-decimal borrowable must not be inflated to 18-decimal scale");
        assertGt(borrowable6, 0, "6-decimal borrowable should be positive");
        assertGt(borrowable18, 0, "18-decimal borrowable should be positive");

        // Sanity: the 6-decimal result should be much smaller numerically than 18-decimal.
        // With correct scaling, borrowable6 (USDC units) should be less than borrowable18 (ETH wei)
        // because USDC uses 6 decimals and ETH uses 18 decimals.
        assertLt(borrowable6, borrowable18, "6-decimal result should be smaller in magnitude than 18-decimal");
    }

    /// @notice C-1 fix: `borrowableAmountFrom` with 18-decimal token still works correctly.
    function test_C1_borrowableAmount_18decimals_stillCorrect() public {
        // Pay into the revnet.
        uint256 payAmount = 5e18;
        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: payAmount}({
            projectId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: USER,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
        assertGt(tokens, 0, "User should have tokens");

        // Query borrowable amount in 18 decimals.
        uint256 borrowable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        // Should be positive and less than or equal to the total surplus.
        assertGt(borrowable, 0, "18-decimal borrowable should be positive");
        // With 50% cash out tax rate, borrowable should be less than the full pay amount.
        assertLe(borrowable, payAmount, "Borrowable should not exceed surplus");
    }

    //*********************************************************************//
    // ──── H-3: Buyback hook receives cross-chain-adjusted context ──── //
    //*********************************************************************//

    /// @notice H-3 fix: The buyback hook receives cross-chain-adjusted `totalSupply` and
    /// `surplus.value` in the context passed by `REVOwner.beforeCashOutRecordedWith`.
    function test_H3_buybackHook_receivesCrossChainAdjustedContext() public {
        // Pay into the revnet to get tokens and create surplus.
        uint256 payAmount = 10e18;
        vm.prank(USER);
        uint256 tokens = jbMultiTerminal().pay{value: payAmount}({
            projectId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: USER,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
        assertGt(tokens, 0, "User should have tokens");

        // Set non-zero remote supply and surplus to simulate cross-chain state.
        uint256 remoteSupply = 5000e18;
        uint256 remoteSurplus = 3e18;
        MOCK_SUCKER_REGISTRY.setRemoteValues(remoteSupply, remoteSurplus);

        // Get the local supply and surplus for comparison.
        uint256 localSupply = jbController().totalTokenSupplyWithReservedTokensOf(REVNET_ID);
        // The local surplus can be queried via the terminal.
        uint256 localSurplus = jbMultiTerminal()
            .currentSurplusOf(REVNET_ID, new address[](0), 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        // Build a context simulating a cash out call (as the terminal would).
        JBBeforeCashOutRecordedContext memory context = JBBeforeCashOutRecordedContext({
            terminal: address(jbMultiTerminal()),
            holder: USER,
            projectId: REVNET_ID,
            rulesetId: 0,
            cashOutCount: tokens / 2,
            totalSupply: localSupply,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: localSurplus
            }),
            useTotalSurplus: true,
            cashOutTaxRate: 5000, // 50% tax
            beneficiaryIsFeeless: false,
            metadata: ""
        });

        // Call beforeCashOutRecordedWith on the REV_OWNER (data hook).
        // Note: REVOwner.beforeCashOutRecordedWith is `view` but our mock records state via SSTORE,
        // so we need to use a staticcall-breaking trick. We use low-level call to bypass the view restriction.
        (bool success, bytes memory retdata) =
            address(REV_OWNER).call(abi.encodeWithSelector(REV_OWNER.beforeCashOutRecordedWith.selector, context));
        assertTrue(success, "beforeCashOutRecordedWith should succeed");

        // Decode the return to verify it does not revert and to inspect what the buyback hook saw.
        (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory hookSpecifications
        ) = abi.decode(retdata, (uint256, uint256, uint256, uint256, JBCashOutHookSpecification[]));

        uint256 expectedTotalSupply = localSupply + remoteSupply;
        uint256 expectedSurplus = localSurplus + remoteSurplus;

        // The mocked buyback hook echoes the context it receives through the first two return values.
        assertEq(cashOutTaxRate, expectedTotalSupply, "Buyback hook should receive cross-chain totalSupply");
        assertEq(cashOutCount, expectedSurplus, "Buyback hook should receive cross-chain surplus value");

        // REVOwner should also return the same cross-chain-adjusted values to the terminal.
        assertEq(totalSupply, expectedTotalSupply, "REVOwner should return cross-chain totalSupply");
        assertEq(effectiveSurplusValue, expectedSurplus, "REVOwner should return cross-chain surplus value");
        assertEq(hookSpecifications.length, 1, "Expected REVOwner to append its fee hook spec");
    }

    //*********************************************************************//
    // ──────── A14: REVHiddenTokens operator gating & views ──────── //
    //*********************************************************************//

    /// @notice A14: Only the project owner or authorized operator can call `hideTokensOf`.
    /// Unauthorized callers should revert.
    function test_A14_hideTokensOf_revertsForUnauthorized() public {
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
        assertGt(userTokens, 0, "User should have tokens");

        // An unauthorized address (not project owner, not operator) should revert.
        vm.prank(UNAUTHORIZED);
        vm.expectRevert();
        HIDDEN_TOKENS.hideTokensOf(REVNET_ID, userTokens / 2, USER);

        // Even the token holder themselves cannot hide without operator permission.
        vm.prank(USER);
        vm.expectRevert();
        HIDDEN_TOKENS.hideTokensOf(REVNET_ID, userTokens / 2, USER);
    }

    /// @notice A14: Hiding tokens reduces the live token supply used for economic calculations.
    function test_A14_hidingTokens_reducesLiveSupply() public {
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
        uint256 totalSupplyBefore = jbController().totalTokenSupplyWithReservedTokensOf(REVNET_ID);

        _allowHolderToHide(USER, REVNET_ID);

        // Hide half the tokens via a split-operator delegate.
        uint256 hideCount = userTokens / 2;
        vm.prank(USER);
        HIDDEN_TOKENS.hideTokensOf(REVNET_ID, hideCount, USER);

        // After hiding: raw totalSupply should be reduced.
        uint256 totalSupplyAfter = jbController().totalTokenSupplyWithReservedTokensOf(REVNET_ID);
        assertEq(totalSupplyAfter, totalSupplyBefore - hideCount, "Raw total supply should decrease");

        assertEq(HIDDEN_TOKENS.hiddenBalanceOf(USER, REVNET_ID), hideCount, "Hidden balance should be tracked");
        assertEq(HIDDEN_TOKENS.totalHiddenOf(REVNET_ID), hideCount, "Total hidden should be tracked");
    }

    /// @notice A14: After hiding, economic supply is reduced until tokens are revealed.
    function test_A14_hiddenTokens_reduceEconomicSupply() public {
        // Pay to get tokens for the user.
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
        uint256 totalSupplyBefore = jbController().totalTokenSupplyWithReservedTokensOf(REVNET_ID);

        _allowHolderToHide(USER, REVNET_ID);

        // Hide 80% of the user's tokens.
        uint256 hideCount = (userTokens * 80) / 100;
        vm.prank(USER);
        HIDDEN_TOKENS.hideTokensOf(REVNET_ID, hideCount, USER);

        // The live totalSupply should be reduced, which also reduces economic supply.
        uint256 rawSupply = jbController().totalTokenSupplyWithReservedTokensOf(REVNET_ID);
        assertEq(rawSupply, totalSupplyBefore - hideCount, "Economic supply should decrease after hiding");

        // The hidden balance should be correctly tracked.
        assertEq(HIDDEN_TOKENS.hiddenBalanceOf(USER, REVNET_ID), hideCount, "Hidden balance tracked");
        assertEq(HIDDEN_TOKENS.totalHiddenOf(REVNET_ID), hideCount, "Total hidden tracked");
    }

    //*********************************************************************//
    // ──────────────── Internal helpers
    // ──────────────── //
    //*********************************************************************//

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

    function _allowHolderToHide(address holder, uint256 revnetId) internal {
        vm.prank(address(REV_DEPLOYER));
        HIDDEN_TOKENS.setTokenHidingAllowedFor(revnetId, holder, true);
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
        JBAccountingContext[] memory acc = new JBAccountingContext[](2);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        acc[1] = JBAccountingContext({
            token: address(USDC_TOKEN), decimals: 6, currency: uint32(uint160(address(USDC_TOKEN)))
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
