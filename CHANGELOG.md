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
