# Invariants — `@rev-net/core-v6`

Scope: invariants for the three contracts that make up `revnet-core-v6` — `REVOwner` (project-NFT holder + runtime data hook), `REVDeployer` (revnet factory), and `REVLoans` (collateralized borrowing against revnet tokens). Sits on top of `nana-core-v6`. The monorepo-wide invariants (e.g. nana-core's terminal/controller mechanics, suckers' bridge accounting, registry-default cohort safety) are not duplicated here — see `../INVARIANTS.md`.

This document is the **policy boundary** for revnets specifically: what holders, borrowers, and operators are guaranteed and what they aren't. The cross-chain arbitrage model that ties the LOCAL-rate sucker branch and AGGREGATED-rate normal branch together is documented separately in [`ARBITRAGE.md`](./ARBITRAGE.md) and cross-referenced below.

Companion docs in this repo:

- [`README.md`](./README.md) — high-level orientation
- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — module boundaries and critical flows
- [`ARBITRAGE.md`](./ARBITRAGE.md) — three intentional arbitrage paths (cross-chain rebalancing, cash-out floor, pay ceiling)
- [`RISKS.md`](./RISKS.md) — risk register and accepted behaviors
- [`ADMINISTRATION.md`](./ADMINISTRATION.md) — control model and roles
- [`USER_JOURNEYS.md`](./USER_JOURNEYS.md) — payer/holder/borrower/operator flows

---

## Section A — Guarantees to Revnet holders

Audience: anyone paying a revnet, holding its tokens, or borrowing against them.

## A.1 Payment and issuance

- A payment of `X` accepted-token mints `weight × X` revnet tokens at the *current stage's* configured weight, minus the reserved percent (which accrues to `pendingReservedTokenBalanceOf` for split distribution).
- `REVOwner.beforePayRecordedWith` (`src/REVOwner.sol:456-502`) **scales the buyback hook's weight** by `projectAmount / context.amount.value` whenever a 721 tier split deducts from the deposit, so payers receive token credit only for the portion that actually entered the project — not for the split portion routed to NFT-tier recipients.
- The weight, reserved percent, cashOutTaxRate, baseCurrency, scopeCashOutsToLocalBalances flag, and extra metadata of each stage are **frozen at queue time**. `REVDeployer._makeRulesetConfigurations` (`src/REVDeployer.sol:877-1055`) commits stage parameters into the `encodedConfigurationHash`, and no caller — operator, deployer, infra owner — can mutate them after launch.
- USD-denominated revnets compute mint amount through the JBPrices feed registry. A revnet's identity commits to its base currency.

## A.2 Cash-out via terminal

- Calling `JBMultiTerminal.cashOutTokensOf` on a revnet token applies the *current stage's* `cashOutTaxRate` to the bonding curve. The reclaim formula is `base × [(MAX − tax) + tax × (count/supply)] / MAX`.
- `REVOwner.beforeCashOutRecordedWith` (`src/REVOwner.sol:242-443`) is the data-hook policy boundary; its three branches are documented inline in the contract:
  1. **Sucker branch** (`src/REVOwner.sol:264-274`): tax = 0, LOCAL supply/surplus. The bridge accounting primitive. See ARBITRAGE.md (Path 1).
  2. **Cash-out delay branch** (`src/REVOwner.sol:277-286`): reverts `REVOwner_CashOutDelayNotFinished` while `cashOutDelayOf[revnetId] > block.timestamp`. Applies to ordinary holder cash-outs only; the sucker branch returns *before* this check by design.
  3. **Ordinary cash-out branch** (`src/REVOwner.sol:288-442`): aggregates cross-chain supply/surplus when `scopeCashOutsToLocalBalances == false`, splits a 2.5% fee from the token count (not the value), proportionally scales reclaim+fee when local liquidity is the binding cap, and routes through the buyback hook for optional AMM settlement (Path 2 floor arb). Cross-currency local loan debt fails closed if a required price is zero.
- Cash-out burns the holder's tokens before reclaim transfer (enforced by `JBMultiTerminal`); no double-cash-out via reentrancy.
- The fee revnet (project 1) receives the bonding-curve reclaim of its 2.5% token share regardless of whether the remaining 97.5% routes through a buyback pool. When the fee hook spec fails, `REVOwner.afterCashOutRecordedWith` returns the funds to the originating terminal via `addToBalanceOf` (`src/REVOwner.sol:655-665`).
- When global effective surplus exceeds local liquidity, **the holder receives `localSurplus - feeAmount`**, strictly less than the global formula. The protocol fee is **never** zeroed by the scaling (`src/REVOwner.sol:331-391`). Holders with a non-zero `minTokensReclaimed` on their cash-out call are protected against this asymmetry; holders without minimums should expect local-liquidity-capped reclaim.

## A.3 Cash-out delay (priming new chains)

- `REVDeployer.CASH_OUT_DELAY` is **7 days** (`src/REVDeployer.sol:81`). It applies when an existing revnet adds a new chain mid-life (computed in `_computeCashOutDelayIfNeeded`, `src/REVDeployer.sol:1063-1079`).
- During the delay window on a freshly-added chain:
  - `cashOutTokensOf` reverts (`src/REVOwner.sol:277-286`).
  - `REVLoans.borrowFrom` reverts (the delay is re-checked via `_cashOutDelayOf`, `src/REVLoans.sol:475-484`, called from `borrowableAmountFrom` and inside `_borrowFrom`).
  - `JBSucker.prepare` (the bridge entrypoint that calls `beforeCashOutRecordedWith` on this contract) **is not blocked** because the sucker branch returns at `src/REVOwner.sol:264-274` before reaching the delay check.
- This asymmetry is the priming mechanism: bridges flow tokens IN during the delay, building local backing, before holders can directly exit.

## A.4 REVLoans guarantees

- `borrowableAmountFrom(revnetId, collateralCount, decimals, currency)` returns **two values**, `(borrowableNow, borrowableCapacity)`. `borrowableCapacity` is the same bonding-curve reclaim that `cashOutTokensOf` would produce **for the same collateral count**, capped at `localSurplus` (`localSurplus = totalSurplus + totalBorrowed`). This cap is the hard guarantee: a borrower cannot drain more than the local economic surplus even when global effective surplus is much larger.
- `borrowableNow` is `borrowableCapacity` **additionally** held to the live treasury surplus — the amount the terminal can actually disburse right now via the use-allowance path. Because earlier borrows have already drawn their amounts out of the live balance (those amounts move into `totalBorrowed`, still counted in `localSurplus`, but are no longer held by the terminal), `borrowableCapacity` can exceed what the terminal currently holds. `borrowableNow` keeps the quote coherent with execution: a borrow sized to it does not revert. Opening a borrow applies the same live cap (it borrows `borrowableNow`); repaying and reallocating value collateral that already backs a loan and draw no fresh funds, so they use `borrowableCapacity`.
- `borrowFrom` requires `OPEN_LOAN` on `holder`. The operator (if delegated) controls `beneficiary`, so holders should only grant `OPEN_LOAN` to fully trusted operators.
- Collateral tokens are **burned at borrow time** (`src/REVLoans.sol:1067-1078`), not escrowed. Total collateral is tracked in `totalCollateralOf[revnetId]` and added back to supply in cash-out math (`src/REVOwner.sol:256-257`) so the bonding curve sees pre-loan economic state.
- Repayment re-mints the returned collateral 1:1 through the controller (`src/REVLoans._returnCollateralFrom`). Partial repays supported.
- A loan's payoff cost grows linearly after the prepaid duration, up to 100% at `LOAN_LIQUIDATION_DURATION = 3650 days` (10 years, `src/REVLoans.sol:92`). After that, the loan can be liquidated permissionlessly.
- `liquidateExpiredLoansFrom(revnetId, startingLoanId, count)` (`src/REVLoans.sol:681-748`) is **permissionless and bountyless** — it pays nothing to the caller. It is pure cleanup: burns expired loan NFTs, zeroes outstanding-debt/collateral counters, and emits `Liquidate`. The burned collateral is **permanently lost** because it was burned at borrow time, not escrowed.
- Stage transitions (`src/REVDeployer.sol:877-887` dev-doc) can change a loan's borrowable amount mid-life: a higher `cashOutTaxRate` in a later stage reduces what the same collateral can borrow, exposing the loan to earlier liquidation. This is by design — loans track the live bonding curve.

## A.5 Protections against external interference

- A third-party EOA **cannot**: queue a new ruleset on any revnet, change cashOutTaxRate / weight / reservedPercent / dataHook / scopeCashOutsToLocalBalances, mint revnet tokens, drain a revnet's treasury, replace `REVOwner` as the project NFT holder, or redirect another holder's cash-out / loan proceeds.
- The non-deploy-time `REVOwner.afterCashOutRecordedWith` fallback path (`src/REVOwner.sol:607-665`) accepts calls from any address. For native fees, `msg.value` must exactly equal `context.forwardedAmount.value`, so an external caller can only donate their own ETH as fees — they cannot spend ETH stranded in the hook. For ERC-20 fees, `msg.value` must be zero and the forwarded amount is pulled from the caller.
- The ERC-2771 trusted forwarder can relay REVOwner's signer-facing entrypoints, but does not gain operator powers itself. `setOperatorOf`, `setDeployer`, `autoIssueFor`, and `burnHeldTokensOf` recover the signer with `_msgSender()`, while terminal/NFT callbacks keep using the direct caller.
- Flash-loan surplus inflation is net-negative against a borrower's own position (see `src/REVLoans.sol:343-357` dev-doc).

---

## Section B — Guarantees to Revnet operators

Audience: the per-revnet operator EOA configured at launch (`configuration.operator`).

## B.1 Powers the operator retains

The operator's permission set is granted by `REVOwner._setOperatorOf` and listed in `REVOwner._operatorPermissionIndexesOf` (`src/REVOwner.sol:917-940`, `src/REVOwner.sol:1053-1061`):

| Permission ID | Capability |
|---|---|
| `SET_SPLIT_GROUPS` | Rotate reserved-token splits at any time, for any ruleset |
| `SET_BUYBACK_POOL` | Point buyback at a different Uniswap V4 pool |
| `SET_BUYBACK_TWAP` | Change the buyback hook's TWAP window |
| `SET_BUYBACK_HOOK` | Swap the buyback hook implementation |
| `SET_PROJECT_URI` | Change project metadata pointer |
| `SET_TOKEN_METADATA` | Change ERC-20 name/symbol |
| `SUCKER_SAFETY` | Trigger the emergency hatch for stuck bridged tokens |
| `SET_ROUTER_TERMINAL` | Configure `JBRouterTerminal` routing |
| `SIGN_FOR_ERC20` | ERC-1271-valid signatures from the project token contract for external integrations |

Plus extras appended via `init.extraOperatorPermissionIds` during `initializeRevnet` (typically 721 hook admin permissions — `ADJUST_721_TIERS`, `SET_721_METADATA`, `MINT_721`, `SET_721_DISCOUNT_PERCENT` — when `preventOperator*` flags are off; see `REVDeployer.sol:670-693`).

Plus indirect powers via the deployer:

- `REVDeployer.deploySuckersFor(revnetId, suckerDeploymentConfiguration)` (`src/REVDeployer.sol:588-615`) — operator-only; gated by the current ruleset's `allowsDeployingSuckers` flag (bit 2 of extraMetadata).

Plus rotation:

- `REVOwner.setOperatorOf(revnetId, newOperator)` (`src/REVOwner.sol:851-863`) — only the current operator can rotate, directly or through the trusted forwarder. `address(0)` permanently relinquishes.

## B.2 Powers the operator does NOT have

- **No control over rulesets.** Operators cannot queue new rulesets (`QUEUE_RULESETS` not granted), cannot launch first rulesets (`LAUNCH_RULESETS` not granted), and cannot change cashOutTaxRate / weight / reservedPercent / dataHook / scopeCashOutsToLocalBalances. The stage chain set in `REVDeployer.deployFor` is permanent.
- **No control over project NFT ownership.** The NFT is owned by `REVOwner` (a singleton); `REVOwner.onERC721Received` only accepts mints from `JBProjects` and never exposes a transfer-out. The operator is not the project owner.
- **No direct mint authority.** The operator cannot call `JBController.mintTokensOf` directly. Token issuance is bounded by:
  - normal pay-driven issuance at the configured weight,
  - `REVOwner.autoIssueFor` (permissionless, single-shot per `(revnet, stage, beneficiary)`, amount fixed at deploy time, `src/REVOwner.sol:797-822`),
  - `sendReservedTokensToSplitsOf` (permissionless, mints the already-reserved share at the configured reserved percent).
- **No control over the project's treasury beyond loans.** `useAllowanceOf` permission is wildcard-granted only to `REVLoans` (`src/REVOwner.sol:681-685`). The operator cannot withdraw surplus or set arbitrary payouts (revnets 1–7 ship with zero payout limits).
- **No control over terminals.** The deployer constructor-pins `MULTI_TERMINAL` and `ROUTER_TERMINAL_REGISTRY`; operators cannot add or replace them.
- **No control over price feeds.** Default-feed changes require `_CRITICAL_INFRA_OWNER`; project-specific feed registration requires controller access the operator doesn't have.
- **No protocol-level seize.** There is no admin path that lets anyone other than the current operator take over operator powers. If a current operator is compromised, the only recovery path is the operator's own `setOperatorOf`.

## B.3 Liveness guarantees

- Payments cannot be DoSed by external parties.
- `sendPayoutsOf`, `sendReservedTokensToSplitsOf`, `processHeldFeesOf`, `autoIssueFor`, `burnHeldTokensOf`, and `liquidateExpiredLoansFrom` are all permissionless. None of them can extract value beyond the deploy-time configured allocation.
- The buyback pool can be front-run at deploy time (an attacker squats the canonical V4 PoolKey). The deploy script catches this and ships the revnet without buyback routing; the operator can wire a different fee-tier pool later via `SET_BUYBACK_POOL` (`src/REVDeployer.sol:442-461`).

---

## Section C — Per-contract operation inventory

For each external/public function: caller, effect, and the invariant it preserves.

## C.1 `REVOwner` — `src/REVOwner.sol`

### One-shot protocol binders

- **`setDeployer(IREVDeployer newDeployer)`** (`src/REVOwner.sol:751-786`) — only the constructor-supplied `_DEPLOYER` account, recovered through ERC-2771 when relayed. Snapshots `CONTROLLER`/`PERMISSIONS`/`PROJECTS` from the deployer; grants wildcard (`revnetId=0`) permissions: `USE_ALLOWANCE` to `LOANS`, `SET_BUYBACK_POOL` to `BUYBACK_HOOK`, `DEPLOY_SUCKERS`+`MAP_SUCKER_TOKEN` to the new deployer.
  - **Invariant:** one-time only — reverts `REVOwner_AlreadyInitialized` on second call. Wildcard grants are immutable after.

### Deployer-only

- **`initializeRevnet(uint256 revnetId, REVOwnerRevnetInit init)`** (`src/REVOwner.sol:678-743`) — only `address(deployer)`. Stores `cashOutDelayOf[revnetId]` (if non-zero), `tiered721HookOf[revnetId]`, accumulates `amountToAutoIssue` (using `+=`, so multiple entries for the same beneficiary stack), appends `extraOperatorPermissionIds`, bootstraps the initial operator via `_setOperatorOf`, applies `extraGrants` (e.g. Croptop publisher `ADJUST_721_TIERS`).
  - **Invariant:** only the canonical deployer can write revnet-scoped state. No path lets an outside caller overwrite an existing revnet's delay/hook/operator/auto-issuance.

### Operator-only (revnet-scoped)

- **`setOperatorOf(uint256 revnetId, address newOperator)`** (`src/REVOwner.sol:851-863`) — only the current operator (checked via `_checkIfIsOperatorOf` against the ERC-2771-aware sender). Revokes the old operator's permissions, grants the merged default+extra set to `newOperator`. `address(0)` permanently relinquishes.
  - **Invariant:** only the current operator can rotate; permission set rotated atomically; new operator's authority is exactly `_operatorPermissionIndexesOf(revnetId)` — never elevated beyond the merged set.

### Permissionless

- **`autoIssueFor(uint256 revnetId, uint256 stageId, address beneficiary)`** (`src/REVOwner.sol:797-822`) — anyone, after `ruleset.start ≤ block.timestamp`. Zeroes `amountToAutoIssue[revnetId][stageId][beneficiary]` **before** calling `CONTROLLER.mintTokensOf` (reentrancy-safe).
  - **Invariant:** each `(revnet, stage, beneficiary)` tuple is single-shot. Amount is fixed at deploy time. Caller cannot redirect tokens to themselves.

- **`burnHeldTokensOf(uint256 revnetId)`** (`src/REVOwner.sol:828-844`) — anyone. Burns this contract's own combined credit + ERC-20 balance for the revnet (residue from reserved-token splits that don't sum to 100%).
  - **Invariant:** only burns this contract's own balance; reverts if zero (no silent no-op).

- **`afterCashOutRecordedWith(JBAfterCashOutRecordedContext)` payable** (`src/REVOwner.sol:607-665`) — no caller validation; useful only when invoked by a terminal. Routes the rev fee to the fee-revnet terminal via `pay`; on failure, returns funds to `msg.sender` via `addToBalanceOf`.
  - **Invariant:** native value must match `context.forwardedAmount.value` exactly; ERC-20 path requires `msg.value == 0`. External callers can only donate their own funds.

### Data-hook callbacks (terminal-only by use)

- **`beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext) view`** (`src/REVOwner.sol:242-443`) — three branches documented above (Section A.2). Returns `(cashOutTaxRate, cashOutCount, totalSupply, effectiveSurplusValue, hookSpecifications)`.
  - **Invariants:** sucker holders get 0% tax + LOCAL state; delay reverts; ordinary path aggregates cross-chain when allowed, scales reclaim+fee proportionally to local liquidity, fee is never zeroed by scaling, cross-currency local debt fails closed on zero price, and the fee path composes at most one buyback cash-out spec.

- **`beforePayRecordedWith(JBBeforePayRecordedContext) view`** (`src/REVOwner.sol:456-502`) — coordinates the 721 hook (NFT tier splits) and buyback hook; scales the buyback hook's weight by `projectAmount / context.amount.value`.
  - **Invariant:** payers receive token credit only for the share that enters the project, not the split share. Buyback hook's `weight=0` (buying back, not minting) is preserved.

- **`hasMintPermissionFor(uint256 revnetId, JBRuleset, address addr) view`** (`src/REVOwner.sol:514-531`) — grants mint to `LOANS`, `BUYBACK_HOOK` and its delegates, and registered suckers.
  - **Invariant:** mint authority is exactly that allowlist; no operator-elevated mint path.

- **`peerChainAdjustedAccountsOf(uint256 revnetId) view`** (`src/REVOwner.sol:543-566`) — exposes local outstanding loan debt as both `surplus` and `balance` and collateral as `supply` for peer-chain sucker snapshots.
  - **Invariant:** loan state travels with snapshots; conservation across chains (see ARBITRAGE.md Section D2.5 in the monorepo INVARIANTS.md). Each source debt must fit the snapshot's `uint128` fields or the snapshot reverts.

- **`onERC721Received(...)`** (`src/REVOwner.sol:868-871`) — only accepts mints from `JBProjects`.

### Views

- `isOperatorOf`, `cashOutDelayOf`, `tiered721HookOf`, `amountToAutoIssue`, `deployer`, `CONTROLLER`, `PERMISSIONS`, `PROJECTS`, `BUYBACK_HOOK`, `DIRECTORY`, `FEE_REVNET_ID`, `LOANS`, `SUCKER_REGISTRY`, `trustedForwarder`, `isTrustedForwarder`, `supportsInterface`.

## C.2 `REVDeployer` — `src/REVDeployer.sol`

### Permissionless launch

- **`deployFor(uint256 revnetId, REVConfig, JBAccountingContext[], REVSuckerDeploymentConfig, REVDeploy721TiersHookConfig, REVCroptopAllowedPost[]) payable`** (`src/REVDeployer.sol:486-521`) — anyone. The 721-hook + Croptop overload.
- **`deployFor(uint256 revnetId, REVConfig, JBAccountingContext[], REVSuckerDeploymentConfig) payable`** (`src/REVDeployer.sol:525-582`) — anyone. The minimal (no Croptop) overload that still deploys an empty 721 hook for runtime uniformity.
  - **Invariant (both):** when `revnetId == 0`, creates a fresh project via `PROJECTS.createFor{value: msg.value}` and forwards the creation fee; when `revnetId != 0`, requires `msg.value == 0` (`REVDeployer_ProjectCreationFeeNotNeeded`). Extending an existing revnet to a new chain is therefore fee-free.
  - **Invariant:** project NFT is permanently transferred to `REVOwner` at the end of `_deployRevnetFor` (`src/REVDeployer.sol:829`); the deployer never retains ownership.
  - **Invariant:** `encodedConfigurationHash` is computed from stage economics + `baseCurrency` + `scopeCashOutsToLocalBalances` + identity fields. Terminal addresses and reserved-token split recipients are excluded by design (see ARCHITECTURE.md `Cross-Chain Configuration Hash`).
  - **Invariant:** cash-out delay applies only when extending an existing revnet whose first stage already started (`_computeCashOutDelayIfNeeded`, `src/REVDeployer.sol:1063-1079`).

### Operator-only

- **`deploySuckersFor(uint256 revnetId, REVSuckerDeploymentConfig)`** (`src/REVDeployer.sol:588-615`) — current operator only (via `REVOwner.isOperatorOf`). Reads the current ruleset's metadata bit 2 (`allowsDeployingSuckers`); reverts if disabled.
  - **Invariant:** only the operator can extend bridging; only when the active ruleset's metadata permits.

### Views and receivers

- `onERC721Received` (`src/REVDeployer.sol:217-222`) — accepts JBProjects mints only.
- `supportsInterface`.
- Public state: `hashedEncodedConfigurationOf[revnetId]`, plus all immutable constructor-supplied references.

## C.3 `REVLoans` — `src/REVLoans.sol`

### Borrower / delegated operator

- **`borrowFrom(revnetId, token, minBorrowAmount, collateralCount, beneficiary, prepaidFeePercent, holder) → (loanId, REVLoan)`** (`src/REVLoans.sol:639-666`) — `holder` or `OPEN_LOAN` operator of `holder`. Burns collateral, calls `TERMINAL.useAllowanceOf`, mints loan NFT to `holder`, sends proceeds to the caller-supplied `beneficiary`. Source fee taken upfront.
  - **Invariants:** bounded by `_borrowableAmountFrom` (current bonding curve, gated by `_cashOutDelayOf`); `localSurplus` cap, plus a live-treasury-surplus cap on the preview and on opening a borrow so the quote never exceeds what the terminal can disburse now; collateral burned at deposit (not escrowed); terminal payout must cover the reserved REV and source fee buckets; reentrancy blocked by `nonReentrantLoanAction` transient flag.

- **`reallocateCollateralFromLoan(loanId, collateralCountToTransfer, token, minBorrowAmount, collateralCountToAdd, beneficiary, prepaidFeePercent)`** (`src/REVLoans.sol:768-835`) — loan owner or `REALLOCATE_LOAN` operator. If `collateralCountToAdd != 0`, also requires `OPEN_LOAN` for the added holder tokens. The transferred collateral from the existing loan can still back the new paired loan created by the reallocation path, and the caller chooses the proceeds `beneficiary`; treat delegated `REALLOCATE_LOAN` as debt-creation/proceeds-redirection authority. Burns original loan NFT; creates reallocated + new loans.
  - **Invariants:** new loan's source token must equal original's (reverts `REVLoans_SourceMismatch`); not `payable` (cannot accept new funds); reverts after `LOAN_LIQUIDATION_DURATION`.

- **`repayLoan(loanId, maxRepayBorrowAmount, collateralCountToReturn, beneficiary, allowance)` payable** (`src/REVLoans.sol:848-...`) — loan owner or `REPAY_LOAN` operator. Forwards repay (incl. source fee) to terminal; remints returned collateral to the caller-supplied `beneficiary`. Partial repays supported. Treat delegated `REPAY_LOAN` as collateral-withdrawal/beneficiary-redirection authority, not merely permission to send debt repayment.
  - **Invariants:** `(maxRepayBorrowAmount=0, collateralCountToReturn=0)` reverts; `newBorrowAmount > loan.amount` reverts; re-checks loan NFT ownership after `_acceptFundsFor` (ERC-777/1363 reentrancy defense); excess refunded to original sender.

### Permissionless

- **`liquidateExpiredLoansFrom(revnetId, startingLoanId, count)`** (`src/REVLoans.sol:681-748`) — anyone. Burns expired loan NFTs, clears storage. No caller bounty. The 10-year `LOAN_LIQUIDATION_DURATION` is fixed.
  - **Invariants:** only acts on loans actually past `createdAt + LOAN_LIQUIDATION_DURATION`; collateral count and total borrowed counters are reduced accordingly; gap in loan ID sequence is permanent.

### Owner

- **`setTokenUriResolver(IJBTokenUriResolver resolver)`** (`src/REVLoans.sol:1006-1011`) — `onlyOwner`. Pure cosmetic.

### Views

- `borrowableAmountFrom`, `loanOf`, `loanSourceTokensOf`, `determineSourceFeeAmount`, `revnetIdOfLoanWith`, `tokenURI`.
- Public state: `isLoanSourceOf`, `tokenUriResolver`, `totalBorrowedFrom`, `totalCollateralOf`, `totalLoansBorrowedFor` (note: monotonic counter; gaps from repaid/liquidated loans are permanent — see dev-doc at `src/REVLoans.sol:166-171`).

---

## Section D — Cross-cutting invariants

1. **One-shot binders.** `REVOwner.setDeployer` reverts on second call (`REVOwner_AlreadyInitialized`). The `_DEPLOYER` immutable cannot be rotated.
2. **Operator rotation is the only path to change operator.** No protocol-level seize, no admin override. `address(0)` permanently relinquishes.
3. **ERC-2771 only changes caller recovery.** The trusted forwarder is constructor-pinned and can relay calls, but authorization still resolves to the original signer.
4. **Suckers get 0% cashout tax.** Enforced via `SUCKER_REGISTRY.isSuckerOf` at `src/REVOwner.sol:264-274`. The registry's trust boundary is that only suckers deployed through its own `deploySuckersFor` flow can register — external addresses cannot self-register.
5. **Wildcard grants on `REVOwner`** (`revnetId=0` scope, set in `setDeployer`):
   - `USE_ALLOWANCE` → `LOANS` — so `REVLoans` can pull from any revnet's terminal surplus allowance.
   - `SET_BUYBACK_POOL` → `BUYBACK_HOOK` — so the buyback registry can configure pools at deploy.
   - `DEPLOY_SUCKERS` + `MAP_SUCKER_TOKEN` → `deployer` — so `REVDeployer` can register suckers on behalf of the project owner.

   These are back-stopped by holders' own auth: a wildcard grant on `REVOwner`'s account does not let the grantee act *on behalf of a holder* — only on behalf of `REVOwner` (which holds the project NFT).
6. **REVLoans collateral is burned, not escrowed.** Loan-to-value can reach 1.0 when `cashOutTaxRate == 0`. With non-zero tax, the curve's concavity provides an implicit margin; e.g. a 10% tax gives ~10% margin against pure pro-rata.
7. **Cash-out delay applies to `cashOutTokensOf` and `REVLoans.borrowFrom` but NOT to `sucker.prepare`.** Intentional asymmetry — see ARBITRAGE.md (Path 1) and `src/REVOwner.sol:264-286`.
8. **Cross-chain arbitrage conservation.** Aggregate surplus across all chains is preserved modulo `protocol_fees_extracted + outstanding_loans`. The LOCAL-vs-AGGREGATED asymmetry is the arbitrageur's margin. See [`ARBITRAGE.md`](./ARBITRAGE.md) for the full taxonomy and `../INVARIANTS.md` Section D2 for the layered conservation invariants.
9. **`encodedConfigurationHash` commits revnet identity across chains.** Includes stage economics + base currency + `scopeCashOutsToLocalBalances` + identity. Excludes terminal addresses (deployer-pinned) and reserved-token split recipients (operator-mutable). See ARCHITECTURE.md `Cross-Chain Configuration Hash`.
10. **No hidden-token supply bucket.** Cash-out and loan denominators start from core's `totalTokenSupplyWithReservedTokensOf()` + `totalCollateralOf[revnetId]`. Voluntary burns destroy the holder's own claim, not tracked as hidden supply. See `RISKS.md` Section 7.11.
11. **Per-leaf reentrancy discipline.** `REVOwner.autoIssueFor` zeroes its mapping before the mint call. `REVLoans` uses a transient `_loanActionEntered` flag (`nonReentrantLoanAction`) across `borrowFrom`, `reallocateCollateralFromLoan`, `repayLoan`, `liquidateExpiredLoansFrom`. `_repayLoan` re-checks loan NFT ownership after `_acceptFundsFor` to defeat ERC-777/1363 callbacks.
12. **Per-stage immutability.** No queue/launch ruleset permission is held by any address after `Deploy.s.sol` completes for revnets 1–7 (see monorepo INVARIANTS.md Section D Item 13).

---

## Section E — Centralization caveats

Out-of-scope third-party attack surface; these are powers held by privileged addresses outside any individual operator's control.

- **`REVLoans` is `Ownable`.** The owner can call `setTokenUriResolver` (cosmetic). This does not affect loan economics or borrower funds. The owner **cannot** mint revnet tokens, drain a revnet's treasury, change a loan's terms, or seize collateral. The owner is set to the deployer Safe by `Deploy.s.sol`.
- **`REVOwner` has no `Ownable`.** It is purely deployer-bound (via the one-shot `setDeployer`) and per-revnet operator-rotated. There is no protocol owner who can edit cash-out delays, hook bindings, or operator assignments after launch. It is ERC-2771-aware; the trusted forwarder is constructor-pinned.
- **`REVDeployer` has no `Ownable`.** It is an ERC-2771-aware factory. The trusted forwarder is constructor-pinned.
- **Per-revnet operator EOAs** can rotate splits, buyback pool, and the operator within their own revnet. Compromise of an operator EOA is the operator's problem, not the protocol's — but a compromised operator cannot mint, cannot change rulesets, and cannot touch surplus beyond what loans allow.
- **`_CRITICAL_INFRA_OWNER` Safe** (NANA ops Safe) owns nana-core/buyback-registry/router-registry/sucker-registry. It does *not* own anything in `revnet-core-v6` directly, but compromise of that Safe could (a) replace the default buyback hook for revnets that don't pin one, (b) add malicious default price feeds (existing feeds are immutable), (c) grant feeless status to malicious addresses, (d) change the project creation fee. See monorepo INVARIANTS.md Section E for the full critical-infra surface.
- **`DEFIFA_REV_START_TIME` env-var hazard.** During multi-chain deploys, an inconsistent `DEFIFA_REV_START_TIME` between origin and follower chain runs of `Deploy.s.sol` can cause the encoded configuration hashes to diverge, breaking sucker peer mapping. This is a deploy-script / ops concern, not a runtime invariant violation. See `ARBITRAGE.md` and the monorepo INVARIANTS Section E for context.

---

## Section F — Key code references

| File:line | What |
|---|---|
| `src/REVOwner.sol:51-207` | Contract header, immutables, constructor |
| `src/REVOwner.sol:242-443` | `beforeCashOutRecordedWith` — the three-branch policy boundary |
| `src/REVOwner.sol:264-274` | Sucker branch: 0% tax + LOCAL supply/surplus (the bridge accounting primitive) |
| `src/REVOwner.sol:277-286` | Cash-out delay enforcement (ordinary holder path only) |
| `src/REVOwner.sol:331-391` | Local-liquidity proportional scaling; fee never zeroed |
| `src/REVOwner.sol:456-502` | `beforePayRecordedWith` — 721 + buyback coordination, weight scaling |
| `src/REVOwner.sol:514-531` | `hasMintPermissionFor` — exact allowlist (LOANS, BUYBACK_HOOK, suckers) |
| `src/REVOwner.sol:543-566` | `peerChainAdjustedAccountsOf` — loan state in peer snapshots |
| `src/REVOwner.sol:607-665` | `afterCashOutRecordedWith` fee processing + value-balanced caller check |
| `src/REVOwner.sol:678-743` | `initializeRevnet` deployer-only revnet bootstrap |
| `src/REVOwner.sol:751-786` | `setDeployer` one-shot binder + wildcard grants |
| `src/REVOwner.sol:797-822` | `autoIssueFor` permissionless, single-shot per `(revnet, stage, beneficiary)` |
| `src/REVOwner.sol:828-844` | `burnHeldTokensOf` residue cleanup |
| `src/REVOwner.sol:851-863` | `setOperatorOf` rotation by current operator |
| `src/REVOwner.sol:917-940` | `_operatorPermissionIndexesOf` — the merged operator permission set |
| `src/REVDeployer.sol:81-93` | Cash-out delay + buyback defaults constants |
| `src/REVDeployer.sol:217-222` | `onERC721Received` accepts JBProjects mints only |
| `src/REVDeployer.sol:442-461` | Buyback pool initialization swallows front-run reverts |
| `src/REVDeployer.sol:486-582` | `deployFor` overloads (with/without 721+Croptop) |
| `src/REVDeployer.sol:588-615` | `deploySuckersFor` operator-only + ruleset-gated |
| `src/REVDeployer.sol:755-849` | `_deployRevnetFor` orchestrates ruleset launch, ERC-20 deploy, pool init, NFT transfer, sucker deploy |
| `src/REVDeployer.sol:877-1055` | `_makeRulesetConfigurations` builds `encodedConfigurationHash` for cross-chain identity |
| `src/REVDeployer.sol:1063-1079` | `_computeCashOutDelayIfNeeded` — 7-day delay only on chains added mid-life |
| `src/REVLoans.sol:81-101` | Loan duration + fee constants (`LOAN_LIQUIDATION_DURATION`, `MIN_PREPAID_FEE_PERCENT`, `MAX_PREPAID_FEE_PERCENT`, `REV_PREPAID_FEE_PERCENT`) |
| `src/REVLoans.sol:239-245` | `nonReentrantLoanAction` transient guard |
| `src/REVLoans.sol:261-291` | `borrowableAmountFrom` — applies cash-out delay gate; returns `(borrowableNow, borrowableCapacity)` |
| `src/REVLoans.sol:343-365` | Flash-loan-surplus-inflation dev-doc (proven net-negative) |
| `src/REVLoans.sol` | `_borrowableAmountFrom` — aggregated supply/surplus when unscoped; returns `(borrowableCapacity, liveTreasurySurplus)` where `borrowableCapacity` is capped at `localSurplus` |
| `src/REVLoans.sol` | The `localSurplus` cap inside `_borrowableAmountFrom`, plus the live-treasury-surplus cap applied at the call sites to the preview (`borrowableNow`) and to opening a borrow |
| `src/REVLoans.sol:475-484` | `_cashOutDelayOf` reads from the data hook (REVOwner) |
| `src/REVLoans.sol:639-666` | `borrowFrom` — requires `OPEN_LOAN` on holder |
| `src/REVLoans.sol:681-748` | `liquidateExpiredLoansFrom` — permissionless, bountyless, after 10 years |
| `src/REVLoans.sol:768-835` | `reallocateCollateralFromLoan` — requires `OPEN_LOAN` if adding fresh collateral |
| `src/REVLoans.sol:1006-1011` | `setTokenUriResolver` owner cosmetic |
| `src/REVLoans.sol:1067-1078` | `_addCollateralTo` — burns collateral at deposit (not escrow) |

---

## See also

- [`ARBITRAGE.md`](./ARBITRAGE.md) — three intentional arbitrage paths, cross-chain conservation, why LOCAL-vs-AGGREGATED asymmetry is by design.
- `../INVARIANTS.md` — monorepo-wide invariants for revnets 1–7 (the deployed set), full cross-cutting invariants (Section D), cross-chain arbitrage model (Section D2), and centralization caveats (Section E).
- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — module boundaries, accounting model, critical flows, the `encodedConfigurationHash` commitment.
- [`RISKS.md`](./RISKS.md) — accepted behaviors and known tradeoffs (sucker 0% tax, no short-horizon liquidation, surplus-donation self-defeat, local-liquidity-capped cash-outs, etc.).
- [`ADMINISTRATION.md`](./ADMINISTRATION.md) — control roles and privileged surfaces in narrative form.
- [`AUDIT_INSTRUCTIONS.md`](./AUDIT_INSTRUCTIONS.md) — auditor scope and orientation.
