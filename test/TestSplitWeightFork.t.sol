// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import /* {*} from */ "./../src/REVDeployer.sol";
import "@croptop/core-v6/src/CTPublisher.sol";
import "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
import "@bananapus/721-hook-v6/script/helpers/Hook721DeploymentLib.sol";
import "@bananapus/suckers-v6/script/helpers/SuckerDeploymentLib.sol";
import "@croptop/core-v6/script/helpers/CroptopDeploymentLib.sol";
import "@bananapus/router-terminal-v6/script/helpers/RouterTerminalDeploymentLib.sol";

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
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
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {REVBaseline721HookConfig} from "../src/structs/REVBaseline721HookConfig.sol";
import {REV721TiersHookFlags} from "../src/structs/REV721TiersHookFlags.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JB721InitTiersConfig} from "@bananapus/721-hook-v6/src/structs/JB721InitTiersConfig.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {REVDeploy721TiersHookConfig} from "../src/structs/REVDeploy721TiersHookConfig.sol";
import {REVCroptopAllowedPost} from "../src/structs/REVCroptopAllowedPost.sol";

// Buyback hook
import {JBBuybackHook} from "@bananapus/buyback-hook-v6/src/JBBuybackHook.sol";
import {IJBBuybackHook} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHook.sol";
import {IWETH9} from "@bananapus/buyback-hook-v6/src/interfaces/external/IWETH9.sol";
import {IGeomeanOracle} from "@bananapus/buyback-hook-v6/src/interfaces/IGeomeanOracle.sol";

// Uniswap V4
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/// @notice Helper that adds liquidity to a V4 pool via the unlock/callback pattern.
contract LiquidityHelper is IUnlockCallback {
    IPoolManager public immutable poolManager;

    struct AddLiqParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
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
        bytes memory data = abi.encode(AddLiqParams(key, tickLower, tickUpper, liquidityDelta));
        poolManager.unlock(data);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "only PM");

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

    function _settleIfNegative(Currency currency, int128 delta) internal {
        if (delta >= 0) return;
        uint256 amount = uint256(uint128(-delta));

        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).transfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    function _takeIfPositive(Currency currency, int128 delta) internal {
        if (delta <= 0) return;
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
    address constant WETH_ADDR = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice Full-range tick bounds for tickSpacing = 60.
    int24 constant TICK_LOWER = -887_220;
    int24 constant TICK_UPPER = 887_220;

    // ───────────────────────── State
    // ─────────────────────────

    REVDeployer REV_DEPLOYER;
    JBBuybackHook BUYBACK_HOOK;
    JB721TiersHook EXAMPLE_HOOK;
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    IJB721TiersHookStore HOOK_STORE;
    IJBAddressRegistry ADDRESS_REGISTRY;
    IREVLoans LOANS_CONTRACT;
    IJBSuckerRegistry SUCKER_REGISTRY;
    CTPublisher PUBLISHER;
    IPoolManager poolManager;
    IWETH9 weth;
    LiquidityHelper liqHelper;

    uint256 FEE_PROJECT_ID;

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;
    address PAYER = makeAddr("payer");
    address SPLIT_BENEFICIARY = makeAddr("splitBeneficiary");

    // Tier configuration: 1 ETH tier with 30% split.
    uint104 constant TIER_PRICE = 1 ether;
    uint32 constant SPLIT_PERCENT = 300_000_000; // 30% of SPLITS_TOTAL_PERCENT (1_000_000_000)
    uint112 constant INITIAL_ISSUANCE = 1000e18; // 1000 tokens per ETH

    // ───────────────────────── Setup
    // ─────────────────────────

    function setUp() public override {
        // Fork mainnet first — we need the real V4 PoolManager.
        string memory rpcUrl = vm.envOr("RPC_ETHEREUM_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl);

        // Verify V4 PoolManager is deployed.
        require(POOL_MANAGER_ADDR.code.length > 0, "PoolManager not deployed at expected address");

        // Deploy fresh JB core on the forked mainnet.
        super.setUp();

        poolManager = IPoolManager(POOL_MANAGER_ADDR);
        weth = IWETH9(WETH_ADDR);
        liqHelper = new LiquidityHelper(poolManager);

        FEE_PROJECT_ID = jbProjects().createFor(multisig());

        SUCKER_REGISTRY = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig(), address(0));
        HOOK_STORE = new JB721TiersHookStore();
        EXAMPLE_HOOK =
            new JB721TiersHook(jbDirectory(), jbPermissions(), jbRulesets(), HOOK_STORE, jbSplits(), multisig());
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
            weth,
            poolManager,
            address(0) // trustedForwarder
        );

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
            IJBRulesetDataHook(address(BUYBACK_HOOK)),
            address(LOANS_CONTRACT),
            TRUSTED_FORWARDER
        );

        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);

        // Fund the payer.
        vm.deal(PAYER, 100 ether);
    }

    modifier onlyFork() {
        string memory rpcUrl = vm.envOr("RPC_ETHEREUM_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) return;
        _;
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
                    tiers: tiers,
                    currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                    decimals: 18,
                    prices: IJBPrices(address(0))
                }),
                reserveBeneficiary: address(0),
                flags: REV721TiersHookFlags({
                    noNewTiersWithReserves: false,
                    noNewTiersWithVotes: false,
                    noNewTiersWithOwnerMinting: false,
                    preventOverspending: false
                })
            }),
            salt: bytes32("FORK_721"),
            splitOperatorCanAdjustTiers: false,
            splitOperatorCanUpdateMetadata: false,
            splitOperatorCanMint: false,
            splitOperatorCanIncreaseDiscountPercent: false
        });
    }

    /// @notice Deploy the fee project, then deploy a revnet with 721 tiers.
    function _deployRevnetWith721() internal returns (uint256 revnetId, IJB721TiersHook hook) {
        // Deploy fee project first.
        (REVConfig memory feeCfg, JBTerminalConfig[] memory feeTc, REVSuckerDeploymentConfig memory feeSdc) =
            _buildMinimalConfig();
        feeCfg.description = REVDescription("Fee", "FEE", "ipfs://fee", "FEE_SALT");

        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeCfg,
            terminalConfigurations: feeTc,
            suckerDeploymentConfiguration: feeSdc
        });

        // Deploy the revnet with 721 hook.
        (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc) =
            _buildMinimalConfig();
        REVDeploy721TiersHookConfig memory hookConfig = _build721Config();

        (revnetId, hook) = REV_DEPLOYER.deployWith721sFor({
            revnetId: 0,
            configuration: cfg,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: sdc,
            tiered721HookConfiguration: hookConfig,
            allowedPosts: new REVCroptopAllowedPost[](0)
        });
    }

    /// @notice Set up a V4 pool for the revnet's project token / WETH pair and register it with the buyback hook.
    function _setupPool(uint256 revnetId, uint256 liquidityTokenAmount) internal returns (PoolKey memory key) {
        // Get the project token.
        address projectToken = address(jbTokens().tokenOf(revnetId));
        require(projectToken != address(0), "project token not deployed");

        // Build sorted pool key.
        address token0;
        address token1;
        if (projectToken < WETH_ADDR) {
            token0 = projectToken;
            token1 = WETH_ADDR;
        } else {
            token0 = WETH_ADDR;
            token1 = projectToken;
        }

        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: REV_DEPLOYER.DEFAULT_BUYBACK_POOL_FEE(),
            tickSpacing: REV_DEPLOYER.DEFAULT_BUYBACK_TICK_SPACING(),
            hooks: IHooks(address(0))
        });

        // Initialize pool at price = 1.0 (tick 0).
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(0);
        poolManager.initialize(key, sqrtPrice);

        // Fund LiquidityHelper with project tokens via JBTokens.mintFor (not deal).
        // deal() skips ERC20Votes checkpoints, causing underflow when tokens are burned.
        vm.prank(address(jbController()));
        jbTokens().mintFor(address(liqHelper), revnetId, liquidityTokenAmount);
        vm.deal(address(liqHelper), liquidityTokenAmount);
        vm.prank(address(liqHelper));
        IWETH9(WETH_ADDR).deposit{value: liquidityTokenAmount}();

        // Approve PoolManager to spend tokens from LiquidityHelper.
        vm.startPrank(address(liqHelper));
        IERC20(projectToken).approve(address(poolManager), type(uint256).max);
        IERC20(WETH_ADDR).approve(address(poolManager), type(uint256).max);
        vm.stopPrank();

        // Add full-range liquidity.
        int256 liquidityDelta = int256(liquidityTokenAmount / 2);
        vm.prank(address(liqHelper));
        liqHelper.addLiquidity(key, TICK_LOWER, TICK_UPPER, liquidityDelta);

        // Mock the oracle at address(0) for hookless pools.
        // The buyback hook calls IGeomeanOracle(address(key.hooks)).observe() for TWAP.
        // Since hooks = address(0), we need code there + a mock response.
        // tick=0 means 1:1 price → TWAP says pool rate is ~1 token/WETH → minting wins.
        _mockOracle(liquidityDelta, 0, uint32(REV_DEPLOYER.DEFAULT_BUYBACK_TWAP_WINDOW()));

        // Cache immutables before prank (vm.prank only applies to the next call).
        uint256 twapWindow = REV_DEPLOYER.DEFAULT_BUYBACK_TWAP_WINDOW();

        // Register pool with buyback hook via split operator (multisig has SET_BUYBACK_POOL permission).
        vm.prank(multisig());
        BUYBACK_HOOK.setPoolFor({
            projectId: revnetId, poolKey: key, twapWindow: twapWindow, terminalToken: JBConstants.NATIVE_TOKEN
        });
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
        tickCumulatives[1] = int56(tick) * int56(int32(twapWindow));

        uint160[] memory secondsPerLiquidityCumulativeX128s = new uint160[](2);
        secondsPerLiquidityCumulativeX128s[0] = 0;
        uint256 liq = uint256(liquidity > 0 ? liquidity : -liquidity);
        if (liq == 0) liq = 1;
        secondsPerLiquidityCumulativeX128s[1] = uint160((uint256(twapWindow) << 128) / liq);

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
    function _buildPayMetadataNoQuote(address hookMetadataTarget) internal view returns (bytes memory) {
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
    function test_fork_swapPath_splitWithBuyback() public onlyFork {
        (uint256 revnetId, IJB721TiersHook hook) = _deployRevnetWith721();

        // Set up pool with deep liquidity at 1:1 price (pool offers ~1 token per WETH).
        // The issuance rate is 1000 tokens/ETH, so the pool rate (~1 token/WETH) is much worse.
        // Wait — at 1:1 pool price, 1 WETH gets ~1 token. Minting gets 1000 tokens.
        // So minting is better → buyback will NOT swap.
        // To make swap win, we need the pool to offer MORE tokens per WETH than minting.
        // Minting rate = 1000 tokens/ETH (before split reduction, the buyback sees reduced weight).
        //
        // After REVDeployer scales weight: weight = 1000e18 * 0.7e18 / 1e18 = 700e18
        // The buyback hook receives weight=700e18 and amount=0.7 ETH.
        // tokenCountWithoutHook = mulDiv(0.7e18, 700e18, 1e18) = 490 tokens.
        //
        // Wait, that's wrong. Let me re-trace:
        // REVDeployer.beforePayRecordedWith:
        //   1. 721 hook returns splitAmount=0.3 ETH → projectAmount = 0.7 ETH
        //   2. buybackHookContext.amount.value = 0.7 ETH, weight = context.weight = 1000e18
        //   3. Buyback hook sees: amountToSwapWith = 0.7 ETH, weight = 1000e18
        //      tokenCountWithoutHook = mulDiv(0.7e18, 1000e18, 1e18) = 700 tokens
        //   4. If pool offers > 700 tokens for 0.7 WETH → swap wins
        //   5. If pool offers < 700 tokens → mint wins
        //
        // At 1:1 pool price, 0.7 WETH gets ~0.7 tokens (after fees). That's way less than 700.
        // We need a pool priced so projectToken is CHEAP — e.g., 1 WETH = 2000 tokens.
        //
        // Let's create a pool at a tick where projectToken is very cheap.
        // tick = -69_000 gives approximately 1 WETH = 1000 tokens. We want more than 700 for 0.7 WETH.
        // Actually, let's just seed the pool with lots of project tokens and little WETH.
        // This naturally makes project tokens cheaper.

        // Instead of tick manipulation, let's just use a pool at tick 0 (1:1) but seed asymmetrically:
        // Lots of project tokens, little WETH → effective price favors the buyer.
        // Actually V4 pool price is set at initialization (sqrtPriceX96), seeding doesn't change the tick.
        //
        // Let's initialize at a tick where 1 WETH = many project tokens.
        // For swap to win: pool must give > 700 tokens for 0.7 WETH.
        // Rate needed: > 1000 tokens/WETH.
        // Use tick = -69082 which gives ~1:1000 ratio (1 WETH ≈ 1000 tokens).
        // With 0.3% fee and slippage, it might give ~997, which is still > 700. Swap wins.

        address projectToken = address(jbTokens().tokenOf(revnetId));
        require(projectToken != address(0), "project token not deployed");

        bool projectTokenIs0 = projectToken < WETH_ADDR;

        // Build sorted pool key.
        address token0 = projectTokenIs0 ? projectToken : WETH_ADDR;
        address token1 = projectTokenIs0 ? WETH_ADDR : projectToken;

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: REV_DEPLOYER.DEFAULT_BUYBACK_POOL_FEE(),
            tickSpacing: REV_DEPLOYER.DEFAULT_BUYBACK_TICK_SPACING(),
            hooks: IHooks(address(0))
        });

        // Set initial tick so that 1 WETH = ~2000 project tokens.
        // If projectToken is token0: price = token1/token0 = WETH/projectToken.
        //   We want projectToken cheap → WETH/projectToken high → tick positive.
        //   tick ~= 76_000 → price ~= 2000.
        // If WETH is token0: price = token1/token0 = projectToken/WETH.
        //   We want projectToken/WETH high → tick positive.
        //   tick ~= 76_000 → price ~= 2000.
        // Either way: positive tick ≈ 2000 of token1 per token0.
        //
        // But we want "1 WETH = 2000 projectTokens".
        // If projectToken is token0: price = WETH per projectToken = 1/2000 → negative tick.
        //   tick ≈ -76_000.
        // If WETH is token0: price = projectToken per WETH = 2000 → positive tick.
        //   tick ≈ 76_000.
        int24 initTick;
        if (projectTokenIs0) {
            // price = WETH/projectToken = 0.0005 → tick ≈ -76_000
            initTick = -76_020; // Rounded to tickSpacing=60
        } else {
            // price = projectToken/WETH = 2000 → tick ≈ 76_000
            initTick = 76_020;
        }

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(initTick);
        poolManager.initialize(key, sqrtPrice);

        // Seed liquidity. We need both tokens.
        // IMPORTANT: Use JBTokens.mintFor (not deal) so ERC20Votes checkpoints are updated.
        // deal() only sets balanceOf/totalSupply but skips Votes checkpoints, causing burn underflow.
        uint256 projectLiq = 10_000_000e18; // lots of project tokens
        uint256 wethLiq = 5000e18; // some WETH

        vm.prank(address(jbController()));
        jbTokens().mintFor(address(liqHelper), revnetId, projectLiq);
        vm.deal(address(liqHelper), wethLiq);
        vm.prank(address(liqHelper));
        IWETH9(WETH_ADDR).deposit{value: wethLiq}();

        vm.startPrank(address(liqHelper));
        IERC20(projectToken).approve(address(poolManager), type(uint256).max);
        IERC20(WETH_ADDR).approve(address(poolManager), type(uint256).max);
        vm.stopPrank();

        // Add full-range liquidity.
        int256 liquidityDelta = int256(wethLiq / 4); // Use fraction for liquidity units
        vm.prank(address(liqHelper));
        liqHelper.addLiquidity(key, TICK_LOWER, TICK_UPPER, liquidityDelta);

        // Mock the oracle at address(0) to report the actual pool price (initTick).
        // This makes the TWAP quote reflect ~2000 tokens/WETH, so the swap path wins.
        _mockOracle(liquidityDelta, initTick, uint32(REV_DEPLOYER.DEFAULT_BUYBACK_TWAP_WINDOW()));

        // Register pool with buyback hook.
        uint256 twapWindow = REV_DEPLOYER.DEFAULT_BUYBACK_TWAP_WINDOW();
        vm.prank(multisig());
        BUYBACK_HOOK.setPoolFor({
            projectId: revnetId, poolKey: key, twapWindow: twapWindow, terminalToken: JBConstants.NATIVE_TOKEN
        });

        // Build metadata: mint tier 1 + quote for swap.
        // The quote tells buyback to swap with the full amount, expecting at least 1 token out.
        address metadataTarget = hook.METADATA_ID_TARGET();
        bytes memory metadata = _buildPayMetadataWithQuote({
            hookMetadataTarget: metadataTarget,
            amountToSwapWith: 0.7 ether, // projectAmount after 30% split
            minimumSwapAmountOut: 1 // Accept any amount from swap
        });

        // Record payer balance before.
        uint256 payerBalBefore = jbTokens().totalBalanceOf(PAYER, revnetId);

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
    function test_fork_mintPath_splitWithBuyback() public onlyFork {
        (uint256 revnetId, IJB721TiersHook hook) = _deployRevnetWith721();

        // Set up pool with 1:1 price. At this price:
        //   0.7 WETH → ~0.7 tokens from pool (after fees).
        //   Direct minting: 700 tokens.
        //   Minting wins by a huge margin → buyback returns context.weight unchanged.
        _setupPool(revnetId, 10_000 ether);

        // Build metadata: mint tier 1 + quote for "swap" with 0.7 ETH, but expect many tokens (forces mint path).
        // When minimumSwapAmountOut > actual pool output, the buyback hook falls back to minting.
        // Actually the buyback hook uses max(payerQuote, twapQuote). If we set minimumSwapAmountOut=0,
        // it'll use the TWAP/spot quote. At 1:1 pool price, spot says ~0.7 tokens for 0.7 WETH.
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
    function test_fork_mintPath_noSplits_fullTokens() public onlyFork {
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
    function test_fork_invariant_tokenPerEthConsistent() public onlyFork {
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
        cfg2.description = REVDescription("NoSplit Fork", "NSF", "ipfs://nosplit", "NSF_SALT");

        uint256 revnetId2 = REV_DEPLOYER.deployFor({
            revnetId: 0, configuration: cfg2, terminalConfigurations: tc2, suckerDeploymentConfiguration: sdc2
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
