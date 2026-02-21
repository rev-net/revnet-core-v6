# Revnet Pre-Deployment Security Checklist

**Status**: All findings documented, tests written. Fixes required before deployment.
**Test Suite**: `forge test --match-contract REVInvincibility -vvv`
**Date**: 2026-02-21

---

## Critical Findings (5)

### C-1: uint112 Truncation in REVLoans._adjust
- **File**: `REVLoans.sol:922-923`
- **Code**: `loan.amount = uint112(newBorrowAmount); loan.collateral = uint112(newCollateralCount);`
- **Impact**: Silently truncates borrow amounts > 5.19e33 (uint112.max), allowing loans with near-zero recorded debt but full ETH disbursement
- **Fix Required**: Add `require(newBorrowAmount <= type(uint112).max)` and `require(newCollateralCount <= type(uint112).max)` before the casts
- **Test**: `test_fixVerify_C1_uint112Truncation` — proves the truncation math
- **Status**: [ ] UNFIXED

### C-2: Array OOB in REVDeployer.beforePayRecordedWith
- **File**: `REVDeployer.sol:248-258`
- **Code**: `hookSpecifications[1] = buybackHookSpecifications[0]` hardcoded to index [1]
- **Impact**: Payment to any revnet with buyback hook but no 721 hook reverts (OOB on size-1 array)
- **Fix Required**: Change line 258 to use dynamic index: `hookSpecifications[usesTiered721Hook ? 1 : 0]`
- **Test**: `test_fixVerify_C2_arrayOOB_noBuybackWithBuyback` — proves the index logic
- **Status**: [ ] UNFIXED

### C-3: Reentrancy in REVLoans._adjust
- **File**: `REVLoans.sol:910 vs 922-923`
- **Code**: `terminal.pay()` at line 910 before `loan.amount = ...` at line 922
- **Impact**: Malicious fee terminal can reenter borrowFrom() with stale loan state, potentially extracting more than collateral supports
- **Fix Required**: Either add `nonReentrant` modifier or move state writes (lines 922-923) before external calls (line 910)
- **Test**: `test_fixVerify_C3_reentrancyDoubleBorrow` — confirms CEI violation pattern
- **Status**: [ ] UNFIXED

### C-4: hasMintPermissionFor Reverts on address(0)
- **File**: `REVDeployer.sol:353-354`
- **Code**: `buybackHook.hasMintPermissionFor(...)` called when `buybackHook == address(0)`
- **Impact**: Blocks ALL sucker claims and external mint operations for revnets without buyback hooks
- **Fix Required**: Add `address(buybackHook) != address(0) &&` guard before the call
- **Test**: `test_fixVerify_C4_hasMintPermission_noBuyback` — triggers the revert
- **Status**: [ ] UNFIXED

### C-5: Zero-Supply Cash Out Drains Surplus
- **File**: `JBCashOuts.sol:31`
- **Code**: `if (cashOutCount >= totalSupply) return surplus;` — 0 >= 0 is true
- **Impact**: When totalSupply=0, cashing out 0 tokens returns the ENTIRE surplus
- **Fix Required**: Add `if (cashOutCount == 0) return 0;` before the totalSupply check
- **Test**: `test_fixVerify_C5_zeroSupplyCashOutDrain` — proves 0/0 returns full surplus
- **Status**: [ ] UNFIXED (in JBCashOuts library)

---

## High Findings (4 revnet-specific)

### H-1: Double Fee on Cash-Outs
- **File**: `REVDeployer.sol:567-624`
- **Impact**: Cash-out fees are charged twice — once by JBMultiTerminal (protocol fee) and once by REVDeployer's afterCashOutRecordedWith (revnet fee). REVDeployer is not registered as feeless.
- **Fix Required**: Register REVDeployer as feeless address, or adjust fee calculation to account for the protocol fee already taken
- **Test**: `test_econ_doubleFeeH1` — measures actual fee amounts
- **Status**: [ ] UNFIXED

### H-2: Broken Fee Terminal Bricks Cash-Outs
- **File**: `REVDeployer.sol:615`
- **Impact**: In the catch block of afterCashOutRecordedWith, `addToBalanceOf()` is NOT wrapped in try/catch. If both feeTerminal.pay() and addToBalanceOf() revert, ALL cash-outs for the revnet become permanently impossible.
- **Fix Required**: Wrap the fallback `addToBalanceOf()` at line 615 in its own try/catch
- **Test**: `test_fixVerify_H2_brokenFeeTerminalBricksCashOuts` — demonstrates both paths revert
- **Status**: [ ] UNFIXED

### H-5: Auto-Issuance Stage ID Mismatch
- **File**: `REVDeployer.sol:1223`
- **Code**: `amountToAutoIssue[revnetId][block.timestamp + i][...] += ...`
- **Impact**: Stage ID computed as `block.timestamp + i` but actual ruleset IDs from JBRulesets may differ. Auto-issuance tokens for non-first stages become permanently unclaimable.
- **Fix Required**: Use the actual ruleset IDs returned by `jbController().queueRulesetsOf()` instead of `block.timestamp + i`
- **Test**: `test_fixVerify_H5_autoIssuanceStageIdMismatch` — confirms mismatch for stage 1+
- **Status**: [ ] UNFIXED

### H-6: Unvalidated Source Terminal
- **File**: `REVLoans.sol:788-791`
- **Impact**: Any terminal can be registered as a loan source. Attacker can grow `_loanSourcesOf` array unboundedly, causing gas DoS on functions that iterate loan sources.
- **Fix Required**: Validate that `loan.source.terminal` is a registered terminal for the project via `DIRECTORY.isTerminalOf(revnetId, loan.source.terminal)`
- **Test**: `test_fixVerify_H6_unvalidatedSourceTerminal` — documents the unvalidated registration
- **Status**: [ ] UNFIXED

---

## Medium Findings (3 revnet-specific)

### M-7: Silent Fee Failure in REVLoans._addTo
- **File**: `REVLoans.sol:833-841`
- **Impact**: REV fee payment in `_addTo` is wrapped in try/catch. If the fee terminal reverts, the fee is silently lost — REV holders lose fee revenue without any notification.
- **Fix Required**: At minimum, emit an event on fee failure. Consider reverting to ensure fees are always collected.
- **Status**: [ ] UNFIXED

### M-10: Cross-Source Value Extraction via reallocateCollateralFromLoan
- **File**: `REVLoans.sol:619-654`
- **Impact**: Collateral from one loan source can be transferred to create a loan from a different source. If source terminals have different fee structures, this enables fee arbitrage.
- **Fix Required**: Consider restricting collateral reallocation to same-source loans
- **Status**: [ ] UNFIXED

### M-11: Flash Loan Surplus Inflation
- **File**: `REVLoans.sol:308-332`
- **Impact**: `borrowableAmountFrom` reads live surplus. An attacker can `addToBalance` (inflating surplus without minting tokens) then immediately borrow at an inflated rate within the same block.
- **Fix Required**: Consider using a time-weighted average surplus or adding a borrowing delay
- **Test**: `test_econ_flashLoanSurplusInflation` — quantifies exact inflation factor
- **Status**: [ ] UNFIXED

---

## Invariant Properties (Verified by Fuzzing)

| ID | Property | Handler Operations | Runs |
|----|----------|-------------------|------|
| INV-REV-1 | Terminal balance covers outstanding loans | payAndBorrow, repayLoan, addToBalance | 256 |
| INV-REV-2 | Ghost collateral sum == totalCollateralOf | payAndBorrow, repayLoan, reallocate | 256 |
| INV-REV-3 | Ghost borrowed sum == totalBorrowedFrom | payAndBorrow, repayLoan | 256 |
| INV-REV-4 | No undercollateralized loans (when no cash-outs) | payAndBorrow, advanceTime | 256 |
| INV-REV-5 | totalSupply + totalCollateral coherent | All 10 operations | 256 |
| INV-REV-6 | Fee project balance monotonically increasing | payAndBorrow (generates fees) | 256 |

---

## Test Execution

```bash
# Section A+B: Fix verification + economic attacks (18 tests)
forge test --match-contract REVInvincibility_FixVerify -vvv

# Section C: Invariant properties (6 invariants)
forge test --match-contract REVInvincibility_Invariants -vvv

# Full suite
forge test --match-contract REVInvincibility -vvv

# Full regression (all existing tests still pass)
forge test -vvv
```

---

## Post-Deployment Monitoring Recommendations

1. **Loan Health Monitor**: Track `totalBorrowedFrom` vs terminal balance for each revnet. Alert if borrowed exceeds 80% of surplus.
2. **Fee Collection Monitor**: Verify fee project token supply increases after every borrow operation. Alert on silent fee failures.
3. **Collateral Consistency**: Periodically verify `sum(loan.collateral)` for all active loans matches `totalCollateralOf(revnetId)`.
4. **Loan Source Array**: Monitor `_loanSourcesOf` array length. Alert if it exceeds expected number of terminals.
5. **Auto-Issuance Claims**: After each stage transition, verify auto-issuance can be claimed at the correct ruleset ID.
6. **Cash-Out Availability**: Monitor that cash-outs succeed after fee terminal configuration changes.

---

## Fix Priority Order

1. **C-3** (Reentrancy) — Highest risk, enables active exploitation
2. **C-5** (Zero-supply drain) — Direct fund loss
3. **C-1** (uint112 truncation) — Fund loss at extreme values
4. **C-4** (hasMintPermission revert) — Blocks sucker claims
5. **C-2** (Array OOB) — Breaks payments for buyback-only revnets
6. **H-2** (Broken fee terminal) — Permanent cash-out DoS
7. **H-5** (Auto-issuance mismatch) — Permanent token loss
8. **H-6** (Unvalidated terminal) — Gas DoS vector
9. **H-1** (Double fee) — Economic loss for users
10. **M-11** (Flash surplus inflation) — Economic exploitation
11. **M-10** (Cross-source extraction) — Fee arbitrage
12. **M-7** (Silent fee failure) — Revenue leakage
