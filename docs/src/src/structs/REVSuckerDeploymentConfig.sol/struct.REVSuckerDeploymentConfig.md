# REVSuckerDeploymentConfig
[Git Source](https://github.com/rev-net/revnet-core-v6/blob/94c003a3a16de2bd012d63cccedd6bd38d21f6e7/src/structs/REVSuckerDeploymentConfig.sol)

**Notes:**
- member: deployerConfigurations The information for how to suck tokens to other chains.

- member: salt The salt to use for creating suckers so that they use the same address across chains.


```solidity
struct REVSuckerDeploymentConfig {
JBSuckerDeployerConfig[] deployerConfigurations;
bytes32 salt;
}
```

