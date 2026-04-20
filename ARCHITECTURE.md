# Architecture

## Purpose

`revnet-core-v6` defines an autonomous Juicebox project pattern with staged, precommitted economics and token-collateralized loans. A revnet is intentionally ownerless after deployment in the human sense: behavior follows staged configuration and constrained runtime hooks instead of ongoing governance.

## System Overview

`REVDeployer` handles launch-time shape, staged rulesets, hook wiring, and runtime wrapper behavior. `REVOwner` provides the owner-like runtime policy surface for pay and cash-out hooks after launch. `REVLoans` manages burn-collateral loan positions represented as ERC-721 loans. `REVHiddenTokens` lets holders burn tokens to exclude them from total supply until they reveal them again.

## Core Invariants

- Revnets are intended to be ownerless after deployment; easy admin recovery paths would violate the product model.
- Stage configuration is effectively permanent once queued.
- Loan collateral is burned, not escrowed, and supply-sensitive logic must treat it as real destruction until repayment.
- Hidden tokens are burned, not escrowed, and reduce total supply until revealed.
- `REVOwner` and `REVDeployer` are tightly coupled; their setup order matters.
- Cash-out delay affects both exits and borrowing power. If the current stage delays cash out, `REVLoans` should treat borrowability as zero until that delay expires.
- Cross-chain supply and surplus are part of revnet economics. Local payouts and loans must not ignore remote sucker snapshots.

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `REVDeployer` | Launch, staged rulesets, hook wiring, permissions, runtime wrapper behavior | Launch-time and runtime wrapper |
| `REVOwner` | Runtime owner-like policy surface | Hook-facing policy |
| `REVLoans` | Borrow, repay, and liquidate burned-collateral loan positions | Economic core |
| `REVHiddenTokens` | Temporary supply exclusion through burn and reveal | Supply-sensitive utility |
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

The repo does not replace core treasury accounting. Its critical economic logic is the interaction between staged revnet configuration, burned-collateral loan state, hidden-token supply exclusion, and omnichain revnet state imported from suckers.

`REVOwner` also composes payment and cash-out hooks. On pay, it merges 721-tier split forwarding with buyback-hook behavior and scales mint weight so the terminal only mints against the share actually entering the project. On cash out, it uses omnichain supply and surplus for reclaim math, exempts trusted suckers from tax and fee routing, and may append a fee hook spec that forwards rev fees to the fee revnet.

## Security Model

- The highest-risk interactions sit where stage economics, treasury state, and loan borrowability meet.
- Ownerlessness removes convenient operational recovery from misconfiguration.
- Hidden-token and burned-collateral semantics materially affect supply-sensitive pricing.
- `REVOwner` is a live runtime policy surface, not just a launch helper. Cash-out delay, buyback composition, sucker exemptions, and fee routing all pass through it.
- Rev cash-out fees stack on top of protocol-fee behavior rather than replacing it. Fee semantics should be reviewed with terminal behavior, not in isolation.

## Safe Change Guide

- Review deploy-time behavior and runtime wrapper behavior together.
- If stage semantics change, inspect loan math, cash-out behavior, and downstream fee expectations together.
- Do not casually add mutable admin escape hatches.
- If you change borrowability, re-check cash-out-delay gating, omnichain surplus inputs, and local-surplus caps together.
- If you change hook composition, re-check 721 split handling, buyback hook assumptions, and which callers retain mint permission through `REVOwner`.
- If loan calculations change, review flash-loan and surplus-sensitive behavior adversarially.

## Canonical Checks

- cash-out-delay interaction with loans:
  `test/TestLoansCashOutDelay.t.sol`
- stage transitions and borrowability drift:
  `test/TestStageTransitionBorrowable.t.sol`
- omnichain or phantom-surplus edge cases:
  `test/audit/CodexPhantomSurplusTerminal.t.sol`

## Source Map

- `src/REVDeployer.sol`
- `src/REVOwner.sol`
- `src/REVLoans.sol`
- `src/REVHiddenTokens.sol`
- `test/TestLoansCashOutDelay.t.sol`
- `test/TestStageTransitionBorrowable.t.sol`
- `test/audit/CodexPhantomSurplusTerminal.t.sol`
