// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "./../src/REVDeployer.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@croptop/core-v6/src/CTPublisher.sol";
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
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {REVLoans} from "../src/REVLoans.sol";
import {REVStageConfig, REVAutoIssuance} from "../src/structs/REVStageConfig.sol";
import {REVDescription} from "../src/structs/REVDescription.sol";
import {IREVLoans} from "./../src/interfaces/IREVLoans.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {REVBaseline721HookConfig} from "../src/structs/REVBaseline721HookConfig.sol";
import {REV721TiersHookFlags} from "../src/structs/REV721TiersHookFlags.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JB721InitTiersConfig} from "@bananapus/721-hook-v6/src/structs/JB721InitTiersConfig.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {REVDeploy721TiersHookConfig} from "../src/structs/REVDeploy721TiersHookConfig.sol";
import {REVCroptopAllowedPost} from "../src/structs/REVCroptopAllowedPost.sol";
import {REVEmpty721Config} from "./helpers/REVEmpty721Config.sol";

// Buyback hook
import {JBBuybackHook} from "@bananapus/buyback-hook-v6/src/JBBuybackHook.sol";
import {JBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/JBBuybackHookRegistry.sol";
import {IGeomeanOracle} from "@bananapus/buyback-hook-v6/src/interfaces/IGeomeanOracle.sol";

// Uniswap V4
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/// @notice Helper that adds liquidity to and swaps on a V4 pool via the unlock/callback pattern.
contract LiquidityHelper is IUnlockCallback {
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IPoolManager public immutable poolManager;

    enum Action {
        ADD_LIQUIDITY,
        SWAP
    }

    struct AddLiqParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
    }

    struct DoSwapParams {
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function addLiquidity(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    )
        external
        payable
    {
        bytes memory data =
        // forge-lint: disable-next-line(named-struct-fields)
        abi.encode(Action.ADD_LIQUIDITY, abi.encode(AddLiqParams(key, tickLower, tickUpper, liquidityDelta)));
        poolManager.unlock(data);
    }

    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    )
        external
        payable
    {
        bytes memory data =
        // forge-lint: disable-next-line(named-struct-fields)
        abi.encode(Action.SWAP, abi.encode(DoSwapParams(key, zeroForOne, amountSpecified, sqrtPriceLimitX96)));
        poolManager.unlock(data);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "only PM");

        (Action action, bytes memory inner) = abi.decode(data, (Action, bytes));

        if (action == Action.ADD_LIQUIDITY) {
            return _handleAddLiquidity(inner);
        } else {
            return _handleSwap(inner);
        }
    }

    function _handleAddLiquidity(bytes memory data) internal returns (bytes memory) {
        AddLiqParams memory params = abi.decode(data, (AddLiqParams));

        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            params.key,
            ModifyLiquidityParams({
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: params.liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );

        _settleIfNegative(params.key.currency0, callerDelta.amount0());
        _settleIfNegative(params.key.currency1, callerDelta.amount1());
        _takeIfPositive(params.key.currency0, callerDelta.amount0());
        _takeIfPositive(params.key.currency1, callerDelta.amount1());

        return abi.encode(callerDelta);
    }

    function _handleSwap(bytes memory data) internal returns (bytes memory) {
        DoSwapParams memory params = abi.decode(data, (DoSwapParams));

        BalanceDelta delta = poolManager.swap(
            // forge-lint: disable-next-line(named-struct-fields)
            params.key,
            SwapParams(params.zeroForOne, params.amountSpecified, params.sqrtPriceLimitX96),
            ""
        );

        // Settle (pay) what we owe, take what we're owed.
        if (delta.amount0() < 0) {
            _settleIfNegative(params.key.currency0, delta.amount0());
        } else {
            _takeIfPositive(params.key.currency0, delta.amount0());
        }
        if (delta.amount1() < 0) {
            _settleIfNegative(params.key.currency1, delta.amount1());
        } else {
            _takeIfPositive(params.key.currency1, delta.amount1());
        }

        return abi.encode(delta);
    }

    function _settleIfNegative(Currency currency, int128 delta) internal {
        if (delta >= 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amount = uint256(uint128(-delta));

        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            IERC20(Currency.unwrap(currency)).transfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    function _takeIfPositive(Currency currency, int128 delta) internal {
        if (delta <= 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amount = uint256(uint128(delta));
        poolManager.take(currency, address(this), amount);
    }

    receive() external payable {}
}

/// @notice Fork tests verifying that revnet 721 tier splits + real Uniswap V4 buyback hook produce correct token
/// issuance in both the swap path (AMM buyback) and the mint path (direct minting).
///
/// Requires: RPC_ETHEREUM_MAINNET env var for mainnet fork (real PoolManager).
///
/// Run with: FOUNDRY_PROFILE=fork forge test --match-contract TestSplitWeightFork -vvv --skip "script/*"
contract TestSplitWeightFork is TestBaseWorkflow {
    using JBMetadataResolver for bytes;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ───────────────────────── Mainnet constants
    // ─────────────────────────

    address constant POOL_MANAGER_ADDR = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    /// @notice Full-range tick bounds for tickSpacing = 200.
    int24 constant TICK_LOWER = -887_200;
    int24 constant TICK_UPPER = 887_200;

    // ───────────────────────── State
    // ─────────────────────────

    // forge-lint: disable-next-line(mixed-case-variable)
    REVDeployer REV_DEPLOYER;
    // forge-lint: disable-next-line(mixed-case-variable)
    JBBuybackHook BUYBACK_HOOK;
    // forge-lint: disable-next-line(mixed-case-variable)
    JBBuybackHookRegistry BUYBACK_REGISTRY;
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
    IPoolManager poolManager;
    LiquidityHelper liqHelper;

    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 FEE_PROJECT_ID;

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;
    // forge-lint: disable-next-line(mixed-case-variable)
    address PAYER = makeAddr("payer");
    // forge-lint: disable-next-line(mixed-case-variable)
    address SPLIT_BENEFICIARY = makeAddr("splitBeneficiary");

    // Tier configuration: 1 ETH tier with 30% split.
    uint104 constant TIER_PRICE = 1 ether;
    uint32 constant SPLIT_PERCENT = 300_000_000; // 30% of SPLITS_TOTAL_PERCENT (1_000_000_000)
    uint112 constant INITIAL_ISSUANCE = 1000e18; // 1000 tokens per ETH

    // ───────────────────────── Setup
    // ─────────────────────────

    function setUp() public override {
        // Fork mainnet at a stable block — deterministic and post-V4 deployment.
        vm.createSelectFork("ethereum", 21_700_000);

        // Verify V4 PoolManager is deployed.
        require(POOL_MANAGER_ADDR.code.length > 0, "PoolManager not deployed at expected address");

        // Deploy fresh JB core on the forked mainnet.
        super.setUp();

        poolManager = IPoolManager(POOL_MANAGER_ADDR);
        liqHelper = new LiquidityHelper(poolManager);

        FEE_PROJECT_ID = jbProjects().createFor(multisig());

        SUCKER_REGISTRY = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig(), address(0));
        HOOK_STORE = new JB721TiersHookStore();
        EXAMPLE_HOOK = new JB721TiersHook(
            jbDirectory(), jbPermissions(), jbPrices(), jbRulesets(), HOOK_STORE, jbSplits(), multisig()
        );
        ADDRESS_REGISTRY = new JBAddressRegistry();
        HOOK_DEPLOYER = new JB721TiersHookDeployer(EXAMPLE_HOOK, HOOK_STORE, ADDRESS_REGISTRY, multisig());
        PUBLISHER = new CTPublisher(jbDirectory(), jbPermissions(), FEE_PROJECT_ID, multisig());

        // Deploy REAL buyback hook with real PoolManager.
        BUYBACK_HOOK = new JBBuybackHook(
            jbDirectory(),
            jbPermissions(),
            jbPrices(),
            jbProjects(),
            jbTokens(),
            poolManager,
            IHooks(address(0)), // oracleHook
            address(0) // trustedForwarder
        );

        // Deploy the registry and set the buyback hook as the default.
        BUYBACK_REGISTRY = new JBBuybackHookRegistry(
            jbPermissions(),
            jbProjects(),
            address(this), // owner
            address(0) // trustedForwarder
        );
        BUYBACK_REGISTRY.setDefaultHook(IJBRulesetDataHook(address(BUYBACK_HOOK)));

        LOANS_CONTRACT = new REVLoans({
            controller: jbController(),
            projects: jbProjects(),
            revId: FEE_PROJECT_ID,
            owner: address(this),
            permit2: permit2(),
            trustedForwarder: TRUSTED_FORWARDER
        });

        REV_DEPLOYER = new REVDeployer{salt: "REVDeployer_Fork"}(
            jbController(),
            SUCKER_REGISTRY,
            FEE_PROJECT_ID,
            HOOK_DEPLOYER,
            PUBLISHER,
            IJBBuybackHookRegistry(address(BUYBACK_REGISTRY)),
            address(LOANS_CONTRACT),
            TRUSTED_FORWARDER
        );

        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);

        // Fund the payer.
        vm.deal(PAYER, 100 ether);
    }

    // ───────────────────────── Helpers
    // ─────────────────────────

    function _buildMinimalConfig()
        internal
        view
        returns (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc)
    {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
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
            initialIssuance: INITIAL_ISSUANCE,
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 5000,
            extraMetadata: 0
        });

        cfg = REVConfig({
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription("Fork Test", "FORK", "ipfs://fork", "FORK_SALT"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });

        sdc = REVSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("FORK_TEST"))
        });
    }

    function _build721Config() internal view returns (REVDeploy721TiersHookConfig memory) {
        JB721TierConfig[] memory tiers = new JB721TierConfig[](1);
        JBSplit[] memory tierSplits = new JBSplit[](1);
        tierSplits[0] = JBSplit({
            preferAddToBalance: false,
            percent: uint32(JBConstants.SPLITS_TOTAL_PERCENT),
            projectId: 0,
            beneficiary: payable(SPLIT_BENEFICIARY),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        tiers[0] = JB721TierConfig({
            price: TIER_PRICE,
            initialSupply: 100,
            votingUnits: 0,
            reserveFrequency: 0,
            reserveBeneficiary: address(0),
            // forge-lint: disable-next-line(unsafe-typecast)
            encodedIPFSUri: bytes32("tier1"),
            category: 1,
            discountPercent: 0,
            allowOwnerMint: false,
            useReserveBeneficiaryAsDefault: false,
            transfersPausable: false,
            useVotingUnits: false,
            cannotBeRemoved: false,
            cannotIncreaseDiscountPercent: false,
            splitPercent: SPLIT_PERCENT,
            splits: tierSplits
        });

        return REVDeploy721TiersHookConfig({
            baseline721HookConfiguration: REVBaseline721HookConfig({
                name: "Fork NFT",
                symbol: "FNFT",
                baseUri: "ipfs://",
                tokenUriResolver: IJB721TokenUriResolver(address(0)),
                contractUri: "ipfs://contract",
                tiersConfig: JB721InitTiersConfig({
                    tiers: tiers, currency: uint32(uint160(JBConstants.NATIVE_TOKEN)), decimals: 18
                }),
                reserveBeneficiary: address(0),
                flags: REV721TiersHookFlags({
                    noNewTiersWithReserves: false,
                    noNewTiersWithVotes: false,
                    noNewTiersWithOwnerMinting: false,
                    preventOverspending: false
                })
            }),
            // forge-lint: disable-next-line(unsafe-typecast)
            salt: bytes32("FORK_721"),
            preventSplitOperatorAdjustingTiers: false,
            preventSplitOperatorUpdatingMetadata: false,
            preventSplitOperatorMinting: false,
            preventSplitOperatorIncreasingDiscountPercent: false
        });
    }

    /// @notice Deploy the fee project, then deploy a revnet with 721 tiers.
    function _deployRevnetWith721() internal returns (uint256 revnetId, IJB721TiersHook hook) {
        // Deploy fee project first.
        (REVConfig memory feeCfg, JBTerminalConfig[] memory feeTc, REVSuckerDeploymentConfig memory feeSdc) =
            _buildMinimalConfig();
        // forge-lint: disable-next-line(named-struct-fields)
        feeCfg.description = REVDescription("Fee", "FEE", "ipfs://fee", "FEE_SALT");

        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeCfg,
            terminalConfigurations: feeTc,
            suckerDeploymentConfiguration: feeSdc,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        // Deploy the revnet with 721 hook.
        (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc) =
            _buildMinimalConfig();
        REVDeploy721TiersHookConfig memory hookConfig = _build721Config();

        (revnetId, hook) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: cfg,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: sdc,
            tiered721HookConfiguration: hookConfig,
            allowedPosts: new REVCroptopAllowedPost[](0)
        });
    }

    /// @notice Set up a V4 pool for the revnet's project token / native ETH pair and register it with the buyback hook.
    function _setupPool(uint256 revnetId, uint256 liquidityTokenAmount) internal returns (PoolKey memory key) {
        // Get the project token.
        address projectToken = address(jbTokens().tokenOf(revnetId));
        require(projectToken != address(0), "project token not deployed");

        // Native ETH is represented as address(0) in V4 pool keys.
        // address(0) is always less than any deployed token address.
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(projectToken),
            fee: REV_DEPLOYER.DEFAULT_BUYBACK_POOL_FEE(),
            tickSpacing: REV_DEPLOYER.DEFAULT_BUYBACK_TICK_SPACING(),
            hooks: IHooks(address(0))
        });

        // Pool is already initialized at 1:1 price by REVDeployer during deployment.
        // Just add liquidity and mock the oracle.

        // Fund LiquidityHelper with project tokens via JBTokens.mintFor (not deal).
        // deal() skips ERC20Votes checkpoints, causing underflow when tokens are burned.
        vm.prank(address(jbController()));
        jbTokens().mintFor(address(liqHelper), revnetId, liquidityTokenAmount);
        // Fund with ETH for the native currency side.
        vm.deal(address(liqHelper), liquidityTokenAmount);

        // Approve PoolManager to spend project tokens from LiquidityHelper.
        vm.startPrank(address(liqHelper));
        IERC20(projectToken).approve(address(poolManager), type(uint256).max);
        vm.stopPrank();

        // Add full-range liquidity.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 liquidityDelta = int256(liquidityTokenAmount / 2);
        vm.prank(address(liqHelper));
        liqHelper.addLiquidity{value: liquidityTokenAmount}(key, TICK_LOWER, TICK_UPPER, liquidityDelta);

        // Mock the oracle at address(0) for hookless pools.
        _mockOracle(liquidityDelta, 0, uint32(REV_DEPLOYER.DEFAULT_BUYBACK_TWAP_WINDOW()));
    }

    /// @notice Mock the IGeomeanOracle at address(0) for hookless pools.
    /// @param liquidity The liquidity to use for secondsPerLiquidity computation.
    /// @param tick The TWAP tick to report (e.g. 0 for 1:1 price).
    /// @param twapWindow The TWAP window in seconds (must match the buyback hook's configured window).
    function _mockOracle(int256 liquidity, int24 tick, uint32 twapWindow) internal {
        // Etch minimal bytecode at address(0) so it's treated as a contract.
        vm.etch(address(0), hex"00");

        int56[] memory tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        // arithmeticMeanTick = (tickCumulatives[1] - tickCumulatives[0]) / twapWindow = tick
        // forge-lint: disable-next-line(unsafe-typecast)
        tickCumulatives[1] = int56(tick) * int56(int32(twapWindow));

        uint136[] memory secondsPerLiquidityCumulativeX128s = new uint136[](2);
        secondsPerLiquidityCumulativeX128s[0] = 0;
        uint256 liq = uint256(liquidity > 0 ? liquidity : -liquidity);
        if (liq == 0) liq = 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        secondsPerLiquidityCumulativeX128s[1] = uint136((uint256(twapWindow) << 128) / liq);

        vm.mockCall(
            address(0),
            abi.encodeWithSelector(IGeomeanOracle.observe.selector),
            abi.encode(tickCumulatives, secondsPerLiquidityCumulativeX128s)
        );
    }

    /// @notice Build payment metadata with both 721 tier selection AND buyback quote.
    function _buildPayMetadataWithQuote(
        address hookMetadataTarget,
        uint256 amountToSwapWith,
        uint256 minimumSwapAmountOut
    )
        internal
        view
        returns (bytes memory)
    {
        // 721 tier metadata: mint tier 1.
        uint16[] memory tierIds = new uint16[](1);
        tierIds[0] = 1;
        bytes memory tierData = abi.encode(true, tierIds); // (allowOverspending, tierIdsToMint)
        bytes4 tierMetadataId = JBMetadataResolver.getId("pay", hookMetadataTarget);

        // Buyback quote metadata.
        bytes memory quoteData = abi.encode(amountToSwapWith, minimumSwapAmountOut);
        bytes4 quoteMetadataId = JBMetadataResolver.getId("quote");

        // Combine both metadata entries.
        bytes4[] memory ids = new bytes4[](2);
        ids[0] = tierMetadataId;
        ids[1] = quoteMetadataId;
        bytes[] memory datas = new bytes[](2);
        datas[0] = tierData;
        datas[1] = quoteData;

        return JBMetadataResolver.createMetadata(ids, datas);
    }

    /// @notice Build payment metadata with only 721 tier selection (no quote → TWAP/spot fallback).
    function _buildPayMetadataNoQuote(address hookMetadataTarget) internal pure returns (bytes memory) {
        uint16[] memory tierIds = new uint16[](1);
        tierIds[0] = 1;
        bytes memory tierData = abi.encode(true, tierIds);
        bytes4 tierMetadataId = JBMetadataResolver.getId("pay", hookMetadataTarget);

        bytes4[] memory ids = new bytes4[](1);
        ids[0] = tierMetadataId;
        bytes[] memory datas = new bytes[](1);
        datas[0] = tierData;

        return JBMetadataResolver.createMetadata(ids, datas);
    }

    // ───────────────────────── Tests
    // ─────────────────────────

    /// @notice SWAP PATH: Pool offers good rate → buyback hook swaps on AMM instead of minting.
    /// With 30% tier split, the buyback should swap with 0.7 ETH worth.
    /// Terminal mints 0 tokens (weight=0), buyback hook mints via controller after swap.
    function test_fork_swapPath_splitWithBuyback() public {
        (uint256 revnetId, IJB721TiersHook hook) = _deployRevnetWith721();

        // We need to initialize the pool and get the price to favor buying project tokens: > 1000 tokens/ETH.
        // Strategy: initialize pool, add liquidity, then swap project tokens for ETH to move the tick.

        address projectToken = address(jbTokens().tokenOf(revnetId));
        require(projectToken != address(0), "project token not deployed");

        // Native ETH is address(0), always less than any deployed token.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(projectToken),
            fee: REV_DEPLOYER.DEFAULT_BUYBACK_POOL_FEE(),
            tickSpacing: REV_DEPLOYER.DEFAULT_BUYBACK_TICK_SPACING(),
            hooks: IHooks(address(0))
        });

        // Pool is already initialized at 1:1 price by REVDeployer during deployment.

        // Seed liquidity. We need both tokens.
        // IMPORTANT: Use JBTokens.mintFor (not deal) so ERC20Votes checkpoints are updated.
        uint256 projectLiq = 10_000_000e18;
        uint256 ethLiq = 5000e18;

        vm.prank(address(jbController()));
        jbTokens().mintFor(address(liqHelper), revnetId, projectLiq);
        vm.deal(address(liqHelper), ethLiq);

        vm.startPrank(address(liqHelper));
        IERC20(projectToken).approve(address(poolManager), type(uint256).max);
        vm.stopPrank();

        // Add full-range liquidity at tick 0 (1:1 price).
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 liquidityDelta = int256(ethLiq / 4);
        vm.prank(address(liqHelper));
        liqHelper.addLiquidity{value: ethLiq}(key, TICK_LOWER, TICK_UPPER, liquidityDelta);

        // Swap a large amount of project tokens for ETH to move the price.
        // This makes project tokens cheaper (more tokens per ETH) so the swap path wins.
        uint256 swapAmount = 5_000_000e18;
        vm.prank(address(jbController()));
        jbTokens().mintFor(address(liqHelper), revnetId, swapAmount);

        // currency0 is native ETH (address(0)), currency1 is projectToken.
        // To sell projectToken for ETH (making project tokens cheaper), swap 1->0 (zeroForOne = false).
        // zeroForOne=false pushes sqrtPrice up (more projectTokens per ETH).
        bool zeroForOne = false;
        uint160 sqrtPriceLimit = TickMath.getSqrtPriceAtTick(76_000);

        vm.prank(address(liqHelper));
        // forge-lint: disable-next-line(unsafe-typecast)
        liqHelper.swap(key, zeroForOne, -int256(swapAmount), sqrtPriceLimit);

        // Read the post-swap tick for the oracle mock.
        (, int24 postSwapTick,,) = poolManager.getSlot0(key.toId());

        // Mock the TWAP oracle to report the post-swap tick (so buyback hook sees the real price).
        _mockOracle(liquidityDelta, postSwapTick, uint32(REV_DEPLOYER.DEFAULT_BUYBACK_TWAP_WINDOW()));

        // Build metadata: mint tier 1 + quote for swap.
        // The quote tells buyback to swap with the full amount, expecting at least 1 token out.
        address metadataTarget = hook.METADATA_ID_TARGET();
        bytes memory metadata = _buildPayMetadataWithQuote({
            hookMetadataTarget: metadataTarget,
            amountToSwapWith: 0.7 ether, // projectAmount after 30% split
            minimumSwapAmountOut: 1 // Accept any amount from swap
        });

        // Pay 1 ETH through the terminal.
        vm.prank(PAYER);
        uint256 terminalTokensReturned = jbMultiTerminal().pay{value: 1 ether}({
            projectId: revnetId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: PAYER,
            minReturnedTokens: 0,
            memo: "Fork: swap path with splits",
            metadata: metadata
        });

        // pay() returns beneficiaryBalanceAfter - beneficiaryBalanceBefore, capturing ALL token sources.
        // In the SWAP path:
        //   - Terminal mints 0 tokens (weight=0 from buyback hook)
        //   - Buyback hook's afterPay swaps 0.7 ETH on AMM and mints via controller
        //   - Pool at ~2000:1 price → 0.7 ETH yields ~1400 tokens (minus pool fee)
        //   - pay() returns the total (0 from terminal + ~1400 from buyback swap)
        //   - More than the 700 tokens minting would produce → swap was the right call
        assertGt(terminalTokensReturned, 700e18, "swap path: should get more tokens than minting (pool rate better)");

        console.log(
            "  Swap path: buyback swapped for %s tokens (minting would give 700)", terminalTokensReturned / 1e18
        );
    }

    /// @notice MINT PATH: Pool offers bad rate → buyback decides minting is better.
    /// With 30% tier split, REVDeployer scales weight from 1000e18 to 700e18.
    /// Terminal mints 700 tokens.
    function test_fork_mintPath_splitWithBuyback() public {
        (uint256 revnetId, IJB721TiersHook hook) = _deployRevnetWith721();

        // Set up pool with 1:1 price. At this price:
        //   0.7 ETH → ~0.7 tokens from pool (after fees).
        //   Direct minting: 700 tokens.
        //   Minting wins by a huge margin → buyback returns context.weight unchanged.
        _setupPool(revnetId, 10_000 ether);

        // Build metadata: mint tier 1 + quote for "swap" with 0.7 ETH, but expect many tokens (forces mint path).
        // When minimumSwapAmountOut > actual pool output, the buyback hook falls back to minting.
        // Actually the buyback hook uses max(payerQuote, twapQuote). If we set minimumSwapAmountOut=0,
        // it'll use the TWAP/spot quote. At 1:1 pool price, spot says ~0.7 tokens for 0.7 ETH.
        // tokenCountWithoutHook = 700 tokens. 700 > ~0.7 → mint wins.
        // We don't even need quote metadata — the spot fallback handles it.
        address metadataTarget = hook.METADATA_ID_TARGET();
        bytes memory metadata = _buildPayMetadataNoQuote(metadataTarget);

        // Pay 1 ETH through the terminal.
        vm.prank(PAYER);
        uint256 tokensReceived = jbMultiTerminal().pay{value: 1 ether}({
            projectId: revnetId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: PAYER,
            minReturnedTokens: 0,
            memo: "Fork: mint path with splits",
            metadata: metadata
        });

        // Mint path: buyback returns context.weight unchanged.
        // REVDeployer scales: weight = 1000e18 * 0.7e18 / 1e18 = 700e18.
        // Terminal: tokenCount = mulDiv(1e18, 700e18, 1e18) = 700e18.
        uint256 expectedTokens = 700e18;

        assertEq(tokensReceived, expectedTokens, "mint path: should receive 700 tokens (weight scaled for 30% split)");

        console.log("  Mint path: terminal minted %s tokens (expected 700)", tokensReceived / 1e18);
    }

    /// @notice MINT PATH without splits: baseline confirming 1000 tokens for 1 ETH.
    function test_fork_mintPath_noSplits_fullTokens() public {
        (uint256 revnetId,) = _deployRevnetWith721();
        _setupPool(revnetId, 10_000 ether);

        // Pay 1 ETH with NO tier metadata (no NFT purchase, no splits).
        vm.prank(PAYER);
        uint256 tokensReceived = jbMultiTerminal().pay{value: 1 ether}({
            projectId: revnetId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: PAYER,
            minReturnedTokens: 0,
            memo: "Fork: no split baseline",
            metadata: ""
        });

        // No splits → no weight reduction. Full 1000 tokens.
        uint256 expectedTokens = 1000e18;
        assertEq(tokensReceived, expectedTokens, "no splits: should receive 1000 tokens");
    }

    /// @notice Invariant: tokens / projectAmount rate is identical with and without splits.
    function test_fork_invariant_tokenPerEthConsistent() public {
        // --- Revnet 1: with 721 splits (30%) ---
        (uint256 revnetId1, IJB721TiersHook hook1) = _deployRevnetWith721();
        _setupPool(revnetId1, 10_000 ether);

        address metadataTarget1 = hook1.METADATA_ID_TARGET();
        bytes memory metadata1 = _buildPayMetadataNoQuote(metadataTarget1);

        vm.prank(PAYER);
        uint256 tokens1 = jbMultiTerminal().pay{value: 1 ether}({
            projectId: revnetId1,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: PAYER,
            minReturnedTokens: 0,
            memo: "invariant: with splits",
            metadata: metadata1
        });

        // --- Revnet 2: no splits (plain payment, no tier metadata) ---
        // Deploy a second revnet without 721 hook.
        (REVConfig memory cfg2, JBTerminalConfig[] memory tc2, REVSuckerDeploymentConfig memory sdc2) =
            _buildMinimalConfig();
        // forge-lint: disable-next-line(named-struct-fields)
        cfg2.description = REVDescription("NoSplit Fork", "NSF", "ipfs://nosplit", "NSF_SALT");

        (uint256 revnetId2,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: cfg2,
            terminalConfigurations: tc2,
            suckerDeploymentConfiguration: sdc2,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        // Set up pool for revnet2 too (so buyback hook has a pool, but will choose mint at 1:1).
        _setupPool(revnetId2, 10_000 ether);

        vm.prank(PAYER);
        uint256 tokens2 = jbMultiTerminal().pay{value: 1 ether}({
            projectId: revnetId2,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: PAYER,
            minReturnedTokens: 0,
            memo: "invariant: no splits",
            metadata: ""
        });

        // Rate check: tokens / projectAmount should be the same.
        // Revnet 1: 700 tokens / 0.7 ETH = 1000 tokens/ETH
        // Revnet 2: 1000 tokens / 1.0 ETH = 1000 tokens/ETH
        uint256 projectAmount1 = 0.7 ether;
        uint256 projectAmount2 = 1 ether;

        uint256 rate1 = (tokens1 * 1e18) / projectAmount1;
        uint256 rate2 = (tokens2 * 1e18) / projectAmount2;

        assertEq(rate1, rate2, "token-per-ETH rate should be identical with and without splits");
    }
}
