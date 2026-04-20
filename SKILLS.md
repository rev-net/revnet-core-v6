# Revnet Core

## Use This File For

- Use this file when the task involves revnet deployment, staged issuance, split-operator logic, auto-issuance, hidden tokens, or the revnet loan system.
- Start here, then decide whether the issue is really in `REVDeployer`, `REVOwner`, `REVLoans`, or `REVHiddenTokens`.

## Read This Next

| If you need... | Open this next |
|---|---|
| Repo overview and operator flow | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Deployment and stage config | [`src/REVDeployer.sol`](./src/REVDeployer.sol), [`script/Deploy.s.sol`](./script/Deploy.s.sol) |
| Runtime owner and data-hook behavior | [`src/REVOwner.sol`](./src/REVOwner.sol), [`references/runtime.md`](./references/runtime.md) |
| Loan accounting and liquidation behavior | [`src/REVLoans.sol`](./src/REVLoans.sol) |
| Temporary token hiding and supply exclusion | [`src/REVHiddenTokens.sol`](./src/REVHiddenTokens.sol) |
| Types and helpers | [`src/structs/`](./src/structs/), [`src/interfaces/`](./src/interfaces/), [`test/helpers/`](./test/helpers/) |
| Lifecycle, loans, and economic proofs | [`test/REVLifecycle.t.sol`](./test/REVLifecycle.t.sol), [`test/REVLoansRegressions.t.sol`](./test/REVLoansRegressions.t.sol), [`test/REVLoans.invariants.t.sol`](./test/REVLoans.invariants.t.sol), [`test/TestLongTailEconomics.t.sol`](./test/TestLongTailEconomics.t.sol) |

## Repo Map

| Area | Where to look |
|---|---|
| Main contracts | [`src/`](./src/) |
| Scripts | [`script/`](./script/) |
| Types | [`src/structs/`](./src/structs/), [`src/interfaces/`](./src/interfaces/) |
| Tests | [`test/`](./test/) |

## Purpose

Deploy and manage Revnets: autonomous Juicebox project shapes with staged issuance schedules, optional buyback pools, cross-chain suckers, hidden-token mechanics, and token-collateralized lending.

## Reference Files

- Open [`references/runtime.md`](./references/runtime.md) for contract roles, deploy/runtime entrypoints, integration points, and key structs.
- Open [`references/operations.md`](./references/operations.md) for events, errors, constants, storage, gotchas, and state-reading recipes.

## Working Rules

- Start in `REVDeployer` for launch-time behavior, `REVOwner` for runtime hook behavior, `REVLoans` for debt accounting, and `REVHiddenTokens` for supply exclusion.
- Revnets are intentionally ownerless after deployment. Treat any admin-recovery instinct as suspect unless the code proves it.
- `REVOwner` is not a minor helper; it is a live runtime policy surface.
- Loan collateral is burned and re-minted, not escrowed. Any change that assumes escrow semantics is likely wrong.
- Cash-out delay is enforced in both runtime cash-outs and loan borrowing. If one path changes without the other, the protection is broken.
- Hidden tokens are supply exclusion, not a side balance.
- Loan behavior, stage transitions, hidden supply, and split-weight adjustments interact. Do not treat them as independent subsystems.
