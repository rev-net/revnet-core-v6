# REVDescription
[Git Source](https://github.com/rev-net/revnet-core-v6/blob/94c003a3a16de2bd012d63cccedd6bd38d21f6e7/src/structs/REVDescription.sol)

**Notes:**
- member: name The name of the ERC-20 token being create for the revnet.

- member: ticker The ticker of the ERC-20 token being created for the revnet.

- member: uri The metadata URI containing revnet's info.

- member: salt Revnets deployed across chains by the same address with the same salt will have the same
address.


```solidity
struct REVDescription {
string name;
string ticker;
string uri;
bytes32 salt;
}
```

