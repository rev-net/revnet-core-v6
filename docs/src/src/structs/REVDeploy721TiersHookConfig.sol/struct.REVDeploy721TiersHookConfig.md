# REVDeploy721TiersHookConfig
[Git Source](https://github.com/rev-net/revnet-core-v6/blob/94c003a3a16de2bd012d63cccedd6bd38d21f6e7/src/structs/REVDeploy721TiersHookConfig.sol)

**Notes:**
- member: baseline721HookConfiguration The baseline config.

- member: salt The salt to base the collection's address on.

- member: splitOperatorCanAdjustTiers A flag indicating if the revnet's split operator can add tiers and remove
tiers if
the tier is allowed to be removed

- member: splitOperatorCanUpdateMetadata A flag indicating if the revnet's split operator can update the 721's
metadata.

- member: splitOperatorCanMint A flag indicating if the revnet's split operator can mint 721's from tiers that
allow it.

- member: splitOperatorCanIncreaseDiscountPercent A flag indicating if the revnet's split operator can increase
the
discount of a tier.


```solidity
struct REVDeploy721TiersHookConfig {
JBDeploy721TiersHookConfig baseline721HookConfiguration;
bytes32 salt;
bool splitOperatorCanAdjustTiers;
bool splitOperatorCanUpdateMetadata;
bool splitOperatorCanMint;
bool splitOperatorCanIncreaseDiscountPercent;
}
```

