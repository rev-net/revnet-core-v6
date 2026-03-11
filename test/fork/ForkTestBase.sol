// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import /* {*} from */ "../../src/REVDeployer.sol";
import "@croptop/core-v6/src/CTPublisher.sol";
import "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
import "@bananapus/721-hook-v6/script/helpers/Hook721DeploymentLib.sol";
import "@bananapus/suckers-v6/script/helpers/SuckerDeploymentLib.sol";
import "@croptop/core-v6/script/helpers/CroptopDeploymentLib.sol";
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
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JB721InitTiersConfig} from "@bananapus/721-hook-v6/src/structs/JB721InitTiersConfig.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {REVDeploy721TiersHookConfig} from "../../src/structs/REVDeploy721TiersHookConfig.sol";
import {REVBaseline721HookConfig} from "../../src/structs/REVBaseline721HookConfig.sol";
import {REV721TiersHookFlags} from "../../src/structs/REV721TiersHookFlags.sol";
import {REVCroptopAllowedPost} from "../../src/structs/REVCroptopAllowedPost.sol";

// Buyback hook
import {JBBuybackHook} from "@bananapus/buyback-hook-v6/src/JBBuybackHook.sol";
import {JBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/JBBuybackHookRegistry.sol";
import {IJBBuybackHook} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHook.sol";
import {IGeomeanOracle} from "@bananapus/buyback-hook-v6/src/interfaces/IGeomeanOracle.sol";

// Uniswap V4
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/// @notice Helper that adds liquidity to a V4 pool via the unlock/callback pattern.
contract LiquidityHelper is IUnlockCallback {
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
            params.key, SwapParams(params.zeroForOne, params.amountSpecified, params.sqrtPriceLimitX96), ""
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

    REVDeployer REV_DEPLOYER;
    JBBuybackHook BUYBACK_HOOK;
    JBBuybackHookRegistry BUYBACK_REGISTRY;
    JB721TiersHook EXAMPLE_HOOK;
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    IJB721TiersHookStore HOOK_STORE;
    IJBAddressRegistry ADDRESS_REGISTRY;
    IREVLoans LOANS_CONTRACT;
    IJBSuckerRegistry SUCKER_REGISTRY;
    CTPublisher PUBLISHER;
    IPoolManager poolManager;
    LiquidityHelper liqHelper;

    uint256 FEE_PROJECT_ID;

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;
    address PAYER = makeAddr("payer");
    address BORROWER = makeAddr("borrower");
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
            poolManager,
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

    // ───────────────────────── Deployment Helpers
    // ─────────────────────────

    /// @notice Deploy the fee project using the given tax rate.
    function _deployFeeProject(uint16 cashOutTaxRate) internal {
        (REVConfig memory feeCfg, JBTerminalConfig[] memory feeTc, REVSuckerDeploymentConfig memory feeSdc) =
            _buildMinimalConfig(cashOutTaxRate);
        feeCfg.description = REVDescription("Fee", "FEE", "ipfs://fee", "FEE_SALT");

        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeCfg,
            terminalConfigurations: feeTc,
            suckerDeploymentConfiguration: feeSdc
        });
    }

    /// @notice Deploy a revnet (no 721 hook) with the given cash out tax rate.
    function _deployRevnet(uint16 cashOutTaxRate) internal returns (uint256 revnetId) {
        (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc) =
            _buildMinimalConfig(cashOutTaxRate);

        revnetId = REV_DEPLOYER.deployFor({
            revnetId: 0, configuration: cfg, terminalConfigurations: tc, suckerDeploymentConfiguration: sdc
        });
    }

    /// @notice Deploy a revnet with 721 tiers and the given cash out tax rate.
    function _deployRevnetWith721(uint16 cashOutTaxRate) internal returns (uint256 revnetId, IJB721TiersHook hook) {
        (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc) =
            _buildMinimalConfig(cashOutTaxRate);
        // Use a different salt to avoid CREATE2 collision with _deployRevnet's ERC-20.
        cfg.description.salt = "FORK_721_SALT";
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

        // Pool is already initialized and registered by REVDeployer during deployment
        // at the issuance weight (1000 tokens/ETH). Full-range liquidity at that price
        // requires ~sqrt(1000) ≈ 31.6x more project tokens than ETH.
        // Mint enough project tokens to cover the asymmetric requirement.
        uint256 projectTokenAmount = liquidityTokenAmount * INITIAL_ISSUANCE / 1e18;

        // Fund LiquidityHelper with project tokens via JBTokens.mintFor (not deal).
        vm.prank(address(jbController()));
        jbTokens().mintFor(address(liqHelper), revnetId, projectTokenAmount);
        // Fund with ETH for the native currency side.
        vm.deal(address(liqHelper), liquidityTokenAmount);

        vm.startPrank(address(liqHelper));
        IERC20(projectToken).approve(address(poolManager), type(uint256).max);
        vm.stopPrank();

        int256 liquidityDelta = int256(liquidityTokenAmount / 2);
        vm.prank(address(liqHelper));
        liqHelper.addLiquidity{value: liquidityTokenAmount}(key, TICK_LOWER, TICK_UPPER, liquidityDelta);

        _mockOracle(liquidityDelta, 0, uint32(REV_DEPLOYER.DEFAULT_BUYBACK_TWAP_WINDOW()));
    }

    /// @notice Mock the IGeomeanOracle at address(0) for hookless pools.
    function _mockOracle(int256 liquidity, int24 tick, uint32 twapWindow) internal {
        vm.etch(address(0), hex"00");

        int56[] memory tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
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
            prepaidFeePercent: prepaidFeePercent
        });
    }
}
