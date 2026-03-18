# revnet-core-v6 Changelog (v5 -> v6)

This document describes all changes between `revnet-core` (v5, Solidity 0.8.23) and `revnet-core-v6` (v6, Solidity 0.8.26).

---

## 1. Breaking Changes

### 1.1 Removed Structs

| Struct | Notes |
|--------|-------|
| `REVBuybackHookConfig` | Removed entirely. Buyback hook configuration is no longer passed by the caller. The deployer auto-configures buyback pools via an immutable `BUYBACK_HOOK` registry. |
| `REVBuybackPoolConfig` | Removed entirely. Was used within `REVBuybackHookConfig`. Buyback pools are now auto-initialized with default parameters. |

### 1.2 Struct Field Changes

#### REVConfig

| Change | v5 | v6 |
|--------|----|----|
| `loanSources` field | `REVLoanSource[] loanSources` | Removed |
| `loans` field | `address loans` | Removed |

Loan sources and the loans contract address are no longer part of the per-revnet configuration. In v6, loans are managed via a single immutable `LOANS` address on the deployer, and fund access limits for loans are derived from terminal configurations rather than explicit loan sources.

#### REVDeploy721TiersHookConfig

| Change | v5 | v6 |
|--------|----|----|
| `baseline721HookConfiguration` type | `JBDeploy721TiersHookConfig` | `REVBaseline721HookConfig` |
| `splitOperatorCanAdjustTiers` | `bool splitOperatorCanAdjustTiers` | Renamed to `bool preventSplitOperatorAdjustingTiers` |
| `splitOperatorCanUpdateMetadata` | `bool splitOperatorCanUpdateMetadata` | Renamed to `bool preventSplitOperatorUpdatingMetadata` |
| `splitOperatorCanMint` | `bool splitOperatorCanMint` | Renamed to `bool preventSplitOperatorMinting` |
| `splitOperatorCanIncreaseDiscountPercent` | `bool splitOperatorCanIncreaseDiscountPercent` | Renamed to `bool preventSplitOperatorIncreasingDiscountPercent` |

The boolean semantics are **inverted**: v5 used opt-in flags (`splitOperatorCan*`), v6 uses opt-out flags (`preventSplitOperator*`). In v6, the permissions are granted by default unless explicitly prevented.

#### REVCroptopAllowedPost

| Change | v5 | v6 |
|--------|----|----|
| `maximumSplitPercent` field | Not present | Added: `uint32 maximumSplitPercent` |

### 1.3 IREVDeployer Interface Changes

| Change | v5 | v6 |
|--------|----|----|
| `deployFor` (no 721s) return type | `returns (uint256)` | `returns (uint256, IJB721TiersHook)` |
| `deployFor` (no 721s) parameters | `(uint256, REVConfig, JBTerminalConfig[], REVBuybackHookConfig, REVSuckerDeploymentConfig)` | `(uint256, REVConfig, JBTerminalConfig[], REVSuckerDeploymentConfig)` |
| `deployWith721sFor` | `deployWith721sFor(uint256, REVConfig, JBTerminalConfig[], REVBuybackHookConfig, REVSuckerDeploymentConfig, REVDeploy721TiersHookConfig, REVCroptopAllowedPost[])` | Removed. Replaced by `deployFor` overload with 6 parameters. |
| `buybackHookOf` view | `buybackHookOf(uint256) returns (IJBRulesetDataHook)` | Removed. Replaced by immutable `BUYBACK_HOOK()`. |
| `loansOf` view | `loansOf(uint256) returns (address)` | Removed. Replaced by immutable `LOANS()`. |

### 1.4 IREVLoans Interface Changes

| Change | v5 | v6 |
|--------|----|----|
| `REVNETS` view | `REVNETS() returns (IREVDeployer)` | Removed. The loans contract no longer stores a reference to the deployer. |
| `numberOfLoansFor` view | `numberOfLoansFor(uint256) returns (uint256)` | Renamed to `totalLoansBorrowedFor(uint256) returns (uint256)` |
| `reallocateCollateralFromLoan` mutability | `external payable` | `external` (not payable) |
| Constructor | `constructor(IREVDeployer, uint256, address, IPermit2, address)` | `constructor(IJBController, IJBProjects, uint256, address, IPermit2, address)` |

### 1.5 Removed Errors

| Contract | v5 Error | v6 Replacement |
|----------|----------|----------------|
| `REVDeployer` | `REVDeployer_LoanSourceDoesntMatchTerminalConfigurations(address, address)` | Removed. Loan sources are no longer validated against terminal configurations. |
| `REVLoans` | `REVLoans_RevnetsMismatch(address, address)` | Replaced by `REVLoans_InvalidTerminal(address, uint256)`. Terminal validation replaces deployer ownership check. |

---

## 2. New Features

### 2.1 New Functions

#### IREVDeployer / REVDeployer

| Function | Description |
|----------|-------------|
| `burnHeldTokensOf(uint256 revnetId)` | Burns any of the revnet's tokens held by the deployer contract. Project tokens can accumulate here from reserved token distribution when splits do not sum to 100%. |
| `deployFor` (4-arg overload) | Convenience overload that deploys a revnet with a default empty 721 hook. Constructs an empty 721 config internally. Returns `(uint256, IJB721TiersHook)`. |
| `BUYBACK_HOOK()` | Returns the immutable `IJBBuybackHookRegistry` used as a data hook to route payments through buyback pools. |
| `LOANS()` | Returns the immutable address of the single loan contract shared by all revnets. |
| `DEFAULT_BUYBACK_POOL_FEE()` | Returns the default Uniswap pool fee tier (`10_000` = 1%) for auto-configured buyback pools. |
| `DEFAULT_BUYBACK_TWAP_WINDOW()` | Returns the default TWAP window (`2 days`) for auto-configured buyback pools. |

### 2.2 New Events

| Contract | Event |
|----------|-------|
| `IREVDeployer` | `BurnHeldTokens(uint256 indexed revnetId, uint256 count, address caller)` |

### 2.3 New Errors

| Contract | Error |
|----------|-------|
| `REVDeployer` | `REVDeployer_NothingToBurn()` |
| `REVLoans` | `REVLoans_InvalidTerminal(address terminal, uint256 revnetId)` |
| `REVLoans` | `REVLoans_NothingToRepay()` |
| `REVLoans` | `REVLoans_ZeroBorrowAmount()` |
| `REVLoans` | `REVLoans_SourceMismatch()` |
| `REVLoans` | `REVLoans_LoanIdOverflow()` |
| `REVLoans` | `REVLoans_BurnPermissionRequired()` |

### 2.4 New Constants

| Contract | Constant | Description |
|----------|----------|-------------|
| `REVDeployer` | `DEFAULT_BUYBACK_POOL_FEE = 10_000` | Default Uniswap pool fee tier (1%) for auto-configured buyback pools. |
| `REVDeployer` | `DEFAULT_BUYBACK_TICK_SPACING = 200` | Default tick spacing for buyback pools, aligned with `UniV4DeploymentSplitHook.TICK_SPACING`. |
| `REVDeployer` | `DEFAULT_BUYBACK_TWAP_WINDOW = 2 days` | Default TWAP window for buyback pools. |

### 2.5 New Structs

| Struct | Description |
|--------|-------------|
| `REVBaseline721HookConfig` | Replaces `JBDeploy721TiersHookConfig` as the type for `REVDeploy721TiersHookConfig.baseline721HookConfiguration`. Contains `name`, `symbol`, `baseUri`, `tokenUriResolver`, `contractUri`, `tiersConfig`, `reserveBeneficiary`, and `flags` (`REV721TiersHookFlags`). |
| `REV721TiersHookFlags` | A subset of `JB721TiersHookFlags` that omits `issueTokensForSplits` (revnets always force it to `false`). Contains `noNewTiersWithReserves`, `noNewTiersWithVotes`, `noNewTiersWithOwnerMinting`, `preventOverspending`. |

---

## 3. Event Changes

### 3.1 Added Events

See section 2.2 above.

### 3.2 Removed Events

| Contract | Event | Notes |
|----------|-------|-------|
| `IREVDeployer` | `SetAdditionalOperator(uint256 revnetId, address additionalOperator, uint256[] permissionIds, address caller)` | Removed entirely. |

### 3.3 Modified Events

| Contract | Event | Change |
|----------|-------|--------|
| `IREVDeployer` | `DeployRevnet` | Removed `REVBuybackHookConfig buybackHookConfiguration` parameter. |
| `IREVLoans` | `ReallocateCollateral` | Typo fix: `removedcollateralCount` (lowercase 'c') renamed to `removedCollateralCount` (uppercase 'C'). |

### 3.4 NatSpec Documentation

All events in v6 interfaces gained comprehensive NatSpec documentation (`@notice`, `@param`). This is a documentation-only change that does not affect the ABI.

---

## 4. Error Changes

### 4.1 Removed Errors

| Contract | Error | Notes |
|----------|-------|-------|
| `REVDeployer` | `REVDeployer_LoanSourceDoesntMatchTerminalConfigurations(address, address)` | Loan sources removed from `REVConfig`. |
| `REVLoans` | `REVLoans_RevnetsMismatch(address, address)` | Replaced by terminal validation via `DIRECTORY.isTerminalOf`. |

### 4.2 New Errors

See section 2.3 above.

### 4.3 Unchanged Errors

The following errors are identical between v5 and v6:

**REVDeployer:**
- `REVDeployer_AutoIssuanceBeneficiaryZeroAddress()`
- `REVDeployer_CashOutDelayNotFinished(uint256, uint256)`
- `REVDeployer_CashOutsCantBeTurnedOffCompletely(uint256, uint256)`
- `REVDeployer_MustHaveSplits()`
- `REVDeployer_NothingToAutoIssue()`
- `REVDeployer_RulesetDoesNotAllowDeployingSuckers()`
- `REVDeployer_StageNotStarted(uint256)`
- `REVDeployer_StagesRequired()`
- `REVDeployer_StageTimesMustIncrease()`
- `REVDeployer_Unauthorized(uint256, address)`

**REVLoans:**
- `REVLoans_CollateralExceedsLoan(uint256, uint256)`
- `REVLoans_InvalidPrepaidFeePercent(uint256, uint256, uint256)`
- `REVLoans_LoanExpired(uint256, uint256)`
- `REVLoans_NewBorrowAmountGreaterThanLoanAmount(uint256, uint256)`
- `REVLoans_NoMsgValueAllowed()`
- `REVLoans_NotEnoughCollateral()`
- `REVLoans_OverflowAlert(uint256, uint256)`
- `REVLoans_OverMaxRepayBorrowAmount(uint256, uint256)`
- `REVLoans_PermitAllowanceNotEnough(uint256, uint256)`
- `REVLoans_ReallocatingMoreCollateralThanBorrowedAmountAllows(uint256, uint256)`
- `REVLoans_Unauthorized(address, address)`
- `REVLoans_UnderMinBorrowAmount(uint256, uint256)`
- `REVLoans_ZeroCollateralLoanIsInvalid()`

---

## 5. Struct Changes

### 5.1 Removed Structs

| Struct | Notes |
|--------|-------|
| `REVBuybackHookConfig` | Buyback hook is now an immutable on the deployer; configuration is automatic. |
| `REVBuybackPoolConfig` | Was used within `REVBuybackHookConfig`. |

### 5.2 New Structs

| Struct | Notes |
|--------|-------|
| `REVBaseline721HookConfig` | Replaces `JBDeploy721TiersHookConfig` in `REVDeploy721TiersHookConfig`. Provides a revnet-specific 721 config that uses `REV721TiersHookFlags` instead of `JB721TiersHookFlags`, omitting `issueTokensForSplits`. |
| `REV721TiersHookFlags` | A subset of `JB721TiersHookFlags` without `issueTokensForSplits` (always forced to `false` for revnets). |

### 5.3 Modified Structs

| Struct | Field | v5 | v6 |
|--------|-------|----|----|
| `REVConfig` | `loanSources` | `REVLoanSource[] loanSources` | Removed |
| `REVConfig` | `loans` | `address loans` | Removed |
| `REVCroptopAllowedPost` | `maximumSplitPercent` | Not present | `uint32 maximumSplitPercent` |
| `REVDeploy721TiersHookConfig` | `baseline721HookConfiguration` | `JBDeploy721TiersHookConfig` | `REVBaseline721HookConfig` |
| `REVDeploy721TiersHookConfig` | `splitOperatorCanAdjustTiers` | `bool splitOperatorCanAdjustTiers` | Renamed/inverted: `bool preventSplitOperatorAdjustingTiers` |
| `REVDeploy721TiersHookConfig` | `splitOperatorCanUpdateMetadata` | `bool splitOperatorCanUpdateMetadata` | Renamed/inverted: `bool preventSplitOperatorUpdatingMetadata` |
| `REVDeploy721TiersHookConfig` | `splitOperatorCanMint` | `bool splitOperatorCanMint` | Renamed/inverted: `bool preventSplitOperatorMinting` |
| `REVDeploy721TiersHookConfig` | `splitOperatorCanIncreaseDiscountPercent` | `bool splitOperatorCanIncreaseDiscountPercent` | Renamed/inverted: `bool preventSplitOperatorIncreasingDiscountPercent` |

### 5.4 Unchanged Structs

The following structs are identical between v5 and v6 (only `forge-lint` comments added):
- `REVAutoIssuance`
- `REVDescription`
- `REVLoan`
- `REVLoanSource`
- `REVStageConfig`
- `REVSuckerDeploymentConfig`

---

## 6. Implementation Changes

### 6.1 REVDeployer

| Change | Description |
|--------|-------------|
| **Solidity version** | Upgraded from `0.8.23` to `0.8.26`. |
| **Buyback hook architecture** | Per-revnet `buybackHookOf` mapping replaced with a single immutable `BUYBACK_HOOK` (`IJBBuybackHookRegistry`). Pools are auto-initialized for each terminal token during deployment via `_tryInitializeBuybackPoolFor`. |
| **Loans architecture** | Per-revnet `loansOf` mapping replaced with a single immutable `LOANS` address. The deployer grants `USE_ALLOWANCE` permission to the loans contract for all revnets in the constructor (wildcard `revnetId=0`). |
| **Constructor permissions** | v6 constructor grants three wildcard permissions: `MAP_SUCKER_TOKEN` to the sucker registry, `USE_ALLOWANCE` to the loans contract, and `SET_BUYBACK_POOL` to the buyback hook. v5 only granted `MAP_SUCKER_TOKEN`. |
| **Deploy function consolidation** | `deployFor` and `deployWith721sFor` merged into two `deployFor` overloads: a 6-arg version (with 721 config and allowed posts) and a 4-arg convenience version (auto-creates empty 721 hook). Both return `(uint256, IJB721TiersHook)`. |
| **Every revnet gets a 721 hook** | The 4-arg `deployFor` overload auto-deploys a default empty 721 hook with all split operator permissions granted. In v5, the simple `deployFor` did not deploy any 721 hook. |
| **721 permission semantics inverted** | v5 used opt-in flags (`splitOperatorCanAdjustTiers` etc.) that conditionally pushed permissions. v6 uses opt-out flags (`preventSplitOperatorAdjustingTiers` etc.) that grant permissions by default unless prevented. |
| **`beforePayRecordedWith` rewrite** | v5 fetched the buyback hook from `buybackHookOf[revnetId]` and the 721 hook separately, passing the 721 hook as a zero-amount `JBPayHookSpecification`. v6 queries the 721 hook first as a data hook to determine its tier split amount, reduces the payment context amount for the buyback hook query, and scales the buyback weight proportionally (`weight * projectAmount / totalAmount`) to prevent minting tokens for the split portion of payments. |
| **`hasMintPermissionFor` updated** | v5 checked `loansOf[revnetId]`, `buybackHookOf[revnetId]`, and suckers. v6 checks the immutable `LOANS`, the immutable `BUYBACK_HOOK`, and delegates to `BUYBACK_HOOK.hasMintPermissionFor` for buyback delegates. |
| **Loan fund access limits simplified** | v5 derived fund access limits from `configuration.loanSources` and validated them against terminal configurations via `_matchingCurrencyOf`. v6 derives them from all terminal configurations directly (one unlimited surplus allowance per terminal+token pair). The `_matchingCurrencyOf` helper is removed. |
| **`burnHeldTokensOf` added** | New function to burn any project tokens held by the deployer. Reverts with `REVDeployer_NothingToBurn` if the balance is zero. |
| **Split operator permissions expanded** | Default permissions increased from 6 (v5) to 9 (v6). Added `SET_BUYBACK_HOOK`, `SET_ROUTER_TERMINAL`, and `SET_TOKEN_METADATA`. |
| **Encoded configuration hash** | v5 included `configuration.loans` in the encoded configuration. v6 does not, since loans are no longer per-revnet. |
| **Deploy ordering** | v6 `_deploy721RevnetFor` deploys the revnet first via `_deployRevnetFor`, then deploys the 721 hook and sets split operator permissions. v5 deployed the 721 hook then called `_deployRevnetFor`. |
| **Croptop `maximumSplitPercent`** | v6 passes the new `maximumSplitPercent` field from `REVCroptopAllowedPost` to `CTAllowedPost`. |
| **Auto-initialized buyback pools** | During deployment, `_tryInitializeBuybackPoolFor` is called for every terminal token to set up Uniswap V4 buyback pools at a generic 1:1 `sqrtPriceX96`. Failures (e.g., pool already initialized) are silently caught via try-catch. |
| **Feeless beneficiary cashout routing** | `beforeCashOutRecordedWith` now checks `context.beneficiaryIsFeeless` and skips the 2.5% revnet fee when the cashout is routed by a feeless address (e.g., the router terminal routing value between projects). v5 did not have this check. The cash out tax rate still applies -- only the protocol fee is waived. |

### 6.2 REVLoans

| Change | Description |
|--------|-------------|
| **Solidity version** | Upgraded from `0.8.23` to `0.8.26`. |
| **Deployer dependency removed** | v5 stored `REVNETS` (`IREVDeployer`) and validated that the revnet was owned by the expected deployer via `RevnetsMismatch`. v6 does not reference the deployer at all. Validation now checks the terminal directly via `DIRECTORY.isTerminalOf`. |
| **Constructor refactored** | v5 accepted `IREVDeployer revnets` and derived `CONTROLLER`, `DIRECTORY`, etc. from it. v6 accepts `IJBController controller` and `IJBProjects projects` directly. |
| **Terminal validation** | `borrowFrom` now validates that the source terminal is registered in the directory for the revnet, reverting with `REVLoans_InvalidTerminal` if not. v5 validated deployer ownership instead. |
| **`numberOfLoansFor` renamed** | Renamed to `totalLoansBorrowedFor` to clarify that it is a monotonically increasing counter, not a count of active loans. |
| **`reallocateCollateralFromLoan` not payable** | v5 marked this function as `external payable`. v6 removes `payable` since the function only moves existing collateral between loans and does not accept new funds. |
| **Source mismatch check** | `reallocateCollateralFromLoan` now validates that the provided source matches the existing loan's source, reverting with `REVLoans_SourceMismatch()` if they differ. |
| **Zero borrow amount check** | `borrowFrom` now reverts with `REVLoans_ZeroBorrowAmount()` if the bonding curve returns zero. v5 did not have this check and would create a zero-amount loan. |
| **Nothing to repay check** | `repayLoan` now reverts with `REVLoans_NothingToRepay()` if both `repayBorrowAmount` and `collateralCountToReturn` are zero, preventing unbounded `totalLoansBorrowedFor` inflation. |
| **Liquidation loop behavior** | v5 broke out of the loop when encountering a loan with `createdAt == 0` (`break`). v6 continues iterating (`continue`), skipping gaps from repaid or previously liquidated loans. |
| **Liquidation cleanup** | v6 adds `delete _loanOf[loanId]` after burning a liquidated loan, clearing stale loan data for a gas refund. v5 did not clean up the loan data. |
| **`_totalBorrowedFrom` decimal normalization** | v6 normalizes token amounts from the source's native decimals to the target decimals before currency conversion. v5 did not perform decimal normalization, which could cause mixed-decimal arithmetic errors for tokens with non-18 decimals (e.g., USDC with 6 decimals). |
| **`_totalBorrowedFrom` zero-price safety** | v6 skips sources with a zero price to prevent division-by-zero panics that would DoS all loan operations. v5 did not handle this case. |
| **`_determineSourceFeeAmount` boundary fix** | An intermediate v6 revision used `>=` for the liquidation check, which created a 1-second window where neither repay nor liquidate could execute. This was fixed back to `>` (matching v5) so the exact boundary second is still repayable, while the liquidation path uses `<=`. |
| **BURN_TOKENS permission prerequisite** | `borrowFrom` now validates upfront that the caller has granted `BURN_TOKENS` permission to the loans contract via `JBPermissions.hasPermission`. Without this, the transaction would revert deep in `JBController.burnTokensOf` with a less informative error. Reverts with `REVLoans_BurnPermissionRequired()`. v5 did not perform this check. |
| **Cross-revnet liquidation guard** | `liquidateExpiredLoansFrom` now validates that `startingLoanId + count` does not exceed `_ONE_TRILLION`, preventing callers from overflowing into a different revnet's loan ID namespace via `_generateLoanId`. Reverts with `REVLoans_LoanIdOverflow()`. v5 did not have this bounds check. |
| **Source fee try-catch hardening** | The source fee payment in `_adjust` is now wrapped in a try-catch block. If the source terminal's `pay` call reverts, the ERC-20 allowance is reclaimed and the fee amount is returned to the beneficiary instead of blocking the entire loan operation. v5 called `terminal.pay` directly without error handling. |
| **Timestamp cast fix** | `borrowFrom` now casts `block.timestamp` to `uint48` when setting `loan.createdAt`, matching the `REVLoan.createdAt` field width. v5 used `uint40`, which would silently truncate timestamps after the year 36812. |
| **`ReallocateCollateral` event typo fix** | v5 used `removedcollateralCount` (lowercase 'c'). v6 fixes it to `removedCollateralCount` (uppercase 'C'). |
| **NatSpec documentation** | Extensive NatSpec added to all functions, views, and internal helpers. Flash loan safety analysis documented in `_borrowableAmountFrom`. |

### 6.3 Named Arguments

Throughout the codebase, function calls were updated to use named argument syntax (e.g., `foo({bar: 1, baz: 2})`) for improved readability.

---

## 7. Migration Table

### Interfaces

| v5 | v6 | Notes |
|----|----|-------|
| `IREVDeployer` | `IREVDeployer` | `deployWith721sFor` removed; two `deployFor` overloads (both return `IJB721TiersHook`). `buybackHookOf` and `loansOf` removed. `BUYBACK_HOOK`, `LOANS`, `DEFAULT_BUYBACK_POOL_FEE`, `DEFAULT_BUYBACK_TWAP_WINDOW`, `burnHeldTokensOf` added. `BurnHeldTokens` event added, `SetAdditionalOperator` event removed. `DeployRevnet` event lost `buybackHookConfiguration` param. NatSpec added. |
| `IREVLoans` | `IREVLoans` | `REVNETS` removed. `numberOfLoansFor` renamed to `totalLoansBorrowedFor`. `reallocateCollateralFromLoan` no longer payable. Constructor takes `IJBController` + `IJBProjects` instead of `IREVDeployer`. `ReallocateCollateral` event typo fixed. NatSpec added. |

### Contracts

| v5 | v6 | Notes |
|----|----|-------|
| `REVDeployer` | `REVDeployer` | Buyback hook architecture changed from per-revnet mapping to immutable registry. Loans changed from per-revnet to single immutable. Deploy functions consolidated. Every revnet gets a 721 hook. 721 permission flags inverted. `beforePayRecordedWith` rewritten for split-aware weight scaling. `burnHeldTokensOf` added. Split operator gains 3 new default permissions (`SET_BUYBACK_HOOK`, `SET_ROUTER_TERMINAL`, `SET_TOKEN_METADATA`). Feeless beneficiary cashout routing skips fee for feeless addresses. |
| `REVLoans` | `REVLoans` | Deployer dependency removed. Terminal validation replaces deployer ownership check. `numberOfLoansFor` renamed. `reallocateCollateralFromLoan` not payable. Source mismatch, zero borrow, nothing-to-repay, and BURN_TOKENS permission checks added. Cross-revnet liquidation guard prevents loan ID namespace overflow. Liquidation loop uses `continue` instead of `break`. Stale loan data cleaned up on liquidation. Decimal normalization and zero-price safety in `_totalBorrowedFrom`. Source fee payment wrapped in try-catch. Timestamp cast fixed from `uint40` to `uint48`. |

### Structs

| v5 | v6 | Notes |
|----|----|-------|
| `REVAutoIssuance` | `REVAutoIssuance` | Identical (lint comment added) |
| `REVBuybackHookConfig` | (removed) | Buyback hook is now an immutable on the deployer |
| `REVBuybackPoolConfig` | (removed) | Was used within `REVBuybackHookConfig` |
| (not present) | `REVBaseline721HookConfig` | New struct for revnet-specific 721 hook configuration |
| (not present) | `REV721TiersHookFlags` | New subset of `JB721TiersHookFlags` without `issueTokensForSplits` |
| `REVConfig` | `REVConfig` | Removed `loanSources` and `loans` fields |
| `REVCroptopAllowedPost` | `REVCroptopAllowedPost` | Added `maximumSplitPercent` field |
| `REVDeploy721TiersHookConfig` | `REVDeploy721TiersHookConfig` | `baseline721HookConfiguration` type changed. Boolean flags inverted from opt-in to opt-out. |
| `REVDescription` | `REVDescription` | Identical (lint comment added) |
| `REVLoan` | `REVLoan` | Identical (lint comment added) |
| `REVLoanSource` | `REVLoanSource` | Identical (lint comment added) |
| `REVStageConfig` | `REVStageConfig` | Identical (lint comment added) |
| `REVSuckerDeploymentConfig` | `REVSuckerDeploymentConfig` | Identical (lint comment added) |
