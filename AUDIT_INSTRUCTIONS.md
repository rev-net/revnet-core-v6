# Audit Instructions -- revnet-core-v6

You are auditing the Revnet + Loans system for Juicebox V6. Revnets are autonomous, ownerless Juicebox projects with pre-programmed multi-stage tokenomics. REVLoans enables borrowing against locked revnet tokens using the bonding curve as the sole collateral valuation mechanism.

Read [RISKS.md](./RISKS.md) for the trust model and known risks. Read [ARCHITECTURE.md](./ARCHITECTURE.md) for the system overview. Read [SKILLS.md](./SKILLS.md) for the complete function reference. Then come back here.

## Scope

**In scope:**

| Contract | Lines | Role |
|----------|-------|------|
| `src/REVDeployer.sol` | ~1,287 | Deploys revnets. Acts as data hook and cash-out hook for all revnets. Manages stages, splits, auto-issuance, buyback hook delegation, 721 hook deployment, suckers, and split operator permissions. |
| `src/REVLoans.sol` | ~1,359 | Token-collateralized lending. Burns collateral on borrow, re-mints on repay. ERC-721 loan NFTs. Three-layer fee model. Permit2 integration. |
| `src/interfaces/` | ~525 | Interface definitions for both contracts |
| `src/structs/` | ~150 | All struct definitions |

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

A **revnet** is a Juicebox project that nobody owns. REVDeployer deploys it, permanently holds its project NFT, and acts as the data hook for all payments and cash-outs. The revnet's economics are encoded as a sequence of **stages** that map 1:1 to Juicebox rulesets. Stages are immutable after deployment.

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
    -> Store calls REVDeployer.beforePayRecordedWith() [data hook]
      -> REVDeployer calls 721 hook's beforePayRecordedWith() for split specs
      -> REVDeployer calls buyback hook's beforePayRecordedWith() for swap decision
      -> REVDeployer scales weight: mulDiv(weight, projectAmount, totalAmount)
      -> Returns merged specs: [721 hook spec, buyback hook spec]
    -> Store records payment with modified weight
  -> Terminal mints tokens via Controller
  -> Terminal executes pay hook specs (721 hook first, then buyback hook)
```

**Key insight:** The weight scaling in `beforePayRecordedWith` ensures the terminal only mints tokens proportional to the amount entering the project (excluding 721 tier split amounts). Without this scaling, payers would get token credit for the split portion too.

### Cash-Out Flow

```
User cashes out via terminal
  -> Terminal calls JBTerminalStore.recordCashOutFor()
    -> Store calls REVDeployer.beforeCashOutRecordedWith() [data hook]
      -> If sucker: return 0% tax, full amount (fee exempt)
      -> If cashOutDelay not passed: revert
      -> If cashOutTaxRate == 0 or no fee terminal: return as-is
      -> Otherwise: split cashOutCount into fee portion + non-fee portion
        -> Compute reclaim for non-fee portion via bonding curve
        -> Compute fee amount via bonding curve on remaining surplus
        -> Return modified cashOutCount + hook spec for fee payment
    -> Store records cash-out with modified parameters
  -> Terminal burns tokens
  -> Terminal transfers reclaimed amount to user
  -> Terminal calls REVDeployer.afterCashOutRecordedWith() [cash-out hook]
    -> REVDeployer pays fee to fee revnet terminal
    -> On failure: returns funds to originating project
```

**Key insight:** The cash-out fee is computed as a two-step bonding curve calculation, not a simple percentage of the reclaimed amount. This is because burning fewer tokens (non-fee portion) changes the surplus-to-supply ratio for the fee portion.

### Loan Flow

```
Borrower calls REVLoans.borrowFrom()
  -> Prerequisite: caller must have granted BURN_TOKENS permission to REVLoans via JBPermissions
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
| `cashOutDelayOf[revnetId]` | Timestamp when cash-outs unlock | Applied only for existing revnets deployed to new chains |
| `hashedEncodedConfigurationOf[revnetId]` | Config hash for cross-chain sucker validation | Gap: does NOT cover terminal configs |
| `tiered721HookOf[revnetId]` | 721 hook address | Set once during deploy, never changed |
| `_extraOperatorPermissions[revnetId]` | Custom permissions for split operator | Set during deploy based on 721 hook prevention flags |

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

REVDeployer proxies between the terminal and two hooks. Verify:

- The 721 hook's `beforePayRecordedWith` is called with the full context, but the buyback hook's is called with a reduced amount. Is this always correct?
- When the 721 hook returns specs with `amount >= context.amount.value`, `projectAmount` is 0 and weight is 0. This means no tokens are minted by the terminal (all funds go to 721 splits). Verify this is safe -- does the buyback hook handle a zero-amount context gracefully?
- The `hookSpecifications` array sizing assumes at most one spec from each hook. Verify neither hook can return multiple specs.
- The weight scaling `mulDiv(weight, projectAmount, context.amount.value)` -- can this produce a weight of 0 when it shouldn't, or a weight > 0 when it should be 0?

### 4. Cash-out fee calculation

The two-step bonding curve fee calculation in `beforeCashOutRecordedWith`:

```solidity
feeCashOutCount = mulDiv(cashOutCount, FEE, MAX_FEE)  // 2.5% of tokens
nonFeeCashOutCount = cashOutCount - feeCashOutCount

postFeeReclaimedAmount = JBCashOuts.cashOutFrom(surplus, nonFeeCashOutCount, totalSupply, taxRate)
feeAmount = JBCashOuts.cashOutFrom(surplus - postFeeReclaimedAmount, feeCashOutCount, totalSupply - nonFeeCashOutCount, taxRate)
```

Verify:
- `postFeeReclaimedAmount + feeAmount <= directReclaim` (total <= what you'd get without fee splitting)
- Micro cash-outs (< 40 wei at 2.5%) round `feeCashOutCount` to zero, bypassing the fee. This is documented as economically insignificant. Verify.
- The `cashOutCount` returned to the terminal is `nonFeeCashOutCount`, but the terminal still burns the full `cashOutCount` tokens. **Wait, is this correct?** Trace through the terminal to verify how many tokens are actually burned.

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
3. **Source prepaid fee (2.5%-50%)** -- `JBFees.feeAmountFrom(borrowAmount, prepaidFeePercent)` paid back to the revnet via `terminal.pay`. NOT try-catch; reverts on failure.

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
- The linear accrual formula: at `timeSinceLoanCreated = LOAN_LIQUIDATION_DURATION`, the fee percent approaches MAX_FEE (100%). Is this correct? The borrower would owe the full remaining loan amount as a fee, making repayment impossible.
- Actually, at liquidation time, `_determineSourceFeeAmount` reverts with `REVLoans_LoanExpired`. So the fee approaches but never reaches 100%. Verify the revert boundary is correct: `>=` vs `>`.

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
| `mulDiv` rounding direction | `beforePayRecordedWith` weight scaling, `_determineSourceFeeAmount`, `_borrowableAmountFrom` | Rounding in borrower's favor compounds over many loans |
| Source fee `pay` without try-catch | `_adjust` line 1086 | If source fee terminal reverts, entire borrow/repay reverts (DoS) |
| `delete _loanOf[loanId]` after external calls | `_repayLoan`, `_reallocateCollateralFromLoan` | Verify delete happens after all references to the loan are resolved |
| Loan storage read after `_adjust` mutates it | `_repayLoan` partial repay path | `_adjust` modifies `loan` via storage pointer; subsequent reads see mutated values |
| Unbounded loop in `_totalBorrowedFrom` | Called during every borrow operation | Gas griefing if many distinct loan sources accumulate |
| `uint112` truncation | `_adjust` explicit check | Verify all paths that set `loan.amount` or `loan.collateral` go through `_adjust` |
| Permit2 try-catch swallowing | `_acceptFundsFor` | If permit fails, fall through to regular transfer. Is the state consistent? |
| ERC-721 `_mint` callback | `borrowFrom`, `_repayLoan`, `_reallocateCollateralFromLoan` | `onERC721Received` can re-enter. Verify all state is settled before mint. |
