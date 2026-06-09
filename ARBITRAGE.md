# Arbitrage Paths in Revnets

A revnet exposes three intentional arbitrage incentives that, together, keep its economic surfaces aligned across (a) chains, (b) AMM secondary markets, and (c) the terminal pay/cashout flows. This document is the canonical reference for builders integrating with revnets, arbitrageurs hunting opportunities, holders reasoning about their economics, and maintainers reading the code. Each path is wired in deliberately; removing any one would create a different problem. The arbitrageur pays effort + capital and gets paid out of the divergence they close. The protocol uses that work to self-equilibrate and grow.

---

## Overview

A revnet has three economic surfaces that can diverge from each other:

1. **Per-chain backing-per-token** (surplus ÷ supply on each chain in a multi-chain deployment).
2. **AMM secondary-market price** for the project token on Uniswap V3/V4 or any other venue.
3. **Terminal pay/cashout rates** — what `terminal.pay` will mint for new ETH, and what `terminal.cashOutTokensOf` will reclaim for burned tokens.

Each of these can drift from the others. The protocol exposes three paths that let outside actors close the drift:

| Path | Trigger | Mechanism | Closes drift between |
|---|---|---|---|
| 1 | Per-chain backing differs | Mint cheap chain → bridge → claim → borrow expensive chain | Chains |
| 2 | AMM bid < bonding-curve reclaim | Buy on AMM → cash out via terminal | AMM ↔ cashout floor |
| 3 | AMM ask > terminal mint cost | Pay via terminal → sell on AMM | AMM ↔ pay ceiling |

In every case, the arbitrageur captures the spread; the protocol captures the equalization.

---

## Path 1 — Cross-chain rebalancing arbitrage

## Trigger

A revnet's per-chain backing-per-token diverges when:

- **Cashout-tax residue** accumulates asymmetrically (the 10% tax stays on the cashing chain).
- **`addToBalanceOf` donations** land unevenly across chains.
- **Auto-issuance** is consumed at different rates per chain.
- **Pay activity** concentrates on certain chains.
- **A new chain is added late** and starts from zero supply with zero backing.

## Mechanism

The arbitrageur runs the following cycle:

1. **Mint cheap** on a low-backing chain. Call `terminal.pay` where the bonding-curve reclaim per token is currently low.
2. **Bridge tokens** via `JBSucker.prepare`. The sucker branch cashes out at the **LOCAL** chain's supply/surplus with `taxRate=0` — see `src/REVOwner.sol:231-233`:

   ```solidity
   if (_isSuckerOf({revnetId: context.projectId, addr: context.holder})) {
       return (0, context.cashOutCount, totalSupply, effectiveSurplusValue, hookSpecifications);
   }
   ```

3. **Claim on the high-backing chain.** The merkle proof flow mints the bridged tokens on the destination.
4. **Borrow or cash out** via `REVLoans.borrowFrom` (or `terminal.cashOutTokensOf`). This path uses the **AGGREGATED** supply/surplus when `scopeCashOutsToLocalBalances=false`, capped at local surplus — see `_borrowableAmountFrom` in `src/REVLoans.sol`:

   ```solidity
   uint256 effectiveSurplus = localSurplus;
   uint256 effectiveSupply = localSupply;
   if (!currentStage.scopeCashOutsToLocalBalances()) {
       effectiveSurplus += SUCKER_REGISTRY.remoteSurplusOf({...});
       effectiveSupply += SUCKER_REGISTRY.remoteTotalSupplyOf(revnetId);
   }
   uint256 reclaimable = JBCashOuts.cashOutFrom({...});
   // Cap at local surplus — can't borrow more than this chain's economic surplus (treasury + already-borrowed).
   // This is the economic ceiling (`borrowableCapacity`); the live treasury surplus is returned alongside it.
   borrowableCapacity = reclaimable > localSurplus ? localSurplus : reclaimable;
   ```

   `_borrowableAmountFrom` returns `(borrowableCapacity, liveTreasurySurplus)`. Callers that draw fresh funds (the
   `borrowableAmountFrom` preview and opening a loan) take the smaller of the two — `borrowableNow` — so the figure
   stays executable in the current state. Callers that only value collateral already backing a loan (repaying and
   reallocating) use `borrowableCapacity` directly.

   **Choosing between borrow and cash out.** Which path extracts more value depends on the stage's configured `cashOutTaxRate`. An economic observation (CryptoEconLab) puts the crossover at approximately **~39%**: above roughly a ~39% `cashOutTaxRate`, opening a `REVLoans.borrowFrom` loan against the tokens extracts more value than burning them via `terminal.cashOutTokensOf`, because the tax penalizes the direct cash-out more than it does the borrow; below that rate, cashing out is the more capital-efficient exit. The exact crossover shifts with the configured tax rate, so treat ~39% as an approximate guide rather than a precise threshold.

The asymmetry between the LOCAL-rate bridge cashout and the AGGREGATED-rate normal cashout is the arbitrageur's margin.

## Why it's beneficial

- **Equalizes cross-chain backing** so the protocol behaves as a unified treasury despite per-chain custody.
- **Primes new chains.** A late-added chain starts with zero local backing. Without an arbitrage incentive, no one would bridge supply in. The asymmetry above is what makes bridging-in profitable, which is how late chains catch up.
- **Lets aggregated cashout/borrow math work as intended.** If backing per chain stayed divergent forever, the AGGREGATED-rate borrow path would systematically over- or under-pay relative to LOCAL economics.

## Why the cash-out delay deliberately doesn't apply to bridges

`cashOutDelayOf[revnetId]` blocks `cashOutTokensOf` and `REVLoans.borrowFrom` during a priming window for newly-added chains. It deliberately **does not** block `sucker.prepare`: the sucker branch in `REVOwner.beforeCashOutRecordedWith` returns at `REVOwner.sol:231-233` *before* the cash-out-delay check. If the delay applied to bridges too, new chains couldn't be primed. The delay blocks direct exits during priming; the bridge stays open so supply can flow in.

## Cost paid by

Holders on the over-backed chain. Their per-token backing premium flattens as the arbitrageur cycles bridge-in / borrow-out. The arbitrageur captures the spread.

## Convergence

Profit per cycle scales with divergence. Each cycle reduces divergence, which reduces the next cycle's profit. Total extractable is bounded by `initial_divergence × supply`. Equalization is monotonic absent concurrent activity that adds new divergence.

## See also

- `../INVARIANTS.md` Section D2 — full conservation model, the asymmetry justification, and the rationale for `scopeCashOutsToLocalBalances=false` on revnets 1–7.
- `deploy-all-v6/test/fork/CrossChainArbCharacterizationFork.t.sol` — quantifies P&L across realistic divergence scenarios.
- `deploy-all-v6/test/invariants/CrossChainArbInvariant.t.sol` — stateful invariants for Layer-1 conservation and Layer-2 variance reduction.
- `deploy-all-v6/test/fork/CrossChainArbScenariosFork.t.sol` — late-chain-joins, whale-exits, cash-out-delay scenarios.

---

## Path 2 — Cash-out floor arbitrage (AMM → terminal)

## Trigger

The AMM secondary-market bid for the project token is **below** the bonding-curve cashout reclaim. Someone on Uniswap is selling tokens for less ETH than the terminal would pay for the same burn.

## Mechanism

1. **Buy tokens cheaply** on Uniswap V4 (or V3, or whatever venue is mispriced).
2. **Call `terminal.cashOutTokensOf`.** The bonding-curve formula `base × [(MAX − tax) + tax × (count/supply)] / MAX` pays out reclaim, minus the 2.5% protocol fee held for 28 days.
3. Profit is `cashout_reclaim − amm_buy_cost − gas − fee`.

## Why it's beneficial

- **The cash-out tax accumulates as backing.** With a 10% cashout tax, 10% of the reclaim is retained in the project's surplus. That retained amount raises per-token backing for the holders who didn't cash out. Floor arb increases the rate at which mispriced AMM supply gets converted into protocol-owned backing.
- **AMM price corrects upward** toward the cashout-floor fair value, reducing the gap that uninformed sellers face.

## Note on the buyback hook

`JBBuybackHook.beforeCashOutRecordedWith` already applies this logic on behalf of users cashing out *through* the terminal. If the AMM bid for the same number of project tokens exceeds the bonding-curve reclaim, the hook routes the swap through Uniswap instead of burning at the curve. Otherwise, it passes through to the terminal.

Dedicated floor arbitrage as an out-of-protocol strategy therefore only matters for actors who interact with both the AMM and the terminal *directly outside* the hook flow — e.g., a bot that watches Uniswap pricing and burns tokens it bought on the open market without using the buyback hook's path. The hook itself does floor arb for ordinary users automatically.

## Cost paid by

Uninformed AMM sellers who under-priced. The protocol absorbs the cashout tax as accumulated backing for remaining holders.

## Convergence

Each cycle pulls AMM supply off the venue and converts it to retained backing. The next cycle's spread is smaller. Self-limiting.

---

## Path 3 — Pay ceiling arbitrage (terminal → AMM)

## Trigger

The AMM ask for the project token is **above** the terminal pay rate. Minting via `terminal.pay` is cheaper per token than buying on Uniswap.

## Mechanism

1. **Call `terminal.pay`** with ETH. The terminal mints `weight × ETH` tokens, minus the reserved percent.
2. **Sell the minted tokens** on Uniswap at the higher market price.
3. Profit is `amm_sale_proceeds − pay_eth_in − gas − fee`.

## Why it's beneficial

- **The ETH from the payment lands in project surplus.** Treasury grows.
- **AMM price corrects downward** toward the issuance rate, removing the mispricing that would otherwise persist as a tax on new buyers using the AMM.
- **Protocol grows as the AMM corrects.** Each cycle injects new ETH backing per minted token while also pulling AMM price toward the issuance equilibrium.

## Note on the buyback hook

`JBBuybackHook.beforePayRecordedWith` applies this logic on behalf of users paying *through* the terminal. If mint cost (bonding curve) is cheaper per token than the AMM swap output, the hook routes through mint. If the AMM is cheaper, the hook routes the user's ETH through Uniswap and delivers the larger token count. Either way, the user gets the better of the two paths.

Dedicated ceiling arbitrage as an out-of-protocol strategy therefore only matters for actors with their own routing logic — e.g., a market maker who pays via terminal directly and sells through their own AMM access.

## Cost paid by

Existing holders see marginal dilution as new supply is minted with new ETH. Per-token backing converges toward the AMM-implied equilibrium — which, in the over-priced AMM case that triggers this path, is *higher* than the bonding-curve-implied backing, so holders may actually see backing rise. The "cost" is that pre-existing holders no longer own as large a slice of the supply.

---

## Cross-cutting properties

## Conservation

Across any sequence of these arbitrages, the aggregated protocol surplus is preserved modulo `protocol_fees_extracted + outstanding_loans`. Arbitrageurs do not break the books; they redistribute value within them. See INVARIANTS.md Section D2.5 for the Layer-1 conservation equation.

## Convergence

Each path has a self-limiting feedback loop: closing divergence reduces the next cycle's profit. None can be exploited infinitely. The total extractable from any starting divergence is bounded.

## Cost-bearing

In each path, the cost is paid by a specific identifiable cohort:

- **Path 1:** over-backed-chain holders lose their backing premium.
- **Path 2:** uninformed AMM sellers absorb the cashout-tax-as-backing capture.
- **Path 3:** pre-existing holders accept marginal dilution.

This is by design. Arbitrageurs are paid to do equalization work that the protocol can't perform itself, and the cost is borne by the cohort whose position was, in some sense, structurally over- or under-priced relative to the equilibrium the arbitrage path enforces.

## Why not block them

Removing any of these would create a worse problem:

- **Without Path 1**, cross-chain backing stays divergent. Late-joining chains cannot be primed because no one has incentive to bridge supply in. The AGGREGATED-rate cashout/borrow math systematically over- or under-pays relative to LOCAL economics.
- **Without Path 2**, AMM price detaches from protocol economics. Mispriced AMM supply never gets converted into protocol-owned backing. The cashout floor stops being a true floor in market practice.
- **Without Path 3**, the protocol can't grow when the AMM bids up its token. The terminal pay rate becomes a one-way gate that captures all the spread for new buyers without translating any of it into treasury growth.

---

## For arbitrageurs: operational notes

- **The simplest profitable scenarios are persistent ones.** Chains where bridge fees + gas allow continued small-cycle equalization, or AMM pools that re-detach from the protocol surface frequently. One-shot arbitrage on a freshly-deployed chain is one big cycle; ongoing arbitrage is a stream of small ones.
- **Cross-chain bridging is gas-intensive.** Suckers, cross-chain messengers (CCIP, OP messenger, Arbitrum inbox), and the destination claim all cost gas. Profit must exceed those costs plus fee impact.
- **The protocol exposes diagnostic data via the buyback hook.** `JBBuybackHook.beforePayRecordedWith` returns view-path detail (TWAP tick, liquidity, pool ID, weight ratio, raw swap quote) that a bot can read to determine the current AMM-vs-mint spread without executing — see the `jb-buyback-hook-noop-spec-is-preview-contract` reference for the noop-spec convention.
- **Indexer support is planned via Bendystraw.** Cross-chain divergence is exposed as a queryable surface — see `bendystraw-v6/CROSS_CHAIN_DIVERGENCE_SURFACE.md`.

---

## For operators: what to monitor

- **If cross-chain backing isn't converging despite bridges being open**, investigate bridging cost barriers (CCIP fees, gas on either side, AMM slippage on the trade legs). Arbitrage only happens when the spread exceeds the round-trip cost.
- **If AMM price stays detached from terminal pay/cashout rates**, the buyback hook may need a wider TWAP window (less sensitive to short-term manipulation but slower to track) or a different fee-tier pool. Operators with `SET_BUYBACK_POOL` and `SET_BUYBACK_TWAP` permissions can adjust these.
- **Persistent backing divergence in one direction** (one chain always richer or poorer) usually indicates structural asymmetry: e.g., one chain is the only chain receiving pays, or one chain is the only chain holders cash out from. That won't equalize until activity itself rebalances — arbitrage can only close gaps that aren't being regenerated.
- **Persistent AMM detachment** in one direction (AMM always cheaper or always more expensive than the terminal) indicates a structural issue: low AMM liquidity preventing closure, or a TWAP window too narrow to track the moving terminal rate.

---

## Reading list

- `../INVARIANTS.md` Section D2 — full conservation model and the deliberate-asymmetry rationale.
- `src/REVOwner.sol:231-233` — sucker branch in `beforeCashOutRecordedWith`, returns `taxRate=0` at LOCAL rate.
- `src/REVLoans.sol:419-435` — aggregated-vs-local supply selection and the local-surplus cap on borrow.
- `deploy-all-v6/test/fork/CrossChainArbCharacterizationFork.t.sol` — quantitative P&L characterization.
- `deploy-all-v6/test/invariants/CrossChainArbInvariant.t.sol` — stateful invariant suite.
- `bendystraw-v6/CROSS_CHAIN_DIVERGENCE_SURFACE.md` — planned indexer support.
