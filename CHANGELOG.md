# Changelog

## Scope

This file describes the verified change from `revnet-core-v5` to the current `revnet-core-v6` repo.

## Current v6 surface

- `REVDeployer`
- `REVOwner`
- `REVLoans`
- `IREVDeployer`
- `IREVOwner`
- `IREVLoans`

## Summary

- The current repo assumes 721 hooks are part of the normal revnet deployment path rather than a separate special case.
- Buyback and loans configuration are more centralized than in v5. The repo is oriented around shared infrastructure instead of repeating per-revnet setup.
- `REVOwner` is now a real part of the repo's runtime surface. That split matters because the hook behavior no longer lives only on `REVDeployer`.
- The v6 test tree is substantially broader than the v5 tree, with dedicated regression, fork, attack, and invariant coverage for loans, cash-outs, split weights, and lifecycle edges.
- The repo moved from the v5 `0.8.23` baseline to `0.8.28`.

## In-v6 changes

### `0.0.52` — Cap reported surplus on `REVOwner.beforeCashOutRecordedWith` to fit local liquidity

PR #149 scaled the fee + reclaim proportionally when the gross global outflow exceeded local terminal liquidity, preserving a nonzero fee. But the data hook still returned the **unscaled** `effectiveSurplusValue` to `JBTerminalStore._cashOutWithDataHook`, which recomputes the beneficiary reclaim as `cashOutFrom(effSurplus, cashOutCount, totalSupply, taxRate)` and caps it at local surplus before adding the fee spec — so `balanceDiff = localSurplus + feeAmount > localSurplus` reverted with `InadequateTerminalStoreBalance`. Omnichain holders could not cash out locally when global surplus dominated.

`cashOutFrom` is linear in `surplus`. After the existing PR #149 scaling, `REVOwner` now lowers the reported `effectiveSurplusValue` proportionally so the store's recomputed reclaim is at most `localSurplus - feeAmount`, leaving exact room for the (preserved) fee spec. The buyback hook still receives the full pre-cap global surplus for its routing decision — only the store-facing return is capped.

The fee is **never** trimmed or zeroed: that was the regression PR #149 fixed.

Integrator impact: omnichain cash-outs that previously reverted with `InadequateTerminalStoreBalance` when local liquidity was the binding cap now settle. The beneficiary receives `localSurplus - feeAmount` and the fee revnet receives `feeAmount`. The user still burns the full `context.cashOutCount` tokens — semantics are the same as the pre-existing local-cap protocol behavior, just now reachable end-to-end.

## Operator delegation

- Added new `JBPermissionIds` for operator delegation in `@bananapus/permission-ids-v6`:
  - `OPEN_LOAN` — open a loan on behalf of a token holder via `REVLoans.borrowFrom`
  - `REALLOCATE_LOAN` — reallocate loan collateral on behalf of a loan owner via `REVLoans.reallocateCollateralFromLoan`
  - `REPAY_LOAN` — repay a loan on behalf of a loan owner via `REVLoans.repayLoan`
- `REVLoans.borrowFrom` now accepts a `holder` parameter. The loan NFT is minted to `holder`, and collateral is burned from `holder`. An operator with `OPEN_LOAN` permission can borrow on behalf of a holder.
- `REVLoans.repayLoan` now allows permissioned operators with `REPAY_LOAN` to repay on behalf of the loan NFT owner. Replacement loans are minted to the original loan owner.
- `REVLoans.reallocateCollateralFromLoan` now allows permissioned operators with `REALLOCATE_LOAN` to reallocate on behalf of the loan NFT owner. Returned collateral and replacement loans go to the original loan owner.
- `REVLoans` stores a `PERMISSIONS` immutable for inline permission checks (cannot inherit `JBPermissioned` due to existing `ERC721 + ERC2771Context + Ownable` inheritance).

### Breaking ABI changes from delegation

- `IREVLoans.borrowFrom` signature changed: added `address holder` as last parameter

## Verified deltas

- `IREVDeployer.deployWith721sFor(...)` is gone.
- `IREVDeployer.deployFor(...)` now has overloads that return `(uint256, IJB721TiersHook)`.
- `IREVDeployer.BUYBACK_HOOK()`, `LOANS()`, and `OWNER()` are explicit v6 surface area.
- `IREVOwner` is a new interface and runtime counterpart to the deployer.
- The old caller-supplied `REVBuybackHookConfig` path is no longer part of the deployer interface.

## Breaking ABI changes

- `deployWith721sFor(...)` was removed.
- `deployFor(...)` overloads changed shape and return the deployed 721 hook.
- `REVConfig` no longer carries `loanSources` or `loans`.
- `REVDeploy721TiersHookConfig` now uses `REVBaseline721HookConfig` and inverted `preventOperator*` booleans.
- `IREVOwner` is a new interface that some integrations must track separately from `IREVDeployer`.

## Indexer impact

- Runtime hook activity may now come from `REVOwner`, not only `REVDeployer`.
- Deployment indexing should assume a 721 hook is returned and present by default.
- Any schema built around caller-supplied buyback-hook config in deploy events needs to be revisited.

## Migration notes

- Re-check any integration that assumed `REVDeployer` was the only important runtime address. `REVOwner` now matters.
- Update deployment and indexing code for the default-721-hook assumption.
- Rebuild ABI expectations from the current interfaces and structs. The revnet surface is not a light-touch v5 upgrade.

## ABI appendix

- Removed functions
  - `deployWith721sFor(...)`
- Changed functions
  - `deployFor(...)` overloads now return the 721 hook
- Added interfaces / runtime addresses
  - `IREVOwner`
  - `OWNER()`
- Changed structs
  - `REVConfig`
  - `REVDeploy721TiersHookConfig`
- Removed config path
  - caller-supplied `REVBuybackHookConfig`
