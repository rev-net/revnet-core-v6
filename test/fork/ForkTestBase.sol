// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "../../src/REVDeployer.sol";
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
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JB721TierConfigFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierConfigFlags.sol";
import {JB721InitTiersConfig} from "@bananapus/721-hook-v6/src/structs/JB721InitTiersConfig.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {REVDeploy721TiersHookConfig} from "../../src/structs/REVDeploy721TiersHookConfig.sol";
import {REVBaseline721HookConfig} from "../../src/structs/REVBaseline721HookConfig.sol";
import {REV721TiersHookFlags} from "../../src/structs/REV721TiersHookFlags.sol";
import {REVCroptopAllowedPost} from "../../src/structs/REVCroptopAllowedPost.sol";
import {REVEmpty721Config} from "../helpers/REVEmpty721Config.sol";

// Buyback hook
import {JBBuybackHook} from "@bananapus/buyback-hook-v6/src/JBBuybackHook.sol";
import {JBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/JBBuybackHookRegistry.sol";
// forge-lint: disable-next-line(unused-import)
import {IJBBuybackHook} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHook.sol";
import {IGeomeanOracle} from "@bananapus/buyback-hook-v6/src/interfaces/IGeomeanOracle.sol";

// Uniswap V4
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
// forge-lint: disable-next-line(unused-import)
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
// forge-lint: disable-next-line(unused-import)
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {REVOwner} from "../../src/REVOwner.sol";
import {IREVDeployer} from "../../src/interfaces/IREVDeployer.sol";

/// @notice Helper that adds liquidity to a V4 pool via the unlock/callback pattern.
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
            params.key,
            // forge-lint: disable-next-line(named-struct-fields)
            SwapParams(params.zeroForOne, params.amountSpecified, params.sqrtPriceLimitX96),
            ""
        );

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

/// @notice Shared base for fork tests. Deploys full JB core + REVDeployer infrastructure on a mainnet fork.
///
/// Requires: RPC_ETHEREUM_MAINNET env var for mainnet fork (real PoolManager).
abstract contract ForkTestBase is TestBaseWorkflow {
    using JBMetadataResolver for bytes;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ───────────────────────── Mainnet constants
    // ─────────────────────────

    address constant POOL_MANAGER_ADDR = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    /// @notice Full-range tick bounds for tickSpacing = 60.
    int24 constant TICK_LOWER = -887_200;
    int24 constant TICK_UPPER = 887_200;

    // ───────────────────────── State
    // ─────────────────────────

    // forge-lint: disable-next-line(mixed-case-variable)
    REVDeployer REV_DEPLOYER;
    // forge-lint: disable-next-line(mixed-case-variable)
    REVOwner REV_OWNER;
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
    address BORROWER = makeAddr("borrower");
    // forge-lint: disable-next-line(mixed-case-variable)
    address SPLIT_BENEFICIARY = makeAddr("splitBeneficiary");

    // Tier configuration: 1 ETH tier with 30% split.
    uint104 constant TIER_PRICE = 1 ether;
    uint32 constant SPLIT_PERCENT = 300_000_000; // 30% of SPLITS_TOTAL_PERCENT (1_000_000_000)
    uint112 constant INITIAL_ISSUANCE = 1000e18; // 1000 tokens per ETH

    // ───────────────────────── Setup
    // ─────────────────────────

    function setUp() public virtual override {
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

        REV_OWNER = new REVOwner(
            IJBBuybackHookRegistry(address(BUYBACK_REGISTRY)),
            jbDirectory(),
            FEE_PROJECT_ID,
            SUCKER_REGISTRY,
            address(LOANS_CONTRACT),
            address(0)
        );

        REV_DEPLOYER = new REVDeployer{salt: "REVDeployer_Fork"}(
            jbController(),
            SUCKER_REGISTRY,
            FEE_PROJECT_ID,
            HOOK_DEPLOYER,
            PUBLISHER,
            IJBBuybackHookRegistry(address(BUYBACK_REGISTRY)),
            address(LOANS_CONTRACT),
            TRUSTED_FORWARDER,
            address(REV_OWNER)
        );

        REV_OWNER.setDeployer(REV_DEPLOYER);

        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);

        // Fund payer and borrower.
        vm.deal(PAYER, 100 ether);
        vm.deal(BORROWER, 100 ether);
    }

    // ───────────────────────── Config Helpers
    // ─────────────────────────

    function _buildMinimalConfig(uint16 cashOutTaxRate)
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
            cashOutTaxRate: cashOutTaxRate,
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
            flags: JB721TierConfigFlags({
                allowOwnerMint: false,
                useReserveBeneficiaryAsDefault: false,
                transfersPausable: false,
                useVotingUnits: false,
                cantBeRemoved: false,
                cantIncreaseDiscountPercent: false,
                cantBuyWithCredits: false
            }),
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

    // ───────────────────────── Deployment Helpers
    // ─────────────────────────

    /// @notice Deploy the fee project using the given tax rate.
    function _deployFeeProject(uint16 cashOutTaxRate) internal {
        (REVConfig memory feeCfg, JBTerminalConfig[] memory feeTc, REVSuckerDeploymentConfig memory feeSdc) =
            _buildMinimalConfig(cashOutTaxRate);
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
    }

    /// @notice Deploy a revnet (no 721 hook) with the given cash out tax rate.
    function _deployRevnet(uint16 cashOutTaxRate) internal returns (uint256 revnetId) {
        (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc) =
            _buildMinimalConfig(cashOutTaxRate);

        (revnetId,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: cfg,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: sdc,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    /// @notice Deploy a revnet with 721 tiers and the given cash out tax rate.
    function _deployRevnetWith721(uint16 cashOutTaxRate) internal returns (uint256 revnetId, IJB721TiersHook hook) {
        (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc) =
            _buildMinimalConfig(cashOutTaxRate);
        // Use a different salt to avoid CREATE2 collision with _deployRevnet's ERC-20.
        cfg.description.salt = "FORK_721_SALT";
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

    // ───────────────────────── Pool Helpers
    // ─────────────────────────

    /// @notice Set up a V4 pool for the revnet's project token / native ETH pair at 1:1 price.
    function _setupPool(uint256 revnetId, uint256 liquidityTokenAmount) internal returns (PoolKey memory key) {
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

        // Pool is already initialized at fair issuance price by REVDeployer during deployment.
        // At high tick (~69078 for 1000 tokens/ETH), full-range liquidity needs ~32x more project tokens than ETH.
        // Mint 50x project tokens and use a smaller liquidity delta to stay within budget.
        vm.prank(address(jbController()));
        jbTokens().mintFor(address(liqHelper), revnetId, liquidityTokenAmount * 50);
        // Fund with ETH for the native currency side.
        vm.deal(address(liqHelper), liquidityTokenAmount);

        vm.startPrank(address(liqHelper));
        IERC20(projectToken).approve(address(poolManager), type(uint256).max);
        vm.stopPrank();

        // forge-lint: disable-next-line(unsafe-typecast)
        int256 liquidityDelta = int256(liquidityTokenAmount / 50);
        vm.prank(address(liqHelper));
        liqHelper.addLiquidity{value: liquidityTokenAmount}(key, TICK_LOWER, TICK_UPPER, liquidityDelta);

        // Mock geomean oracle at tick 69078 (~1000 tokens/ETH, matching INITIAL_ISSUANCE).
        _mockOracle(liquidityDelta, 69_078, uint32(REV_DEPLOYER.DEFAULT_BUYBACK_TWAP_WINDOW()));
    }

    /// @notice Mock the IGeomeanOracle at address(0) for hookless pools.
    function _mockOracle(int256 liquidity, int24 tick, uint32 twapWindow) internal {
        vm.etch(address(0), hex"00");

        int56[] memory tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
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

    // ───────────────────────── Balance Helpers
    // ─────────────────────────

    /// @notice Get a project's balance in the terminal store.
    function _terminalBalance(uint256 projectId, address token) internal view returns (uint256) {
        return jbTerminalStore().balanceOf(address(jbMultiTerminal()), projectId, token);
    }

    // ───────────────────────── Payment Helpers
    // ─────────────────────────

    /// @notice Pay the revnet with ETH.
    function _payRevnet(uint256 revnetId, address payer, uint256 amount) internal returns (uint256 tokensReceived) {
        vm.prank(payer);
        tokensReceived = jbMultiTerminal().pay{value: amount}({
            projectId: revnetId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }

    // ───────────────────────── Metadata Helpers
    // ─────────────────────────

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
        uint16[] memory tierIds = new uint16[](1);
        tierIds[0] = 1;
        bytes memory tierData = abi.encode(true, tierIds);
        bytes4 tierMetadataId = JBMetadataResolver.getId("pay", hookMetadataTarget);

        bytes memory quoteData = abi.encode(amountToSwapWith, minimumSwapAmountOut);
        bytes4 quoteMetadataId = JBMetadataResolver.getId("quote");

        bytes4[] memory ids = new bytes4[](2);
        ids[0] = tierMetadataId;
        ids[1] = quoteMetadataId;
        bytes[] memory datas = new bytes[](2);
        datas[0] = tierData;
        datas[1] = quoteData;

        return JBMetadataResolver.createMetadata(ids, datas);
    }

    /// @notice Build payment metadata with only 721 tier selection (no quote -> TWAP/spot fallback).
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

    // ───────────────────────── ERC721 Helpers
    // ─────────────────────────

    /// @notice Get the owner of a loan NFT. REVLoans is ERC721 but typed as IREVLoans.
    function _loanOwnerOf(uint256 loanId) internal view returns (address) {
        return REVLoans(payable(address(LOANS_CONTRACT))).ownerOf(loanId);
    }

    // ───────────────────────── Loan Helpers
    // ─────────────────────────

    /// @notice Build a native token loan source.
    function _nativeLoanSource() internal view returns (REVLoanSource memory) {
        return REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
    }

    /// @notice Grant BURN_TOKENS permission to the loans contract for a given account.
    function _grantBurnPermission(address account, uint256 revnetId) internal {
        // Permission ID 11 = BURN_TOKENS in JBPermissionIds
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), account, revnetId, 11, true, true)),
            abi.encode(true)
        );
    }

    /// @notice Create a loan for the given borrower. Returns the loan ID and loan struct.
    function _createLoan(
        uint256 revnetId,
        address borrower,
        uint256 collateral,
        uint256 prepaidFeePercent
    )
        internal
        returns (uint256 loanId, REVLoan memory loan)
    {
        REVLoanSource memory source = _nativeLoanSource();
        uint256 borrowable =
            LOANS_CONTRACT.borrowableAmountFrom(revnetId, collateral, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        require(borrowable > 0, "no borrowable amount");

        _grantBurnPermission(borrower, revnetId);

        vm.prank(borrower);
        (loanId, loan) = LOANS_CONTRACT.borrowFrom({
            revnetId: revnetId,
            source: source,
            minBorrowAmount: 0,
            collateralCount: collateral,
            beneficiary: payable(borrower),
            prepaidFeePercent: prepaidFeePercent,
            holder: borrower
        });
    }
}
