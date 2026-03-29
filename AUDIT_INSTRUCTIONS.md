# Audit Instructions -- revnet-core-v6

You are auditing the Revnet + Loans system for Juicebox V6. Revnets are autonomous, ownerless Juicebox projects with pre-programmed multi-stage tokenomics. REVLoans enables borrowing against locked revnet tokens using the bonding curve as the sole collateral valuation mechanism.

Read [RISKS.md](./RISKS.md) for the trust model and known risks. Read [ARCHITECTURE.md](./ARCHITECTURE.md) for the system overview. Read [SKILLS.md](./SKILLS.md) for the complete function reference. Then come back here.

## Scope

**In scope:**

| Contract | Lines | Role |
|----------|-------|------|
| `src/REVDeployer.sol` | ~19,746 bytes | Deploys revnets. Manages stages, splits, auto-issuance, buyback hook delegation, 721 hook deployment, suckers, split operator permissions, and all state storage. Split from original monolith to stay under EIP-170 (24,576 bytes). |
| `src/REVOwner.sol` | ~8,353 bytes (~310 lines) | Runtime hook contract. Implements `IJBRulesetDataHook` + `IJBCashOutHook`. Set as the `dataHook` in each revnet's ruleset metadata. Handles `beforePayRecordedWith`, `beforeCashOutRecordedWith`, `afterCashOutRecordedWith`, `hasMintPermissionFor`, and sucker verification. Stores `cashOutDelayOf` and `tiered721HookOf` mappings (set by REVDeployer via DEPLOYER-restricted setters). **Key audit focus: the `initialize()` one-shot pattern, DEPLOYER-restricted setter access control, and circular dependency with REVDeployer.** |
| `src/REVLoans.sol` | ~1,359 lines | Token-collateralized lending. Burns collateral on borrow, re-mints on repay. ERC-721 loan NFTs. Three-layer fee model. Permit2 integration. |
| `src/interfaces/` | ~525 | Interface definitions for both contracts |
| `src/structs/` | ~212 | All struct definitions |

**Dependencies (assumed correct, but verify integration points):**
- `@bananapus/core-v6` -- JBController, JBMultiTerminal, JBTerminalStore, JBTokens, JBPrices, JBRulesets
- `@bananapus/721-hook-v6` -- IJB721TiersHook, IJB721TiersHookDeployer
- `@bananapus/buyback-hook-v6` -- IJBBuybackHookRegistry
- `@bananapus/suckers-v6` -- IJBSuckerRegistry
- `@croptop/core-v6` -- CTPublisher
- `@openzeppelin/contracts` -- ERC721, ERC2771Context, Ownable, SafeERC20
- `@uniswap/permit2` -- IPermit2, IAllowanceTransfer
- `@prb/math` -- mulDiv

## The System in 90 Seconds

A **revnet** is a Juicebox project that nobody owns. REVDeployer deploys it and permanently holds its project NFT. REVOwner acts as the data hook for all payments and cash-outs (`dataHook` in ruleset metadata). The deployer/owner split was necessary to stay under the EIP-170 contract size limit. The revnet's economics are encoded as a sequence of **stages** that map 1:1 to Juicebox rulesets. Stages are immutable after deployment.

Each stage defines:
- **Initial issuance** (`initialIssuance`): tokens minted per unit of base currency
- **Issuance decay** (`issuanceCutFrequency` + `issuanceCutPercent`): how issuance decreases over time
- **Cash-out tax** (`cashOutTaxRate`): bonding curve parameter (0 = no tax, 9999 = max allowed)
- **Split percent** (`splitPercent`): percentage of minted tokens sent to reserved splits
- **Auto-issuances**: pre-configured token mints that can be claimed once per stage per beneficiary

**REVLoans** lets users borrow against their revnet tokens:
1. Burn tokens as collateral
2. Borrow up to the bonding curve cash-out value of those tokens
3. Pay a three-layer fee (2.5% protocol + 1% REV + 2.5%-50% source prepaid)
4. Receive an ERC-721 representing the loan
5. Repay anytime to re-mint collateral tokens
6. After 10 years, anyone can liquidate (collateral permanently lost)

## How Revnets Interact with Juicebox Core

Understanding this interaction is essential. REVDeployer wraps core Juicebox functions with revnet-specific logic.

### Payment Flow

```
User pays terminal
  -> Terminal calls JBTerminalStore.recordPaymentFrom()
    -> Store calls REVOwner.beforePayRecordedWith() [data hook]
      -> REVOwner reads tiered721HookOf from its own storage
      -> REVOwner calls 721 hook's beforePayRecordedWith() for split specs
      -> REVOwner calls buyback hook's beforePayRecordedWith() for swap decision
      -> REVOwner scales weight: mulDiv(weight, projectAmount, totalAmount)
      -> Returns merged specs: [721 hook spec, buyback hook spec]
    -> Store records payment with modified weight
  -> Terminal mints tokens via Controller
  -> Terminal executes pay hook specs (721 hook first, then buyback hook)
```

**Key insight:** The weight scaling in `REVOwner.beforePayRecordedWith` ensures the terminal only mints tokens proportional to the amount entering the project (excluding 721 tier split amounts). Without this scaling, payers would get token credit for the split portion too.

### Cash-Out Flow

```
User cashes out via terminal
  -> Terminal calls JBTerminalStore.recordCashOutFor()
    -> Store calls REVOwner.beforeCashOutRecordedWith() [data hook]
      -> If sucker: return 0% tax, full amount (fee exempt)
      -> If cashOutDelay not passed (reads from REVOwner storage): revert
      -> If cashOutTaxRate == 0 or no fee terminal: return as-is
      -> Otherwise: split cashOutCount into fee portion + non-fee portion
        -> Compute reclaim for non-fee portion via bonding curve
        -> Compute fee amount via bonding curve on remaining surplus
        -> Return modified cashOutCount + hook spec for fee payment
    -> Store records cash-out with modified parameters
  -> Terminal burns tokens
  -> Terminal transfers reclaimed amount to user
  -> Terminal calls REVOwner.afterCashOutRecordedWith() [cash-out hook]
    -> REVOwner pays fee to fee revnet terminal
    -> On failure: returns funds to originating project
```

**Key insight:** The cash-out fee is computed as a two-step bonding curve calculation, not a simple percentage of the reclaimed amount. This is because burning fewer tokens (non-fee portion) changes the surplus-to-supply ratio for the fee portion.

### Loan Flow

```
Borrower calls REVLoans.borrowFrom()
  -> Prerequisite: caller must have granted BURN_TOKENS permission to REVLoans via JBPermissions
  -> Enforce cash-out delay: resolve REVOwner from ruleset dataHook, check IREVOwner.cashOutDelayOf(revnetId) (stored on REVOwner)
  -> Validate: collateral > 0, terminal registered, prepaidFeePercent in range
  -> Generate loan ID: revnetId * 1T + loanNumber
  -> Create loan in storage
  -> Calculate borrowAmount via bonding curve:
    -> totalSurplus = aggregate from all terminals
    -> totalBorrowed = aggregate from all loan sources
    -> borrowable = JBCashOuts.cashOutFrom(surplus + borrowed, collateral, supply + totalCollateral, taxRate)
  -> Calculate source fee: JBFees.feeAmountFrom(borrowAmount, prepaidFeePercent)
  -> _adjust():
    -> Write loan.amount and loan.collateral to storage (CEI)
    -> _addTo(): pull funds via useAllowanceOf, pay REV fee, transfer to beneficiary
    -> _addCollateralTo(): burn collateral tokens via Controller
    -> Pay source fee to terminal
  -> Mint loan ERC-721 to borrower
```

**Key insight:** `_borrowableAmountFrom` includes `totalBorrowed` in the surplus calculation (`surplus + totalBorrowed`) and `totalCollateral` in the supply calculation (`totalSupply + totalCollateral`). This means outstanding loans don't reduce the borrowable amount for new loans -- the virtual surplus and virtual supply are used.

## Key State Variables

### REVDeployer Storage

| Variable | Purpose | Audit Focus |
|----------|---------|-------------|
| `amountToAutoIssue[revnetId][stageId][beneficiary]` | Premint tokens per stage per beneficiary | Single-claim enforcement (zeroed before mint) |
| `hashedEncodedConfigurationOf[revnetId]` | Config hash for cross-chain sucker validation | Gap: does NOT cover terminal configs |
| `_extraOperatorPermissions[revnetId]` | Custom permissions for split operator | Set during deploy based on 721 hook prevention flags |

### REVOwner Storage

| Variable | Purpose | Audit Focus |
|----------|---------|-------------|
| `DEPLOYER` | REVDeployer address | Set once via `initialize()`. **Not immutable** -- stored as a regular storage variable to break circular dependency. Verify `initialize()` can only be called once and with the correct address. Used to restrict access to `setCashOutDelayOf()` and `setTiered721HookOf()`. |
| `cashOutDelayOf[revnetId]` | Timestamp when cash-outs unlock | Set by REVDeployer via `setCashOutDelayOf()` (DEPLOYER-restricted). Applied only for existing revnets deployed to new chains. **Read by REVLoans via IREVOwner.** Verify only DEPLOYER can call the setter. |
| `tiered721HookOf[revnetId]` | 721 hook address | Set by REVDeployer via `setTiered721HookOf()` (DEPLOYER-restricted). Set once during deploy, never changed. **Read by REVOwner internally during pay hooks.** Verify only DEPLOYER can call the setter. |

### REVLoans Storage

| Variable | Purpose | Audit Focus |
|----------|---------|-------------|
| `_loanOf[loanId]` | Per-loan state (REVLoan struct) | Deleted on repay/liquidate; verify no stale reads |
| `totalCollateralOf[revnetId]` | Sum of all burned collateral for a revnet | Must match sum of active loan collaterals |
| `totalBorrowedFrom[revnetId][terminal][token]` | Total debt per loan source | Must match sum of active loan amounts per source |
| `totalLoansBorrowedFor[revnetId]` | Monotonically increasing loan counter | Used for loan ID generation; never decrements |
| `isLoanSourceOf[revnetId][terminal][token]` | Whether a source has been used | Only set to true, never back to false |
| `_loanSourcesOf[revnetId]` | Array of all loan sources | Only grows; iterated in `_totalBorrowedFrom` |

### REVLoan Struct (packed storage)

```solidity
struct REVLoan {
    uint112 amount;          // Borrowed amount in source token's decimals
    uint112 collateral;      // Number of revnet tokens burned as collateral
    uint48  createdAt;       // Block timestamp when loan was created
    uint16  prepaidFeePercent; // Fee percent prepaid (25-500, out of MAX_FEE=1000)
    uint32  prepaidDuration;   // Seconds of interest-free window
    REVLoanSource source;    // (token, terminal) pair
}
```

**Note:** `uint112` max is ~5.19e33. Amounts above this are checked in `_adjust` and revert with `REVLoans_OverflowAlert`.

## Priority Audit Areas

Audit in this order. Earlier items have higher blast radius:

### 1. Loan collateral valuation and manipulation

The bonding curve is the sole collateral oracle. Verify:

- `_borrowableAmountFrom` correctly aggregates surplus across all terminals
- `totalBorrowed` and `totalCollateral` adjustments in the virtual surplus/supply calculation are correct
- Stage transitions don't allow arbitrage (borrow under old tax rate, benefit from new rate)
- Rounding in `JBCashOuts.cashOutFrom` doesn't favor the borrower
- Cross-currency aggregation in `_totalBorrowedFrom` handles decimal normalization correctly
- Price feed failures (zero price) are handled gracefully (sources skipped, not reverted)

### 2. CEI pattern in loan operations

No reentrancy guard. Verify the CEI ordering in:

- `_adjust`: writes `loan.amount` and `loan.collateral` before `_addTo` / `_removeFrom` / `_addCollateralTo` / `_returnCollateralFrom`
- `borrowFrom`: `_adjust` before `_mint` (ERC-721 onReceived callback)
- `repayLoan`: `_burn` before `_adjust` before `_mint` (for partial repay)
- `reallocateCollateralFromLoan`: `_reallocateCollateralFromLoan` before `borrowFrom` -- two full loan operations in sequence
- `liquidateExpiredLoansFrom`: `_burn` and `delete` before storage updates

**Specific concern:** In `reallocateCollateralFromLoan`, the reallocation creates a new loan NFT and then `borrowFrom` creates another. Between these two operations, tokens are minted back to the caller (returned collateral) which are then immediately burned (new loan collateral). If `borrowFrom` triggers an external callback (via pay hooks or the ERC-721 mint), can the caller manipulate state between the two operations?

### 3. Data hook composition

REVOwner proxies between the terminal and two hooks. REVOwner reads `tiered721HookOf` and `cashOutDelayOf` from its own storage (set by REVDeployer via DEPLOYER-restricted setters). Verify:

- The 721 hook's `beforePayRecordedWith` is called with the full context, but the buyback hook's is called with a reduced amount. Is this always correct?
- When the 721 hook returns specs with `amount >= context.amount.value`, `projectAmount` is 0 and weight is 0. This means no tokens are minted by the terminal (all funds go to 721 splits). Verify this is safe -- does the buyback hook handle a zero-amount context gracefully?
- The `hookSpecifications` array sizing assumes at most one spec from each hook. Verify neither hook can return multiple specs.
- The weight scaling `mulDiv(weight, projectAmount, context.amount.value)` -- can this produce a weight of 0 when it shouldn't, or a weight > 0 when it should be 0?

### 4. Cash-out fee calculation

The two-step bonding curve fee calculation in `REVOwner.beforeCashOutRecordedWith`:

```solidity
feeCashOutCount = mulDiv(cashOutCount, FEE, MAX_FEE)  // 2.5% of tokens
nonFeeCashOutCount = cashOutCount - feeCashOutCount

postFeeReclaimedAmount = JBCashOuts.cashOutFrom(surplus, nonFeeCashOutCount, totalSupply, taxRate)
feeAmount = JBCashOuts.cashOutFrom(surplus - postFeeReclaimedAmount, feeCashOutCount, totalSupply - nonFeeCashOutCount, taxRate)
```

Verify:
- `postFeeReclaimedAmount + feeAmount <= directReclaim` (total <= what you'd get without fee splitting)
- Micro cash-outs (< 40 wei at 2.5%) round `feeCashOutCount` to zero, bypassing the fee. This is documented as economically insignificant. Verify.
- The `cashOutCount` returned to the terminal is `nonFeeCashOutCount`, but the terminal still burns the full `cashOutCount` tokens. **Open question**: Does the terminal burn the full original `cashOutCount` or only the `nonFeeCashOutCount`? Trace through `JBMultiTerminal.cashOutTokensOf()` to verify. If the full count is burned, the fee tokens are effectively destroyed -- this may be intentional (fee is taken from the surplus).

### 5. Permission model

REVDeployer grants wildcard permissions during construction:

```solidity
constructor() {
    _setPermission(SUCKER_REGISTRY, 0, MAP_SUCKER_TOKEN);     // All revnets
    _setPermission(LOANS, 0, USE_ALLOWANCE);                   // All revnets
    _setPermission(BUYBACK_HOOK, 0, SET_BUYBACK_POOL);        // All revnets
}
```

These are projectId=0 (wildcard) permissions. Verify:
- `JBPermissions` resolves wildcard correctly -- these grant the permission for ALL revnets owned by REVDeployer, not just project 0
- The LOANS contract can call `useAllowanceOf` on any revnet's terminal -- verify this is constrained by the bonding curve calculation in `borrowFrom`
- No other permission is granted at wildcard level

### 6. Auto-issuance timing

Stage IDs computed during deployment must match JBRulesets-assigned IDs:

```solidity
amountToAutoIssue[revnetId][block.timestamp + i][beneficiary] += count;
```

Later claimed via:
```solidity
(JBRuleset memory ruleset,) = CONTROLLER.getRulesetOf(revnetId, stageId);
if (ruleset.start > block.timestamp) revert REVDeployer_StageNotStarted(stageId);
```

Verify:
- JBRulesets assigns IDs as `latestId >= block.timestamp ? latestId + 1 : block.timestamp`. Does this produce `block.timestamp, block.timestamp+1, block.timestamp+2, ...` when all stages are queued in one transaction?
- What if another contract queued a ruleset for the same project in the same block? (Shouldn't be possible since REVDeployer owns the project, but verify.)
- `getRulesetOf` returns the ruleset by ID. If the stage hasn't started yet, `ruleset.start` is the derived start time, not the queue time. The timing guard uses `ruleset.start`, which is correct. But what if `startsAtOrAfter` is 0 for the first stage and `block.timestamp` is used? The stage starts immediately -- can auto-issuance be claimed in the same transaction as deployment?

### 7. Loan fee model

Three layers of fees on borrow:

1. **Protocol fee (2.5%)** -- charged by `useAllowanceOf` (JBMultiTerminal takes it automatically)
2. **REV fee (1%)** -- `JBFees.feeAmountFrom(borrowAmount, REV_PREPAID_FEE_PERCENT=10)` paid to REV revnet. Try-catch; zeroed on failure.
3. **Source prepaid fee (2.5%-50%)** -- `JBFees.feeAmountFrom(borrowAmount, prepaidFeePercent)` paid back to the revnet via `terminal.pay`. Try-catch; on failure the fee is refunded to the borrower instead of being paid to the revnet.

On repay, the source fee is time-proportional:

```solidity
if (timeSinceLoanCreated <= prepaidDuration) return 0;  // Free window
// After prepaid window: linear accrual
fullSourceFeeAmount = JBFees.feeAmountFrom(
    loan.amount - prepaid,
    mulDiv(timeSinceLoanCreated - prepaidDuration, MAX_FEE, LOAN_LIQUIDATION_DURATION - prepaidDuration)
);
sourceFeeAmount = mulDiv(fullSourceFeeAmount, amount, loan.amount);
```

Verify:
- The `prepaidDuration` calculation: `mulDiv(prepaidFeePercent, LOAN_LIQUIDATION_DURATION, MAX_PREPAID_FEE_PERCENT)`. At 2.5% (25), this is `25 * 3650 days / 500 = 182.5 days`. At 50% (500), it's `500 * 3650 days / 500 = 3650 days` (full duration). Is this the intended mapping?
- The linear accrual formula: at `timeSinceLoanCreated = LOAN_LIQUIDATION_DURATION`, the fee percent approaches MAX_FEE (100%). The borrower would owe the full remaining loan amount as a fee, making repayment impossible.
- At the boundary, `_determineSourceFeeAmount` reverts with `REVLoans_LoanExpired` before the fee reaches 100%. The revert uses `>` (not `>=`) so the exact boundary second is still repayable -- verify this matches the liquidation path which uses `<=`.

### 8. REVOwner initialization and circular dependency

REVOwner and REVDeployer have a circular dependency broken by a one-shot `initialize()` call. Deploy order: REVOwner first, then REVDeployer(owner=REVOwner), then REVOwner.initialize(deployer). Verify:

- `initialize()` can only be called once (subsequent calls revert)
- `DEPLOYER` is a storage variable, not immutable, to break the circular dependency
- Before `initialize()` is called, the DEPLOYER-restricted setters (`setCashOutDelayOf`, `setTiered721HookOf`) would reject calls, leaving `cashOutDelayOf` and `tiered721HookOf` unpopulated
- No path allows `initialize()` to be called with the wrong deployer address after the correct one is set
- Only DEPLOYER can call `setCashOutDelayOf()` and `setTiered721HookOf()` -- verify access control on these setters
- `cashOutDelayOf` and `tiered721HookOf` are stored on REVOwner (not REVDeployer) -- verify REVOwner reads from its own storage and the setters cannot be called by unauthorized addresses
- Both contracts define `FEE = 25` independently -- verify they stay in sync

## Invariants

Fuzzable properties that should hold for all valid inputs:

1. **Collateral accounting**: `totalCollateralOf[revnetId]` equals the sum of `_loanOf[loanId].collateral` for all active loans belonging to that revnet.
2. **Borrowed amount accounting**: `totalBorrowedFrom[revnetId][terminal][token]` equals the sum of `_loanOf[loanId].amount` for all active loans with that source.
3. **Loan NFT ownership**: The ERC-721 owner of a loan NFT is the only address authorized to repay, reallocate, or manage that loan (absent ROOT or explicit permission grants).
4. **No flash-loan profit**: Borrowing and repaying in the same block (zero time elapsed) should never yield a net profit to the borrower after all fees.
5. **Stage monotonicity**: Stage transitions are monotonically increasing in time -- a later stage's `startsAtOrAfter` is always strictly greater than the previous stage's.
6. **REVOwner initialization**: `DEPLOYER` is set exactly once via `initialize()` and matches the REVDeployer that references this REVOwner via `OWNER()`. Only the initialized `DEPLOYER` can call `setCashOutDelayOf()` and `setTiered721HookOf()`.

## How to Run Tests

```bash
cd revnet-core-v6
npm install
forge build
forge test

# Run with verbosity for debugging
forge test -vvvv --match-test testName

# Write a PoC
forge test --match-path test/audit/ExploitPoC.t.sol -vvv

# Gas analysis
forge test --gas-report
```

## Anti-Patterns to Hunt

| Pattern | Where | Why |
|---------|-------|-----|
| `mulDiv` rounding direction | `REVOwner.beforePayRecordedWith` weight scaling, `_determineSourceFeeAmount`, `_borrowableAmountFrom` | Rounding in borrower's favor compounds over many loans |
| Source fee `pay` silently caught on revert | `REVLoans._adjust` try-catch block | The catch block silently returns funds to the borrower instead of paying the fee, which could allow borrowers to intentionally cause fee payment reverts to avoid paying the source fee |
| `delete _loanOf[loanId]` after external calls | `_repayLoan`, `_reallocateCollateralFromLoan` | Verify delete happens after all references to the loan are resolved |
| Loan storage read after `_adjust` mutates it | `_repayLoan` partial repay path | `_adjust` modifies `loan` via storage pointer; subsequent reads see mutated values |
| Unbounded loop in `_totalBorrowedFrom` | Called during every borrow operation | Gas griefing if many distinct loan sources accumulate |
| `uint112` truncation | `_adjust` explicit check | Verify all paths that set `loan.amount` or `loan.collateral` go through `_adjust` |
| Permit2 try-catch swallowing | `_acceptFundsFor` | If permit fails, fall through to regular transfer. Is the state consistent? |
| ERC-721 `_mint` callback | `borrowFrom`, `_repayLoan`, `_reallocateCollateralFromLoan` | `onERC721Received` can re-enter. Verify all state is settled before mint. |

## Previous Audit Findings

No prior formal audit with finding IDs has been conducted on this codebase. All risk analysis is internal. See [RISKS.md](./RISKS.md) for the trust model and known risks.

## Coverage Gaps

- **Stage transition during active loans**: No test for borrowing under one stage's tax rate and the stage transitioning before repayment.
- **Multi-source loan aggregation**: `_totalBorrowedFrom` iterates all sources, but no test with >3 active sources testing gas and precision.
- **Concurrent borrow + cash out**: No test for a borrow and cash out on the same revnet in the same block.
- **Auto-issuance with sucker deployment**: No test for claiming auto-issuance on a cross-chain revnet during the cashOutDelay window.
- **Partial repay + reallocation**: No test for `reallocateCollateralFromLoan` with a partial repay in the same transaction.
- **Loan fee approaching 100%**: No test for repayment at `LOAN_LIQUIDATION_DURATION - 1 second` where the fee should be just under 100%.

## Error Reference

| Error | Contract | Trigger |
|-------|----------|---------|
| `REVDeployer_AutoIssuanceBeneficiaryZeroAddress` | REVDeployer | Auto-issuance configured with `beneficiary == address(0)` |
| `REVDeployer_CashOutDelayNotFinished` | REVDeployer | Cash-out attempted before `cashOutDelayOf[revnetId]` timestamp has passed |
| `REVDeployer_CashOutsCantBeTurnedOffCompletely` | REVDeployer | Stage configured with `cashOutTaxRate >= MAX_CASH_OUT_TAX_RATE` (10,000) |
| `REVDeployer_MustHaveSplits` | REVDeployer | Stage has `splitPercent > 0` but empty `splits` array |
| `REVDeployer_NothingToAutoIssue` | REVDeployer | `autoIssueFor` called but `amountToAutoIssue` is zero for the given beneficiary and stage |
| `REVDeployer_NothingToBurn` | REVDeployer | `burnFrom` called but REVDeployer holds zero tokens for the revnet |
| `REVDeployer_RulesetDoesNotAllowDeployingSuckers` | REVDeployer | `deploySuckersFor` called but current ruleset metadata disallows sucker deployment |
| `REVDeployer_StageNotStarted` | REVDeployer | `autoIssueFor` called for a stage whose `ruleset.start > block.timestamp` |
| `REVDeployer_StagesRequired` | REVDeployer | `deployFor` / `launchChainsFor` called with empty `stageConfigurations` array |
| `REVDeployer_StageTimesMustIncrease` | REVDeployer | Stage `startsAtOrAfter` timestamps are not strictly increasing |
| `REVDeployer_Unauthorized` | REVDeployer | Caller is not the split operator (for operator-gated functions) or not the project owner (for `launchChainsFor`) |
| `REVLoans_CashOutDelayNotFinished` | REVLoans | `borrowFrom` called during the 30-day cash-out delay period (cross-chain deployment protection) |
| `REVLoans_CollateralExceedsLoan` | REVLoans | `reallocateCollateralFromLoan` called with `collateralCountToReturn > loan.collateral` |
| `REVLoans_InvalidPrepaidFeePercent` | REVLoans | `prepaidFeePercent` outside `[MIN_PREPAID_FEE_PERCENT, MAX_PREPAID_FEE_PERCENT]` range (25-500) |
| `REVLoans_InvalidTerminal` | REVLoans | Loan source references a terminal not registered in `JBDirectory` for the revnet |
| `REVLoans_LoanExpired` | REVLoans | Repay/reallocation attempted after `LOAN_LIQUIDATION_DURATION` has elapsed since loan creation |
| `REVLoans_LoanIdOverflow` | REVLoans | Loan counter for a revnet exceeds 1 trillion (namespace collision with next revnet ID) |
| `REVLoans_NewBorrowAmountGreaterThanLoanAmount` | REVLoans | Partial repay would increase the loan's borrow amount above the original |
| `REVLoans_NoMsgValueAllowed` | REVLoans | `msg.value > 0` sent when the loan source token is not the native token |
| `REVLoans_NotEnoughCollateral` | REVLoans | `_reallocateCollateralFromLoan` attempts to remove more collateral than the loan holds |
| `REVLoans_NothingToRepay` | REVLoans | `repayLoan` called with both `repayBorrowAmount == 0` and `collateralCountToReturn == 0` |
| `REVLoans_OverMaxRepayBorrowAmount` | REVLoans | Actual repay cost (principal + accrued fee) exceeds caller's `maxRepayBorrowAmount` |
| `REVLoans_OverflowAlert` | REVLoans | Loan amount or collateral exceeds `uint112` max, or Permit2 amount exceeds `uint160` max |
| `REVLoans_PermitAllowanceNotEnough` | REVLoans | Permit2 allowance is less than the required transfer amount |
| `REVLoans_ReallocatingMoreCollateralThanBorrowedAmountAllows` | REVLoans | After reallocation, the remaining collateral's bonding curve value is less than the remaining borrow amount |
| `REVLoans_SourceMismatch` | REVLoans | Repay/reallocation called with a source (token, terminal) that does not match the loan's original source |
| `REVLoans_Unauthorized` | REVLoans | Caller is not the ERC-721 owner of the loan being managed |
| `REVLoans_UnderMinBorrowAmount` | REVLoans | Bonding curve returns a borrow amount below the caller's `minBorrowAmount` (slippage protection) |
| `REVLoans_ZeroBorrowAmount` | REVLoans | Bonding curve returns zero for the given collateral (e.g., zero surplus) |
| `REVLoans_ZeroCollateralLoanIsInvalid` | REVLoans | `borrowFrom` called with `collateralCount == 0` |

## Compiler and Version Info

- **Solidity**: 0.8.28
- **EVM target**: Cancun
- **Optimizer**: via-IR, 100 runs
- **Dependencies**: OpenZeppelin 5.x, PRBMath, Permit2, nana-core-v6, nana-721-hook-v6, nana-buyback-hook-v6, nana-suckers-v6
- **Build**: `forge build` (Foundry)

## How to Report Findings

For each finding:

1. **Title** -- one line, starts with severity (CRITICAL/HIGH/MEDIUM/LOW)
2. **Affected contract(s)** -- exact file path and line numbers
3. **Description** -- what is wrong, in plain language
4. **Trigger sequence** -- step-by-step, minimal steps to reproduce
5. **Impact** -- what an attacker gains, what a user loses (with numbers if possible)
6. **Proof** -- code trace showing the exact execution path, or a Foundry test
7. **Fix** -- minimal code change that resolves the issue

**Severity guide:**
- **CRITICAL**: Direct fund loss, collateral manipulation enabling undercollateralized loans, or permanent DoS.
- **HIGH**: Conditional fund loss, loan fee bypass, or broken invariant.
- **MEDIUM**: Value leakage, fee calculation inaccuracy, griefing.
- **LOW**: Informational, edge-case-only with no material impact.
