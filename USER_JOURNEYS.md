# User Journeys -- revnet-core-v6

Every user path through the Revnet + Loans system. For each journey: entry point, key parameters, state changes, events, and edge cases.

Read [SKILLS.md](./SKILLS.md) for the complete function reference. Read [ARCHITECTURE.md](./ARCHITECTURE.md) for the system overview.

---

## 1. Deploy a New Revnet

**Entry point:** `REVDeployer.deployFor(revnetId=0, configuration, terminalConfigurations, suckerDeploymentConfiguration)` (4-arg version, deploys with default empty 721 hook)

Or: `REVDeployer.deployFor(revnetId=0, configuration, terminalConfigurations, suckerDeploymentConfiguration, tiered721HookConfiguration, allowedPosts)` (6-arg version, deploys with configured 721 tiers and optional croptop posts)

**Key parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `revnetId` | `uint256` | Set to 0 to deploy a new revnet. |
| `configuration.description` | `REVDescription` | `name`, `ticker`, `uri`, `salt` for the ERC-20 token. |
| `configuration.baseCurrency` | `uint32` | 1 = ETH, 2 = USD. Determines the denomination for issuance weights. |
| `configuration.splitOperator` | `address` | The address that will manage splits, 721 tiers, and suckers. |
| `configuration.stageConfigurations` | `REVStageConfig[]` | One or more stages defining the revnet's economics. |
| `terminalConfigurations` | `JBTerminalConfig[]` | Which terminals and tokens the revnet accepts. |
| `suckerDeploymentConfiguration` | `REVSuckerDeploymentConfig` | Cross-chain sucker config. Set `salt = bytes32(0)` to skip. |

**What happens (in order):**

1. `revnetId = PROJECTS.count() + 1` (next available ID)
2. `_makeRulesetConfigurations` converts stages to JBRulesetConfigs:
   - Validates: at least one stage, `startsAtOrAfter` strictly increasing, `cashOutTaxRate < MAX`, splits required if `splitPercent > 0`
   - Each stage becomes a ruleset with: duration = `issuanceCutFrequency`, weight = `initialIssuance`, weightCutPercent = `issuanceCutPercent`, data hook = REVDeployer address
   - Fund access limits: unlimited surplus allowance per terminal/token (for loans)
   - Encoded configuration hash computed from economic parameters
   - Auto-issuance amounts stored: `amountToAutoIssue[revnetId][block.timestamp + i][beneficiary] += count`
3. `CONTROLLER.launchProjectFor` creates the Juicebox project, minting the ERC-721 to REVDeployer
4. Cash-out delay set if first stage's `startsAtOrAfter` has already passed (existing revnet deploying to new chain)
5. `CONTROLLER.deployERC20For` deploys the project's ERC-20 token
6. Buyback pools initialized for each terminal token via `_tryInitializeBuybackPoolFor` (try-catch, silent failure OK)
7. Suckers deployed if `suckerDeploymentConfiguration.salt != bytes32(0)`
8. Config hash stored: `hashedEncodedConfigurationOf[revnetId] = encodedConfigurationHash`
9. **4-arg version only:** Default empty 721 hook deployed, split operator gets all 721 permissions
10. **6-arg version only:** Configured 721 hook deployed with prevention flags applied, croptop posts configured if any

**Events:**
- `DeployRevnet(revnetId, configuration, terminalConfigurations, suckerDeploymentConfiguration, rulesetConfigurations, encodedConfigurationHash, caller)`
- `StoreAutoIssuanceAmount(revnetId, stageId, beneficiary, count, caller)` for each auto-issuance on this chain
- `DeploySuckers(...)` if suckers are deployed
- `SetCashOutDelay(revnetId, cashOutDelay, caller)` if applicable

**Edge cases:**
- If `startsAtOrAfter = 0` for the first stage, `block.timestamp` is used. The stage starts immediately.
- Auto-issuances with `chainId != block.chainid` are included in the config hash but not stored on this chain.
- Auto-issuances with `count = 0` are skipped (not stored, not included in config hash).
- Buyback pool initialization silently fails if the pool already exists.
- The `assert` on `launchProjectFor` return value catches project ID mismatches (should never happen).

---

## 2. Convert an Existing Juicebox Project to a Revnet

**Entry point:** `REVDeployer.deployFor(revnetId=<existingProjectId>, configuration, terminalConfigurations, suckerDeploymentConfiguration)`

**Prerequisites:**
- Caller must own the project's ERC-721 NFT
- Project must have no controller and no rulesets (blank project)

**What happens:**

1. `_msgSender()` must equal `PROJECTS.ownerOf(revnetId)` (owner check)
2. Project NFT transferred from owner to REVDeployer via `safeTransferFrom` -- **irreversible**
3. `CONTROLLER.launchRulesetsFor` initializes rulesets for the existing project
4. `CONTROLLER.setUriOf` sets the project's metadata URI
5. Cash-out delay applied if first stage has already started
6. Same remaining steps as new deployment (ERC-20, buyback pools, suckers, 721 hook)

**Events:**
- `DeployRevnet(revnetId, configuration, terminalConfigurations, suckerDeploymentConfiguration, rulesetConfigurations, encodedConfigurationHash, caller)`
- `StoreAutoIssuanceAmount(revnetId, stageId, beneficiary, count, caller)` for each auto-issuance on this chain
- `DeploySuckers(...)` if suckers are deployed
- `SetCashOutDelay(revnetId, cashOutDelay, caller)` if applicable

**Edge cases:**
- This is a **one-way operation**. The project NFT is permanently locked in REVDeployer.
- `launchRulesetsFor` reverts if rulesets already exist. `setControllerOf` reverts if a controller is already set.
- Useful in deploy scripts where the project ID is needed before configuration (e.g., for cross-chain sucker peer mappings).

---

## 3. Pay a Revnet

**Entry point:** `JBMultiTerminal.pay(projectId, token, amount, beneficiary, minReturnedTokens, memo, metadata)`

This is a standard Juicebox payment, but REVDeployer intervenes as the data hook.

**What happens:**

1. Terminal records payment in store
2. Store calls `REVDeployer.beforePayRecordedWith(context)`:
   - Calls 721 hook's `beforePayRecordedWith` for split specs (tier purchases)
   - Computes `projectAmount = context.amount.value - totalSplitAmount`
   - Calls buyback hook's `beforePayRecordedWith` with reduced amount context
   - Scales weight: `weight = mulDiv(weight, projectAmount, context.amount.value)` (or 0 if `projectAmount == 0`)
   - Returns merged hook specs: [721 hook spec, buyback hook spec]
3. Store calculates token count using the modified weight
4. Terminal mints tokens via controller
5. Terminal executes hook specs:
   - 721 hook processes tier purchases
   - Buyback hook processes swap (if applicable)

**Preview**: Call `JBMultiTerminal.previewPayFor(revnetId, token, amount, beneficiary, metadata)` to simulate the full payment including REVDeployer's data hook effects (buyback routing, 721 tier splits, weight adjustment). Returns the expected token count and hook specifications. When the buyback hook is active, noop specs may carry routing diagnostics (TWAP tick, liquidity, pool ID) even when the protocol mint path wins.

**Events:** No revnet-specific events. The payment is handled by `JBMultiTerminal` and `JBController` (see nana-core-v6). REVDeployer's `beforePayRecordedWith` is a `view` function and emits nothing.

**Edge cases:**
- If the buyback hook determines a DEX swap is better, weight = 0 and the buyback hook spec receives the full project amount. The buyback hook buys tokens on the DEX and mints them to the payer.
- If `totalSplitAmount >= context.amount.value`, `projectAmount = 0`, weight = 0, and no tokens are minted by the terminal. All funds go to 721 tier splits.
- If no 721 hook is set (`tiered721HookOf[revnetId] == address(0)`), only the buyback hook is consulted.

---

## 4. Cash Out from a Revnet

**Entry point:** `JBMultiTerminal.cashOutTokensOf(holder, projectId, tokenCount, token, minTokensReclaimed, beneficiary, metadata)`

**What happens:**

1. Terminal records cash-out in store
2. Store calls `REVDeployer.beforeCashOutRecordedWith(context)`:
   - **If sucker:** Returns 0% tax, full cash-out count, no hooks (fee exempt)
   - **If cash-out delay active:** Reverts with `REVDeployer_CashOutDelayNotFinished`
   - **If no tax or no fee terminal:** Returns parameters unchanged
   - **Otherwise:** Splits cash-out into fee portion (2.5%) and non-fee portion:
     - `feeCashOutCount = mulDiv(cashOutCount, 25, 1000)`
     - `nonFeeCashOutCount = cashOutCount - feeCashOutCount`
     - Computes `postFeeReclaimedAmount` via bonding curve for non-fee tokens
     - Computes `feeAmount` via bonding curve for fee tokens (on remaining surplus)
     - Returns `nonFeeCashOutCount` as the adjusted cash-out count + hook spec for fee
3. Terminal burns ALL of the user's specified token count
4. Terminal transfers the reclaimed amount to the beneficiary
5. Terminal calls `REVDeployer.afterCashOutRecordedWith(context)`:
   - Transfers fee amount from terminal to this contract
   - Pays fee to fee revnet's terminal via `feeTerminal.pay`
   - On failure: returns funds to the originating project via `addToBalanceOf`

**Preview**: Call `JBMultiTerminal.previewCashOutFrom(holder, revnetId, cashOutCount, tokenToReclaim, beneficiary, metadata)` to simulate the full cash out including REVDeployer's data hook effects (fee splitting, tax rate). Returns the expected reclaim amount and hook specifications. For a simpler estimate without data hook effects, use `JBTerminalStore.currentTotalReclaimableSurplusOf(revnetId, cashOutCount, decimals, currency)`.

**Events:** No revnet-specific events. Cash-out events are emitted by `JBMultiTerminal` and `JBController`. REVDeployer's `beforeCashOutRecordedWith` is a `view` function. The `afterCashOutRecordedWith` hook processes fees but does not emit events.

**Edge cases:**
- Suckers bypass both the cash-out fee AND the cash-out delay. The `_isSuckerOf` check is the only gate.
- `cashOutTaxRate == 0` means no tax and no revnet fee. The terminal's 2.5% protocol fee only applies up to the `feeFreeSurplusOf` amount (round-trip prevention), not the full reclaim.
- Micro cash-outs (< 40 wei at 2.5%) round `feeCashOutCount` to 0, bypassing the fee. Gas cost far exceeds the bypassed fee.
- The fee is paid to `FEE_REVNET_ID`, not `REV_ID`. These may be different projects.
- Both the revnet fee and the terminal protocol fee apply. The revnet fee is computed first (at the data hook level, by splitting the cashout token count into fee and non-fee portions), then the terminal's 2.5% protocol fee is applied to all outbound fund amounts (both the beneficiary's reclaim and the hook-forwarded fee amount).

---

## 5. Borrow Against Revnet Tokens (REVLoans)

**Entry point:** `REVLoans.borrowFrom(revnetId, source, minBorrowAmount, collateralCount, beneficiary, prepaidFeePercent)`

**Prerequisites:**
- Caller must hold `collateralCount` revnet ERC-20 tokens
- Caller must grant `BURN_TOKENS` permission to the REVLoans contract for the revnet's project ID via `JBPermissions.setPermissionsFor()`. Without this, the transaction reverts in `JBController.burnTokensOf` with `JBPermissioned_Unauthorized`.

**Key parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `revnetId` | `uint256` | The revnet to borrow from. |
| `source` | `REVLoanSource` | `{token, terminal}` -- which terminal and token to borrow. |
| `minBorrowAmount` | `uint256` | Slippage protection -- revert if you'd get less. |
| `collateralCount` | `uint256` | Number of revnet tokens to burn as collateral. |
| `beneficiary` | `address payable` | Receives the borrowed funds and fee payment tokens. |
| `prepaidFeePercent` | `uint256` | 25-500 (2.5%-50% of MAX_FEE=1000). Higher = longer interest-free window. |

**What happens:**

1. **Validation:**
   - `collateralCount > 0` (no zero-collateral loans)
   - `source.terminal` is registered for the revnet in the directory
   - `prepaidFeePercent` in range [25, 500]
2. **Loan ID generation:** `revnetId * 1_000_000_000_000 + (++totalLoansBorrowedFor[revnetId])`
3. **Loan creation in storage:**
   - `source`, `createdAt = block.timestamp`, `prepaidFeePercent`, `prepaidDuration = mulDiv(prepaidFeePercent, 3650 days, 500)`
4. **Borrow amount calculation:**
   - `totalSurplus` from all terminals (aggregated via `JBSurplus.currentSurplusOf`)
   - `totalBorrowed` from all loan sources (aggregated via `_totalBorrowedFrom`)
   - `borrowAmount = JBCashOuts.cashOutFrom(surplus + borrowed, collateral, supply + totalCollateral, cashOutTaxRate)`
5. **Validation:** `borrowAmount > 0`, `borrowAmount >= minBorrowAmount`
6. **Source fee:** `JBFees.feeAmountFrom(borrowAmount, prepaidFeePercent)`
7. **`_adjust` executes:**
   - Writes `loan.amount = borrowAmount` and `loan.collateral = collateralCount` to storage (CEI)
   - `_addTo`:
     - Registers the source if first time
     - Increments `totalBorrowedFrom`
     - Calls `terminal.useAllowanceOf` to pull funds (incurs 2.5% protocol fee automatically)
     - Pays REV fee (1%) to `REV_ID` via `feeTerminal.pay` (try-catch; zeroed on failure)
     - Transfers remaining: `netAmountPaidOut - revFeeAmount - sourceFeeAmount` to beneficiary
   - `_addCollateralTo`: increments `totalCollateralOf`, burns collateral via `CONTROLLER.burnTokensOf`
   - Pays source fee to revnet via `terminal.pay` (try-catch — on failure, returns fee amount to beneficiary)
8. **Mint loan ERC-721** to `_msgSender()`

**Events:** `Borrow(loanId, revnetId, loan, source, borrowAmount, collateralCount, sourceFeeAmount, beneficiary, caller)`

**Edge cases:**
- Revnets always deploy an ERC-20 at creation, so collateral is always ERC-20 tokens (never credits).
- The `minBorrowAmount` check is against the raw bonding curve output, BEFORE fees are deducted. The actual amount received is less.
- `prepaidDuration` at minimum (25): `25 * 3650 days / 500 = 182.5 days`. At maximum (500): `500 * 3650 days / 500 = 3650 days`.
- Both the REV fee payment and the source fee payment failures are non-fatal. If either `feeTerminal.pay` or `source.terminal.pay` reverts, the fee amount is transferred to the beneficiary instead.
- Loan NFT is minted to `_msgSender()`, not `beneficiary`. The caller owns the loan; the beneficiary receives the funds.

---

## 6. Repay a Loan

**Entry point:** `REVLoans.repayLoan(loanId, maxRepayBorrowAmount, collateralCountToReturn, beneficiary, allowance)`

**Key parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `loanId` | `uint256` | The loan to repay (from the ERC-721). |
| `maxRepayBorrowAmount` | `uint256` | Maximum amount willing to pay. Use `type(uint256).max` for "whatever it costs." |
| `collateralCountToReturn` | `uint256` | How many collateral tokens to get back (up to `loan.collateral`). |
| `beneficiary` | `address payable` | Receives the re-minted collateral tokens and fee payment tokens. |
| `allowance` | `JBSingleAllowance` | Optional permit2 data. Set `amount = 0` to skip. |

**What happens:**

1. **Authorization:** `_ownerOf(loanId) == _msgSender()` (only loan NFT owner can repay)
2. **Collateral check:** `collateralCountToReturn <= loan.collateral`
3. **Calculate new borrow amount** for remaining collateral via bonding curve:
   - `newBorrowAmount = _borrowAmountFrom(loan, revnetId, loan.collateral - collateralCountToReturn)`
   - Verify `newBorrowAmount <= loan.amount` (collateral value hasn't increased enough to over-collateralize)
   - `repayBorrowAmount = loan.amount - newBorrowAmount`
4. **Nothing-to-do check:** Reverts if `repayBorrowAmount == 0 && collateralCountToReturn == 0`
5. **Source fee calculation:**
   - If within prepaid window (`timeSinceCreated <= prepaidDuration`): fee = 0
   - If expired (`timeSinceCreated >= LOAN_LIQUIDATION_DURATION`): revert `REVLoans_LoanExpired`
   - Otherwise: linear fee based on time elapsed beyond prepaid window
   - `repayBorrowAmount += sourceFeeAmount` (fee added to repayment)
6. **Accept funds:** `_acceptFundsFor` handles native token (uses `msg.value`) or ERC-20 (with optional permit2)
7. **Max repay check:** `repayBorrowAmount <= maxRepayBorrowAmount`
8. **Execute repay** via `_repayLoan`:
   - **Full repay** (`collateralCountToReturn == loan.collateral`): burns original NFT, calls `_adjust` with amounts zeroed, deletes loan, returns same loan ID
   - **Partial repay:** burns original NFT, creates new loan with reduced amount/collateral, copies `createdAt`/`prepaidFeePercent`/`prepaidDuration` from original, mints new NFT
9. **Refund excess:** If `maxRepayBorrowAmount > repayBorrowAmount`, transfers the difference back to `_msgSender()`

**Events:** `RepayLoan(loanId, revnetId, paidOffLoanId, loan, paidOffLoan, repayBorrowAmount, sourceFeeAmount, collateralCountToReturn, beneficiary, caller)`

**Edge cases:**
- The source fee on repay is time-proportional. At the boundary of the prepaid window, it jumps from 0 to a small amount.
- Partial repay creates a new loan NFT with a new loan ID but preserves `createdAt` and `prepaidFeePercent`. The prepaid window clock doesn't reset.
- If the collateral has increased in value since borrowing (surplus grew), `newBorrowAmount > loan.amount` triggers `REVLoans_NewBorrowAmountGreaterThanLoanAmount`. The borrower should use `reallocateCollateralFromLoan` instead.
- For ERC-20 repayments, the contract tries standard `transferFrom` first. If allowance is insufficient, it falls through to permit2.
- `msg.value` is used directly for native token repayments (overrides `maxRepayBorrowAmount`).

---

## 7. Get Liquidated

**Entry point:** `REVLoans.liquidateExpiredLoansFrom(revnetId, startingLoanId, count)`

**Permissionless.** Anyone can call this to clean up expired loans.

**Key parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `revnetId` | `uint256` | The revnet to liquidate loans from. |
| `startingLoanId` | `uint256` | The LOAN NUMBER (not full loan ID) to start iterating from. |
| `count` | `uint256` | How many loan numbers to iterate over. |

**What happens (per loan in range):**

1. Construct full loan ID: `revnetId * 1_000_000_000_000 + (startingLoanId + i)`
2. Read loan from storage. If `createdAt == 0`, skip (already repaid or liquidated).
3. Check ownership. If `_ownerOf(loanId) == address(0)`, skip (already burned).
4. Check expiry: `block.timestamp > loan.createdAt + LOAN_LIQUIDATION_DURATION` (strictly greater than)
5. Burn the loan NFT via `_burn(loanId)`
6. Delete loan data: `delete _loanOf[loanId]`
7. Decrement `totalCollateralOf[revnetId]` by `loan.collateral`
8. Decrement `totalBorrowedFrom[revnetId][terminal][token]` by `loan.amount`

**Events:** `Liquidate(loanId, revnetId, loan, caller)` for each liquidated loan

**Edge cases:**
- The collateral was burned when the loan was created. There is nothing to "seize" -- liquidation is purely bookkeeping cleanup.
- The borrower retains whatever funds they borrowed. The burned collateral tokens are permanently lost.
- `startingLoanId` is the loan NUMBER within the revnet, not the full loan ID. The function constructs full IDs internally.
- Gaps in the loan ID sequence (from repaid or already-liquidated loans) are skipped via the `createdAt == 0` check.
- Gas cost scales linearly with `count`. Choose parameters carefully to avoid iterating over many empty slots.
- The `>` comparison means a loan is liquidatable starting at `createdAt + LOAN_LIQUIDATION_DURATION + 1` second.

---

## 8. Reallocate Collateral Between Loans

**Entry point:** `REVLoans.reallocateCollateralFromLoan(loanId, collateralCountToTransfer, source, minBorrowAmount, collateralCountToAdd, beneficiary, prepaidFeePercent)`

**Purpose:** If a loan's collateral has appreciated (surplus grew, or tax rate decreased), extract excess collateral and use it to open a new loan.

**Key parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `loanId` | `uint256` | The existing loan to take collateral from. |
| `collateralCountToTransfer` | `uint256` | Tokens to move from existing loan to new loan. |
| `source` | `REVLoanSource` | Must match the existing loan's source (same terminal + token). |
| `minBorrowAmount` | `uint256` | Slippage protection for the new loan. |
| `collateralCountToAdd` | `uint256` | Additional fresh tokens to add to the new loan (from caller's balance). |
| `beneficiary` | `address payable` | Receives proceeds from the new loan. |
| `prepaidFeePercent` | `uint256` | For the new loan (25-500). |

**What happens:**

1. **Authorization:** `_ownerOf(loanId) == _msgSender()`
2. **Source match:** New loan source must match existing loan source (prevents cross-source value extraction)
3. **`_reallocateCollateralFromLoan`:**
   - Burns original loan NFT
   - Validates `collateralCountToTransfer <= loan.collateral`
   - Computes `newCollateralCount = loan.collateral - collateralCountToTransfer`
   - Computes `borrowAmount = _borrowAmountFrom(loan, revnetId, newCollateralCount)`
   - Validates `borrowAmount >= loan.amount` (remaining collateral must still cover the original loan amount)
   - Creates replacement loan with original values
   - Calls `_adjust` to reduce collateral (returns excess tokens to caller via `_returnCollateralFrom`)
   - Mints replacement loan NFT to caller
   - Deletes original loan data
4. **`borrowFrom`:** Opens a new loan with `collateralCountToTransfer + collateralCountToAdd` as collateral
   - The `collateralCountToTransfer` tokens were just re-minted to the caller in step 3
   - The `collateralCountToAdd` tokens come from the caller's existing balance
   - Both are burned as collateral for the new loan

**Events:**
- `ReallocateCollateral(loanId, revnetId, reallocatedLoanId, reallocatedLoan, removedCollateralCount, caller)`
- `Borrow(newLoanId, revnetId, ...)` from the `borrowFrom` call

**Edge cases:**
- This function is NOT payable. Any ETH sent with the call is rejected at the EVM level.
- The original loan's `createdAt` and `prepaidFeePercent` are preserved on the replacement loan. The new loan gets fresh values.
- If `collateralCountToTransfer == loan.collateral`, the replacement loan has 0 collateral and must have `borrowAmount >= loan.amount` (which requires the bonding curve to return 0 for 0 collateral, which it does). But `borrowAmount = 0 < loan.amount` would revert. So you can't transfer ALL collateral -- some must remain.
- Between `_reallocateCollateralFromLoan` and `borrowFrom`, collateral tokens are minted to the caller and then immediately burned. If the caller is a contract with a `receive` function that re-enters, verify this is safe.

---

## 9. Claim Auto-Issuance

**Entry point:** `REVDeployer.autoIssueFor(revnetId, stageId, beneficiary)`

**Permissionless.** Anyone can call this on behalf of any beneficiary.

**Key parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `revnetId` | `uint256` | The revnet to claim from. |
| `stageId` | `uint256` | The stage ID (= `block.timestamp + stageIndex` from deployment). |
| `beneficiary` | `address` | The address to receive the tokens. |

**What happens:**

1. `CONTROLLER.getRulesetOf(revnetId, stageId)` retrieves the ruleset
2. Validates `ruleset.start <= block.timestamp` (stage has started)
3. Reads `count = amountToAutoIssue[revnetId][stageId][beneficiary]`
4. Validates `count > 0`
5. **Zeroes the amount BEFORE minting** (CEI pattern): `amountToAutoIssue[...] = 0`
6. `CONTROLLER.mintTokensOf(revnetId, count, beneficiary, "", useReservedPercent=false)`

**Events:** `AutoIssue(revnetId, stageId, beneficiary, count, caller)`

**Edge cases:**
- `useReservedPercent = false` means the FULL `count` goes to the beneficiary. No split percent is applied.
- Auto-issuance is one-time per (revnetId, stageId, beneficiary). Once claimed, `amountToAutoIssue` is zero and calling again reverts with `REVDeployer_NothingToAutoIssue`.
- The `stageId` must exactly match the value stored during deployment. If the deployment timestamp assumption doesn't hold (see RISKS.md S-3), the stage ID may be wrong and the claim will fail.
- Auto-issuances for other chains (where `chainId != block.chainid`) are not stored on this chain and cannot be claimed here.

---

## 10. Burn Held Tokens

**Entry point:** `REVDeployer.burnHeldTokensOf(revnetId)`

**Permissionless.** Anyone can call this.

**Purpose:** When reserved token splits don't sum to 100%, the remainder goes to the project owner (REVDeployer). This function burns those tokens to prevent them from sitting idle.

**What happens:**

1. Reads REVDeployer's token balance for the revnet
2. Reverts with `REVDeployer_NothingToBurn` if balance is 0
3. Burns all held tokens via `CONTROLLER.burnTokensOf`

**Events:** `BurnHeldTokens(revnetId, count, caller)`

---

## 11. Change Split Operator

**Entry point:** `REVDeployer.setSplitOperatorOf(revnetId, newSplitOperator)`

**Authorization:** Only the current split operator can call this.

**What happens:**

1. `_checkIfIsSplitOperatorOf(revnetId, _msgSender())` verifies caller is current operator
2. Revokes all permissions from old operator: `_setPermissionsFor(this, _msgSender(), revnetId, empty)`
3. Grants all split operator permissions to new operator: `_setSplitOperatorOf(revnetId, newSplitOperator)`

**Default permissions (9):** SET_SPLIT_GROUPS, SET_BUYBACK_POOL, SET_BUYBACK_TWAP, SET_PROJECT_URI, ADD_PRICE_FEED, SUCKER_SAFETY, SET_BUYBACK_HOOK, SET_ROUTER_TERMINAL, SET_TOKEN_METADATA

**Additional permissions (if not prevented by 721 hook deployment flags):** ADJUST_721_TIERS, SET_721_METADATA, MINT_721, SET_721_DISCOUNT_PERCENT

**Events:** `ReplaceSplitOperator(revnetId, newSplitOperator, caller)`

**Edge cases:**
- The split operator is singular. There can only be one at a time.
- Setting `newSplitOperator = address(0)` effectively abandons the operator role. Nobody can change splits after that.
- The old operator's permissions are fully revoked (set to empty array), not just the split-specific ones.

---

## 12. Deploy Suckers for an Existing Revnet

**Entry point:** `REVDeployer.deploySuckersFor(revnetId, suckerDeploymentConfiguration)`

**Authorization:** Only the split operator can call this. The current stage must allow sucker deployment (bit 2 of `extraMetadata`).

**What happens:**

1. `_checkIfIsSplitOperatorOf(revnetId, _msgSender())`
2. Reads current ruleset metadata
3. Checks `(metadata.metadata >> 2) & 1 == 1` (third bit = allow suckers)
4. Deploys suckers via `SUCKER_REGISTRY.deploySuckersFor` using stored config hash

**Events:** `DeploySuckers(revnetId, encodedConfigurationHash, suckerDeploymentConfiguration, caller)`

**Edge cases:**
- The `extraMetadata` bit check means sucker deployment can be disabled for specific stages. If the current stage doesn't allow it, the transaction reverts.
- The `encodedConfigurationHash` used for the salt comes from the stored hash, not a newly computed one. This ensures cross-chain consistency.

---

## 13. Stage Transitions (Automatic)

**No entry point.** Stage transitions happen automatically via the Juicebox rulesets system.

**How it works:**

Each stage is a JBRuleset with:
- `duration = issuanceCutFrequency` (e.g., 30 days)
- `weight = initialIssuance`
- `weightCutPercent = issuanceCutPercent`
- `mustStartAtOrAfter = startsAtOrAfter`

When a stage's duration expires, it either:
1. **Cycles:** If no later stage is ready to start, the current stage repeats with decayed weight (`weight *= (1 - weightCutPercent/1e9)`)
2. **Transitions:** If the next stage's `startsAtOrAfter` has been reached, the next stage activates with its own `initialIssuance`

**Impact on active loans:**

When a stage transition changes `cashOutTaxRate`:
- `_borrowableAmountFrom` uses the CURRENT stage's `cashOutTaxRate`
- A higher tax rate reduces borrowable amount per unit of collateral
- A lower tax rate increases borrowable amount per unit of collateral
- Existing loans are NOT automatically adjusted -- they retain their original `amount`
- A loan can become under-collateralized if the new tax rate is higher (collateral's cash-out value drops below `loan.amount`)
- The protocol has no mechanism to force repayment -- only the 10-year expiry applies

**Impact on payments:**
- New payments use the new stage's issuance rate
- The buyback hook compares DEX price vs. new issuance rate for swap-vs-mint decisions

**Impact on cash-outs:**
- The bonding curve uses the new stage's `cashOutTaxRate`
- If the new stage has a higher tax rate, cash-outs return less
- If the new stage has a lower tax rate, cash-outs return more

**Edge cases:**
- If `issuanceCutFrequency = 0` (no duration), the stage never expires. It must be replaced by a later stage's `startsAtOrAfter`.
- Weight decay across many cycles (20,000+) requires progressive cache updates via `updateRulesetWeightCache()`. Without caching, operations revert with `WeightCacheRequired`.
- The issuance cut is applied per cycle. After N cycles: `weight = initialIssuance * (1 - issuanceCutPercent/1e9)^N`.

---

## Summary: Entry Points by Actor

| Actor | Function | Authorization |
|-------|----------|---------------|
| Anyone | `REVDeployer.deployFor(0, ...)` | None (deploys new revnet) |
| Project owner | `REVDeployer.deployFor(existingId, ...)` | Must own project NFT |
| Anyone | `JBMultiTerminal.pay(...)` | None |
| Token holder | `JBMultiTerminal.cashOutTokensOf(...)` | Must hold tokens |
| Token holder | `REVLoans.borrowFrom(...)` | Must hold tokens + grant `BURN_TOKENS` permission to REVLoans |
| Loan owner | `REVLoans.repayLoan(...)` | Must own loan NFT |
| Loan owner | `REVLoans.reallocateCollateralFromLoan(...)` | Must own loan NFT |
| Anyone | `REVLoans.liquidateExpiredLoansFrom(...)` | None (permissionless after 10 years) |
| Anyone | `REVDeployer.autoIssueFor(...)` | None (permissionless after stage starts) |
| Anyone | `REVDeployer.burnHeldTokensOf(...)` | None |
| Split operator | `REVDeployer.setSplitOperatorOf(...)` | Must be current split operator |
| Split operator | `REVDeployer.deploySuckersFor(...)` | Must be current split operator + stage allows it |
| Contract owner | `REVLoans.setTokenUriResolver(...)` | Must be Ownable owner of REVLoans |
