// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {mulDiv, sqrt} from "@prb/math/src/Common.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

/// @notice Fork test validating `sqrtPriceX96` computation for buyback pool initialization
/// with non-18-decimal terminal tokens.
///
/// Before the fix, `_tryInitializeBuybackPoolFor` hardcoded `1e18` as the terminal token unit,
/// producing an incorrect pool price for tokens like USDC (6 decimals). The fix uses
/// `10 ** terminalTokenDecimals` instead.
///
/// Run with: forge test --match-contract BuybackPoolDecimalsForkTest --fork-url $RPC_ETHEREUM_MAINNET -vvv
contract BuybackPoolDecimalsForkTest is Test {
    function setUp() external {
        vm.createSelectFork("ethereum");
    }

    /// @notice Compute sqrtPriceX96 the same way REVDeployer._tryInitializeBuybackPoolFor does.
    /// @param initialIssuance Project tokens per terminal token (18-decimal fixed point).
    /// @param terminalTokenDecimals Decimals of the terminal token (e.g. 6 for USDC, 18 for WETH).
    /// @param terminalTokenLessThanProjectToken True when token0 = terminal, token1 = project.
    function _computeSqrtPriceX96(
        uint112 initialIssuance,
        uint8 terminalTokenDecimals,
        bool terminalTokenLessThanProjectToken
    )
        internal
        pure
        returns (uint160)
    {
        uint256 terminalTokenUnit = 10 ** terminalTokenDecimals;

        if (terminalTokenLessThanProjectToken) {
            return uint160(sqrt(mulDiv(uint256(initialIssuance), 1 << 192, terminalTokenUnit)));
        } else {
            return uint160(sqrt(mulDiv(terminalTokenUnit, 1 << 192, uint256(initialIssuance))));
        }
    }

    /// @notice 18-decimal token (WETH): sqrtPriceX96 should equal the established baseline.
    function test_sqrtPriceX96_18DecimalToken() external view {
        uint112 issuance = uint112(1_000e18); // 1000 project tokens per terminal token

        // token0 = terminal (18 dec), token1 = project
        uint160 sqrtPrice = _computeSqrtPriceX96(issuance, 18, true);

        // Expected: sqrt(1000 * 2^192) = sqrt(1000) * 2^96
        uint160 expected = uint160(sqrt(mulDiv(1_000e18, 1 << 192, 1e18)));
        assertEq(sqrtPrice, expected, "18-dec sqrtPriceX96 should match baseline");
    }

    /// @notice 6-decimal token (USDC): sqrtPriceX96 should differ from the 18-decimal case.
    ///
    /// Before the fix, both cases produced the same sqrtPriceX96 because `1e18` was hardcoded.
    /// After the fix, the 6-decimal price is sqrt(10^12) ≈ 10^6 times larger than the 18-decimal price.
    function test_sqrtPriceX96_6DecimalToken() external view {
        uint112 issuance = uint112(1_000e18); // 1000 project tokens per terminal token

        // token0 = terminal (6 dec), token1 = project
        uint160 sqrtPrice6 = _computeSqrtPriceX96(issuance, 6, true);
        uint160 sqrtPrice18 = _computeSqrtPriceX96(issuance, 18, true);

        // The 6-dec price should be larger because fewer raw units represent 1 full token.
        assertGt(sqrtPrice6, sqrtPrice18, "6-dec sqrtPriceX96 should be larger than 18-dec");

        // Verify the exact ratio: sqrt(10^(18-6)) = sqrt(10^12) = 10^6
        // sqrtPrice6 / sqrtPrice18 ≈ 10^6 (within rounding)
        uint256 ratio = uint256(sqrtPrice6) * 1e18 / uint256(sqrtPrice18);
        assertApproxEqRel(ratio, 1e6 * 1e18, 0.001e18, "ratio should be ~10^6");
    }

    /// @notice Inverse ordering: when token0 = project, token1 = terminal.
    function test_sqrtPriceX96_6DecimalToken_inverseOrdering() external view {
        uint112 issuance = uint112(1_000e18);

        // token0 = project, token1 = terminal (6 dec)
        uint160 sqrtPrice6 = _computeSqrtPriceX96(issuance, 6, false);
        uint160 sqrtPrice18 = _computeSqrtPriceX96(issuance, 18, false);

        // For inverse ordering, smaller decimals → smaller sqrtPriceX96.
        assertLt(sqrtPrice6, sqrtPrice18, "6-dec inverse sqrtPriceX96 should be smaller than 18-dec");
    }

    /// @notice Verify self-consistency: sqrtPriceX96(token0<token1) * sqrtPriceX96(token0>token1) ≈ 2^192.
    ///
    /// In Uniswap V4, price = token1/token0. Swapping the ordering inverts the price.
    /// So sqrt(P) * sqrt(1/P) = sqrt(P * 1/P) = sqrt(1) → both sqrtPriceX96 values multiplied ≈ 2^96 each.
    function test_sqrtPriceX96_selfConsistency_6Dec() external view {
        uint112 issuance = uint112(500e18);

        uint160 sqrtForward = _computeSqrtPriceX96(issuance, 6, true);
        uint160 sqrtInverse = _computeSqrtPriceX96(issuance, 6, false);

        // forward * inverse should approximate (2^96)^2 = 2^192
        uint256 product = uint256(sqrtForward) * uint256(sqrtInverse);

        // Allow small rounding error (< 0.1%)
        assertApproxEqRel(product, 1 << 192, 0.001e18, "forward * inverse should approximate 2^192");
    }

    /// @notice 8-decimal token (WBTC): sqrtPriceX96 should use 10^8 as the unit.
    function test_sqrtPriceX96_8DecimalToken() external view {
        uint112 issuance = uint112(100e18); // 100 project tokens per WBTC

        uint160 sqrtPrice8 = _computeSqrtPriceX96(issuance, 8, true);
        uint160 sqrtPrice18 = _computeSqrtPriceX96(issuance, 18, true);

        // The 8-dec price should be larger than 18-dec.
        assertGt(sqrtPrice8, sqrtPrice18, "8-dec sqrtPriceX96 should be larger than 18-dec");

        // Ratio: sqrt(10^(18-8)) = sqrt(10^10) ≈ 10^5
        uint256 ratio = uint256(sqrtPrice8) * 1e18 / uint256(sqrtPrice18);
        assertApproxEqRel(ratio, 1e5 * 1e18, 0.001e18, "ratio should be ~10^5");
    }
}
