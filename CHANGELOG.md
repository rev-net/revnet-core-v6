# Changelog

## 0.0.87 — Adopt per-context oracle-free cross-chain surplus

- Raised `@bananapus/suckers-v6` `^0.0.67 → ^0.0.69` to adopt the per-context cross-chain surplus API.
- `REVOwner` and `REVLoans` now call `SUCKER_REGISTRY.totalRemoteSurplusOf(projectId, currency, decimals)` (renamed
  from `remoteSurplusOf`, with `currency` and `decimals` swapped); `remoteTotalSupplyOf` is unchanged.
- `REVOwner.peerChainAdjustedAccountsOf` now takes only `projectId` and returns `(uint256 supply, JBSourceContext[]
  contexts)`. Each loan source token's outstanding debt is exported as its own context, raw and un-valued in the
  token's own currency and decimals (counted as both surplus and balance), so the receiving chain folds it into the
  matching same-asset local context at par. The previous oracle conversion is no longer applied on this path;
  `_localLoanStateOf` still values local cash-out math into a single currency.

## 0.0.86 — Raise dependency floors to latest and update the test harness for them

- Raised every dependency caret floor to its latest published version: `@bananapus/721-hook-v6` `^0.0.59 → ^0.0.65`,
  `@bananapus/buyback-hook-v6` `^0.0.64 → ^0.0.66`, `@bananapus/core-v6` `^0.0.72 → ^0.0.79`,
  `@bananapus/ownable-v6` `^0.0.32 → ^0.0.36`, `@bananapus/permission-ids-v6` `^0.0.27 → ^0.0.29`,
  `@bananapus/router-terminal-v6` `^0.0.58 → ^0.0.60`, `@bananapus/suckers-v6` `^0.0.60 → ^0.0.67`,
  `@croptop/core-v6` `^0.0.60 → ^0.0.64`, and `@bananapus/address-registry-v6` `^0.0.29 → ^0.0.33`. No `src/` change.
- This is the floor bump that 0.0.85 attempted and rolled back. The two upstream changes that the earlier attempt
  caught are now handled in the test harness:
  - `@croptop/core-v6` `CTPublisher` added a `permit2` constructor argument (now the fourth parameter, before
    `trustedForwarder`). Every test that builds a `CTPublisher` now passes the canonical Permit2 address
    (`0x000000000022D473030F116dDEE9F6B43aC78BA3`) and uses named constructor arguments.
  - `@bananapus/core-v6` `JBProjects` now caps `setCreationFee` at `MAX_CREATION_FEE` (`0.001 ether`). The three
    `REVDeployerRegressions` tests that set a creation fee lowered their value from `0.01 ether` to `0.001 ether` so
    it stays within the cap while still confirming the fee is forwarded.

## 0.0.85 — Document NatSpec, comment, and lint conventions in STYLE_GUIDE

- `STYLE_GUIDE.md`: expand the NatSpec section to spell out the required tags for every member, add a Comments
  section documenting the inline-comment and "describe current behavior as the only behavior" conventions, and
  expand the Linting section to document the `--deny notes` zero-warning CI gate. Documentation only — no source
  change.
- Attempted to raise the dependency caret floors to the latest published versions, but reverted the floor bump:
  it broke the non-fork test build because `@croptop/core-v6` added a required `permit2` constructor argument to
  `CTPublisher` that the test harness does not yet supply. The dependency floors are unchanged; the STYLE_GUIDE
  documentation ships on its own.

## 0.0.84 — Borrowable-amount preview matches what a borrow can execute

- `REVLoans.borrowableAmountFrom` previously reconstructed the revnet's economic liquidity as
  `localSurplus = totalSurplus + totalBorrowed` and capped its quote at that value. Because an actual borrow draws funds
  from the **live** treasury balance through the terminal's use-allowance path — which is strictly less than the
  reconstructed value once earlier borrows have already drawn it down — the preview could quote more than the terminal
  could currently deliver, so a borrow sized to the quote would revert even though the economic limit allowed it.
- The preview now **additionally** caps its result at the live treasury surplus (the amount the terminal can disburse
  right now). The existing economic cap is preserved; the smaller of the two bounds applies. Opening a borrow applies
  the same live cap, so a borrow sized to the freshly-quoted amount executes without reverting.
- `borrowableAmountFrom` now **returns both values** so a single read serves both purposes:
  `(uint256 borrowableNow, uint256 borrowableCapacity)`. `borrowableNow` is what a borrow can execute right now (held to
  the terminal's live balance); `borrowableCapacity` is the economic ceiling including amounts already borrowed against
  the revnet — the same figure repaying and reallocating value collateral against. This is a return-shape change to the
  public view (pre-deploy, no live consumers); callers that read a single value should destructure the first return.
- Internally, the live cap is now applied at the call sites rather than threaded through a boolean parameter. Opening a
  borrow takes the smaller of `borrowableCapacity` and the live balance; repaying and reallocating use
  `borrowableCapacity` directly, since they value collateral that **already** backs a loan and draw no fresh funds.
  Removing the threaded parameter and its branches also brought the `REVLoans` runtime size back under the 24,576-byte
  limit (24,350 bytes).
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
