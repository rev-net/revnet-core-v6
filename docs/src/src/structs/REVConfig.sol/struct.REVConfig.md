# REVConfig
[Git Source](https://github.com/rev-net/revnet-core-v6/blob/94c003a3a16de2bd012d63cccedd6bd38d21f6e7/src/structs/REVConfig.sol)

**Notes:**
- member: description The description of the revnet.

- member: baseCurrency The currency that the issuance is based on.

- member: splitOperator The address that will receive the token premint and initial production split,
and who is allowed to change who the operator is. Only the operator can replace itself after deployment.

- member: stageConfigurations The periods of changing constraints.


```solidity
struct REVConfig {
REVDescription description;
uint32 baseCurrency;
address splitOperator;
REVStageConfig[] stageConfigurations;
}
```

