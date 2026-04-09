# Revnet Core Risk Register

This file focuses on the risks created by autonomous treasury-backed projects with staged economics, composable hooks, cross-chain wiring, and token-collateralized loans.

Read [ARCHITECTURE.md](./ARCHITECTURE.md) and [SKILLS.md](./SKILLS.md) for protocol context first.

## How to use this file

- Read `Priority risks` first; they capture the highest-impact ways a revnet can misprice, misroute, or mis-govern itself.
- Use the detailed sections for economics, loans, data-hook proxying, and liveness reasoning.
- Treat `Accepted Behaviors` and `Invariants to Verify` as the operating contract for revnet deployments.

## Priority risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Loan mispricing from bad surplus or configuration | `REVLoans` depends on correct surplus, fee, and deployer-owned configuration; bad inputs can enable over-borrowing. | Surplus and price checks, deployer verification, and loan-specific invariant coverage. |
| P0 | Deployer or data-hook proxy blast radius | `REVDeployer` sits in the pay and cash-out path for all revnets it launched. A bug here affects every attached project. | High-scrutiny review, composition testing, and cautious shared-deployer usage. |
| P1 | Stage or split misconfiguration becomes permanent | Revnets are intentionally autonomous and hard to govern after launch; bad initial economics are difficult or impossible to fix. | Strong pre-launch review, deployment runbooks, and config simulation before production. |

## 1. Trust Assumptions

### What the system assumes to be correct

- **REVOwner is a singleton data hook.** Every revnet shares one `beforePayRecordedWith` and `beforeCashOutRecordedWith` implementation in REVOwner. A bug in either function affects ALL revnets deployed by that deployer simultaneously. There is no per-project isolation and no circuit breaker.
- **REVOwner deployer binding is precomputed.** REVOwner records the account that deployed it as an internal one-time binder, and only that account can bind `DEPLOYER`. Deployment tooling must precompute the canonical REVDeployer address and call `setDeployer(...)` before constructing REVDeployer. This removes the old frontrunnable ambient initializer, but it also means deployment scripts must not skip the prebind step.
- **Stage immutability is the trust model.** Once `deployFor()` completes, stage parameters (issuance, `cashOutTaxRate`, splits, auto-issuances) are locked forever. No owner, no governance, no upgrade path. A misconfigured deployment is permanent. This is intentional -- the absence of admin keys IS the security property.
- **Bonding curve is the sole collateral oracle.** `REVLoans` uses `JBCashOuts.cashOutFrom` to value collateral. There is no external price oracle, no liquidation margin, and no health factor. The borrowable amount equals the cash-out value at the moment of borrowing.
- **Juicebox core contracts are correct.** `JBController`, `JBMultiTerminal`, `JBTerminalStore`, `JBTokens`, `JBPrices` -- a bug in any of these is a bug in every revnet.
- **Buyback hook operates correctly.** `BUYBACK_HOOK` handles swap-vs-mint routing. All revnets from the same deployer share one instance. Failure falls back to direct minting (not a revert), so the failure mode is economic inefficiency, not fund loss.
- **Suckers are honest bridges.** Suckers get 0% cashout tax in `beforeCashOutRecordedWith`. A compromised or malicious sucker registered in `SUCKER_REGISTRY` can extract funds from any revnet at zero cost.
- **Auto-issuance beneficiaries are set at deployment.** Beneficiary addresses are baked into the stage configuration. If a beneficiary address is a contract that becomes compromised, or an EOA whose keys are lost, those auto-issuance tokens are either captured or permanently unclaimable.
- **REVLoans contract address is immutable per deployer.** `LOANS` is set once in the REVDeployer constructor (and shared as an immutable on REVOwner) with wildcard `USE_ALLOWANCE` permission (`projectId=0`). If the loans contract has a vulnerability, every revnet's surplus is exposed.

### What you do NOT need to trust

- **Project owners.** There are none. REVDeployer permanently holds the project NFT.
- **Split operators.** They can change splits, manage 721 tiers, deploy suckers, and set buyback pools, but cannot change stage parameters, issuance rates, cashout tax rates, or directly access treasury funds.
- **Token holders.** They can only cash out proportional to the bonding curve. Borrowers can only borrow up to the bonding curve value of their burned collateral.

---

## 2. Economic Risks

### Loan economics

- **100% LTV with no safety margin.** Borrowable amount equals exact bonding curve cash-out value. When `cashOutTaxRate == 0`, this is true 100% LTV. Any decrease in surplus (other cash-outs, payouts, stage transitions) makes existing loans effectively under-collateralized. The protocol has no liquidation trigger for under-collateralized loans -- only the 10-year expiry.
- **Loans beat cash-outs above ~39% tax.** Above approximately 39.16% `cashOutTaxRate`, borrowing is more capital-efficient than cashing out because loans preserve upside while providing immediate liquidity. Based on CryptoEconLab research. This is by design but creates an incentive to borrow rather than cash out at higher tax rates, concentrating risk in the loan system.
- **10-year free put option.** Over the loan's lifetime, if the collateral's real value drops below the borrowed amount, the borrower has no incentive to repay. The borrower keeps the borrowed funds and forfeits worthless collateral. This is equivalent to a free put option with a 10-year expiry. The protocol absorbs this loss through permanent supply reduction (burned collateral never re-minted).

### Stage transition edge cases

- **`cashOutTaxRate` increase destroys loan health.** Active loans use the CURRENT stage's `cashOutTaxRate`. When a stage transition increases this rate, existing loans become under-collateralized -- the collateral's cash-out value drops but the loan amount remains unchanged. No forced repayment or margin call mechanism exists. Over 10 years with multiple stage transitions, this compounds.
- **`cashOutTaxRate` decrease creates refinancing opportunity.** When a new stage lowers the tax rate, existing collateral becomes worth more. Borrowers can `reallocateCollateralFromLoan` to extract the surplus value. This creates a predictable, front-runnable event at every stage boundary.
- **Weight decay approaching zero over long periods.** With `issuanceCutPercent > 0` and `issuanceCutFrequency > 0`, issuance weight decays exponentially through successive rulesets. After long enough, new payments mint negligibly few tokens, meaning the token supply effectively freezes. This concentrates cash-out value among existing holders and makes the bonding curve increasingly sensitive to individual cash-outs. The current repo models decay through ruleset duration and `weightCutPercent`, so validation should focus on long-horizon ruleset progression and issuance-decay tests rather than any separate weight-cache updater.
- **Duration=0 stages never auto-expire.** A stage with `duration=0` (no issuance cut frequency) persists until explicitly replaced by a subsequent stage's `startsAtOrAfter`. If the next stage's `startsAtOrAfter` is far in the future, the current stage runs indefinitely at its configured parameters.

### Cross-currency reclaim calculations

- **`_totalBorrowedFrom` aggregates across currencies via `JBPrices`.** Each loan source may be in a different token/currency. Aggregation normalizes decimals and converts via price feeds. If a price feed returns zero, that source is skipped (prevents division-by-zero DoS). But a stale or manipulated price feed silently over- or under-counts total borrowed amount, affecting all subsequent borrow operations for the revnet.
- **Undercount from zero-price feeds is unbounded.** When `PRICES.pricePerUnitOf` returns 0 for a source, that source's entire outstanding debt is excluded from the `_totalBorrowedFrom` total. There is no cap on the magnitude of the omission -- it equals the full borrowed amount from the affected source. Concretely: if a revnet has 100 ETH borrowed across 3 sources and one source's feed returns 0, that source's debt becomes invisible, potentially allowing the remaining borrowing capacity to be over-utilized. The more debt concentrated in the affected source, the larger the undercount.
- **Cascading effect on borrowing capacity.** Because `_totalBorrowedFrom` is called on every `borrowFrom` to enforce `_borrowableAmountFrom`, an undercount directly inflates the perceived remaining borrowing capacity for the entire revnet -- not just the affected source. New borrowers across all sources benefit from the artificially low total, and the over-extension compounds with each new loan taken while the feed is down.
- **No automatic recovery mechanism.** Once a price feed returns 0, the affected source's debt remains invisible to `_totalBorrowedFrom` until the feed recovers. There is no event emitted when a source is skipped, no fallback oracle, and no circuit breaker that pauses borrowing when feed health degrades. Operators should actively monitor price feed health and treat any feed returning 0 as a risk event for the revnet's loan system.
- **Decimal normalization truncation.** When converting from higher-decimal tokens (18) to lower-decimal targets (6), integer division truncates. For sources with large outstanding borrows in high-decimal tokens, this truncation can systematically undercount the total borrowed amount, allowing slightly more borrowing than intended. For example, converting 999,999,999,999 wei (18-decimal) to 6-decimal precision discards 12 digits of precision. Across many sources, these per-source truncation errors accumulate additively, further widening the gap between the reported and actual total debt.

### Hidden token supply manipulation

- **Hiding reduces totalSupply, inflating per-token cash-out value.** When a holder hides tokens via `REVHiddenTokens`, those tokens are burned and excluded from `totalSupply`. The bonding curve sees fewer tokens, so each remaining token is worth more on cash-out. A holder with a large position can hide tokens, have an accomplice cash out at the inflated rate, then reveal. The net effect depends on the `cashOutTaxRate` and the relative positions. Operator delegation (`HIDE_TOKENS`/`REVEAL_TOKENS` permissions) extends this to permissioned operators acting on behalf of holders.
- **Hidden tokens must be revealed before use as loan collateral.** `REVHiddenTokens` and `REVLoans` are separate systems. A holder cannot borrow against hidden tokens — they must first reveal (re-mint) them, then borrow. This is by design but may confuse users.
- **Reveal mints without reserved percent.** `revealTokensOf` calls `mintTokensOf` with `useReservedPercent: false`. This is correct because the tokens were previously burned and are being restored, not newly issued. But it means revealed tokens bypass the reserved-token mechanism entirely.
- **REVHiddenTokens has mint permission via REVOwner.** The contract is added to `REVOwner.hasMintPermissionFor`. If `REVHiddenTokens` has a vulnerability, it could mint unbounded tokens for any revnet.

### Auto-issuance overflow potential

- **`REVAutoIssuance.count` is `uint104` (~2.03e31).** Multiple auto-issuances for the same beneficiary in the same stage are summed via `+=` in `_makeRulesetConfigurations`. If cumulative auto-issuances exceed `uint256`, this wraps. In practice, `uint104` inputs limit each addition, but verify no path allows the mapping value to overflow.
- **Auto-issuance dilutes existing holders.** Large auto-issuances at stage boundaries dilute the token supply, reducing per-token cash-out value. This is permissionless (`autoIssueFor` can be called by anyone). A griefing vector exists where someone calls `autoIssueFor` immediately before another user's cash-out to reduce their reclaim amount. However, the dilution is pre-configured and predictable.

---

## 3. Loan System Risks

### Collateral valuation during price volatility

- **Bonding curve is internal, not market-price.** Collateral is valued by the bonding curve (`JBCashOuts.cashOutFrom`) which depends on surplus, total supply, and `cashOutTaxRate`. External market price (e.g., DEX price of the revnet token) is irrelevant to collateral valuation. If the market price diverges significantly from the bonding curve value, arbitrage opportunities arise between borrowing and trading.
- **Surplus is cross-terminal aggregate.** `_borrowableAmountFrom` calls `JBSurplus.currentSurplusOf` across all terminals. If one terminal holds tokens in a volatile asset that has crashed, the aggregate surplus drops, reducing collateral value for ALL borrowers regardless of which terminal their loan draws from.

### Liquidation concerns

- **No cascading liquidation mechanism.** There is no health factor, no margin call, and no keeper-triggered liquidation for under-collateralized loans. The only liquidation path is `liquidateExpiredLoansFrom` after 10 years. Under-collateralized loans persist indefinitely within that window.
- **Liquidation iterates by loan number.** `liquidateExpiredLoansFrom` takes `startingLoanId` and `count`, iterating sequentially. Repaid and already-liquidated loans are skipped (`createdAt == 0`), but the caller pays gas for every skip. If a revnet has thousands of loans with sparse gaps (many repaid), liquidation becomes expensive. The `count` parameter bounds gas per call, but a malicious actor could create many small loans to increase cleanup costs.
- **Liquidation permanently destroys collateral.** Collateral was burned at borrow time. Upon liquidation, `totalCollateralOf` is decremented but no tokens are minted or returned. The collateral is permanently removed from the token supply. This deflates the total supply, increasing per-token value for remaining holders -- a mild positive externality from defaults.

### Loan source rotation after deployment

- **Loan sources grow monotonically.** `_loanSourcesOf[revnetId]` is append-only. Each new `(terminal, token)` pair used for borrowing adds an entry. Entries are never removed, even if all loans from that source are repaid. `_totalBorrowedFrom` iterates the entire array on every borrow/repay.
- **Removed terminals remain as loan sources.** If a terminal is de-registered from `JBDirectory` (via migration), existing loans from that terminal remain valid (the loan struct stores a direct reference to the terminal contract). New borrows against that terminal are blocked by `DIRECTORY.isTerminalOf` check in `borrowFrom`. But `_totalBorrowedFrom` still queries the de-registered terminal's `accountingContextForTokenOf` -- verify this doesn't revert.

### `reallocateCollateralFromLoan` sandwich potential

- **Reallocation is two operations in one transaction.** `reallocateCollateralFromLoan` first reduces collateral on the existing loan (via `_reallocateCollateralFromLoan`), then opens a new loan (via `borrowFrom`). Between these two operations, the surplus and total supply have changed (collateral was returned to the caller, changing supply). The new loan's borrowable amount is computed with the post-reallocation state.
- **Source mismatch check.** `reallocateCollateralFromLoan` enforces that the new loan's source matches the existing loan's source (`source.token == existingSource.token && source.terminal == existingSource.terminal`). This prevents cross-source value extraction.
- **MEV opportunity at stage boundaries.** If a borrower knows a stage transition will decrease `cashOutTaxRate`, they can wait until just after the transition and `reallocateCollateralFromLoan` to extract more borrowed funds from the same collateral. This is predictable and not preventable by design.

### Cross-chain cash-out delay enforcement

- **Loans enforce the same 30-day cash-out delay as direct cash outs.** When a revnet is deployed to a new chain where its first stage has already started, REVDeployer calls `REVOwner.setCashOutDelayOf()` to set a 30-day delay (stored on REVOwner). `borrowFrom` resolves the REVOwner from the current ruleset's `dataHook` and checks `IREVOwner.cashOutDelayOf(revnetId)` (read directly from REVOwner storage), reverting with `REVLoans_CashOutDelayNotFinished` if the delay hasn't passed. `borrowableAmountFrom` returns 0 during the delay. This prevents cross-chain arbitrage via the loan system (bridging tokens to a new chain and immediately borrowing against them before prices equilibrate).

### BURN_TOKENS permission prerequisite

- **Borrowers must grant BURN_TOKENS permission before calling `borrowFrom`.** The loans contract burns the caller's tokens as collateral via `JBController.burnTokensOf`, which requires the caller to have granted `BURN_TOKENS` permission to the loans contract for the revnet's project ID. Without this, the transaction reverts deep in `JBController` with `JBPermissioned_Unauthorized`. The prerequisite is documented in `borrowFrom`'s NatSpec.

---

## 4. Data Hook Proxy Risks

REVOwner sits between the terminal and the actual hooks (buyback hook, 721 hook). This proxy pattern creates composition risks.

### Underlying hook reverts

- **721 hook revert in `beforePayRecordedWith`.** The call to `IJBRulesetDataHook(tiered721Hook).beforePayRecordedWith(context)` in REVOwner is NOT wrapped in try-catch. If the 721 hook reverts (e.g., due to a storage corruption or out-of-gas), the entire payment reverts. This is a single point of failure for all payments to revnets with 721 hooks.
- **Buyback hook is more resilient.** The `BUYBACK_HOOK.beforePayRecordedWith(buybackHookContext)` call in REVOwner is also not try-caught, but the buyback hook is a shared singleton controlled by the protocol. If it reverts, all revnets from that deployer are affected.
- **Cash-out fee terminal revert.** In `REVOwner.afterCashOutRecordedWith`, the fee payment to the fee terminal IS wrapped in try-catch with a fallback to `addToBalanceOf`. If the fallback also reverts, the entire cashout transaction reverts — no funds are stuck, but the cashout is blocked until the terminal is available.

### Sucker bypass path (0% cashout tax)

- **Suckers bypass all economic protections.** `REVOwner.beforeCashOutRecordedWith` returns `(0, context.cashOutCount, context.totalSupply, hookSpecifications)` for suckers -- zero tax, no fee. A compromised sucker effectively has a backdoor to extract the full pro-rata surplus of any token it holds.
- **Sucker registration is controlled by `SUCKER_REGISTRY`.** The registry has `MAP_SUCKER_TOKEN` wildcard permission from the deployer. The split operator has `SUCKER_SAFETY` permission. Verify that `deploySuckersFor` correctly checks the `extraMetadata` bit (bit 2) for sucker deployment permission per stage.

### Permission escalation through proxy

- **`hasMintPermissionFor` grants mint to five categories.** `REVOwner.hasMintPermissionFor` grants mint to: the loans contract, the hidden tokens contract, buyback hook, buyback hook delegates, and suckers. If any of these contracts have a vulnerability that allows arbitrary calls, they can mint unlimited revnet tokens for any revnet.
- **Wildcard permissions.** REVDeployer grants `USE_ALLOWANCE` to `LOANS` with `projectId=0` (wildcard). This means the loans contract can drain surplus from ANY revnet deployed by this deployer, constrained only by the loan logic itself. A bug in `REVLoans._addTo` that miscalculates `addedBorrowAmount` could drain treasuries.

---

## 5. Access Control

### Stage configuration immutability

- **No function modifies rulesets after deployment.** REVDeployer holds the project NFT and is the only entity that could call `CONTROLLER.queueRulesetsOf`. But REVDeployer has no function that does this. The only ruleset interaction after deployment is reading via `currentRulesetOf` and `getRulesetOf`. This is the core immutability guarantee -- verify no code path exists that calls `queueRulesetsOf` or `launchRulesetsFor` on an already-deployed revnet.
- **Project NFT cannot be recovered.** Once transferred to REVDeployer via `safeTransferFrom` or minted by `launchProjectFor`, the NFT is permanently held. REVDeployer implements `onERC721Received` but only accepts from `PROJECTS`. It has no `transferFrom` or equivalent for project NFTs.

### Who can deploy and modify

- **`deployFor` is permissionless for new revnets** (`revnetId == 0`). Anyone can deploy a revnet with arbitrary configuration.
- **`deployFor` with existing project requires ownership.** The caller must be `PROJECTS.ownerOf(revnetId)` and the project must be blank (no controller, no rulesets).
- **Split operator is singular and self-replacing.** `setSplitOperatorOf` can only be called by the current split operator. If the split operator is set to address(0) or a contract with no ability to call `setSplitOperatorOf`, the role is permanently lost.
- **Split operator permissions are cumulative during deployment.** `_extraOperatorPermissions[revnetId]` is populated via `.push()` during deployment. If the same permission ID is pushed twice, the array has duplicates but this is harmless (the permission check uses `hasPermissions` which doesn't care about duplicates).

### Split operator trust boundaries

- **ADD_PRICE_FEED.** The split operator can add price feeds for the revnet. A malicious price feed could return manipulated values, affecting cross-currency surplus calculations and loan collateral valuations. Price feeds are immutable once added (cannot be replaced).
- **SET_SPLIT_GROUPS.** The split operator controls where reserved tokens go. A compromised operator can redirect all reserved tokens to themselves.
- **DEPLOY_SUCKERS (via `deploySuckersFor`).** The split operator can deploy new suckers if the current stage allows it (`extraMetadata` bit 2). A malicious sucker gets 0% cashout tax privilege. This is the highest-impact split operator action.
- **SET_ROUTER_TERMINAL.** The split operator can configure the router terminal, potentially redirecting payments.

---

## 6. DoS Vectors

### Long stage chains

- **`_makeRulesetConfigurations` iterates all stages.** Deployment cost scales linearly with stage count. There is no explicit cap on the number of stages. A deployment with hundreds of stages would be expensive but is not blocked.
- **Auto-issuance inner loop.** For each stage, the deployment iterates all `autoIssuances[]`. The combined iteration (stages x auto-issuances per stage) could hit the block gas limit for extreme configurations.

### Many auto-issuances

- **`autoIssueFor` is one-per-call.** Each call processes a single `(revnetId, stageId, beneficiary)` tuple. If a stage has many beneficiaries, they must each be claimed individually. Not a DoS vector against the protocol, but a usability concern.

### Loan source enumeration

- **`_totalBorrowedFrom` iterates ALL sources on every borrow and repay.** Gas cost: ~20k per source (external `accountingContextForTokenOf` call + storage read + potential price feed call). With 10 sources, this adds ~200k gas per loan operation. With 50+ sources (unlikely but possible), operations become prohibitively expensive.
- **Mitigation.** `borrowFrom` checks `DIRECTORY.isTerminalOf` before accepting a new source. The number of registered terminals per project is practically bounded. But nothing prevents a terminal from being registered, used for one loan, de-registered, and then a new terminal registered -- leaving stale entries in the source array.

---

## 7. Invariants to Verify

These MUST hold. Breaking any of them is a finding.

### Loan accounting

- **Collateral conservation.** `totalCollateralOf[revnetId]` == sum of `loan.collateral` for all active (non-liquidated, non-repaid) loans of that revnet.
- **Borrowed amount conservation.** `totalBorrowedFrom[revnetId][terminal][token]` == sum of `loan.amount` for all active loans from that source.
- **No double-mint collateral.** Repaying a loan mints collateral back exactly once. A repaid loan cannot be repaid again (NFT is burned, storage is deleted).
- **No zero-collateral loans.** Every active loan has `collateral > 0` and `amount > 0`. The `borrowFrom` function reverts on `collateralCount == 0` and `borrowAmount == 0`.
- **Liquidation only after expiry.** `liquidateExpiredLoansFrom` skips loans where `block.timestamp <= loan.createdAt + LOAN_LIQUIDATION_DURATION`.
- **Total loans counter monotonicity.** `totalLoansBorrowedFor[revnetId]` only increments (on borrow, repay-with-replacement, and reallocation). It never decrements. Loan IDs are unique and never reused.

### Stage and deployment

- **Stage immutability.** After `deployFor` completes, no function in REVDeployer calls `CONTROLLER.queueRulesetsOf` or modifies ruleset parameters.
- **Stage progression monotonicity.** `startsAtOrAfter` values strictly increase between stages. The first stage can be 0 (mapped to `block.timestamp`).
- **Auto-issuance single-claim.** Each `(revnetId, stageId, beneficiary)` can only be claimed once. `amountToAutoIssue` is zeroed BEFORE the external `mintTokensOf` call (CEI pattern).
- **Split percentages.** Per-stage `splitPercent > 0` requires `splits.length > 0`. Split percentages are validated by `JBSplits` in core (must sum to <= `SPLITS_TOTAL_PERCENT`).

### Fee flows

- **Cash-out fees flow to fee revnet.** If the fee terminal `pay` succeeds, the fee goes to `FEE_REVNET_ID`. If it fails, the fee returns to the originating project via `addToBalanceOf`. Funds are never lost and never kept by the caller.
- **Loan REV fees flow to REV revnet.** If `feeTerminal.pay` succeeds, the fee goes to `REV_ID`. If it fails (try-catch), the fee amount is zeroed and added to the borrower's payout. The fee is never lost -- it either reaches the REV revnet or goes to the borrower.

### Hidden token accounting

- **Hidden balance conservation.** `totalHiddenOf[revnetId]` == sum of `hiddenBalanceOf[holder][revnetId]` across all holders.
- **Reveal bounded by hide.** No holder can reveal more tokens than they have hidden. `revealTokensOf` reverts with `REVHiddenTokens_InsufficientHiddenBalance` if `tokenCount > hiddenBalanceOf[caller][revnetId]`.
- **No double-mint from reveal.** Each hidden token can only be revealed once. Decrementing `hiddenBalanceOf` before minting prevents double-reveal.

### Privilege isolation

- **Sucker privilege.** Only addresses returning `true` from `SUCKER_REGISTRY.isSuckerOf(projectId, addr)` get 0% cashout tax. No other code path grants this exemption.
- **Loan ownership.** Only `_ownerOf(loanId)` — or an operator with the relevant `JBPermissionIds` (`REPAY_LOAN` for repayment, `REALLOCATE_LOAN` for reallocation) — can call `repayLoan` and `reallocateCollateralFromLoan`. Similarly, `borrowFrom` requires the caller to be the `holder` or to have `OPEN_LOAN` permission. The loan NFT is burned before any state changes in repayment, preventing double-use. In all delegated cases, collateral and replacement loans flow to the original holder/owner, not the operator.
- **Mint permission.** Only `LOANS`, `HIDDEN_TOKENS`, `BUYBACK_HOOK`, buyback hook delegates (via `BUYBACK_HOOK.hasMintPermissionFor`), and suckers (via `REVOwner._isSuckerOf`) can mint tokens. No other address passes the `REVOwner.hasMintPermissionFor` check.

---

## 8. Accepted Behaviors

### 8.1 Suckers receive 0% cashout tax (by design)

`REVOwner.beforeCashOutRecordedWith` returns `cashOutTaxRate = 0` for any address where `SUCKER_REGISTRY.isSuckerOf(projectId, addr)` returns true. This grants suckers the full pro-rata reclaim with no tax retention. This is intentional: suckers burn tokens on the source chain and mint equivalent tokens on the destination chain. The zero-tax path ensures bridged tokens preserve their full economic value across chains. The security boundary is the sucker registry — only addresses registered by authorized deployers (gated by `DEPLOY_SUCKERS` permission and per-stage `extraMetadata` bit 2) receive this privilege.

### 8.2 No liquidation trigger for under-collateralized loans (by design)

`REVLoans` has no health factor, no margin call, and no keeper-triggered liquidation. The only liquidation path is `liquidateExpiredLoansFrom` after 10 years. This is a conscious design choice: the protocol treats under-collateralized loans as free put options where the borrower forfeits worthless collateral and keeps the borrowed funds. The protocol absorbs this "loss" through permanent supply reduction (burned collateral), which is deflationary for remaining holders. A liquidation mechanism would add complexity, require oracles, and introduce MEV extraction opportunities at liquidation boundaries — all of which conflict with the revnet's minimal-trust design philosophy.

### 8.3 Auto-issuance dilution is permissionless but predictable

`autoIssueFor` can be called by anyone, diluting existing holders by minting pre-configured token amounts to beneficiaries. This is accepted because: (1) auto-issuance amounts are set immutably at deployment, so dilution is fully predictable, (2) the dilution only occurs once per `(revnetId, stageId, beneficiary)` tuple (single-claim guarantee), and (3) delaying the call only delays the inevitable — the configured amounts will eventually be minted. A griefing vector exists where someone calls `autoIssueFor` immediately before another user's cash-out, but the dilution magnitude is deterministic and can be priced in.

### 8.4 Surplus manipulation via donations is economically irrational (by design)

`_borrowableAmountFrom` reads live surplus. An attacker could inflate surplus via `addToBalanceOf`, but donations are permanent (no recovery), and the extra borrowable amount is always less than the donation. `pay` increases both surplus AND supply, neutralizing the effect. With non-zero `cashOutTaxRate`, the concave bonding curve makes this even worse for attackers. The attack is self-defeating by construction.

### 8.5 Borrow-repay arbitrage is unprofitable (by design)

A borrower who pays the prepaid fee upfront (minimum 2.5% + REV fee 1% = 3.5%) can repay at any time within the prepaid duration with no additional cost. If the bonding curve value of the collateral increases during the prepaid window, the borrower can repay, recover their collateral, and cash out at the higher value. This is not profitable as a standalone strategy because the 3.5% minimum fee exceeds the expected value gained from short-term surplus fluctuations. For borrowers who need liquidity anyway, it provides free optionality — which is the intended use case.
