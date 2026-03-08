# REVStageConfig
[Git Source](https://github.com/rev-net/revnet-core-v6/blob/94c003a3a16de2bd012d63cccedd6bd38d21f6e7/src/structs/REVStageConfig.sol)

**Notes:**
- member: startsAtOrAfter The timestamp to start a stage at the given rate at or after.

- member: autoIssuances The configurations of mints during this stage.

- member: splitPercent The percentage of newly issued tokens that should be split with the operator, out
of 10_000 (JBConstants.MAX_RESERVED_PERCENT).

- member: splits The splits for the revnet.

- member: initialIssuance The number of revnet tokens that one unit of the revnet's base currency will buy, as
a fixed point number
with 18 decimals.

- member: issuanceCutFrequency The number of seconds between applied issuance decreases. This
should be at least 24 hours.

- member: issuanceCutPercent The percent that issuance should decrease over time. This percentage is out
of 1_000_000_000 (JBConstants.MAX_CUT_PERCENT). 0% corresponds to no issuance increase.

- member: cashOutTaxRate The factor determining how much each token can cash out from the revnet once
cashed out. This rate is out of 10_000 (JBConstants.MAX_CASH_OUT_TAX_RATE). 0% corresponds to no tax when cashing
out.

- member: extraMetadata Extra info to attach set into this stage that may affect hooks.


```solidity
struct REVStageConfig {
uint48 startsAtOrAfter;
REVAutoIssuance[] autoIssuances;
uint16 splitPercent;
JBSplit[] splits;
uint112 initialIssuance;
uint32 issuanceCutFrequency;
uint32 issuanceCutPercent;
uint16 cashOutTaxRate;
uint16 extraMetadata;
}
```

