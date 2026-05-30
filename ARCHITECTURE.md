# Architecture

## Purpose

`revnet-core-v6` defines an autonomous Juicebox project pattern with staged, precommitted economics and token-collateralized loans. A revnet is intentionally ownerless after deployment in the human sense: behavior follows staged configuration and constrained runtime hooks instead of ongoing governance.

## System Overview

`REVDeployer` handles launch-time shape, staged rulesets, hook wiring, and runtime wrapper behavior. `REVOwner` provides the owner-like runtime policy surface for pay and cash-out hooks after launch. `REVLoans` manages burn-collateral loan positions represented as NFTs.

## Core Invariants

- Revnets are intended to be ownerless after deployment; easy admin recovery paths would violate the product model.
- Stage configuration is effectively permanent once queued.
- Loan collateral is burned, not escrowed.
- `REVOwner` and `REVDeployer` are tightly coupled; their setup order matters.
- Cash-out delay affects both exits and borrowing power.
- Cross-chain supply and surplus are part of revnet economics. Local payouts and loans must not ignore remote sucker snapshots.

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `REVDeployer` | Launch, staged rulesets, hook wiring, permissions, runtime wrapper behavior | Launch-time and runtime wrapper |
| `REVOwner` | Runtime owner-like policy surface | Hook-facing policy |
| `REVLoans` | Borrow, repay, and liquidate burned-collateral loan positions | Economic core |
| config structs | Stage, loan-source, auto-issuance, and hook config | Launch-time inputs |

## Trust Boundaries

- Treasury and ruleset mechanics remain rooted in `nana-core-v6`.
- Optional integrations come from `nana-buyback-hook-v6`, `nana-router-terminal-v6`, `nana-suckers-v6`, and `nana-721-hook-v6`.
- This repo composes those systems into an ownerless product shape instead of reimplementing them.

## Critical Flows

### Revnet Lifecycle

```text
creator
  -> deploys a revnet with a fixed stage sequence
stage transitions
  -> activate automatically over time through rulesets
participants
  -> pay in, receive tokens, cash out, and interact with enabled integrations
operators or permissionless callers
  -> perform bounded maintenance such as auto-issuance claims
```

### Loan Lifecycle

```text
borrower
  -> burns revnet tokens as collateral
  -> borrowability is computed from the current stage, omnichain supply/surplus, and local liquidity caps
  -> receives treasury-backed funds through REVLoans
  -> later repays to remint collateral
  -> or is liquidated after the expiration window
```

## Accounting Model

The repo does not replace core treasury accounting. Its critical economic logic is the interaction between staged revnet config, burned-collateral loan state, and omnichain revnet state imported from suckers.

`REVOwner` also composes payment and cash-out hooks. On pay, it can merge 721-tier split forwarding with buyback-hook behavior and scale mint weight so the terminal only mints against the share that actually enters the project. On cash out, it can use omnichain supply and surplus for reclaim math, exempt trusted suckers, and append fee-hook specs.

When global effective surplus exceeds local terminal liquidity, `beforeCashOutRecordedWith` scales the unscaled bonding-curve reclaim and fee proportionally to fit the local cap, then lowers the surplus value it reports back to `JBTerminalStore` so the store's recomputed reclaim leaves room for the (preserved) fee spec. The buyback hook still sees the full pre-cap global surplus for its routing decision. The user burns the full requested `cashOutCount` and receives `localSurplus - feeAmount`; the protocol fee is never zeroed by this scaling.

## Security Model

- The highest-risk interactions sit where stage economics, treasury state, and loan borrowability meet.
- Ownerlessness removes convenient recovery from misconfiguration.
- Burned-collateral semantics materially affect supply-sensitive pricing.
- `REVOwner` is a live runtime policy surface, not only a launch helper.
- Rev cash-out fees stack on top of protocol-fee behavior rather than replacing it.

## Safe Change Guide

- Review deploy-time behavior and runtime wrapper behavior together.
- If stage semantics change, inspect loan math, cash-out behavior, and downstream fee expectations together.
- Do not casually add mutable admin escape hatches.
- If you change borrowability, re-check cash-out-delay gating, omnichain surplus inputs, and local-surplus caps together.
- If you change hook composition, re-check 721 split handling, buyback assumptions, and mint-permission flows.

## Cross-Chain Configuration Hash

`REVDeployer` produces an `encodedConfigurationHash` for each revnet that determines sucker deployment salts. This hash commits the revnet's identity across chains. It includes:

- `baseCurrency`, `description.name`, `description.ticker`, `description.salt`
- `scopeCashOutsToLocalBalances`
- Stage parameters (timing, issuance limits, cash-out tax rates, extra metadata, and auto-issuances)

Terminal addresses are constructor-pinned on `REVDeployer` and are not repeated in the per-revnet hash. Accounting contexts (token addresses) are also excluded because tokens like USDC legitimately differ per chain.

This means cross-chain matching is driven by immutable revnet economics and the deployer installation, not by caller-selected terminals. A deployment with a different canonical terminal stack must use a different deployer, which changes the trust boundary even if the per-revnet hash matches.

This is exactly why a revnet denominates in a *standard* currency, never a token. `baseCurrency` is a `JBCurrencyIds` value (`ETH = 1`, `USD = 2`) — chain-independent, so it is safe to commit to the cross-chain hash. The concrete asset a terminal accepts lives in a per-chain `JBAccountingContext` whose `currency` is token-keyed (`uint32(uint160(token))`) and is deliberately excluded from the hash, because the same logical asset has a different address on each chain (USDC) or may not exist (a chain whose native token is not ETH). Each chain bridges its local token to the revnet's standard `baseCurrency` through a locally-registered `JBPrices` feed, which `JBTerminalStore` reads on pay/cash-out whenever the accepted token's currency differs from `baseCurrency`. A USD revnet therefore prices each chain's local USDC into USD via that chain's USDC/USD feed, while the revnet config stays byte-identical everywhere. Consequence: `baseCurrency` must stay a standard `JBCurrencyIds` unit — making a revnet's denomination chain-specific (e.g. a token-keyed `baseCurrency`) would break cross-chain identity. See `nana-core-v6/ARCHITECTURE.md` (Currency model) for the terminal-side mechanics.

## Canonical Checks

- cash-out-delay interaction with loans:
  `test/TestLoansCashOutDelay.t.sol`
- stage transitions and borrowability drift:
  `test/TestStageTransitionBorrowable.t.sol`
- omnichain or phantom-surplus edge cases:
  `test/regression/PhantomSurplusTerminal.t.sol`
- terminal exclusion from configuration hash:
  `test/TestTerminalEncodingInHash.t.sol`

## Source Map

- `src/REVDeployer.sol`
- `src/REVOwner.sol`
- `src/REVLoans.sol`
- `test/TestLoansCashOutDelay.t.sol`
- `test/TestStageTransitionBorrowable.t.sol`
- `test/regression/PhantomSurplusTerminal.t.sol`
