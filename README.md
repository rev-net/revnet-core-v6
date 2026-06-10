# Revnet Core

`@rev-net/core-v6` deploys and operates Revnets: Juicebox project shapes with staged economics, optional tiered NFTs, cross-chain support, buyback integration, and token-collateralized loans.


## Documentation

- [INVARIANTS.md](./INVARIANTS.md) — per-contract guarantees + operation inventory
- [ARBITRAGE.md](./ARBITRAGE.md) — the three intentional protocol-beneficial arbitrage paths
- [ARCHITECTURE.md](./ARCHITECTURE.md) — module layout
- [ADMINISTRATION.md](./ADMINISTRATION.md) — admin surface (REVOwner + REVLoans ownable)
- [RISKS.md](./RISKS.md) — threat model
- [USER_JOURNEYS.md](./USER_JOURNEYS.md) — example flows
- [AUDIT_INSTRUCTIONS.md](./AUDIT_INSTRUCTIONS.md) — auditor scope and orientation
- [SKILLS.md](./SKILLS.md) — agent-oriented navigation map
- [STYLE_GUIDE.md](./STYLE_GUIDE.md) — solidity conventions across the V6 ecosystem
- [CHANGELOG.md](./CHANGELOG.md) - V5 to V6 migration changelog

## Overview

A Revnet is meant to minimize human administration after launch. Its economics are encoded up front as a sequence of stages, and the runtime hook plus loan system enforce those rules over time.

This package provides:

- a deployer that launches Revnets and stores their long-lived configuration
- a runtime hook that mediates pay, cash-out, mint-permission, and delayed-cash-out behavior
- a loan system that burns token collateral on borrow and remints on repayment

It also composes with the 721 hook stack, buyback hook, router terminal, Croptop, and suckers where needed.

Use this repo when the product is a treasury-backed network with encoded stage transitions and a tightly constrained post-launch admin surface. Do not use it when the goal is ordinary governance or a simple project deploy.

## Key contracts

| Contract | Role |
| --- | --- |
| `REVDeployer` | Launches and configures Revnets, stages, operators, and optional auxiliary features. |
| `REVOwner` | Runtime data-hook and cash-out-hook surface used by active Revnets. |
| `REVLoans` | Loan surface that lets users borrow against Revnet tokens with burned collateral and NFT loan positions. |

## Mental model

Read the package in two halves:

1. deployment-time shape: `REVDeployer` decides what the network will be allowed to do
2. runtime enforcement: `REVOwner` and `REVLoans` decide how that shape behaves over time

Most mistakes come from assuming a deploy-time parameter can be changed later or that a runtime hook is only advisory.

## Read these files first

1. `src/REVDeployer.sol`
2. `src/REVOwner.sol`
3. `src/REVLoans.sol`
4. the integrated hook or bridge repo used by the deployment

## Integration traps

- the deployer holding the project NFT is part of the ownership model, not an implementation detail
- operators are constrained, not equivalent to general protocol governance
- the loan system depends on live revnet economics and should be reviewed together with the runtime hook
- optional integrations like buybacks, 721 hooks, and suckers materially change the resulting network

## Where state lives

- deployment-time configuration and operator envelope live in `REVDeployer`
- runtime pay and cash-out behavior live in `REVOwner`
- loan positions and loan-specific state live in `REVLoans`

## High-signal tests

1. `test/REVLifecycle.t.sol`
2. `test/REVLoans.invariants.t.sol`
3. `test/TestLongTailEconomics.t.sol`
4. `test/fork/TestLoanBorrowFork.t.sol`
5. `test/regression/PhantomSurplusTerminal.t.sol`

## Install

```bash
npm install @rev-net/core-v6
```

## Development

```bash
npm install
forge build --deny notes
forge test --deny notes
```

Useful scripts:

- `npm run deploy:mainnets`
- `npm run deploy:testnets`

## Deployment notes

Revnet deployment assumes the core protocol, 721 hook, buyback hook, router terminal, suckers, and Croptop packages are available. Revnets are intentionally unowned in the direct human sense after deployment, but the deployer contract itself remains part of the ownership model.

## Repository layout

```text
src/
  REVDeployer.sol
  REVOwner.sol
  REVLoans.sol
  interfaces/
  structs/
test/
  lifecycle, deployment, loan, fork, invariant, review, and regression coverage
script/
  Deploy.s.sol
  helpers/
```

## Risks and notes

- Revnets are intentionally hard to change after launch, so bad stage design is expensive
- `REVLoans` relies on live treasury conditions and is sensitive to surplus and pricing assumptions; zero cross-currency prices fail closed instead of hiding outstanding debt
- the deployer and runtime hook should be treated as one design, not two separate systems
- burned-collateral lending is operationally different from escrowed-collateral lending

## For AI agents

- Describe Revnets as treasury-backed Juicebox project shapes with encoded stage transitions, not as simple presets.
- Read `REVDeployer`, `REVOwner`, and `REVLoans` together before answering economic or admin-surface questions.
- If a deployment enables buybacks, 721 hooks, or suckers, inspect those sibling repos before making definitive claims.
