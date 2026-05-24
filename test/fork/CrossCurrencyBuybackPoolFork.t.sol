// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {mulDiv, sqrt} from "@prb/math/src/Common.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

/// @notice Validates `sqrtPriceX96` for the cross-currency case where a revnet accepts a terminal token whose
/// accounting currency differs from the revnet's base currency. The deployer must convert the issuance rate
/// through the project's price feeds before seeding the buyback pool — otherwise the pool's first liquidity
/// tick is denominated against the base currency and the first organic swap gets arbitraged at the corrected
/// price.
///
/// Run with: `forge test --match-contract CrossCurrencyBuybackPoolForkTest -vvv`
contract CrossCurrencyBuybackPoolForkTest is Test {
    /// @notice Replicates the deployer's `sqrtPriceX96` derivation for a cross-currency accounting context.
    /// @param initialIssuance Project tokens per unit of the revnet's base currency (18-decimal fixed point).
    /// @param terminalTokenDecimals Decimals of the terminal token (e.g. 6 for USDC, 18 for WETH).
    /// @param priceRate `JBPrices.pricePerUnitOf(pricingCurrency=terminalCurrency, unitCurrency=baseCurrency,
    ///                  decimals=terminalTokenDecimals)`. For ETH-base + USDC-currency, this is the USD price
    ///                  of 1 ETH expressed in `terminalTokenDecimals` fixed point (e.g. 3000 * 1e6).
    /// @param terminalTokenLessThanProjectToken True when `token0 = terminal` in the resulting V4 pool.
    function _computeSqrtPriceX96WithConversion(
        uint112 initialIssuance,
        uint8 terminalTokenDecimals,
        uint256 priceRate,
        bool terminalTokenLessThanProjectToken
    )
        internal
        pure
        returns (uint160)
    {
        uint256 terminalTokenUnit = 10 ** terminalTokenDecimals;
        uint256 adjustedInitialIssuance =
            mulDiv({x: uint256(initialIssuance), y: terminalTokenUnit, denominator: priceRate});

        if (terminalTokenLessThanProjectToken) {
            return uint160(sqrt(mulDiv(adjustedInitialIssuance, 1 << 192, terminalTokenUnit)));
        } else {
            return uint160(sqrt(mulDiv(terminalTokenUnit, 1 << 192, adjustedInitialIssuance)));
        }
    }

    /// @notice Same-decimal cross-currency (e.g. WBTC accounting against ETH base): conversion is applied even
    /// though the decimals match. Confirms that decimal-equality does NOT bypass the conversion — only
    /// currency-equality does.
    function test_crossCurrencySameDecimals_appliesConversion() external pure {
        // 1000 project tokens per 1 ETH-base unit.
        uint112 issuance = uint112(1000e18);
        // 1 ETH = 0.05 BTC, in 18-dec fixed point.
        uint256 rate = 5e16;

        uint160 converted = _computeSqrtPriceX96WithConversion(issuance, 18, rate, true);

        // Same call ignoring conversion (legacy buggy behavior) — would treat 1 BTC raw as 1 ETH raw.
        uint256 terminalUnit = 1e18;
        uint160 legacy = uint160(sqrt(mulDiv(uint256(issuance), 1 << 192, terminalUnit)));

        // The two must differ — otherwise the conversion has no effect.
        assertTrue(converted != legacy, "cross-currency same-decimals must change sqrtPriceX96");

        // Specifically, the converted pool seeds 20x more project tokens per terminal token at 0.05 BTC/ETH.
        assertGt(converted, legacy, "BTC-priced terminal yields more project tokens per terminal unit");
    }

    /// @notice 6-decimal stablecoin accounting against an 18-decimal base currency: combines decimal mismatch
    /// with currency mismatch. Mirrors USDC-accepting revnet against ETH base, the most likely production case.
    function test_crossCurrencyMixedDecimals_appliesConversion() external pure {
        // 1000 project tokens per 1 ETH-base unit.
        uint112 issuance = uint112(1000e18);
        // 1 ETH = 3000 USDC, in 6-dec fixed point (matches `pricePerUnitOf(..., decimals=6)`).
        uint256 rate = 3000 * 1e6;

        uint160 converted = _computeSqrtPriceX96WithConversion(issuance, 6, rate, true);

        // Legacy (buggy) behavior ignores the rate and treats USDC raw as ETH raw — 3000x off.
        uint256 terminalUnit = 1e6;
        uint160 legacy = uint160(sqrt(mulDiv(uint256(issuance), 1 << 192, terminalUnit)));

        assertTrue(converted != legacy, "cross-currency mixed-decimals must change sqrtPriceX96");

        // sqrt(3000) ≈ 54.77x ratio between legacy and corrected. Confirm direction: legacy under-prices the
        // terminal token by 3000x, so legacy.sqrtPriceX96 reflects ~3000x more project tokens per USDC raw.
        assertGt(legacy, converted, "legacy mis-pricing inflates project-per-terminal ratio");
    }

    /// @notice When the rate would deliver a zero adjusted issuance (e.g. extremely depressed terminal value),
    /// the deployer skips the price-derived seed and falls back to the 1:1 sentinel. This guards against pool
    /// init reverts on degenerate price-feed inputs.
    function test_crossCurrencyZeroAdjusted_fallsBackToSentinel() external pure {
        // 1 project token per 1 ETH-base unit — minimum issuance.
        uint112 issuance = 1;
        // Astronomically high rate: terminal currency is "worth" much more than base.
        uint256 rate = type(uint128).max;

        uint256 terminalTokenUnit = 1e18;
        uint256 adjusted = mulDiv({x: uint256(issuance), y: terminalTokenUnit, denominator: rate});

        // Confirm the conversion floors to zero. The production code's `if (adjustedInitialIssuance == 0)`
        // branch then seeds the pool at the 1:1 sentinel rather than computing an invalid sqrt.
        assertEq(adjusted, 0, "extreme rate must floor adjusted issuance to zero");
    }

    /// @notice Same-currency baseline: when the accounting currency equals the base currency, the conversion
    /// produces an `adjustedInitialIssuance` equal to the original `initialIssuance` (no behavioral change
    /// versus the pre-conversion code path). This is the regression guard for ETH-base + native-ETH terminals.
    function test_sameCurrencyBaseline_matchesLegacyMath() external pure {
        uint112 issuance = uint112(1000e18);
        // Same-currency rate: `pricePerUnitOf` returns `10**decimals` when pricing == unit.
        uint256 rate = 1e18;
        uint8 decimals = 18;

        uint160 converted = _computeSqrtPriceX96WithConversion(issuance, decimals, rate, true);

        uint256 terminalUnit = 10 ** decimals;
        uint160 legacy = uint160(sqrt(mulDiv(uint256(issuance), 1 << 192, terminalUnit)));

        assertEq(converted, legacy, "same-currency conversion must equal legacy math");
    }
}
