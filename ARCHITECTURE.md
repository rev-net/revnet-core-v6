# Architecture

## Purpose

`revnet-core-v6` defines an autonomous Juicebox project pattern with staged, precommitted economics and token-collateralized loans. A revnet is intentionally ownerless after deployment: project behavior follows its queued stages and integrated hooks rather than ongoing governance.

## Boundaries

- `REVDeployer` owns launch-time configuration and runtime wrapper behavior.
- `REVOwner` owns owner-like data-hook behavior for revnet projects.
- `REVLoans` owns the loan lifecycle.
- The repo composes several sibling repos instead of reimplementing them.

## Main Components

| Component | Responsibility |
| --- | --- |
| `REVDeployer` | Launches revnets, queues staged rulesets, wires hooks, grants operator permissions, and exposes runtime wrapper behavior |
| `REVOwner` | Ownerless policy surface plugged into revnet rulesets |
| `REVLoans` | Burn-collateral borrow/repay/liquidate flow represented as ERC-721 loans |
| config structs | Stage, auto-issuance, loan source, and 721-hook configuration surfaces |

## Runtime Model

### Revnet Lifecycle

```text
creator
  -> deploys a revnet with a fixed sequence of stages
stage transitions
  -> happen automatically over time through ruleset activation
participants
  -> pay in, receive tokens, cash out, and interact with downstream hooks
operators or permissionless callers
  -> perform bounded maintenance actions such as auto-issuance claims
```

### Loan Lifecycle

```text
borrower
  -> burns revnet tokens as collateral
  -> receives funds from the treasury through REVLoans
  -> later repays to remint collateral
  -> or gets liquidated after the long expiration window
```

## Critical Invariants

- The project is designed to be ownerless after deployment. "Easy" admin recovery paths would break the product thesis.
- Stage configuration is effectively permanent once queued.
- Loan collateral is burned, not escrowed. Supply-sensitive logic must treat that as real destruction until repayment.
- `REVOwner` and `REVDeployer` are tightly coupled. Their setup order is part of correctness.

## Where Complexity Lives

- Revnets span deployment-time guarantees, runtime hook behavior, and loan-state transitions.
- The most subtle risks sit where treasury state, stage economics, and loan borrowability interact.
- Ownerlessness is a feature, but it also removes easy operational recovery from misconfiguration.

## Dependencies

- `nana-core-v6` for treasury and ruleset mechanics
- `nana-buyback-hook-v6`, `nana-suckers-v6`, `nana-router-terminal-v6`, and optionally `nana-721-hook-v6` for composed features
- `croptop-core-v6` and other product repos when revnets are used as economic backends

## Safe Change Guide

- Treat deployer-time behavior and runtime wrapper behavior as one system.
- Any change to stage semantics should be checked against loan math, cash-out semantics, and downstream fee-project expectations.
- Do not casually add mutable admin escape hatches.
- Flash-loan and surplus-sensitive logic deserves adversarial review whenever loan calculations change.
- If a change affects borrowability or repayment, test both sourced and unsourced loan paths.
