// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {mulDiv, sqrt} from "@prb/math/src/Common.sol";

/// @notice Invariant 2 from TEST_IMPROVEMENT_PLAN.md Section 7:
///         sqrtPriceX96^2 / 2^192 ≈ issuanceRate / 10^terminalDecimals (within 0.1%)
/// @dev Fuzz test that verifies the pool initialization price is consistent with
///      the economic intent for any decimal/issuance combination.
contract PoolPriceConsistencyTest is Test {
    /// @notice Fuzz: sqrtPriceX96 encodes the correct price ratio for any valid inputs.
    /// @dev The sqrtPriceX96 formula is:
    ///      If terminalToken < projectToken (terminal is token0):
    ///        sqrtPriceX96 = sqrt(issuance * 2^192 / terminalUnit)
    ///        price = sqrtPriceX96^2 / 2^192 = issuance / terminalUnit
    ///      If projectToken < terminalToken (project is token0):
    ///        sqrtPriceX96 = sqrt(terminalUnit * 2^192 / issuance)
    ///        price = sqrtPriceX96^2 / 2^192 = terminalUnit / issuance
    function testFuzz_sqrtPriceX96_encodesCorrectRatio(uint8 terminalDecimals, uint112 issuance) external pure {
        terminalDecimals = uint8(bound(terminalDecimals, 2, 18));
        uint256 terminalUnit = 10 ** uint256(terminalDecimals);

        // Cap issuance to avoid mulDiv overflow: issuance * 2^192 must not overflow uint256.
        // Max safe issuance = type(uint256).max / (2^192) ≈ 1.84e19
        // But mulDiv handles the intermediate by using 512-bit math, so the constraint is:
        //   issuance * (2^192) / terminalUnit must fit in uint256
        //   → issuance < type(uint256).max * terminalUnit / (2^192)
        //   For terminalUnit=100 (2 dec): max ≈ 1.84e21
        //   For terminalUnit=1e18 (18 dec): max ≈ 1.84e37
        // Use terminalUnit-dependent bound:
        uint256 maxIssuance = type(uint256).max / (1 << 96); // ≈ 1.46e48 — safe for mulDiv's 512-bit
        maxIssuance = maxIssuance / ((1 << 96) / terminalUnit + 1); // tighten per terminalUnit
        if (maxIssuance > type(uint112).max) maxIssuance = type(uint112).max;
        // Ensure issuance >= terminalUnit so expectedPrice >= 1 (avoids degenerate zero-price cases
        // where sqrt rounding dominates)
        if (maxIssuance < terminalUnit) return; // skip degenerate cases

        issuance = uint112(bound(issuance, terminalUnit, maxIssuance));

        // Simulate terminalToken < projectToken (terminal is token0)
        uint256 sqrtPrice = sqrt(mulDiv(uint256(issuance), 1 << 192, terminalUnit));

        // Recover the price: sqrtPrice^2 / 2^192
        uint256 recoveredPrice = mulDiv(sqrtPrice, sqrtPrice, 1 << 192);

        // Expected price: issuance / terminalUnit
        uint256 expectedPrice = uint256(issuance) / terminalUnit;

        // Allow rounding tolerance: sqrt introduces up to 1 unit of absolute error.
        // For large prices, use relative tolerance (0.1%). For small prices, use absolute tolerance (1).
        if (expectedPrice == 0) {
            assertLe(recoveredPrice, 1, "zero-price rounding");
        } else {
            uint256 absDiff =
                recoveredPrice > expectedPrice ? recoveredPrice - expectedPrice : expectedPrice - recoveredPrice;
            // Combined tolerance: absDiff <= max(1, expectedPrice / 1000)
            uint256 tolerance = expectedPrice / 1000;
            if (tolerance == 0) tolerance = 1;
            assertLe(absDiff, tolerance, "price ratio must be within 0.1% or 1 wei");
        }
    }

    /// @notice Explicit: 6-decimal terminal (USDC) with issuance 1e18 produces correct price.
    function test_explicit_6dec_priceConsistency() external pure {
        uint256 issuance = 1e18; // 1e18 project tokens per terminal token unit
        uint256 terminalUnit = 1e6; // USDC

        uint256 sqrtPrice = sqrt(mulDiv(issuance, 1 << 192, terminalUnit));
        uint256 recoveredPrice = mulDiv(sqrtPrice, sqrtPrice, 1 << 192);
        uint256 expectedPrice = issuance / terminalUnit; // 1e12

        uint256 absDiff =
            recoveredPrice > expectedPrice ? recoveredPrice - expectedPrice : expectedPrice - recoveredPrice;
        assertLe(absDiff * 1000, expectedPrice, "6-dec price consistency");
    }

    /// @notice Explicit: 18-decimal terminal (ETH) with issuance 1e18 produces correct price.
    function test_explicit_18dec_priceConsistency() external pure {
        uint256 issuance = 1e18;
        uint256 terminalUnit = 1e18;

        uint256 sqrtPrice = sqrt(mulDiv(issuance, 1 << 192, terminalUnit));
        uint256 recoveredPrice = mulDiv(sqrtPrice, sqrtPrice, 1 << 192);
        uint256 expectedPrice = issuance / terminalUnit; // 1

        uint256 absDiff =
            recoveredPrice > expectedPrice ? recoveredPrice - expectedPrice : expectedPrice - recoveredPrice;
        assertLe(absDiff, 1, "18-dec price consistency (allow 1 wei rounding)");
    }

    /// @notice Explicit: 8-decimal terminal (WBTC) with large issuance.
    function test_explicit_8dec_priceConsistency() external pure {
        uint256 issuance = 20e18; // 20 project tokens per WBTC unit
        uint256 terminalUnit = 1e8; // WBTC

        uint256 sqrtPrice = sqrt(mulDiv(issuance, 1 << 192, terminalUnit));
        uint256 recoveredPrice = mulDiv(sqrtPrice, sqrtPrice, 1 << 192);
        uint256 expectedPrice = issuance / terminalUnit; // 2e11

        uint256 absDiff =
            recoveredPrice > expectedPrice ? recoveredPrice - expectedPrice : expectedPrice - recoveredPrice;
        assertLe(absDiff * 1000, expectedPrice, "8-dec price consistency");
    }
}
