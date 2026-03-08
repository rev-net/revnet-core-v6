# REVCroptopAllowedPost
[Git Source](https://github.com/rev-net/revnet-core-v6/blob/94c003a3a16de2bd012d63cccedd6bd38d21f6e7/src/structs/REVCroptopAllowedPost.sol)

Criteria for allowed posts.

**Notes:**
- member: category A category that should allow posts.

- member: minimumPrice The minimum price that a post to the specified category should cost.

- member: minimumTotalSupply The minimum total supply of NFTs that can be made available when minting.

- member: maxTotalSupply The max total supply of NFTs that can be made available when minting. Leave as 0 for
max.

- member: maximumSplitPercent The maximum split percent (out of JBConstants.SPLITS_TOTAL_PERCENT) that a
poster can set. 0 means splits are not allowed.

- member: allowedAddresses A list of addresses that are allowed to post on the category through Croptop.


```solidity
struct REVCroptopAllowedPost {
uint24 category;
uint104 minimumPrice;
uint32 minimumTotalSupply;
uint32 maximumTotalSupply;
uint32 maximumSplitPercent;
address[] allowedAddresses;
}
```

