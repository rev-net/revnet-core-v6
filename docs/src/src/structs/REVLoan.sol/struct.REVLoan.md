# REVLoan
[Git Source](https://github.com/rev-net/revnet-core-v6/blob/94c003a3a16de2bd012d63cccedd6bd38d21f6e7/src/structs/REVLoan.sol)

**Notes:**
- member: borrowedAmount The amount that is being borrowed.

- member: collateralTokenCount The number of collateral tokens currently accounted for.

- member: createdAt The timestamp when the loan was created.

- member: prepaidFeePercent The percentage of the loan's fees that were prepaid.

- member: prepaidDuration The duration that the loan was prepaid for.

- member: source The source of the loan.


```solidity
struct REVLoan {
uint112 amount;
uint112 collateral;
uint48 createdAt;
uint16 prepaidFeePercent;
uint32 prepaidDuration;
REVLoanSource source;
}
```

