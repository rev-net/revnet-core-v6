# IREVDeployer
[Git Source](https://github.com/rev-net/revnet-core-v6/blob/94c003a3a16de2bd012d63cccedd6bd38d21f6e7/src/interfaces/IREVDeployer.sol)


## Functions
### CASH_OUT_DELAY

The number of seconds until a revnet's participants can cash out after deploying to a new network.


```solidity
function CASH_OUT_DELAY() external view returns (uint256);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The cash out delay in seconds.|


### CONTROLLER

The controller used to create and manage Juicebox projects for revnets.


```solidity
function CONTROLLER() external view returns (IJBController);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`IJBController`|The controller contract.|


### DIRECTORY

The directory of terminals and controllers for Juicebox projects.


```solidity
function DIRECTORY() external view returns (IJBDirectory);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`IJBDirectory`|The directory contract.|


### PROJECTS

The contract that mints ERC-721s representing project ownership.


```solidity
function PROJECTS() external view returns (IJBProjects);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`IJBProjects`|The projects contract.|


### PERMISSIONS

The contract that stores Juicebox project access permissions.


```solidity
function PERMISSIONS() external view returns (IJBPermissions);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`IJBPermissions`|The permissions contract.|


### FEE

The cash out fee as a fraction out of `JBConstants.MAX_FEE`.


```solidity
function FEE() external view returns (uint256);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The fee value.|


### DEFAULT_BUYBACK_POOL_FEE

The default Uniswap pool fee tier for auto-configured buyback pools.


```solidity
function DEFAULT_BUYBACK_POOL_FEE() external view returns (uint24);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint24`|The fee tier (10_000 = 1%).|


### DEFAULT_BUYBACK_TWAP_WINDOW

The default TWAP window for auto-configured buyback pools.


```solidity
function DEFAULT_BUYBACK_TWAP_WINDOW() external view returns (uint32);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint32`|The TWAP window in seconds.|


### SUCKER_REGISTRY

The registry that deploys and tracks suckers for revnets.


```solidity
function SUCKER_REGISTRY() external view returns (IJBSuckerRegistry);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`IJBSuckerRegistry`|The sucker registry contract.|


### FEE_REVNET_ID

The Juicebox project ID of the revnet that receives cash out fees.


```solidity
function FEE_REVNET_ID() external view returns (uint256);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The fee revnet ID.|


### PUBLISHER

The croptop publisher revnets can use to publish ERC-721 posts to their tiered ERC-721 hooks.


```solidity
function PUBLISHER() external view returns (CTPublisher);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`CTPublisher`|The publisher contract.|


### BUYBACK_HOOK

The buyback hook used as a data hook to route payments through buyback pools.


```solidity
function BUYBACK_HOOK() external view returns (IJBRulesetDataHook);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`IJBRulesetDataHook`|The buyback hook contract.|


### HOOK_DEPLOYER

The deployer used to create tiered ERC-721 hooks for revnets.


```solidity
function HOOK_DEPLOYER() external view returns (IJB721TiersHookDeployer);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`IJB721TiersHookDeployer`|The hook deployer contract.|


### LOANS

The loan contract used by all revnets.


```solidity
function LOANS() external view returns (address);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|The loans contract address.|


### amountToAutoIssue

The number of revnet tokens that can be auto-minted for a beneficiary during a stage.


```solidity
function amountToAutoIssue(uint256 revnetId, uint256 stageId, address beneficiary) external view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`revnetId`|`uint256`|The ID of the revnet.|
|`stageId`|`uint256`|The ID of the stage.|
|`beneficiary`|`address`|The beneficiary of the auto-mint.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The number of tokens available to auto-issue.|


### cashOutDelayOf

The timestamp when cash outs become available for a revnet's participants.


```solidity
function cashOutDelayOf(uint256 revnetId) external view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`revnetId`|`uint256`|The ID of the revnet.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The cash out delay timestamp.|


### deploySuckersFor

Deploy new suckers for an existing revnet.


```solidity
function deploySuckersFor(
    uint256 revnetId,
    REVSuckerDeploymentConfig calldata suckerDeploymentConfiguration
)
    external
    returns (address[] memory suckers);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`revnetId`|`uint256`|The ID of the revnet to deploy suckers for.|
|`suckerDeploymentConfiguration`|`REVSuckerDeploymentConfig`|The suckers to set up for the revnet.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`suckers`|`address[]`|The addresses of the deployed suckers.|


### hashedEncodedConfigurationOf

The hashed encoded configuration of each revnet.


```solidity
function hashedEncodedConfigurationOf(uint256 revnetId) external view returns (bytes32);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`revnetId`|`uint256`|The ID of the revnet.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bytes32`|The hashed encoded configuration.|


### isSplitOperatorOf

Whether an address is a revnet's split operator.


```solidity
function isSplitOperatorOf(uint256 revnetId, address addr) external view returns (bool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`revnetId`|`uint256`|The ID of the revnet.|
|`addr`|`address`|The address to check.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|A flag indicating whether the address is the revnet's split operator.|


### tiered721HookOf

Each revnet's tiered ERC-721 hook.


```solidity
function tiered721HookOf(uint256 revnetId) external view returns (IJB721TiersHook);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`revnetId`|`uint256`|The ID of the revnet.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`IJB721TiersHook`|The tiered ERC-721 hook.|


### autoIssueFor

Auto-mint a revnet's tokens from a stage for a beneficiary.


```solidity
function autoIssueFor(uint256 revnetId, uint256 stageId, address beneficiary) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`revnetId`|`uint256`|The ID of the revnet to auto-mint tokens from.|
|`stageId`|`uint256`|The ID of the stage auto-mint tokens are available from.|
|`beneficiary`|`address`|The address to auto-mint tokens to.|


### deployFor

Deploy a revnet, or initialize an existing Juicebox project as a revnet.


```solidity
function deployFor(
    uint256 revnetId,
    REVConfig memory configuration,
    JBTerminalConfig[] memory terminalConfigurations,
    REVSuckerDeploymentConfig memory suckerDeploymentConfiguration
)
    external
    returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`revnetId`|`uint256`|The ID of the Juicebox project to initialize. Send 0 to deploy a new revnet.|
|`configuration`|`REVConfig`|Core revnet configuration.|
|`terminalConfigurations`|`JBTerminalConfig[]`|The terminals to set up for the revnet.|
|`suckerDeploymentConfiguration`|`REVSuckerDeploymentConfig`|The suckers to set up for cross-chain token transfers.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The ID of the newly created or initialized revnet.|


### deployWith721sFor

Deploy a revnet with tiered ERC-721s and optional croptop posting support.


```solidity
function deployWith721sFor(
    uint256 revnetId,
    REVConfig calldata configuration,
    JBTerminalConfig[] memory terminalConfigurations,
    REVSuckerDeploymentConfig memory suckerDeploymentConfiguration,
    REVDeploy721TiersHookConfig memory tiered721HookConfiguration,
    REVCroptopAllowedPost[] memory allowedPosts
)
    external
    returns (uint256, IJB721TiersHook hook);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`revnetId`|`uint256`|The ID of the Juicebox project to initialize. Send 0 to deploy a new revnet.|
|`configuration`|`REVConfig`|Core revnet configuration.|
|`terminalConfigurations`|`JBTerminalConfig[]`|The terminals to set up for the revnet.|
|`suckerDeploymentConfiguration`|`REVSuckerDeploymentConfig`|The suckers to set up for cross-chain token transfers.|
|`tiered721HookConfiguration`|`REVDeploy721TiersHookConfig`|How to set up the tiered ERC-721 hook.|
|`allowedPosts`|`REVCroptopAllowedPost[]`|Restrictions on which croptop posts are allowed on the revnet's ERC-721 tiers.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The ID of the newly created or initialized revnet.|
|`hook`|`IJB721TiersHook`|The tiered ERC-721 hook that was deployed for the revnet.|


### setSplitOperatorOf

Change a revnet's split operator. Only the current split operator can call this.


```solidity
function setSplitOperatorOf(uint256 revnetId, address newSplitOperator) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`revnetId`|`uint256`|The ID of the revnet.|
|`newSplitOperator`|`address`|The new split operator's address.|


### burnHeldTokensOf

Burn any of a revnet's tokens held by this contract.


```solidity
function burnHeldTokensOf(uint256 revnetId) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`revnetId`|`uint256`|The ID of the revnet whose tokens should be burned.|


## Events
### ReplaceSplitOperator

```solidity
event ReplaceSplitOperator(uint256 indexed revnetId, address indexed newSplitOperator, address caller);
```

### DeploySuckers

```solidity
event DeploySuckers(
    uint256 indexed revnetId,
    bytes32 encodedConfigurationHash,
    REVSuckerDeploymentConfig suckerDeploymentConfiguration,
    address caller
);
```

### DeployRevnet

```solidity
event DeployRevnet(
    uint256 indexed revnetId,
    REVConfig configuration,
    JBTerminalConfig[] terminalConfigurations,
    REVSuckerDeploymentConfig suckerDeploymentConfiguration,
    JBRulesetConfig[] rulesetConfigurations,
    bytes32 encodedConfigurationHash,
    address caller
);
```

### SetCashOutDelay

```solidity
event SetCashOutDelay(uint256 indexed revnetId, uint256 cashOutDelay, address caller);
```

### AutoIssue

```solidity
event AutoIssue(
    uint256 indexed revnetId, uint256 indexed stageId, address indexed beneficiary, uint256 count, address caller
);
```

### StoreAutoIssuanceAmount

```solidity
event StoreAutoIssuanceAmount(
    uint256 indexed revnetId, uint256 indexed stageId, address indexed beneficiary, uint256 count, address caller
);
```

### BurnHeldTokens

```solidity
event BurnHeldTokens(uint256 indexed revnetId, uint256 count, address caller);
```

