# Revnet Core

`@rev-net/core-v6` deploys and operates Revnets: Juicebox project shapes with staged economics, optional tiered NFTs, cross-chain support, buyback integration, hidden-token mechanics, and token-collateralized loans.

Docs: <https://docs.juicebox.money>
Architecture: [ARCHITECTURE.md](./ARCHITECTURE.md)  
User journeys: [USER_JOURNEYS.md](./USER_JOURNEYS.md)  
Skills: [SKILLS.md](./SKILLS.md)  
Risks: [RISKS.md](./RISKS.md)  
Administration: [ADMINISTRATION.md](./ADMINISTRATION.md)  
Audit instructions: [AUDIT_INSTRUCTIONS.md](./AUDIT_INSTRUCTIONS.md)

## Overview

A Revnet is meant to minimize human administration after launch. Its economics are encoded up front as a sequence of stages, and the runtime hook plus loan system enforce those rules over time.

This package provides:

- a deployer that launches Revnets and stores their long-lived configuration
- a runtime hook that mediates pay, cash-out, mint-permission, and delayed-cash-out behavior
- a loan system that burns token collateral on borrow and remints on repayment
- a hidden-token system that temporarily removes tokens from visible supply while preserving economic claim
  denominators

It also composes with the 721 hook stack, buyback hook, router terminal, Croptop, and suckers where needed.

Use this repo when the product is a treasury-backed network with encoded stage transitions and a tightly constrained post-launch admin surface. Do not use it when the goal is ordinary governance or a simple project deploy.

## Key Contracts

| Contract | Role |
| --- | --- |
| `REVDeployer` | Launches and configures Revnets, stages, split operators, and optional auxiliary features. |
| `REVOwner` | Runtime data-hook and cash-out-hook surface used by active Revnets. |
| `REVLoans` | Loan surface that lets users borrow against Revnet tokens with burned collateral and NFT loan positions. |
| `REVHiddenTokens` | Lets token holders temporarily hide tokens from visible/governance supply until reveal, while cash-out and loan denominators still count hidden supply. |

## Mental Model

Read the package in two halves:

1. deployment-time shape: `REVDeployer` decides what the network will be allowed to do
2. runtime enforcement: `REVOwner`, `REVLoans`, and `REVHiddenTokens` decide how that shape behaves over time

Most mistakes come from assuming a deploy-time parameter can be changed later or that a runtime hook is only advisory.

## Read These Files First

1. `src/REVDeployer.sol`
2. `src/REVOwner.sol`
3. `src/REVLoans.sol`
4. `src/REVHiddenTokens.sol`
5. the integrated hook or bridge repo used by the deployment

## Integration Traps

- the deployer holding the project NFT is part of the ownership model, not an implementation detail
- split operators are constrained, not equivalent to general protocol governance
- the loan system depends on live revnet economics and should be reviewed together with the runtime hook
- optional integrations like buybacks, 721 hooks, and suckers materially change the resulting network

## Where State Lives

- deployment-time configuration and operator envelope live in `REVDeployer`
- runtime pay and cash-out behavior live in `REVOwner`
- loan positions and loan-specific state live in `REVLoans`
- hidden-token state lives in `REVHiddenTokens`

## High-Signal Tests

1. `test/REVLifecycle.t.sol`
2. `test/REVLoans.invariants.t.sol`
3. `test/TestLongTailEconomics.t.sol`
4. `test/fork/TestLoanBorrowFork.t.sol`
5. `test/audit/CodexPhantomSurplusTerminal.t.sol`

## Install

```bash
npm install @rev-net/core-v6
```

## Development

```bash
npm install
forge build
forge test
```

Useful scripts:

- `npm run deploy:mainnets`
- `npm run deploy:testnets`
- `npm run deploy:mainnets:1_1`
- `npm run deploy:testnets:1_1`

## Deployment Notes

Revnet deployment assumes the core protocol, 721 hook, buyback hook, router terminal, suckers, and Croptop packages are available. Revnets are intentionally unowned in the direct human sense after deployment, but the deployer contract itself remains part of the ownership model.

## Repository Layout

```text
src/
  REVDeployer.sol
  REVOwner.sol
  REVLoans.sol
  REVHiddenTokens.sol
  interfaces/
  structs/
test/
  lifecycle, deployment, loan, fork, invariant, audit, and regression coverage
script/
  Deploy.s.sol
  helpers/
```

## Risks And Notes

- Revnets are intentionally hard to change after launch, so bad stage design is expensive
- `REVLoans` relies on live treasury conditions and is sensitive to surplus and pricing assumptions
- the deployer and runtime hook should be treated as one design, not two separate systems
- burned-collateral lending is operationally different from escrowed-collateral lending

## For AI Agents

- Describe Revnets as treasury-backed Juicebox project shapes with encoded stage transitions, not as simple presets.
- Read `REVDeployer`, `REVOwner`, `REVLoans`, and `REVHiddenTokens` together before answering economic or admin-surface questions.
- If a deployment enables buybacks, 721 hooks, or suckers, inspect those sibling repos before making definitive claims.
