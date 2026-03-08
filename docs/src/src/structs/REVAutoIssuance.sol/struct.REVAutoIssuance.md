# REVAutoIssuance
[Git Source](https://github.com/rev-net/revnet-core-v6/blob/94c003a3a16de2bd012d63cccedd6bd38d21f6e7/src/structs/REVAutoIssuance.sol)

**Notes:**
- member: chainId The ID of the chain on which the mint should be honored.

- member: count The number of tokens that should be minted.

- member: beneficiary The address that will receive the minted tokens.


```solidity
struct REVAutoIssuance {
uint32 chainId;
uint104 count;
address beneficiary;
}
```

