# Changelog

## 0.0.84 — Borrowable-amount preview matches what a borrow can execute

- `REVLoans.borrowableAmountFrom` previously reconstructed the revnet's economic liquidity as
  `localSurplus = totalSurplus + totalBorrowed` and capped its quote at that value. Because an actual borrow draws funds
  from the **live** treasury balance through the terminal's use-allowance path — which is strictly less than the
  reconstructed value once earlier borrows have already drawn it down — the preview could quote more than the terminal
  could currently deliver, so a borrow sized to the quote would revert even though the economic limit allowed it.
- The preview now **additionally** caps its result at the live treasury surplus (the amount the terminal can disburse
  right now). The existing economic cap is preserved; the smaller of the two bounds applies. Opening a borrow applies
  the same live cap, so a borrow sized to the freshly-quoted amount executes without reverting.
- Repaying and reallocating are unaffected: those paths value collateral that **already** backs a loan and draw no
  fresh funds from the terminal, so they continue to use the un-capped economic value (their fund movement is
  unchanged).
- No storage-layout change. No change to fees, accounting, or which funds move during a borrow — only the quoted and
  opened amount is held to what the live treasury can deliver.

## 0.0.81 — Bump buyback-hook-v6 and router-terminal-v6 to latest

- `@bananapus/buyback-hook-v6`: `^0.0.58 → ^0.0.64`. Spans the cash-out `skip` encoding (`(uint256, bool)`, 0.0.62), the
  metadata purpose rename `"quote"`/`"cashOutMinReclaimed"` → `"pay"`/`"cashOut"` (0.0.63), and the gas-only
  constructor-immutable-ID refactor (0.0.64). **No revnet src change required:** `REVOwner` forwards
  `context.metadata` unchanged to `BUYBACK_HOOK.beforeCashOutRecordedWith` and never builds or decodes buyback-targeted
  metadata itself, so the rename/encoding changes are transparent to it.
- `@bananapus/router-terminal-v6`: `^0.0.55 → ^0.0.58` (the router's own metadata purposes were renamed to `"pay"`/
  `"cashOut"` and it now depends on buyback 0.0.64). `REVDeployer` only references the router-terminal *registry*
  address; no constructor or interface usage changed for revnet.
- Cleared a pre-existing `Warning (2018)` by marking the file-reading script helper
  `CoreDeploymentLib._tryGetDeploymentAddress` `view` (matches its `_getDeploymentAddress` sibling).
- No `src/` behavioral change. 379 non-fork tests pass (1 skipped); build is warning-free.

## 0.0.64 — Owner-settable referral target on `REVLoans`

- New `referralProjectId()` view returning the packed `(chainId << 48) | projectId` reference credited as the referrer on every `useAllowanceOf` call this contract makes.
- New `setReferralProjectId(uint256 projectId, uint256 chainId)` (`onlyOwner`): takes the two fields unpacked, packs and stores them. Bounded so the pack is lossless — `projectId <= type(uint48).max`, `chainId <= type(uint208).max`. Reverts with `REVLoans_ReferralProjectIdTooLarge` / `REVLoans_ReferralChainIdTooLarge` otherwise. Emits `SetReferralProjectId(referralChainId, referralProjectId, caller)`.
- Default at construction: `(chainId = 1, projectId = REV_ID)` — fee-volume credit still lands on the REV revnet on Ethereum mainnet regardless of which chain a loan originates from. Owner can repoint this if REV ever migrates chains, or pass `(0, 0)` to disable referral credit entirely.
- The inline `(uint256(1) << 48) | REV_ID` pack inside `_borrowAmountFrom` is replaced by a read of the new storage slot. No external behavior change for default deployments.
- Storage layout: `referralProjectId` was inserted at slot 8 in alphabetical order between `isLoanSourceOf` and `tokenUriResolver` (per `STYLE_GUIDE.md`), shifting all subsequent public slots by 1. `LoanIdOverflowGuard.t.sol`'s `TOTAL_LOANS_BORROWED_FOR_SLOT` was bumped 11 → 12 and `StorageLayoutStable.t.sol` was updated in lockstep. **External slot-based tooling reading `totalLoansBorrowedFor`/`totalCollateralOf`/`totalBorrowedFrom`/`tokenUriResolver` directly via raw storage must be re-pointed.**

## 0.0.62 — Omit unset router terminal registry

- `REVDeployer` now omits `ROUTER_TERMINAL_REGISTRY` from the canonical terminal configuration when it was
  constructed with `address(0)`.
- This supports chains where the router terminal stack is unavailable while still launching revnets with the canonical
  multi terminal.

## 0.0.56 — Bump v6 deps to nana-core-v6 0.0.53 cohort

- `@bananapus/core-v6`: `^0.0.48 → ^0.0.53` ([PR #145](https://github.com/Bananapus/nana-core-v6/pull/145)).
- `@bananapus/721-hook-v6`: `^0.0.47 → ^0.0.50`.
- `@bananapus/buyback-hook-v6`: `^0.0.39 → ^0.0.46`.
- `@bananapus/router-terminal-v6`: `^0.0.37 → ^0.0.43`.
- `@bananapus/suckers-v6`: `^0.0.37 → ^0.0.46`.
- `@bananapus/permission-ids-v6`: `^0.0.24 → ^0.0.25`.
- Test updates:
  - `jbMultiTerminal().FEE()` → `JBConstants.FEE` (FEE moved to a compile-time constant in core 0.0.52+).
  - `JBBuybackHook` constructor signature changed in 0.0.45 (V4 PoolManager + Hooks moved to a one-shot setter). Updated `ForkTestBase` and `TestSplitWeightFork` to construct then call `setChainSpecificConstants`.
  - All `JBRulesetMetadata` test literals patched to include `pauseCrossProjectFeeFreeInflows: false`. `REVConfig` and `JBBeforeCashOutRecordedContext` literals are unchanged (no new fields).

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
