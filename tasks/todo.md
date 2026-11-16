# Held fallbacks: no try/catch branch may redirect value

- [x] REVOwner.afterCashOutRecordedWith: a failed fee pay is held in `heldFeeOf[revnetId][token][holder]` instead of
      being returned to the revnet's balance. `processHeldFeeOf` retries with no catch.
- [x] REVLoans: a failed REV fee or source fee is held in `heldFeeOf[heldFeeId]` instead of being handed to the
      borrower. `processHeldFeeOf` retries with no catch.
- [ ] Tests: out of scope for this PR.
