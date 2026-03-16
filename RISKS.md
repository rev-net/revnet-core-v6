# revnet-core-v6 -- Risks

Known security properties, trust assumptions, and vulnerability vectors for auditors of the Revnet + Loans system.

Read [ARCHITECTURE.md](./ARCHITECTURE.md) and [SKILLS.md](./SKILLS.md) for protocol context. Read [AUDIT_INSTRUCTIONS.md](./AUDIT_INSTRUCTIONS.md) for auditing guidance. Then come back here.

## Trust Model

### What You Trust

1. **REVDeployer as singleton data hook.** REVDeployer is the data hook for every revnet it deploys. A bug in `beforePayRecordedWith` or `beforeCashOutRecordedWith` affects all revnets simultaneously. There is no per-project isolation.

2. **Immutable stages.** Once deployed, stage parameters (issuance, cashOutTaxRate, splits, auto-issuances) cannot be changed. There is no owner, no governance, no upgrade path. A misconfigured deployment is permanent. This IS the trust model.

3. **Bonding curve as collateral oracle.** REVLoans uses the Juicebox bonding curve (`JBCashOuts.cashOutFrom`) as its sole collateral valuation method. There is no external oracle, no liquidation margin, no health factor. The borrowable amount equals the cash-out value of the collateral at the moment of borrowing.

4. **Juicebox core contracts.** The entire system depends on `JBController`, `JBMultiTerminal`, `JBTerminalStore`, `JBTokens`, and `JBPrices` operating correctly. A bug in any of these is a bug in every revnet.

5. **Buyback hook.** REVDeployer delegates swap-vs-mint decisions to `BUYBACK_HOOK`. All revnets deployed by the same deployer share one buyback hook instance. Buyback hook failure falls back to direct minting (not a revert).

6. **Suckers.** Cross-chain bridge implementations are trusted for token transport. Suckers get 0% cashout tax privilege in `beforeCashOutRecordedWith`. A compromised sucker can extract funds at zero cost.

### What You Do NOT Need to Trust

- **Project owners.** There are none. REVDeployer permanently holds the project NFT.
- **Split operators.** They can change splits and manage 721 tiers, but cannot change stage parameters, issuance rates, cashout tax rates, or access treasury funds directly.
- **Token holders.** They can only cash out proportional to the bonding curve. Borrowers can only borrow up to the bonding curve value of their burned collateral.

## Loan Economics Risks

These are the highest-priority risks for this audit. REVLoans is a lending protocol built on top of a bonding curve with no external price oracle.

| # | Risk | Severity | Description | Status |
|---|------|----------|-------------|--------|
| L-1 | **Surplus manipulation via `addToBalanceOf`** | Medium | `_borrowableAmountFrom` reads live surplus from all terminals. An attacker could temporarily inflate surplus to increase borrowable amount. **However:** donations via `addToBalanceOf` are permanent (no recovery), and the attacker's extra borrowable amount equals `donation * (collateral / totalSupply)`, which is always less than the donation. Attack is economically irrational. | Mitigated by design |
| L-2 | **Stage transition changes collateral value** | Medium | Active loans use the CURRENT stage's `cashOutTaxRate` for collateral valuation (`_borrowableAmountFrom`). When a stage transition increases `cashOutTaxRate`, existing loans become effectively under-collateralized -- the collateral is worth less than when the loan was originated. Borrowers retain the original borrowed amount. | By design -- borrowers should monitor stage timelines |
| L-3 | **100% LTV with no safety margin** | Medium | Borrowable amount equals exact bonding curve cash-out value. A `cashOutTaxRate` of 0 means true 100% LTV. Any decrease in surplus (from other cash-outs, payouts, or stage transitions) makes the loan under-collateralized. The protocol has no liquidation trigger for under-collateralized loans -- only the 10-year expiry. | By design -- `cashOutTaxRate > 0` creates implicit margin |
| L-4 | **10-year liquidation drift** | Low | Over 10 years, the real value of locked collateral tokens can diverge significantly from the borrowed amount. Tokens that appreciated create an incentive to repay; tokens that depreciated create an incentive to abandon (free put option for the borrower). | By design |
| L-5 | **Loans beat cash-outs above ~39% tax** | Informational | Above approximately 39.16% `cashOutTaxRate`, borrowing is more capital-efficient than cashing out because loans preserve upside while providing liquidity. Based on CryptoEconLab research. | By design |
| L-6 | **Cross-currency borrowed amount aggregation** | Medium | `_totalBorrowedFrom` aggregates borrowed amounts across multiple (terminal, token) pairs, normalizing decimals and converting currencies via `JBPrices`. If a price feed returns zero, the source is skipped. If a price feed returns a stale or manipulated value, the total borrowed amount is miscalculated, affecting all subsequent borrow operations. | Price feed staleness checked by Chainlink feeds; project-specific feeds may lack checks |
| L-7 | **`uint112` truncation** | Medium | `REVLoan.amount` and `REVLoan.collateral` are `uint112` (~5.19e33). The `_adjust` function checks for overflow and reverts with `REVLoans_OverflowAlert`. Verify this check is applied to all paths that set these values. | Checked in `_adjust` |
| L-8 | **Fee terminal revert during borrow** | Medium | In `_addTo`, the REV fee payment is wrapped in try-catch (fee is zeroed on failure, borrower gets it instead). But the source fee payment at the end of `_adjust` is NOT wrapped in try-catch. If `terminal.pay` reverts for the source fee, the entire borrow reverts. | Potential DoS vector if fee terminal is unavailable |
| L-9 | **Loan source array unbounded growth** | Low | `_loanSourcesOf[revnetId]` grows monotonically. No validation that a terminal is registered for the project at borrow time beyond `DIRECTORY.isTerminalOf` check. The number of distinct (terminal, token) pairs is practically bounded, but `_totalBorrowedFrom` iterates the full array. | Bounded in practice (< 10 sources typical) |

## Data Hook Proxy Pattern Risks

REVDeployer sits between the terminal and the actual hooks (buyback hook, 721 hook). This proxy pattern creates composition risks.

| # | Risk | Severity | Description |
|---|------|----------|-------------|
| D-1 | **Weight scaling arithmetic** | High | In `beforePayRecordedWith`, weight is scaled by `mulDiv(weight, projectAmount, context.amount.value)` to account for 721 split amounts. If `projectAmount == 0` (all funds go to splits), weight is set to 0. If `projectAmount < context.amount.value`, weight is proportionally reduced. Verify: (a) no rounding direction favors the attacker, (b) the scaling is applied consistently when the buyback hook returns weight=0 (buying back, not minting). |
| D-2 | **721 hook spec ordering** | Medium | `beforePayRecordedWith` places the 721 hook spec first, then the buyback hook spec. The terminal processes specs in order. Verify that the ordering doesn't create a state where one hook's execution invalidates assumptions made by the other. |
| D-3 | **Empty specs from 721 hook** | Medium | If `tiered721Hook.beforePayRecordedWith` returns an empty specs array, `totalSplitAmount` is 0 and the full payment goes to the buyback hook. If it returns a spec with amount > `context.amount.value`, `projectAmount` underflows to 0. Both paths need verification. |
| D-4 | **Cash-out fee calculation** | High | `beforeCashOutRecordedWith` computes the fee by splitting `cashOutCount` into `feeCashOutCount` and `nonFeeCashOutCount`, then computing two separate bonding curve calculations. The second calculation uses reduced surplus and supply. Verify: (a) total reclaimed (post-fee + fee) <= what a single full calculation would return, (b) rounding doesn't allow fee evasion. |
| D-5 | **`afterCashOutRecordedWith` caller trust** | Medium | No caller validation -- the comment says "a non-terminal caller would just be donating their own funds as fees." Verify this is true: can a crafted `context` cause the function to transfer tokens from `msg.sender` to an unintended destination? The function calls `safeTransferFrom(msg.sender, ...)` and then pays the fee terminal. |

## Stage Immutability Risks

| # | Risk | Severity | Description |
|---|------|----------|-------------|
| S-1 | **`cashOutTaxRate` cannot equal MAX** | Medium | `_makeRulesetConfigurations` enforces `cashOutTaxRate < MAX_CASH_OUT_TAX_RATE`. This means cash outs can never be fully disabled. If a revnet is designed to never allow cash outs, it cannot achieve this. |
| S-2 | **Stage time ordering** | Medium | `startsAtOrAfter` values must strictly increase between stages. The first stage can be 0 (uses `block.timestamp`). Verify that stage transitions work correctly when `startsAtOrAfter` is in the far future and the current stage has `duration > 0` (the stage cycles until the next one starts). |
| S-3 | **Auto-issuance stage ID assumption** | High | Stage IDs are `block.timestamp + i` during deployment. This assumes JBRulesets assigns IDs the same way. If the JBRulesets ID assignment logic changes or if there's a collision (another project queued a ruleset at the same timestamp), the stage IDs won't match and auto-issuance will fail. The code has detailed comments explaining this assumption -- verify it holds. |
| S-4 | **Active loans during stage transition** | Medium | When a stage with low `cashOutTaxRate` transitions to one with high `cashOutTaxRate`, existing loans become less collateralized (the collateral's cash-out value drops). The protocol has no mechanism to force repayment or adjust terms. Over 10 years, multiple stage transitions could compound this effect. |

## Cross-Chain / Matching Hash Risks

| # | Risk | Severity | Description |
|---|------|----------|-------------|
| X-1 | **Matching hash gap** | High | `hashedEncodedConfigurationOf` covers: `baseCurrency`, `name`, `ticker`, `salt`, and per-stage: `startsAtOrAfter`, `splitPercent`, `initialIssuance`, `issuanceCutFrequency`, `issuanceCutPercent`, `cashOutTaxRate`, and auto-issuances. It does NOT cover: terminal configurations, accounting contexts, sucker token mappings, 721 hook configuration, or croptop posts. Two deployments with identical hashes can have fundamentally different terminal setups. |
| X-2 | **NATIVE_TOKEN on non-ETH chains (INTEROP-6)** | Medium | `JBConstants.NATIVE_TOKEN` represents the chain's native token. On Celo, that's CELO, not ETH. A revnet with `baseCurrency=1` (ETH) deployed on Celo with NATIVE_TOKEN accounting creates a semantic mismatch -- CELO payments priced as ETH. The matching hash doesn't catch this. **Safe chains:** Ethereum, Optimism, Base, Arbitrum. **Affected chains:** Celo, Polygon, Avalanche, BNB Chain. |
| X-3 | **30-day cash-out delay** | Low | When deploying an existing revnet to a new chain where `firstStageConfig.startsAtOrAfter < block.timestamp`, a 30-day cash-out delay is applied. This prevents cross-chain liquidity arbitrage but could surprise users. Verify the delay is correctly enforced in `beforeCashOutRecordedWith` and that suckers (which bypass the check) cannot be used to circumvent the delay for non-bridging cash-outs. |

## Reentrancy Analysis

REVLoans and REVDeployer use no `ReentrancyGuard`. Both rely on CEI (Checks-Effects-Interactions) ordering.

| Function | State Update Timing | External Calls After | Risk |
|----------|-------------------|---------------------|------|
| `REVLoans._adjust` | `loan.amount` and `loan.collateral` written BEFORE external calls | `_addTo` (useAllowanceOf, pay), `_removeFrom` (addToBalanceOf), `_addCollateralTo` (burnTokensOf), `_returnCollateralFrom` (mintTokensOf), source fee `pay` | LOW -- state pre-committed; reentrant call sees updated values |
| `REVLoans.borrowFrom` | Loan created in storage, then `_adjust` called, then `_mint` | Per `_adjust` above, plus ERC721 `_mint` (onERC721Received callback) | LOW -- mint happens last, after all state is settled |
| `REVLoans.repayLoan` | Burns original loan NFT, then creates replacement via `_adjust` + `_mint` | Per `_adjust` above | LOW -- original loan burned before any external calls |
| `REVLoans.reallocateCollateralFromLoan` | Burns original loan, creates replacement, then calls `borrowFrom` for new loan | `_reallocateCollateralFromLoan` + `borrowFrom` in sequence | MEDIUM -- two loan operations in sequence; verify no cross-loan manipulation possible during reallocation callback |
| `REVDeployer.afterCashOutRecordedWith` | No state changes | `safeTransferFrom`, `feeTerminal.pay`, fallback `addToBalanceOf` | LOW -- stateless; just routes funds |
| `REVDeployer.autoIssueFor` | `amountToAutoIssue` zeroed BEFORE `mintTokensOf` | `CONTROLLER.mintTokensOf` | LOW -- CEI pattern prevents double-claim |

### Key reentrancy concern: `_adjust` source fee payment

In `_adjust`, the source fee is paid via `loan.source.terminal.pay{value: payValue}(...)` at the end of the function. This call goes to an external terminal, which could potentially call back into REVLoans. However, by this point all loan state (`amount`, `collateral`) has been committed, and the loan NFT has not yet been minted (in the `borrowFrom` path). A reentrant `borrowFrom` would burn different collateral tokens and create a separate loan -- verify this is safe.

## MEV / Front-Running Risks

| Risk | Description | Mitigation |
|------|-------------|------------|
| **Borrow sandwich** | Attacker sees a large cash-out in the mempool, borrows first (at higher surplus), then the cash-out reduces surplus, making the attacker's collateral worth less. But the attacker still has the borrowed funds. | Not profitable: attacker's own collateral is worth less, and they owe the same amount back. The 10-year horizon makes this a losing trade. |
| **Cash-out front-running** | Large cash-outs visible in mempool. Front-runner cashes out first, reducing surplus for the victim. | Use private mempools; `minTokensReclaimed` parameter on terminal. Not a revnet-specific risk. |
| **Stage transition front-running** | Immediately before a stage transition that changes `cashOutTaxRate`, front-run to borrow or cash out under the old, more favorable rate. | Stage transitions are deterministic and predictable. Borrowers and cashers should plan around them. Not preventable by design. |
| **Auto-issuance front-running** | Call `autoIssueFor` to mint tokens that dilute supply before a target user's cash-out. | Auto-issuance is permissionless and predictable. The tokens are pre-configured at deployment. Dilution is expected. |

## Privileged Roles

| Role | Capabilities | Constraints |
|------|-------------|-------------|
| **REVDeployer** (contract) | Holds all project NFTs. Acts as data hook. Grants permissions. | Cannot change stage parameters. Singleton -- shared across all revnets. |
| **Split operator** (per-revnet) | Change splits, manage 721 tiers, deploy suckers, set buyback pools, set project URI. | Cannot change issuance, cashOutTaxRate, or access treasury directly. Singular -- only one address at a time. Can transfer role via `setSplitOperatorOf`. |
| **REVLoans** (contract) | USE_ALLOWANCE permission on all revnets (wildcard projectId=0). Can burn and mint tokens. | Only exercises these permissions through loan operations with bonding curve constraints. |
| **BUYBACK_HOOK** (contract) | SET_BUYBACK_POOL permission on all revnets. Mint permission delegated by `hasMintPermissionFor`. | Immutable per deployer instance. |
| **SUCKER_REGISTRY** (contract) | MAP_SUCKER_TOKEN permission on all revnets. | Token mappings immutable once outbox has entries. |
| **Auto-issuance beneficiaries** | Receive pre-minted tokens per stage. | Amounts fixed at deploy time. Permissionless claim -- anyone can call `autoIssueFor` on their behalf. |

## Operational Risks

| Risk | Description | Mitigation |
|------|-------------|------------|
| Fee revnet must have terminals | Cash-out fees and loan REV fees are paid to `FEE_REVNET_ID` / `REV_ID`. If those projects have no terminal for the token, fees fail silently (try-catch in most places). | Monitor fee project health |
| Buyback pool initialization failure | `_tryInitializeBuybackPoolFor` is wrapped in try-catch. If pool initialization fails, payments still work (fall back to direct minting) but without DEX buyback efficiency. | Silent -- no event on failure |
| Split gas exhaustion | No explicit cap on splits array length. Large split arrays during reserved token distribution or payouts can exceed block gas limit. | Keep split count reasonable (< 50) |
| Loan source iteration | `_totalBorrowedFrom` iterates all loan sources. If a revnet accumulates many distinct (terminal, token) pairs, gas costs increase for every borrow/repay operation. | Practically bounded (< 10 sources typical) |

## Security Properties to Verify

These MUST hold. If you can break any of them, it's a finding:

1. **Collateral conservation**: `totalCollateralOf[revnetId]` == sum of `loan.collateral` for all active loans of that revnet.
2. **Borrowed amount conservation**: `totalBorrowedFrom[revnetId][terminal][token]` == sum of `loan.amount` for all active loans from that source.
3. **No double-mint collateral**: Repaying a loan mints collateral back exactly once. A repaid loan cannot be repaid again.
4. **No zero-collateral loans**: Every active loan has `collateral > 0` and `amount > 0`.
5. **Liquidation only after expiry**: Loans can only be liquidated after `LOAN_LIQUIDATION_DURATION` (3650 days).
6. **Auto-issuance single-claim**: Each `(revnetId, stageId, beneficiary)` tuple can only be claimed once. The amount is zeroed before minting.
7. **Stage immutability**: After deployment, no function can modify a revnet's rulesets, issuance parameters, or cashOutTaxRate.
8. **Fee collection**: Cash-out fees and loan fees flow to the fee revnet. If fee payment fails, funds are returned to the originating project (not lost, not kept by the caller).
9. **Sucker privilege isolation**: Only addresses registered in `SUCKER_REGISTRY` for a revnet get 0% cashout tax. The `_isSuckerOf` check cannot be bypassed.
10. **Loan ownership**: Only the ERC-721 owner of a loan can repay it or reallocate its collateral.
