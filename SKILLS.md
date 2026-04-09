# Revnet Core

## Use This File For

- Use this file when the task involves revnet deployment, staged issuance, split operator logic, auto-issuance, or the revnet loan system built on top of Juicebox core.
- Start here, then open the deployer, owner, or loans contract depending on whether the issue is launch-time config, runtime hook behavior, or debt accounting.

## Read This Next

| If you need... | Open this next |
|---|---|
| Repo overview and operator flow | [`README.md`](./README.md) |
| Deployment and stage config | [`src/REVDeployer.sol`](./src/REVDeployer.sol), [`script/Deploy.s.sol`](./script/Deploy.s.sol) |
| Runtime owner and data-hook behavior | [`src/REVOwner.sol`](./src/REVOwner.sol) |
| Loan accounting and liquidation behavior | [`src/REVLoans.sol`](./src/REVLoans.sol) |
| Temporary token hiding and supply exclusion | [`src/REVHiddenTokens.sol`](./src/REVHiddenTokens.sol) |
| Types and helpers | [`src/structs/`](./src/structs/), [`src/interfaces/`](./src/interfaces/), [`test/helpers/`](./test/helpers/) |
| Loan regressions, economics, and forks | [`test/REVLoansRegressions.t.sol`](./test/REVLoansRegressions.t.sol), [`test/TestLongTailEconomics.t.sol`](./test/TestLongTailEconomics.t.sol), [`test/fork/`](./test/fork/), [`test/regression/`](./test/regression/) |

## Repo Map

| Area | Where to look |
|---|---|
| Main contracts | [`src/`](./src/) |
| Scripts | [`script/`](./script/) |
| Types | [`src/structs/`](./src/structs/), [`src/interfaces/`](./src/interfaces/) |
| Tests | [`test/`](./test/) |

## Purpose

Deploy and manage Revnets -- autonomous, unowned Juicebox projects with staged issuance schedules, built-in Uniswap buyback pools, cross-chain suckers, and token-collateralized lending.

## Reference Files

| If you need... | Open this next |
|---|---|
| Contract roles, deploy/runtime entrypoints, integration points, or key structs | [`references/runtime.md`](./references/runtime.md) |
| Events, errors, constants, storage, gotchas, state-reading recipes, or examples | [`references/operations.md`](./references/operations.md) |

## Working Rules

- Start in `REVDeployer` for launch-time behavior, `REVOwner` for runtime hook behavior, `REVLoans` for collateral and debt accounting, and `REVHiddenTokens` for temporary supply exclusion.
- Verify any economic assumption in code or tests before relying on it. Revnet docs carry more economic interpretation than most repos.
- For anything cross-chain or stage-related, check both the deployer path and the reading-state reference before editing.
