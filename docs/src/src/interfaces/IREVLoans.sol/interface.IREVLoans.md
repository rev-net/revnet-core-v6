# IREVLoans
[Git Source](https://github.com/rev-net/revnet-core-v6/blob/94c003a3a16de2bd012d63cccedd6bd38d21f6e7/src/interfaces/IREVLoans.sol)


## Functions
### LOAN_LIQUIDATION_DURATION

The duration after which a loan expires and its collateral is permanently lost.


```solidity
function LOAN_LIQUIDATION_DURATION() external view returns (uint256);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The loan liquidation duration in seconds.|


### PERMIT2

The permit2 utility used for token transfers.


```solidity
function PERMIT2() external view returns (IPermit2);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`IPermit2`|The permit2 contract.|


### CONTROLLER

The controller that manages revnets using this loans contract.


```solidity
function CONTROLLER() external view returns (IJBController);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`IJBController`|The controller contract.|


### DIRECTORY

The directory of terminals and controllers for revnets.


```solidity
function DIRECTORY() external view returns (IJBDirectory);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`IJBDirectory`|The directory contract.|


### PRICES

The contract that stores prices for each revnet.


```solidity
function PRICES() external view returns (IJBPrices);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`IJBPrices`|The prices contract.|


### PROJECTS

The contract that mints ERC-721s representing project ownership.


```solidity
function PROJECTS() external view returns (IJBProjects);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`IJBProjects`|The projects contract.|


### REV_ID

The ID of the REV revnet that receives protocol fees from loans.


```solidity
function REV_ID() external view returns (uint256);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The REV revnet ID.|


### REV_PREPAID_FEE_PERCENT

The fee percent charged by the REV revnet on each loan, in terms of `JBConstants.MAX_FEE`.


```solidity
function REV_PREPAID_FEE_PERCENT() external view returns (uint256);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The REV prepaid fee percent.|


### MIN_PREPAID_FEE_PERCENT

The minimum fee percent that must be prepaid when borrowing, in terms of `JBConstants.MAX_FEE`.


```solidity
function MIN_PREPAID_FEE_PERCENT() external view returns (uint256);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The minimum prepaid fee percent.|


### MAX_PREPAID_FEE_PERCENT

The maximum fee percent that can be prepaid when borrowing, in terms of `JBConstants.MAX_FEE`.


```solidity
function MAX_PREPAID_FEE_PERCENT() external view returns (uint256);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The maximum prepaid fee percent.|


### borrowableAmountFrom

The amount that can be borrowed from a revnet given a certain amount of collateral.


```solidity
function borrowableAmountFrom(
    uint256 revnetId,
    uint256 collateralCount,
    uint256 decimals,
    uint256 currency
)
    external
    view
    returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`revnetId`|`uint256`|The ID of the revnet to check for borrowable assets from.|
|`collateralCount`|`uint256`|The amount of collateral used to secure the loan.|
|`decimals`|`uint256`|The decimals the resulting fixed point value will include.|
|`currency`|`uint256`|The currency that the resulting amount should be in terms of.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The amount that can be borrowed from the revnet.|


### determineSourceFeeAmount

Determines the source fee amount for a loan being paid off a certain amount.


```solidity
function determineSourceFeeAmount(
    REVLoan memory loan,
    uint256 amount
)
    external
    view
    returns (uint256 sourceFeeAmount);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`loan`|`REVLoan`|The loan having its source fee amount determined.|
|`amount`|`uint256`|The amount being paid off.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`sourceFeeAmount`|`uint256`|The source fee amount for the loan.|


### isLoanSourceOf

Whether a revnet currently has outstanding loans from the specified terminal in the specified token.


```solidity
function isLoanSourceOf(uint256 revnetId, IJBPayoutTerminal terminal, address token) external view returns (bool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`revnetId`|`uint256`|The ID of the revnet issuing the loan.|
|`terminal`|`IJBPayoutTerminal`|The terminal that the loan is issued from.|
|`token`|`address`|The token being loaned.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|A flag indicating if the revnet has an active loan source.|


### loanOf

Get a loan's details.


```solidity
function loanOf(uint256 loanId) external view returns (REVLoan memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`loanId`|`uint256`|The ID of the loan to retrieve.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`REVLoan`|The loan data.|


### loanSourcesOf

The sources of each revnet's loans.

This array only grows -- sources are appended when a new (terminal, token) pair is first used for
borrowing, but are never removed. Gas cost scales linearly with the number of distinct sources, though this is
practically bounded to a small number of unique (terminal, token) pairs.


```solidity
function loanSourcesOf(uint256 revnetId) external view returns (REVLoanSource[] memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`revnetId`|`uint256`|The ID of the revnet to get the loan sources for.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`REVLoanSource[]`|The array of loan sources.|


### totalLoansBorrowedFor

The cumulative number of loans ever created for a revnet, used as a loan ID sequence counter.

This counter only increments and never decrements. It does NOT represent the count of currently active
loans -- repaid and liquidated loans leave permanent gaps in the sequence. Do not use this value to determine
how many loans are currently outstanding.


```solidity
function totalLoansBorrowedFor(uint256 revnetId) external view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`revnetId`|`uint256`|The ID of the revnet to get the cumulative loan count for.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The cumulative number of loans ever created.|


### revnetIdOfLoanWith

The revnet ID for the loan with the provided loan ID.


```solidity
function revnetIdOfLoanWith(uint256 loanId) external view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`loanId`|`uint256`|The loan ID to get the revnet ID of.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The ID of the revnet.|


### tokenUriResolver

The contract resolving each loan ID to its ERC-721 URI.


```solidity
function tokenUriResolver() external view returns (IJBTokenUriResolver);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`IJBTokenUriResolver`|The token URI resolver.|


### totalBorrowedFrom

The total amount loaned out by a revnet from a specified terminal in a specified token.


```solidity
function totalBorrowedFrom(
    uint256 revnetId,
    IJBPayoutTerminal terminal,
    address token
)
    external
    view
    returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`revnetId`|`uint256`|The ID of the revnet issuing the loan.|
|`terminal`|`IJBPayoutTerminal`|The terminal that the loan is issued from.|
|`token`|`address`|The token being loaned.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The total amount borrowed.|


### totalCollateralOf

The total amount of collateral supporting a revnet's loans.


```solidity
function totalCollateralOf(uint256 revnetId) external view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`revnetId`|`uint256`|The ID of the revnet.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|The total collateral count.|


### borrowFrom

Open a loan by borrowing from a revnet. Collateral tokens are burned and only re-minted upon repayment.


```solidity
function borrowFrom(
    uint256 revnetId,
    REVLoanSource calldata source,
    uint256 minBorrowAmount,
    uint256 collateralCount,
    address payable beneficiary,
    uint256 prepaidFeePercent
)
    external
    returns (uint256 loanId, REVLoan memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`revnetId`|`uint256`|The ID of the revnet being borrowed from.|
|`source`|`REVLoanSource`|The source of the loan (terminal and token).|
|`minBorrowAmount`|`uint256`|The minimum amount to borrow, denominated in the source's token.|
|`collateralCount`|`uint256`|The amount of tokens to use as collateral for the loan.|
|`beneficiary`|`address payable`|The address that will receive the borrowed funds and fee payment tokens.|
|`prepaidFeePercent`|`uint256`|The fee percent to charge upfront, in terms of `JBConstants.MAX_FEE`.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`loanId`|`uint256`|The ID of the loan created from borrowing.|
|`<none>`|`REVLoan`|The loan created from borrowing.|


### liquidateExpiredLoansFrom

Liquidates loans that have exceeded the liquidation duration, permanently destroying their collateral.


```solidity
function liquidateExpiredLoansFrom(uint256 revnetId, uint256 startingLoanId, uint256 count) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`revnetId`|`uint256`|The ID of the revnet to liquidate loans from.|
|`startingLoanId`|`uint256`|The loan number to start iterating from.|
|`count`|`uint256`|The number of loans to iterate over.|


### repayLoan

Repay a loan or return excess collateral no longer needed to support the loan.


```solidity
function repayLoan(
    uint256 loanId,
    uint256 maxRepayBorrowAmount,
    uint256 collateralCountToReturn,
    address payable beneficiary,
    JBSingleAllowance calldata allowance
)
    external
    payable
    returns (uint256 paidOffLoanId, REVLoan memory paidOffloan);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`loanId`|`uint256`|The ID of the loan being repaid.|
|`maxRepayBorrowAmount`|`uint256`|The maximum amount to repay, denominated in the source's token.|
|`collateralCountToReturn`|`uint256`|The amount of collateral to return from the loan.|
|`beneficiary`|`address payable`|The address receiving the returned collateral and fee payment tokens.|
|`allowance`|`JBSingleAllowance`|A permit2 allowance to facilitate the repayment transfer.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`paidOffLoanId`|`uint256`|The ID of the loan after it has been paid off.|
|`paidOffloan`|`REVLoan`|The loan after it has been paid off.|


### reallocateCollateralFromLoan

Refinance a loan by transferring extra collateral from an existing loan to a new loan.


```solidity
function reallocateCollateralFromLoan(
    uint256 loanId,
    uint256 collateralCountToTransfer,
    REVLoanSource calldata source,
    uint256 minBorrowAmount,
    uint256 collateralCountToAdd,
    address payable beneficiary,
    uint256 prepaidFeePercent
)
    external
    returns (uint256 reallocatedLoanId, uint256 newLoanId, REVLoan memory reallocatedLoan, REVLoan memory newLoan);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`loanId`|`uint256`|The ID of the loan to reallocate collateral from.|
|`collateralCountToTransfer`|`uint256`|The amount of collateral to transfer from the original loan.|
|`source`|`REVLoanSource`|The source of the new loan (terminal and token). Must match the existing loan's source.|
|`minBorrowAmount`|`uint256`|The minimum amount to borrow for the new loan.|
|`collateralCountToAdd`|`uint256`|Additional collateral to add to the new loan from the caller's balance.|
|`beneficiary`|`address payable`|The address that will receive the borrowed funds and fee payment tokens.|
|`prepaidFeePercent`|`uint256`|The fee percent to charge upfront for the new loan.|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`reallocatedLoanId`|`uint256`|The ID of the reallocated (reduced) loan.|
|`newLoanId`|`uint256`|The ID of the newly created loan.|
|`reallocatedLoan`|`REVLoan`|The reallocated loan data.|
|`newLoan`|`REVLoan`|The new loan data.|


### setTokenUriResolver

Sets the address of the resolver used to retrieve the token URI of loans.


```solidity
function setTokenUriResolver(IJBTokenUriResolver resolver) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`resolver`|`IJBTokenUriResolver`|The new token URI resolver.|


## Events
### Borrow

```solidity
event Borrow(
    uint256 indexed loanId,
    uint256 indexed revnetId,
    REVLoan loan,
    REVLoanSource source,
    uint256 borrowAmount,
    uint256 collateralCount,
    uint256 sourceFeeAmount,
    address payable beneficiary,
    address caller
);
```

### Liquidate

```solidity
event Liquidate(uint256 indexed loanId, uint256 indexed revnetId, REVLoan loan, address caller);
```

### RepayLoan

```solidity
event RepayLoan(
    uint256 indexed loanId,
    uint256 indexed revnetId,
    uint256 indexed paidOffLoanId,
    REVLoan loan,
    REVLoan paidOffLoan,
    uint256 repayBorrowAmount,
    uint256 sourceFeeAmount,
    uint256 collateralCountToReturn,
    address payable beneficiary,
    address caller
);
```

### ReallocateCollateral

```solidity
event ReallocateCollateral(
    uint256 indexed loanId,
    uint256 indexed revnetId,
    uint256 indexed reallocatedLoanId,
    REVLoan reallocatedLoan,
    uint256 removedCollateralCount,
    address caller
);
```

### SetTokenUriResolver

```solidity
event SetTokenUriResolver(IJBTokenUriResolver indexed resolver, address caller);
```

