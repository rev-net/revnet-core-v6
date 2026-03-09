# revnet-core-v6 — Risks

## Trust Assumptions

1. **REVDeployer Contract** — Acts as data hook for all deployed revnets. A bug in REVDeployer affects every revnet's pay and cashout behavior.
2. **Immutable Stages** — Once deployed, stage parameters cannot be changed. If configured incorrectly, there is no fix (by design — this IS the trust model).
3. **Buyback Hook** — REVDeployer delegates to the buyback hook for swap-vs-mint decisions. Buyback hook failure falls back to direct minting.
4. **Suckers** — Cross-chain bridge implementations trusted for token transport. Bridge compromise = fund loss.
5. **Core Protocol** — Relies on JBController, JBMultiTerminal, JBTerminalStore for correct operation.

## Known Risks

| Risk | Description | Mitigation |
|------|-------------|------------|
| Irreversible deployment | Stage parameters cannot be changed after deployment | Thorough testing before deploy; matching hash verification |
| Loan collateral manipulation | Attacker inflates surplus to borrow more, then deflates | Borrow based on bonding curve value at time of borrow; existing loans unaffected by surplus changes |
| 10-year liquidation drift | Collateral real value may diverge from loan over 10 years | Gradual liquidation schedule; early repayment available |
| Loans beat cash-outs | Above ~39% cashOutTaxRate, borrowing is more capital-efficient than cashing out | By design (CryptoEconLab finding); creates natural demand for loans |
| Matching hash gap | Hash covers economic parameters but NOT terminal configs, accounting contexts, or token mappings | Verify full configuration manually before cross-chain deploy |

## INTEROP-6: NATIVE_TOKEN on Non-ETH Chains

**Severity:** Medium
**Status:** Acknowledged — by design

When a revnet expands to a chain where the native token is not ETH (e.g., Celo), using `NATIVE_TOKEN` as the accounting context creates a semantic mismatch — CELO payments priced as ETH without a price feed.

**Impact:** Issuance mispricing, surplus fragmentation, cross-chain arbitrage.

**Safe chains:** Ethereum, Optimism, Base, Arbitrum
**Affected chains:** Celo, Polygon, Avalanche, BNB Chain

**Mitigation:** Use WETH ERC20 (not NATIVE_TOKEN) on non-ETH chains. Map `WETH → WETH` in sucker token mappings.

## Privileged Roles

| Role | Capabilities | Notes |
|------|-------------|-------|
| Deployer (one-time) | Configures all stage parameters | Parameters immutable after deploy |
| Auto-issuance beneficiaries | Receive pre-minted tokens per stage | Configured at deploy time |
| Suckers | 0% cashout tax privilege | Enables cross-chain bridging without fee |

## Reentrancy Considerations

| Function | Protection | Risk |
|----------|-----------|------|
| `REVLoans.borrowFrom` | Collateral locked BEFORE funds transferred | LOW |
| `REVLoans.repayLoan` | Loan state cleared BEFORE collateral returned | LOW |
| `REVDeployer.beforePayRecordedWith` | View function, no state changes | NONE |
