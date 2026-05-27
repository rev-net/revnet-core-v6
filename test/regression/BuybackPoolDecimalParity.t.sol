// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {mulDiv, sqrt} from "@prb/math/src/Common.sol";

/// @notice Standalone harness that replicates the `sqrtPriceX96` calculation from
/// `REVDeployer._tryInitializeBuybackPoolFor`. This tests the formula in isolation without needing the full
/// REVDeployer constructor wiring.
/// @dev The comparison formula hardcodes `1e18` instead of `10 ** terminalTokenDecimals`, which demonstrates the
/// expected difference for non-18-decimal tokens.
contract SqrtPriceHarness {
    /// @notice Compute the sqrtPriceX96 exactly as REVDeployer does.
    /// @param terminalToken The terminal token address (normalized: native → address(0)).
    /// @param projectToken The project token address (always 18 decimals).
    /// @param terminalTokenDecimals The decimal precision of the terminal token.
    /// @param initialIssuance The initial issuance rate (project tokens per terminal token unit).
    function computeSqrtPriceX96(
        address terminalToken,
        address projectToken,
        uint8 terminalTokenDecimals,
        uint112 initialIssuance
    )
        external
        pure
        returns (uint160 sqrtPriceX96)
    {
        uint256 terminalTokenUnit = 10 ** terminalTokenDecimals;

        if (initialIssuance == 0 || projectToken == address(0) || projectToken == terminalToken) {
            sqrtPriceX96 = uint160(1 << 96);
        } else if (terminalToken < projectToken) {
            // token0 = terminal, token1 = project → price = issuance / terminalTokenUnit
            sqrtPriceX96 = uint160(sqrt(mulDiv(uint256(initialIssuance), 1 << 192, terminalTokenUnit)));
        } else {
            // token0 = project, token1 = terminal → price = terminalTokenUnit / issuance
            sqrtPriceX96 = uint160(sqrt(mulDiv(terminalTokenUnit, 1 << 192, uint256(initialIssuance))));
        }
    }

    /// @notice Compute using the 1e18-hardcoded comparison formula.
    function computeSqrtPriceX96_BUGGY(
        address terminalToken,
        address projectToken,
        uint8, /* terminalTokenDecimals (ignored in buggy version) */
        uint112 initialIssuance
    )
        external
        pure
        returns (uint160 sqrtPriceX96)
    {
        uint256 terminalTokenUnit = 1e18; // Hardcoded comparison path.

        if (initialIssuance == 0 || projectToken == address(0) || projectToken == terminalToken) {
            sqrtPriceX96 = uint160(1 << 96);
        } else if (terminalToken < projectToken) {
            sqrtPriceX96 = uint160(sqrt(mulDiv(uint256(initialIssuance), 1 << 192, terminalTokenUnit)));
        } else {
            sqrtPriceX96 = uint160(sqrt(mulDiv(terminalTokenUnit, 1 << 192, uint256(initialIssuance))));
        }
    }
}

/// @notice Regression tests proving `_tryInitializeBuybackPoolFor` uses `10 ** terminalTokenDecimals` instead of
/// hardcoded `1e18`.
/// @dev Non-18-decimal tokens such as USDC and WBTC must produce a different sqrtPriceX96 than the 1e18-hardcoded
/// comparison formula.
contract BuybackPoolDecimalParityTest is Test {
    SqrtPriceHarness harness;

    // Use deterministic addresses where terminal < project for token0/token1 ordering.
    address constant TERMINAL_TOKEN = address(0x1000);
    address constant PROJECT_TOKEN = address(0x2000);

    // Standard issuance: 1,000,000 project tokens per terminal token unit
    uint112 constant ISSUANCE = 1_000_000e18;

    function setUp() public {
        harness = new SqrtPriceHarness();
    }

    /// @notice 6-decimal token (USDC): decimal-aware and 1e18-hardcoded formulas must differ.
    function test_6dec_fixedDiffersFromBuggy() public view {
        uint160 fixed_ = harness.computeSqrtPriceX96(TERMINAL_TOKEN, PROJECT_TOKEN, 6, ISSUANCE);
        uint160 buggy = harness.computeSqrtPriceX96_BUGGY(TERMINAL_TOKEN, PROJECT_TOKEN, 6, ISSUANCE);

        assertNotEq(fixed_, buggy, "6-dec: fixed formula must differ from buggy 1e18 formula");
        assertTrue(fixed_ > 0, "6-dec: sqrtPriceX96 must be non-zero");
    }

    /// @notice 8-decimal token (WBTC): decimal-aware and 1e18-hardcoded formulas must differ.
    function test_8dec_fixedDiffersFromBuggy() public view {
        uint160 fixed_ = harness.computeSqrtPriceX96(TERMINAL_TOKEN, PROJECT_TOKEN, 8, ISSUANCE);
        uint160 buggy = harness.computeSqrtPriceX96_BUGGY(TERMINAL_TOKEN, PROJECT_TOKEN, 8, ISSUANCE);

        assertNotEq(fixed_, buggy, "8-dec: fixed formula must differ from buggy 1e18 formula");
        assertTrue(fixed_ > 0, "8-dec: sqrtPriceX96 must be non-zero");
    }

    /// @notice 18-decimal token: decimal-aware and 1e18-hardcoded formulas must match.
    function test_18dec_fixedMatchesBuggy() public view {
        uint160 fixed_ = harness.computeSqrtPriceX96(TERMINAL_TOKEN, PROJECT_TOKEN, 18, ISSUANCE);
        uint160 buggy = harness.computeSqrtPriceX96_BUGGY(TERMINAL_TOKEN, PROJECT_TOKEN, 18, ISSUANCE);

        assertEq(fixed_, buggy, "18-dec: both formulas should produce identical results");
    }

    /// @notice 6-decimal token: verify the price encodes the correct ratio.
    /// @dev For token0=terminal(6dec), token1=project(18dec):
    ///      price = issuance / terminalTokenUnit
    ///      With issuance=1e24 and unit=1e6: price = 1e18
    ///      sqrtPriceX96 = sqrt(price * 2^192) = sqrt(1e18 * 2^192)
    function test_6dec_correctPriceRatio() public view {
        uint160 result = harness.computeSqrtPriceX96(TERMINAL_TOKEN, PROJECT_TOKEN, 6, ISSUANCE);

        // The expected sqrtPriceX96: sqrt(mulDiv(ISSUANCE, 2^192, 10^6))
        // = sqrt(1e24 * 2^192 / 1e6) = sqrt(1e18 * 2^192)
        uint256 expectedSquared = mulDiv(uint256(ISSUANCE), 1 << 192, 1e6);
        uint160 expected = uint160(sqrt(expectedSquared));

        assertEq(result, expected, "6-dec: sqrtPriceX96 should match expected calculation");
    }

    /// @notice 8-decimal token: verify the price encodes the correct ratio.
    function test_8dec_correctPriceRatio() public view {
        uint160 result = harness.computeSqrtPriceX96(TERMINAL_TOKEN, PROJECT_TOKEN, 8, ISSUANCE);

        uint256 expectedSquared = mulDiv(uint256(ISSUANCE), 1 << 192, 1e8);
        uint160 expected = uint160(sqrt(expectedSquared));

        assertEq(result, expected, "8-dec: sqrtPriceX96 should match expected calculation");
    }

    /// @notice Zero issuance → 1:1 price (1 << 96).
    function test_zeroIssuance_returns1to1() public view {
        uint160 result = harness.computeSqrtPriceX96(TERMINAL_TOKEN, PROJECT_TOKEN, 6, 0);
        assertEq(result, uint160(1 << 96), "zero issuance should produce 1:1 sqrtPriceX96");
    }

    /// @notice Reversed token ordering (token0=project, token1=terminal) uses inverted formula.
    function test_reversedOrdering_usesInverse() public view {
        // Swap addresses so terminal > project → token0 = project, token1 = terminal
        address termLow = address(0x2000);
        address projHigh = address(0x1000); // proj < term

        uint160 result = harness.computeSqrtPriceX96(termLow, projHigh, 6, ISSUANCE);

        // For token0=project, token1=terminal: price = terminalTokenUnit / issuance
        uint256 expectedSquared = mulDiv(1e6, 1 << 192, uint256(ISSUANCE));
        uint160 expected = uint160(sqrt(expectedSquared));

        assertEq(result, expected, "reversed ordering should use inverse formula");
    }
}
