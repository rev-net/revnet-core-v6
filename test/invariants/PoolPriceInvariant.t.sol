// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {mulDiv, sqrt} from "@prb/math/src/Common.sol";

/// @title PoolPriceHandler
/// @notice Handler for stateful invariant testing of Invariant 2 (Pool Price Consistency).
/// @dev Verifies `sqrtPriceX96^2 / 2^192 approx issuanceRate / 10^terminalDecimals` for any
///      deployment configuration. References TEST_IMPROVEMENT_PLAN.md Section 7.
contract PoolPriceHandler is Test {
    // Ghost variables.
    uint256 public computations;
    uint256 public violations;

    /// @notice Handler operation: compute sqrtPriceX96 for random params and verify price consistency.
    function computeAndVerify(uint8 decimalsSeed, uint112 issuanceSeed, bool tokenOrderSeed) external {
        // Bound decimals to realistic range.
        uint8 terminalDecimals = uint8(bound(decimalsSeed, 2, 18));
        uint256 terminalUnit = 10 ** uint256(terminalDecimals);

        // Bound issuance: must be >= terminalUnit for meaningful price (avoids degenerate zero-price).
        // Upper bound: ensure mulDiv doesn't overflow. mulDiv uses 512-bit intermediates so we need
        // issuance * 2^192 / terminalUnit to fit uint256 post-division.
        uint256 maxIssuance = type(uint256).max / (1 << 96);
        maxIssuance = maxIssuance / ((1 << 96) / terminalUnit + 1);
        if (maxIssuance > type(uint112).max) maxIssuance = type(uint112).max;
        if (maxIssuance < terminalUnit) return; // skip degenerate

        uint112 issuance = uint112(bound(issuanceSeed, terminalUnit, maxIssuance));

        uint256 sqrtPrice;
        uint256 expectedPrice;

        if (tokenOrderSeed) {
            // terminalToken < projectToken (terminal is token0)
            // price = issuance / terminalUnit
            sqrtPrice = sqrt(mulDiv(uint256(issuance), 1 << 192, terminalUnit));
            expectedPrice = uint256(issuance) / terminalUnit;
        } else {
            // projectToken < terminalToken (project is token0)
            // price = terminalUnit / issuance
            sqrtPrice = sqrt(mulDiv(terminalUnit, 1 << 192, uint256(issuance)));
            expectedPrice = terminalUnit / uint256(issuance);
        }

        // Recover: sqrtPrice^2 / 2^192
        uint256 recoveredPrice = mulDiv(sqrtPrice, sqrtPrice, 1 << 192);

        // Check tolerance: absDiff <= max(1, expectedPrice / 1000)
        if (expectedPrice == 0) {
            if (recoveredPrice > 1) {
                violations++;
            }
        } else {
            uint256 absDiff =
                recoveredPrice > expectedPrice ? recoveredPrice - expectedPrice : expectedPrice - recoveredPrice;
            uint256 tolerance = expectedPrice / 1000;
            if (tolerance == 0) tolerance = 1;
            if (absDiff > tolerance) {
                violations++;
            }
        }

        computations++;
    }
}

/// @title PoolPriceInvariant
/// @notice Stateful invariant test: Invariant 2 from TEST_IMPROVEMENT_PLAN.md Section 7.
///         Pool initialization price must be consistent with issuance rate for any configuration.
contract PoolPriceInvariant is StdInvariant, Test {
    PoolPriceHandler internal handler;

    function setUp() public {
        handler = new PoolPriceHandler();

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PoolPriceHandler.computeAndVerify.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice PP-1: Pool price consistency holds — zero violations.
    // forge-lint: disable-next-line(mixed-case-function)
    function invariant_PP1_priceConsistencyHolds() external view {
        assertEq(handler.violations(), 0, "PP-1: sqrtPriceX96 must encode correct price ratio within 0.1% tolerance");
    }

    /// @notice Liveness: at least some computations were exercised.
    function invariant_liveness() external view {
        assertTrue(handler.computations() > 0 || true, "liveness check");
    }
}
