# Security Considerations

## [INTEROP-6] Cross-Chain Accounting Mismatch: NATIVE_TOKEN on Non-ETH Chains

**Severity:** Medium
**Status:** Acknowledged — by design, not fixable without oracle dependencies

### Description

When a revnet expands to a chain where the native token is not ETH (e.g., Celo where native = CELO), using `JBConstants.NATIVE_TOKEN` as the terminal accounting context and sucker token mapping creates a semantic mismatch. The protocol treats CELO payments as ETH-equivalent.

### What the Matching Hash Covers

The hash computed in `REVDeployer._makeRulesetConfigurations()` ensures both sides of a cross-chain deployment agree on:
- `baseCurrency`, `loans`, `name`, `ticker`, `salt`
- Per stage: timing, splits, issuance, cash-out tax
- Per auto-issuance: chainId, beneficiary, count

### What the Matching Hash Does NOT Cover

- Terminal configurations (which tokens are accepted)
- Accounting contexts (token address, decimals, currency)
- Sucker token mappings (localToken → remoteToken)

Two deployments can produce identical hashes while one accepts ETH-native and the other accepts CELO-native. The hash is a safety check for economic parameter alignment, not a guarantee of asset compatibility.

### Impact on Revnets

1. **Issuance mispricing** — A revnet with `baseCurrency = ETH` that accepts `NATIVE_TOKEN` on Celo prices CELO payments as ETH (1:1 without a price feed), massively overvaluing them.
2. **Surplus fragmentation** — Cash-out bonding curve on each chain only sees that chain's surplus. Token holders must bridge to the chain with more surplus for fair cash-out values.
3. **Cash-out arbitrage** — Different effective valuations across chains let arbitrageurs buy tokens cheaply on one chain and cash out on another.

### Recommended Configuration for Non-ETH Chains

When deploying a revnet to Celo or other non-ETH-native chains:

```solidity
// DO: Use WETH ERC20 as accounting context
accountingContextsToAccept[0] = JBAccountingContext({
    token: WETH_ADDRESS,  // e.g., 0xD221812... on Celo
    decimals: 18,
    currency: ETH_CURRENCY
});

// DO: Map WETH → WETH in sucker token mappings
tokenMappings[0] = JBTokenMapping({
    localToken: WETH_ADDRESS,
    remoteToken: WETH_ADDRESS,
    minGas: 200_000,
    minBridgeAmount: 0.01 ether
});

// DON'T: Use NATIVE_TOKEN on non-ETH chains
// This maps CELO → ETH which are different assets
tokenMappings[0] = JBTokenMapping({
    localToken: JBConstants.NATIVE_TOKEN,   // = CELO on Celo
    remoteToken: JBConstants.NATIVE_TOKEN,  // = ETH on Ethereum
    ...
});
```

### Safe Chains

OP Stack L2s where native token IS ETH: Ethereum, Optimism, Base, Arbitrum.

### Affected Chains

Any chain where native token ≠ ETH: Celo (CELO), Polygon (MATIC), Avalanche (AVAX), BNB Chain (BNB).
