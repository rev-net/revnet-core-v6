# REVLoanSource
[Git Source](https://github.com/rev-net/revnet-core-v6/blob/94c003a3a16de2bd012d63cccedd6bd38d21f6e7/src/structs/REVLoanSource.sol)

**Notes:**
- member: token The token that is being loaned.

- member: terminal The terminal that the loan is being made from.


```solidity
struct REVLoanSource {
address token;
IJBPayoutTerminal terminal;
}
```

