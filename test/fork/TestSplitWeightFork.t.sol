// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./ForkTestBase.sol";

/// @notice Fork tests verifying that revnet 721 tier splits + real Uniswap V4 buyback hook produce correct token
/// issuance in both the swap path (AMM buyback) and the mint path (direct minting).
///
/// Requires: RPC_ETHEREUM_MAINNET env var for mainnet fork (real PoolManager).
///
/// Run with: FOUNDRY_PROFILE=fork forge test --match-contract TestSplitWeightFork -vvv --skip "script/*"
contract TestSplitWeightFork is ForkTestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ───────────────────────── Tests
    // ─────────────────────────

    /// @notice SWAP PATH: Pool offers good rate -> buyback hook swaps on AMM instead of minting.
    /// With 30% tier split, the buyback should swap with 0.7 ETH worth.
    /// Terminal mints 0 tokens (weight=0), buyback hook mints via controller after swap.
    function test_fork_swapPath_splitWithBuyback() public {
        _deployFeeProject(5000);
        (uint256 revnetId, IJB721TiersHook hook) = _deployRevnetWith721(5000);

        // Initialize pool and register with buyback hook, then move the price
        // so project tokens are cheap (swap path wins).

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

        // Initialize at 1:1 price and register with buyback hook.
        poolManager.initialize(key, uint160(1 << 96));
        uint256 twapWindow = uint256(REV_DEPLOYER.DEFAULT_BUYBACK_TWAP_WINDOW());
        vm.prank(address(REV_DEPLOYER));
        BUYBACK_REGISTRY.setPoolFor(revnetId, key.fee, key.tickSpacing, twapWindow, JBConstants.NATIVE_TOKEN);

        uint256 projectLiq = 10_000_000e18;
        uint256 ethLiq = 5000e18;

        vm.prank(address(jbController()));
        jbTokens().mintFor(address(liqHelper), revnetId, projectLiq);
        vm.deal(address(liqHelper), ethLiq);

        vm.startPrank(address(liqHelper));
        IERC20(projectToken).approve(address(poolManager), type(uint256).max);
        vm.stopPrank();

        // Add full-range liquidity at tick 0 (1:1 price).
        int256 liquidityDelta = int256(ethLiq / 4);
        vm.prank(address(liqHelper));
        liqHelper.addLiquidity{value: ethLiq}(key, TICK_LOWER, TICK_UPPER, liquidityDelta);

        // Swap a large amount of project tokens for ETH to move the price.
        uint256 swapAmount = 5_000_000e18;
        vm.prank(address(jbController()));
        jbTokens().mintFor(address(liqHelper), revnetId, swapAmount);

        // currency0 is native ETH (address(0)), currency1 is projectToken.
        // To sell projectToken for ETH (making project tokens cheaper), swap 1->0 (zeroForOne = false).
        // zeroForOne=false pushes sqrtPrice up (more projectTokens per ETH).
        bool zeroForOne = false;
        uint160 sqrtPriceLimit = TickMath.getSqrtPriceAtTick(76_000);

        vm.prank(address(liqHelper));
        liqHelper.swap(key, zeroForOne, -int256(swapAmount), sqrtPriceLimit);

        // Read the post-swap tick for the oracle mock.
        (, int24 postSwapTick,,) = poolManager.getSlot0(key.toId());
        _mockOracle(liquidityDelta, postSwapTick, uint32(REV_DEPLOYER.DEFAULT_BUYBACK_TWAP_WINDOW()));

        address metadataTarget = hook.METADATA_ID_TARGET();
        bytes memory metadata = _buildPayMetadataWithQuote({
            hookMetadataTarget: metadataTarget, amountToSwapWith: 0.7 ether, minimumSwapAmountOut: 1
        });

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

        assertGt(terminalTokensReturned, 700e18, "swap path: should get more tokens than minting (pool rate better)");
    }

    /// @notice MINT PATH: Pool offers bad rate -> buyback decides minting is better.
    /// With 30% tier split, REVDeployer scales weight from 1000e18 to 700e18.
    /// Terminal mints 700 tokens.
    function test_fork_mintPath_splitWithBuyback() public {
        _deployFeeProject(5000);
        (uint256 revnetId, IJB721TiersHook hook) = _deployRevnetWith721(5000);
        _setupPool(revnetId, 10_000 ether);

        address metadataTarget = hook.METADATA_ID_TARGET();
        bytes memory metadata = _buildPayMetadataNoQuote(metadataTarget);

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

        uint256 expectedTokens = 700e18;
        assertEq(tokensReceived, expectedTokens, "mint path: should receive 700 tokens (weight scaled for 30% split)");
    }

    /// @notice MINT PATH without splits: baseline confirming 1000 tokens for 1 ETH.
    function test_fork_mintPath_noSplits_fullTokens() public {
        _deployFeeProject(5000);
        (uint256 revnetId,) = _deployRevnetWith721(5000);
        _setupPool(revnetId, 10_000 ether);

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

        uint256 expectedTokens = 1000e18;
        assertEq(tokensReceived, expectedTokens, "no splits: should receive 1000 tokens");
    }

    /// @notice Invariant: tokens / projectAmount rate is identical with and without splits.
    function test_fork_invariant_tokenPerEthConsistent() public {
        _deployFeeProject(5000);

        // --- Revnet 1: with 721 splits (30%) ---
        (uint256 revnetId1, IJB721TiersHook hook1) = _deployRevnetWith721(5000);
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
        uint256 revnetId2 = _deployRevnet(5000);
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

        uint256 projectAmount1 = 0.7 ether;
        uint256 projectAmount2 = 1 ether;

        uint256 rate1 = (tokens1 * 1e18) / projectAmount1;
        uint256 rate2 = (tokens2 * 1e18) / projectAmount2;

        assertEq(rate1, rate2, "token-per-ETH rate should be identical with and without splits");
    }
}
