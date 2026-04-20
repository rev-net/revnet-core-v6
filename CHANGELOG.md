# Changelog

## Scope

This file describes the verified change from `revnet-core-v5` to the current `revnet-core-v6` repo.

## Current v6 surface

- `REVDeployer`
- `REVOwner`
- `REVLoans`
- `REVHiddenTokens`
- `IREVDeployer`
- `IREVOwner`
- `IREVLoans`
- `IREVHiddenTokens`

## Summary

- The current repo assumes 721 hooks are part of the normal revnet deployment path rather than a separate special case.
- Buyback and loans configuration are more centralized than in v5. The repo is oriented around shared infrastructure instead of repeating per-revnet setup.
- `REVOwner` is now a real part of the repo's runtime surface. That split matters because the hook behavior no longer lives only on `REVDeployer`.
- The v6 test tree is substantially broader than the v5 tree, with dedicated regression, fork, attack, and invariant coverage for loans, cash-outs, split weights, and lifecycle edges.
- The repo moved from the v5 `0.8.23` baseline to `0.8.28`.

## Operator delegation (permission IDs 35–39)

- Added five new `JBPermissionIds` for operator delegation in `@bananapus/permission-ids-v6`:
  - `HIDE_TOKENS` (35) — lets an authorized operator allow or disallow holders to hide their own tokens via `REVHiddenTokens`
  - `OPEN_LOAN` (36) — open a loan on behalf of a token holder via `REVLoans.borrowFrom`
  - `REALLOCATE_LOAN` (37) — reallocate loan collateral on behalf of a loan owner via `REVLoans.reallocateCollateralFromLoan`
  - `REPAY_LOAN` (38) — repay a loan on behalf of a loan owner via `REVLoans.repayLoan`
  - `REVEAL_TOKENS` (39) — legacy permission id; hidden-token reveal no longer depends on it
- `REVHiddenTokens` now inherits `JBPermissioned` and accepts a `holder` parameter on `hideTokensOf` and `revealTokensOf`. Hiding is gated by an operator-managed holder allowlist. Revealing is holder-only and does not require special permission.
- `REVLoans.borrowFrom` now accepts a `holder` parameter. The loan NFT is minted to `holder`, and collateral is burned from `holder`. An operator with `OPEN_LOAN` permission can borrow on behalf of a holder.
- `REVLoans.repayLoan` now allows permissioned operators with `REPAY_LOAN` to repay on behalf of the loan NFT owner. Replacement loans are minted to the original loan owner.
- `REVLoans.reallocateCollateralFromLoan` now allows permissioned operators with `REALLOCATE_LOAN` to reallocate on behalf of the loan NFT owner. Returned collateral and replacement loans go to the original loan owner.
- `REVLoans` stores a `PERMISSIONS` immutable for inline permission checks (cannot inherit `JBPermissioned` due to existing `ERC721 + ERC2771Context + Ownable` inheritance).

### Breaking ABI changes from delegation

- `IREVHiddenTokens.hideTokensOf` signature changed: added `address holder` parameter
- `IREVHiddenTokens.revealTokensOf` signature changed: added `address holder` parameter
- `IREVHiddenTokens.setTokenHidingAllowedFor` added for operator-managed holder allowlisting
- `IREVHiddenTokens.HideTokens` event: added `address holder` field
- `IREVHiddenTokens.RevealTokens` event: added `address holder` field
- `IREVLoans.borrowFrom` signature changed: added `address holder` as last parameter

## Verified deltas

- `IREVDeployer.deployWith721sFor(...)` is gone.
- `IREVDeployer.deployFor(...)` now has overloads that return `(uint256, IJB721TiersHook)`.
- `IREVDeployer.BUYBACK_HOOK()`, `LOANS()`, and `OWNER()` are explicit v6 surface area.
- `IREVOwner` is a new interface and runtime counterpart to the deployer.
- `IREVHiddenTokens` is a new interface for temporary token hiding (burn to exclude from totalSupply, re-mint on reveal).
- `REVHiddenTokens` is a new standalone contract that lets holders temporarily hide tokens to increase cash-out value for remaining holders.
- The old caller-supplied `REVBuybackHookConfig` path is no longer part of the deployer interface.

## Breaking ABI changes

- `deployWith721sFor(...)` was removed.
- `deployFor(...)` overloads changed shape and return the deployed 721 hook.
- `REVConfig` no longer carries `loanSources` or `loans`.
- `REVDeploy721TiersHookConfig` now uses `REVBaseline721HookConfig` and inverted `preventSplitOperator*` booleans.
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
