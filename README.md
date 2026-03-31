# Revnet Core

`@rev-net/core-v6` deploys and operates Revnets: autonomous Juicebox projects with staged economics, optional tiered NFTs, cross-chain support, buyback integration, and token-collateralized loans.

Docs: <https://docs.juicebox.money>
Architecture: [ARCHITECTURE.md](./ARCHITECTURE.md)

## Overview

A Revnet is meant to run without a human owner after launch. Its economics are encoded up front as a sequence of stages, and the runtime hook plus loan system enforce those rules over time.

This package provides:

- a deployer that launches Revnets and stores their long-lived configuration
- a runtime hook that mediates pay, cash-out, mint-permission, and delayed-cash-out behavior
- an ERC-721 loan system that burns token collateral on borrow and remints on repayment

It also composes with the 721 hook stack, buyback hook, router terminal, Croptop, and suckers where needed.

Use this repo when the product is an autonomous treasury-backed network with encoded stage transitions. Do not use it when governance, mutable operator control, or simple project deployment is the goal.

The key point is that a Revnet is not just "a Juicebox project with presets." It is a project shape whose admin surface is intentionally collapsed into deployment-time configuration plus constrained runtime operators.

## Key Contracts

| Contract | Role |
| --- | --- |
| `REVDeployer` | Launches and configures Revnets, stages, split operators, and optional auxiliary features. |
| `REVOwner` | Runtime data-hook and cash-out-hook surface used by active Revnets. |
| `REVLoans` | Loan surface that lets users borrow against Revnet tokens with burned collateral and NFT loan positions. |

## Mental Model

Read the package in two halves:

1. deployment-time shape: `REVDeployer` decides what the network will be allowed to do
2. runtime enforcement: `REVOwner` and `REVLoans` decide how that shape behaves over time

That split matters because most mistakes are one of these:

- assuming a deploy-time parameter can be changed later
- assuming a runtime hook is only advisory rather than economically binding

The shortest useful reading order is:

1. `REVDeployer`
2. `REVOwner`
3. `REVLoans`
4. any integrated hook or bridge repo the deployment enables

## Read These Files First

1. `src/REVDeployer.sol`
2. `src/REVOwner.sol`
3. `src/REVLoans.sol`
4. the integrated hook or bridge repo used by the deployment

## Integration Traps

- the deployer holding the project NFT is not an implementation detail; it is part of the ownership model
- split operators are constrained, not equivalent to general protocol governance
- the loan system depends on live revnet economics, so it should be reviewed together with the runtime hook and treasury assumptions
- optional integrations like buybacks, 721 hooks, and suckers are compositional, but they materially change the resulting network

## Where State Lives

- deployment-time configuration and operator envelope live in `REVDeployer`
- runtime pay and cash-out behavior live in `REVOwner`
- loan positions and loan-specific state live in `REVLoans`

Do not audit those contracts in isolation if the deployment enables cross-package features; the composed network is the real product.

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

Revnet deployment assumes the core protocol, 721 hook, buyback hook, router terminal, suckers, and Croptop packages are available. Every Revnet is intentionally unowned after deployment in the human sense; the deployer contract itself retains the project NFT.

## Repository Layout

```text
src/
  REVDeployer.sol
  REVOwner.sol
  REVLoans.sol
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
- `REVLoans` relies on live treasury conditions and is therefore sensitive to surplus and pricing assumptions
- the deployer and runtime hook have a tight relationship that should be treated as one design, not two independent contracts
- burned-collateral lending is operationally different from escrowed-collateral lending and needs clear integrator expectations

The usual review failure mode is to focus on the loans or the stages in isolation. The real system is the combination of stage economics, runtime hook behavior, and who is still allowed to act after deployment.
