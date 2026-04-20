# Revnet Core

## Use This File For

- Use this file when the task involves revnet deployment, staged issuance, split operator logic, auto-issuance, or the revnet loan system built on top of Juicebox core.
- Start here, then decide whether the issue is really in `REVDeployer` deployment shape, `REVOwner` runtime-hook behavior, or `REVLoans` debt accounting. Most confusion in this repo comes from mixing those three roles.

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
| Stage, fee, and adversarial edge cases | [`test/TestStageTransitionBorrowable.t.sol`](./test/TestStageTransitionBorrowable.t.sol), [`test/TestSplitWeightE2E.t.sol`](./test/TestSplitWeightE2E.t.sol), [`test/TestLoansCashOutDelay.t.sol`](./test/TestLoansCashOutDelay.t.sol), [`test/REVLoansAttacks.t.sol`](./test/REVLoansAttacks.t.sol), [`test/TestFlashLoanSurplus.t.sol`](./test/TestFlashLoanSurplus.t.sol) |

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
- Revnets are intentionally ownerless after deployment. Treat any “admin recovery” instinct as suspect unless the code proves it.
- `REVOwner` is not a minor helper; it is the live ruleset data hook. Cash-out fees, sucker exemptions, buyback composition, and mint permission checks all run through it.
- `REVOwner.beforePayRecordedWith(...)` intentionally composes 721 split specs before buyback routing and then rescales weight to the amount that actually enters the project. Treat that ordering as an invariant.
- Loan collateral is burned and re-minted, not escrowed. Any change that assumes escrow semantics is likely wrong.
- Cash-out delay is enforced in both runtime cash-outs and loan borrowing. If one path changes without the other, the protection is broken.
- Hidden tokens are supply exclusion, not a side balance. They change redemption economics by reducing visible supply until revealed.
- Verify any economic assumption in code or tests before relying on it. Revnet docs carry more economic interpretation than most repos.
- Loan behavior, stage transitions, and split-weight adjustments interact. Do not treat them as independent subsystems when editing economics.
- Cash-out delay, buyback defaults, and sucker deployment rules all exist to protect cross-chain and launch-time economics. They are not optional configuration sugar.
- For anything cross-chain or stage-related, check both the deployer path and the reading-state reference before editing.
