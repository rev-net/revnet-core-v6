# Revnet Runtime Reference

Use this file when you already know the task is in `revnet-core-v6` and need the deployer, owner, or loans surface in detail.

## Purpose

Deploy and manage Revnets -- autonomous, unowned Juicebox projects with staged issuance schedules, built-in Uniswap buyback pools, cross-chain suckers, and token-collateralized lending.

## Contracts

| Contract | Role |
|----------|------|
| `REVDeployer` | Deploys revnets, permanently owns the project NFT. Manages stages, splits, auto-issuance, buyback hooks, suckers, split operators, and configuration state storage. Exposes `OWNER()` view returning the REVOwner address. Calls DEPLOYER-restricted setters on REVOwner during deployment to store `cashOutDelayOf` and `tiered721HookOf`. |
| `REVOwner` | Runtime hook contract for all revnets. Implements `IJBRulesetDataHook` + `IJBCashOutHook`. Set as the `dataHook` in each revnet's ruleset metadata. Handles pay hooks, cash-out hooks, mint permissions, and sucker verification. Stores `cashOutDelayOf` and `tiered721HookOf` mappings (set by REVDeployer via DEPLOYER-restricted setters `setCashOutDelayOf()` and `setTiered721HookOf()`). |
| `REVLoans` | Issues token-collateralized loans from revnet treasuries. Each loan is an ERC-721 NFT. Burns collateral on borrow, re-mints on repay. Charges tiered fees (REV protocol fee + source fee + prepaid fee). |
| `REVHiddenTokens` | Burns tokens into a hidden balance and can later re-mint them. This is a supply-management primitive, not just a wallet convenience feature. |

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
| `REVHiddenTokens.hiddenBalanceOf(holder, revnetId)` | Returns how many tokens a holder has hidden from visible supply. |

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
### Hidden Tokens

| Function | Permissions | What it does |
|----------|------------|-------------|
| `REVHiddenTokens.hideTokensOf(revnetId, tokenCount, holder)` | Holder only. The holder must either be allowlisted or personally hold `HIDE_TOKENS`. | Burns visible tokens, increases hidden balance, and lowers visible supply. |
| `REVHiddenTokens.revealTokensOf(revnetId, tokenCount, holder)` | Holder only | Re-mints previously hidden tokens back to the holder and reduces hidden balance. |
| `REVHiddenTokens.setTokenHidingAllowedFor(revnetId, holder, isAllowed)` | Operator with `HIDE_TOKENS` | Allows or revokes a holder's ability to hide their own tokens. |
