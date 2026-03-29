# Revnet Core

## Purpose

Deploy and manage Revnets -- autonomous, unowned Juicebox projects with staged issuance schedules, built-in Uniswap buyback pools, cross-chain suckers, and token-collateralized lending.

## Contracts

| Contract | Role |
|----------|------|
| `REVDeployer` | Deploys revnets, permanently owns the project NFT. Manages stages, splits, auto-issuance, buyback hooks, suckers, split operators, and configuration state storage. Exposes `OWNER()` view returning the REVOwner address. Calls DEPLOYER-restricted setters on REVOwner during deployment to store `cashOutDelayOf` and `tiered721HookOf`. |
| `REVOwner` | Runtime hook contract for all revnets. Implements `IJBRulesetDataHook` + `IJBCashOutHook`. Set as the `dataHook` in each revnet's ruleset metadata. Handles pay hooks, cash-out hooks, mint permissions, and sucker verification. Stores `cashOutDelayOf` and `tiered721HookOf` mappings (set by REVDeployer via DEPLOYER-restricted setters `setCashOutDelayOf()` and `setTiered721HookOf()`). (~310 lines) |
| `REVLoans` | Issues token-collateralized loans from revnet treasuries. Each loan is an ERC-721 NFT. Burns collateral on borrow, re-mints on repay. Charges tiered fees (REV protocol fee + source fee + prepaid fee). (~1,359 lines) |

## Key Functions

### Deployment

| Function | Permissions | What it does |
|----------|------------|-------------|
| `REVDeployer.deployFor(revnetId, config, terminals, suckerConfig)` | Permissionless | Deploy a new revnet (`revnetId=0`) or convert an existing Juicebox project. Encodes stage configs into rulesets, deploys ERC-20 token, initializes buyback pool at 1:1 price, sets up split operator, suckers, loans permissions, and deploys a default empty tiered ERC-721 hook. |
| `REVDeployer.deployFor(revnetId, config, terminals, suckerConfig, hookConfig, allowedPosts)` | Permissionless | Same as `deployFor` but deploys a tiered ERC-721 hook with pre-configured tiers. Optionally configures Croptop posting criteria and grants publisher permission to add tiers. |
| `REVDeployer.deploySuckersFor(revnetId, suckerConfig)` | Split operator | Deploy new cross-chain suckers post-launch. Validates ruleset allows sucker deployment (bit 2 of `extraMetadata`). Uses stored config hash for cross-chain matching. |

### Data Hooks (REVOwner)

| Function | Permissions | What it does |
|----------|------------|-------------|
| `REVOwner.beforePayRecordedWith(context)` | Terminal callback | Calls the 721 hook first for split specs, then calls the buyback hook with a reduced amount context (payment minus split amount). Adjusts the returned weight proportionally for splits (`weight = mulDiv(weight, amount - splitAmount, amount)`) so the terminal only mints tokens for the amount entering the project. Assembles pay hook specs (721 hook specs first, then buyback spec). Reads `tiered721HookOf` from REVOwner storage. |
| `REVOwner.beforeCashOutRecordedWith(context)` | Terminal callback | If sucker: returns full amount with 0 tax (fee exempt). Otherwise: calculates 2.5% fee, enforces 30-day cash-out delay (reads `cashOutDelayOf` from REVOwner storage), returns modified count + fee hook spec. |
| `REVOwner.afterCashOutRecordedWith(context)` | Permissionless | Cash-out hook callback. Receives fee amount and pays it to the fee revnet's terminal. Falls back to returning funds if fee payment fails. |
| `REVOwner.hasMintPermissionFor(revnetId, ruleset, addr)` | View | Returns `true` for: loans contract, buyback hook, buyback hook delegates, or suckers. |
| `REVOwner.cashOutDelayOf(revnetId)` | View | Returns the cash-out delay timestamp from REVOwner storage. Exposed for REVLoans compatibility (REVLoans imports IREVOwner for this). |

### Split Operator

| Function | Permissions | What it does |
|----------|------------|-------------|
| `REVDeployer.setSplitOperatorOf(revnetId, newOperator)` | Split operator | Replace the current split operator. Revokes old permissions, grants new ones. |

### Auto-Issuance

| Function | Permissions | What it does |
|----------|------------|-------------|
| `REVDeployer.autoIssueFor(revnetId, stageId, beneficiary)` | Permissionless | Mint pre-configured auto-issuance tokens for a beneficiary once a stage has started. One-time per stage per beneficiary. |
| `REVDeployer.burnHeldTokensOf(revnetId)` | Permissionless | Burn any reserved tokens held by the deployer (when splits < 100%). |

### Loans -- Borrowing

| Function | Permissions | What it does |
|----------|------------|-------------|
| `REVLoans.borrowFrom(revnetId, source, minBorrowAmount, collateralCount, beneficiary, prepaidFeePercent)` | Permissionless (caller must grant BURN_TOKENS to REVLoans) | Open a loan: enforce cash-out delay if set (cross-chain deployment protection), burn collateral tokens, pull funds from revnet via `useAllowanceOf`, pay REV fee (1%) + terminal fee (2.5%), transfer remainder to beneficiary, mint loan NFT. |
| `REVLoans.repayLoan(loanId, maxRepayBorrowAmount, collateralCountToReturn, beneficiary, allowance)` | Loan NFT owner | Repay fully or partially. Returns funds to revnet via `addToBalanceOf`, re-mints collateral tokens, burns/replaces the loan NFT. Supports permit2 signatures. |
| `REVLoans.reallocateCollateralFromLoan(loanId, collateralCountToTransfer, source, minBorrowAmount, collateralCountToAdd, beneficiary, prepaidFeePercent)` | Loan NFT owner | Refinance: remove excess collateral from an existing loan and open a new loan with the freed collateral. Burns original, mints two replacements. |
| `REVLoans.liquidateExpiredLoansFrom(revnetId, startingLoanId, count)` | Permissionless | Clean up loans past the 10-year liquidation duration. Burns NFTs and decrements accounting totals. Collateral is permanently lost. |
| `REVLoans.setTokenUriResolver(resolver)` | Contract owner (`onlyOwner`) | Set the `IJBTokenUriResolver` used for loan NFT token URIs. |

### Loans -- Views

| Function | What it does |
|----------|-------------|
| `REVLoans.borrowableAmountFrom(revnetId, collateralCount, decimals, currency)` | Calculate how much can be borrowed for a given collateral amount. Returns 0 during the cash-out delay period. Aggregates surplus from all terminals, applies bonding curve. |
| `REVLoans.determineSourceFeeAmount(loan, amount)` | Calculate the time-proportional source fee for a loan repayment. Zero during prepaid window, linear accrual after. |
| `REVLoans.loanOf(loanId)` | Returns the full `REVLoan` struct for a loan. |
| `REVLoans.loanSourcesOf(revnetId)` | Returns all `(terminal, token)` pairs used for loans by a revnet. |
| `REVLoans.revnetIdOfLoanWith(loanId)` | Decode the revnet ID from a loan ID (`loanId / 1_000_000_000_000`). |

## Integration Points

| Dependency | Import | Used For |
|------------|--------|----------|
| `@bananapus/core-v6` | `IJBController`, `IJBDirectory`, `IJBPermissions`, `IJBProjects`, `IJBTerminal`, `IJBPrices`, `JBConstants`, `JBCashOuts`, `JBSurplus` | Project lifecycle, rulesets, token minting/burning, fund access, terminal payments, price feeds, bonding curve |
| `@bananapus/721-hook-v6` | `IJB721TiersHook`, `IJB721TiersHookDeployer` | Deploying and registering tiered ERC-721 pay hooks |
| `@bananapus/buyback-hook-v6` | `IJBBuybackHookRegistry` | Configuring Uniswap buyback pools per revnet |
| `@bananapus/suckers-v6` | `IJBSuckerRegistry` | Deploying cross-chain suckers, checking sucker status for fee exemption |
| `@croptop/core-v6` | `CTPublisher` | Configuring Croptop posting criteria for 721 tiers |
| `@bananapus/permission-ids-v6` | `JBPermissionIds` | Permission ID constants (SET_SPLIT_GROUPS, USE_ALLOWANCE, etc.) |
| `@openzeppelin/contracts` | `ERC721`, `ERC2771Context`, `Ownable`, `SafeERC20` | Loan NFTs, meta-transactions, ownership, safe token transfers |
| `@uniswap/permit2` | `IPermit2`, `IAllowanceTransfer` | Gasless token approvals for loan repayments |
| `@prb/math` | `mulDiv` | Precise fixed-point multiplication and division |

## Key Types

| Struct | Key Fields | Used In |
|--------|------------|---------|
| `REVConfig` | `description` (REVDescription), `baseCurrency`, `splitOperator`, `stageConfigurations[]` | `deployFor` |
| `REVStageConfig` | `startsAtOrAfter` (uint48), `initialIssuance` (uint112), `issuanceCutFrequency` (uint32), `issuanceCutPercent` (uint32), `cashOutTaxRate` (uint16), `splitPercent` (uint16), `splits[]`, `autoIssuances[]`, `extraMetadata` (uint16) | Translated into `JBRulesetConfig` |
| `REVDescription` | `name`, `ticker`, `uri`, `salt` | ERC-20 token deployment and project metadata |
| `REVAutoIssuance` | `chainId` (uint32), `count` (uint104), `beneficiary` | Per-stage cross-chain token auto-minting |
| `REVLoan` | `amount` (uint112), `collateral` (uint112), `createdAt` (uint48), `prepaidFeePercent` (uint16), `prepaidDuration` (uint32), `source` (REVLoanSource) | Per-loan state in `REVLoans` |
| `REVLoanSource` | `token`, `terminal` (IJBPayoutTerminal) | Identifies which terminal and token a loan draws from |
| `REVDeploy721TiersHookConfig` | `baseline721HookConfiguration` (REVBaseline721HookConfig), `salt`, `preventSplitOperatorAdjustingTiers`, `preventSplitOperatorUpdatingMetadata`, `preventSplitOperatorMinting`, `preventSplitOperatorIncreasingDiscountPercent` | 721 hook deployment with operator permissions (preventive flags — `false` = allowed). Uses `REVBaseline721HookConfig` (not `JBDeploy721TiersHookConfig`) to omit `issueTokensForSplits` — revnets always force it to `false`. |
| `REVBaseline721HookConfig` | `name`, `symbol`, `baseUri`, `tokenUriResolver`, `contractUri`, `tiersConfig`, `reserveBeneficiary`, `flags` (REV721TiersHookFlags) | Same as `JBDeploy721TiersHookConfig` but uses `REV721TiersHookFlags` which omits `issueTokensForSplits`. |
| `REV721TiersHookFlags` | `noNewTiersWithReserves`, `noNewTiersWithVotes`, `noNewTiersWithOwnerMinting`, `preventOverspending` | Same as `JB721TiersHookFlags` minus `issueTokensForSplits`. Revnets do their own weight adjustment for splits. |
| `REVCroptopAllowedPost` | `category` (uint24), `minimumPrice` (uint104), `minimumTotalSupply` (uint32), `maximumTotalSupply` (uint32), `allowedAddresses[]` | Croptop posting criteria |
| `REVSuckerDeploymentConfig` | `deployerConfigurations[]`, `salt` | Cross-chain sucker deployment |

## Events

### REVDeployer

| Event | When It Fires |
|-------|---------------|
| `AutoIssue(revnetId, stageId, beneficiary, count, caller)` | When tokens are auto-issued for a beneficiary during a stage via `autoIssueFor`. |
| `BurnHeldTokens(revnetId, count, caller)` | When held tokens are burned from the deployer contract via `burnHeldTokensOf`. |
| `DeployRevnet(revnetId, configuration, terminalConfigurations, suckerDeploymentConfiguration, rulesetConfigurations, encodedConfigurationHash, caller)` | When a new revnet is deployed via `deployFor`. |
| `DeploySuckers(revnetId, encodedConfigurationHash, suckerDeploymentConfiguration, caller)` | When suckers are deployed for a revnet via `deploySuckersFor`. |
| `ReplaceSplitOperator(revnetId, newSplitOperator, caller)` | When the split operator of a revnet is replaced via `setSplitOperatorOf`. |
| `SetCashOutDelay(revnetId, cashOutDelay, caller)` | When the cash out delay is set for a revnet during deployment to a new chain. |
| `StoreAutoIssuanceAmount(revnetId, stageId, beneficiary, count, caller)` | When an auto-issuance amount is stored for a beneficiary during deployment. |

### REVLoans

| Event | When It Fires |
|-------|---------------|
| `Borrow(loanId, revnetId, loan, source, borrowAmount, collateralCount, sourceFeeAmount, beneficiary, caller)` | When a loan is created by borrowing from a revnet via `borrowFrom`. |
| `Liquidate(loanId, revnetId, loan, caller)` | When a loan is liquidated after exceeding the 10-year liquidation duration via `liquidateExpiredLoansFrom`. |
| `ReallocateCollateral(loanId, revnetId, reallocatedLoanId, reallocatedLoan, removedCollateralCount, caller)` | When collateral is reallocated from one loan to a new loan via `reallocateCollateralFromLoan`. |
| `RepayLoan(loanId, revnetId, paidOffLoanId, loan, paidOffLoan, repayBorrowAmount, sourceFeeAmount, collateralCountToReturn, beneficiary, caller)` | When a loan is repaid via `repayLoan`. |
| `SetTokenUriResolver(resolver, caller)` | When the token URI resolver is changed via `setTokenUriResolver`. |

## Errors

### REVDeployer

| Error | When It Fires |
|-------|---------------|
| `REVDeployer_AutoIssuanceBeneficiaryZeroAddress()` | When an auto-issuance config has a zero-address beneficiary. |
| `REVDeployer_CashOutDelayNotFinished(cashOutDelay, blockTimestamp)` | When a cash out is attempted before the 30-day delay has elapsed. |
| `REVDeployer_CashOutsCantBeTurnedOffCompletely(cashOutTaxRate, maxCashOutTaxRate)` | When `cashOutTaxRate` equals `MAX_CASH_OUT_TAX_RATE` (10,000). Must be strictly less. |
| `REVDeployer_MustHaveSplits()` | When a stage with `splitPercent > 0` has no splits configured. |
| `REVDeployer_NothingToAutoIssue()` | When `autoIssueFor` is called but no tokens are available for auto-issuance. |
| `REVDeployer_NothingToBurn()` | When `burnHeldTokensOf` is called but the deployer holds no tokens. |
| `REVDeployer_RulesetDoesNotAllowDeployingSuckers()` | When `deploySuckersFor` is called but the current ruleset's `extraMetadata` bit 2 is not set. |
| `REVDeployer_StageNotStarted(stageId)` | When `autoIssueFor` is called for a stage that hasn't started yet. |
| `REVDeployer_StagesRequired()` | When `deployFor` is called with zero stage configurations. |
| `REVDeployer_StageTimesMustIncrease()` | When stage `startsAtOrAfter` values are not strictly increasing. |
| `REVDeployer_Unauthorized(revnetId, caller)` | When a non-split-operator calls a split-operator-only function. |

### REVLoans

| Error | When It Fires |
|-------|---------------|
| `REVLoans_CashOutDelayNotFinished(cashOutDelay, blockTimestamp)` | When borrowing during the 30-day cash-out delay period (cross-chain deployment protection). |
| `REVLoans_CollateralExceedsLoan(collateralToReturn, loanCollateral)` | When trying to return more collateral than the loan holds. |
| `REVLoans_InvalidPrepaidFeePercent(prepaidFeePercent, min, max)` | When `prepaidFeePercent` is outside the allowed range (2.5%--50%). |
| `REVLoans_InvalidTerminal(terminal, revnetId)` | When the specified terminal is not registered for the revnet. |
| `REVLoans_LoanExpired(timeSinceLoanCreated, loanLiquidationDuration)` | When trying to repay or reallocate an expired loan. |
| `REVLoans_LoanIdOverflow()` | When the loan ID counter exceeds the per-revnet trillion-ID namespace. |
| `REVLoans_NewBorrowAmountGreaterThanLoanAmount(newBorrowAmount, loanAmount)` | When a reallocation would produce a reduced loan with a larger borrow amount than the original. |
| `REVLoans_NoMsgValueAllowed()` | When `msg.value > 0` on a non-native-token repayment. |
| `REVLoans_NotEnoughCollateral()` | When the caller does not have enough tokens for the requested collateral. |
| `REVLoans_NothingToRepay()` | When `repayLoan` is called with zero repay amount and zero collateral to return. |
| `REVLoans_OverMaxRepayBorrowAmount(maxRepayBorrowAmount, repayBorrowAmount)` | When the actual repay cost exceeds the caller's `maxRepayBorrowAmount`. |
| `REVLoans_OverflowAlert(value, limit)` | When a value would overflow `uint112` storage. |
| `REVLoans_PermitAllowanceNotEnough(allowanceAmount, requiredAmount)` | When the permit2 allowance is insufficient for the repayment. |
| `REVLoans_ReallocatingMoreCollateralThanBorrowedAmountAllows(newBorrowAmount, loanAmount)` | When the collateral being transferred out would leave the original loan undercollateralized. |
| `REVLoans_SourceMismatch()` | When `reallocateCollateralFromLoan` specifies a source that doesn't match the existing loan's source. |
| `REVLoans_Unauthorized(caller, owner)` | When a non-owner tries to repay or reallocate someone else's loan. |
| `REVLoans_UnderMinBorrowAmount(minBorrowAmount, borrowAmount)` | When the actual borrow amount is less than the caller's `minBorrowAmount`. |
| `REVLoans_ZeroBorrowAmount()` | When a borrow or reallocation would result in zero borrowed funds. |
| `REVLoans_ZeroCollateralLoanIsInvalid()` | When a loan would end up with zero collateral. |

## Constants

### REVDeployer

| Constant | Value | Purpose |
|----------|-------|---------|
| `CASH_OUT_DELAY` | 2,592,000 (30 days) | Prevents cross-chain liquidity arbitrage on new chain deployments |
| `FEE` | 25 (of MAX_FEE=1000) | 2.5% cash-out fee paid to fee revnet |
| `DEFAULT_BUYBACK_POOL_FEE` | 10,000 | 1% Uniswap fee tier for default buyback pools |
| `DEFAULT_BUYBACK_TWAP_WINDOW` | 2 days | TWAP observation window for buyback price |
| `DEFAULT_BUYBACK_TICK_SPACING` | 200 | Tick spacing for default buyback V4 pools |

### REVLoans

| Constant | Value | Purpose |
|----------|-------|---------|
| `LOAN_LIQUIDATION_DURATION` | 3,650 days (10 years) | After this, collateral is forfeit |
| `MIN_PREPAID_FEE_PERCENT` | 25 (2.5%) | Minimum upfront fee borrowers must pay |
| `MAX_PREPAID_FEE_PERCENT` | 500 (50%) | Maximum upfront fee |
| `REV_PREPAID_FEE_PERCENT` | 10 (1%) | Protocol-level fee to $REV revnet |
| `_ONE_TRILLION` | 1,000,000,000,000 | Loan ID generator base: `revnetId * 1T + loanNumber` |

## Storage

### REVDeployer

| Mapping | Visibility | Type | Purpose |
|---------|-----------|------|---------|
| `amountToAutoIssue` | `public` | `revnetId => stageId => beneficiary => uint256` | Premint tokens per stage per beneficiary |
| `hashedEncodedConfigurationOf` | `public` | `revnetId => bytes32` | Config hash for cross-chain sucker validation |
| `_extraOperatorPermissions` | `internal` | `revnetId => uint256[]` | Custom permissions for split operator (no auto-getter) |

### REVOwner

| Mapping | Visibility | Type | Purpose |
|---------|-----------|------|---------|
| `DEPLOYER` | `public` | `address` | REVDeployer address (storage variable, set once via `initialize()`) |
| `cashOutDelayOf` | `public` | `revnetId => uint256` | Timestamp when cash outs unlock (0 = no delay). Set by REVDeployer via `setCashOutDelayOf()`. |
| `tiered721HookOf` | `public` | `revnetId => address` | Deployed 721 hook address (if any). Set by REVDeployer via `setTiered721HookOf()`. |

### REVLoans

| Mapping | Visibility | Type | Purpose |
|---------|-----------|------|---------|
| `isLoanSourceOf` | `public` | `revnetId => terminal => token => bool` | Is this (terminal, token) pair used for loans? |
| `totalLoansBorrowedFor` | `public` | `revnetId => uint256` | Counter for loan numbering |
| `totalBorrowedFrom` | `public` | `revnetId => terminal => token => uint256` | Tracks debt per loan source |
| `totalCollateralOf` | `public` | `revnetId => uint256` | Sum of all burned collateral |
| `_loanOf` | `internal` | `loanId => REVLoan` | Per-loan state (use `loanOf(loanId)` view) |
| `_loanSourcesOf` | `internal` | `revnetId => REVLoanSource[]` | Array of all loan sources used (use `loanSourcesOf(revnetId)` view) |
| `tokenUriResolver` | `public` | `IJBTokenUriResolver` | Resolver for loan NFT token URIs |

## Gotchas

1. **Revnets are permanently ownerless.** `REVDeployer` holds the project NFT forever. There is no function to release it. Stage parameters cannot be changed after deployment.
2. **Collateral is burned, not held.** Unlike traditional lending, collateral tokens are destroyed at borrow time and re-minted on repay. If a loan liquidates after 10 years, the collateral is permanently lost.
3. **100% LTV by design.** Borrowable amount equals the pro-rata cash-out value. No safety margin unless the stage has `cashOutTaxRate > 0`. A tax of 20% creates ~20% effective collateral buffer.
4. **Loan ID encoding.** `loanId = revnetId * 1_000_000_000_000 + loanNumber`. Each revnet supports ~1 trillion loans. Use `revnetIdOfLoanWith(loanId)` to decode.
5. **uint112 truncation risk.** `REVLoan.amount` and `REVLoan.collateral` are `uint112`. Values above ~5.19e33 truncate silently.
6. **Auto-issuance stage IDs.** Computed as `block.timestamp + i` during deployment. These match the Juicebox ruleset IDs because `JBRulesets` assigns IDs the same way (`latestId >= block.timestamp ? latestId + 1 : block.timestamp`), producing identical sequential IDs when all stages are queued in a single `deployFor()` call.
7. **Cash-out fee stacking.** Cash outs incur both the Juicebox terminal fee (2.5%) and the revnet cash-out fee (2.5% to fee revnet). These compound. The 2.5% fee is deducted from the TOKEN AMOUNT being cashed out, not from the reclaim value. 2.5% of the tokens are redirected to the fee revnet, which then redeems them at the bonding curve independently. The net reclaim to the caller is based on 97.5% of the tokens, not 97.5% of the computed ETH value. This is by design.
8. **30-day cash-out delay.** Applied when deploying an existing revnet to a new chain where the first stage has already started. Prevents cross-chain liquidity arbitrage. Enforced in both `beforeCashOutRecordedWith` (direct cash outs) and `REVLoans.borrowFrom` / `borrowableAmountFrom` (loans). The delay is stored on REVOwner (`cashOutDelayOf(revnetId)`) and set by REVDeployer during deployment via `setCashOutDelayOf()`. REVLoans imports IREVOwner (not IREVDeployer) to read it.
9. **`cashOutTaxRate` cannot be MAX.** Must be strictly less than `MAX_CASH_OUT_TAX_RATE` (10,000). Revnets cannot fully disable cash outs.
10. **Split operator is singular.** Only ONE address can be split operator at a time. The operator can replace itself via `setSplitOperatorOf` but cannot delegate or multi-sig.
11. **NATIVE_TOKEN on non-ETH chains.** `JBConstants.NATIVE_TOKEN` on Celo means CELO, on Polygon means MATIC -- not ETH. Use ERC-20 WETH instead. The config matching hash does NOT catch terminal configuration differences.
12. **Loan source array is unbounded.** `_loanSourcesOf[revnetId]` grows without limit. No validation that a terminal is actually registered for the project.
13. **Flash-loan surplus exposure.** `borrowableAmountFrom` reads live surplus. A flash loan can temporarily inflate the treasury to borrow more than the sustained value supports.
14. **Fee revnet must have terminals.** Cash-out fees and loan protocol fees are paid to `FEE_REVNET_ID`. If that project has no terminal for the token, the fee silently fails (try-catch).
15. **Buyback hook is immutable per deployer.** `BUYBACK_HOOK` is set at construction time on both REVDeployer and REVOwner. All revnets deployed by the same deployer share the same buyback hook.
16. **Cross-chain config matching.** `hashedEncodedConfigurationOf` covers economic parameters (baseCurrency, stages, auto-issuances) but NOT terminal configurations, accounting contexts, or sucker token mappings. Two deployments with identical hashes can have different terminal setups.
17. **Loan fee model has three layers.** See Constants table for exact values: REV protocol fee, terminal fee, and prepaid source fee (borrower-chosen, buys interest-free window). After the prepaid window, source fee accrues linearly over the remaining loan duration.
18. **Permit2 fallback.** `REVLoans` uses permit2 for ERC-20 transfers as a fallback when standard allowance is insufficient. Wrapped in try-catch.
19. **39.16% cash-out tax crossover.** Below ~39% cash-out tax, cashing out is more capital-efficient than borrowing. Above ~39%, loans become more efficient because they preserve upside while providing liquidity. Based on CryptoEconLab academic research. Design implication: revnets intended for active token trading should consider this threshold when setting `cashOutTaxRate`.
20. **REVDeployer always deploys a 721 hook** via `HOOK_DEPLOYER.deployHookFor` — even if `baseline721HookConfiguration` has empty tiers. This is correct by design: it lets the split operator add and sell NFTs later without migration. Non-revnet projects should follow the same pattern by using `JB721TiersHookProjectDeployer.launchProjectFor` (or `JBOmnichainDeployer.launchProjectFor`) instead of bare `launchProjectFor`.
21. **REVOwner circular dependency.** REVOwner and REVDeployer have a circular dependency broken by a one-shot `initialize()` call. `REVOwner.DEPLOYER` is a storage variable (not immutable) set via `initialize()`. If `initialize()` is never called or called with the wrong address, all runtime hook behavior breaks. Deploy order: REVOwner first, then REVDeployer(owner=REVOwner), then REVOwner.initialize(deployer). REVOwner stores `cashOutDelayOf` and `tiered721HookOf` mappings, which are set by REVDeployer via DEPLOYER-restricted setters (`setCashOutDelayOf()`, `setTiered721HookOf()`).

### NATIVE_TOKEN Accounting on Non-ETH Chains

When deploying to a chain where the native token is NOT ETH (Celo, Polygon), the terminal must NOT use `JBConstants.NATIVE_TOKEN` as its accounting context. `NATIVE_TOKEN` represents whatever is native on that chain, but `baseCurrency=1` (ETH) assumes ETH-denominated value.

**Correct (Celo):**
```solidity
JBAccountingContext({
    token: WETH_CELO,     // ERC-20 WETH, not native CELO
    decimals: 18,
    currency: uint32(uint160(WETH_CELO))
})
```

**Wrong (Celo):**
```solidity
JBAccountingContext({
    token: JBConstants.NATIVE_TOKEN,  // This is CELO, not ETH!
    decimals: 18,
    currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
})
```

## Reading Revnet State

Quick-reference for common read operations. All functions are `view`/`pure` and permissionless.

### Current Stage & Ruleset

| What | Call | Returns |
|------|------|---------|
| Current ruleset (stage) | `IJBController(CONTROLLER).currentRulesetOf(revnetId)` | `(JBRuleset, JBRulesetMetadata)` -- the active stage's parameters |
| All queued rulesets | `IJBController(CONTROLLER).allRulesetsOf(revnetId, startingId, size)` | `JBRulesetWithMetadata[]` -- paginated list of stages |
| Specific stage by ID | `IJBController(CONTROLLER).getRulesetOf(revnetId, stageId)` | `(JBRuleset, JBRulesetMetadata)` for that stage |

### Split Operator

| What | Call | Returns |
|------|------|---------|
| Check if address is split operator | `REVDeployer.isSplitOperatorOf(revnetId, addr)` | `bool` |

### Token Supply & Surplus

| What | Call | Returns |
|------|------|---------|
| Total supply (incl. pending reserved) | `IJBController(CONTROLLER).totalTokenSupplyWithReservedTokensOf(revnetId)` | `uint256` |
| Pending reserved tokens | `IJBController(CONTROLLER).pendingReservedTokenBalanceOf(revnetId)` | `uint256` |
| Current surplus (single terminal) | `IJBTerminalStore(STORE).currentSurplusOf(terminal, revnetId, configs, decimals, currency)` | `uint256` |

### Auto-Issuance

| What | Call | Returns |
|------|------|---------|
| Remaining auto-issuance for beneficiary | `REVDeployer.amountToAutoIssue(revnetId, stageId, beneficiary)` | `uint256` (0 if already claimed) |

### Loans

| What | Call | Returns |
|------|------|---------|
| Borrowable amount for collateral | `REVLoans.borrowableAmountFrom(revnetId, collateralCount, decimals, currency)` | `uint256` |
| Total borrowed (per source) | `REVLoans.totalBorrowedFrom(revnetId, terminal, token)` | `uint256` |
| Total collateral locked | `REVLoans.totalCollateralOf(revnetId)` | `uint256` |
| Loan details | `REVLoans.loanOf(loanId)` | `REVLoan` struct |
| All loan sources | `REVLoans.loanSourcesOf(revnetId)` | `REVLoanSource[]` |
| Loan count | `REVLoans.totalLoansBorrowedFor(revnetId)` | `uint256` |
| Source fee for repayment | `REVLoans.determineSourceFeeAmount(loan, amount)` | `uint256` |
| Revnet ID from loan ID | `REVLoans.revnetIdOfLoanWith(loanId)` | `uint256` (pure) |
| Loan NFT owner | `REVLoans.ownerOf(loanId)` | `address` (ERC-721) |

### Deployer Config

| What | Call | Returns |
|------|------|---------|
| Config hash (cross-chain matching) | `REVDeployer.hashedEncodedConfigurationOf(revnetId)` | `bytes32` |
| REVOwner address | `REVDeployer.OWNER()` | `address` |

### REVOwner State

| What | Call | Returns |
|------|------|---------|
| 721 hook address | `REVOwner.tiered721HookOf(revnetId)` | `IJB721TiersHook` |
| Cash-out delay timestamp | `REVOwner.cashOutDelayOf(revnetId)` | `uint256` (0 = no delay) |

## Example Integration

```solidity
import {REVConfig} from "@rev-net/core-v6/src/structs/REVConfig.sol";
import {REVStageConfig} from "@rev-net/core-v6/src/structs/REVStageConfig.sol";
import {REVDescription} from "@rev-net/core-v6/src/structs/REVDescription.sol";
import {REVSuckerDeploymentConfig} from "@rev-net/core-v6/src/structs/REVSuckerDeploymentConfig.sol";
import {IREVDeployer} from "@rev-net/core-v6/src/interfaces/IREVDeployer.sol";

// --- Deploy a simple revnet with one stage ---

REVStageConfig[] memory stages = new REVStageConfig[](1);
stages[0] = REVStageConfig({
    startsAtOrAfter: 0,                    // Start immediately (uses block.timestamp)
    autoIssuances: new REVAutoIssuance[](0),
    splitPercent: 2000,                    // 20% of new tokens go to splits
    splits: splits,                        // Reserved token split destinations
    initialIssuance: 1_000_000e18,         // 1M tokens per unit of base currency
    issuanceCutFrequency: 30 days,         // Decay period
    issuanceCutPercent: 100_000_000,       // 10% cut per period (out of 1e9)
    cashOutTaxRate: 2000,                  // 20% tax on cash outs
    extraMetadata: 0
});

REVConfig memory config = REVConfig({
    description: REVDescription({
        name: "My Revnet Token",
        ticker: "MYREV",
        uri: "ipfs://...",
        salt: bytes32(0)
    }),
    baseCurrency: 1,                       // ETH
    splitOperator: msg.sender,
    stageConfigurations: stages
});

deployer.deployFor({
    revnetId: 0,                           // 0 = deploy new
    configuration: config,
    terminalConfigurations: terminals,
    suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
        deployerConfigurations: new JBSuckerDeployerConfig[](0),
        salt: bytes32(0)
    })
});

// --- Borrow against revnet tokens ---

loans.borrowFrom({
    revnetId: revnetId,
    source: REVLoanSource({ token: JBConstants.NATIVE_TOKEN, terminal: terminal }),
    minBorrowAmount: 0,
    collateralCount: 1000e18,              // Burn 1000 tokens as collateral
    beneficiary: msg.sender,               // Receive borrowed funds
    prepaidFeePercent: 25                  // 2.5% prepaid fee (minimum)
});

// --- Reallocate collateral (refinance) ---
// Remove 500 tokens of collateral from an existing loan,
// use them (plus 200 new tokens) to open a fresh loan.
// The original loan shrinks, and a new loan NFT is minted.
(uint256 reallocatedLoanId, uint256 newLoanId, , ) = loans.reallocateCollateralFromLoan({
    loanId: loanId,
    collateralCountToTransfer: 500e18,     // Move 500 tokens out of existing loan
    source: REVLoanSource({ token: JBConstants.NATIVE_TOKEN, terminal: terminal }),
    minBorrowAmount: 0,
    collateralCountToAdd: 200e18,          // Add 200 fresh tokens on top
    beneficiary: payable(msg.sender),      // Receive new loan proceeds
    prepaidFeePercent: 25                  // 2.5% prepaid fee on new loan
});
// Result: original loan now has 500 fewer collateral tokens (reallocatedLoanId),
// new loan has 700 tokens of collateral (newLoanId).

// --- Repay a loan ---

loans.repayLoan({
    loanId: loanId,
    maxRepayBorrowAmount: type(uint256).max,     // Repay in full
    collateralCountToReturn: loan.collateral,    // Return all collateral
    beneficiary: msg.sender,                     // Receive re-minted tokens
    allowance: JBSingleAllowance({ ... })        // Optional permit2
});
```
