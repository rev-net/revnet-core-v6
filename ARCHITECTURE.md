# revnet-core-v6 — Architecture

## Purpose

Autonomous revenue networks ("revnets") built on Juicebox V6. REVDeployer creates projects with pre-programmed multi-stage rulesets that cannot be changed after deployment. REVLoans enables borrowing against locked revnet tokens.

## Contract Map

```
src/
├── REVDeployer.sol  — Deploys revnets: stages → rulesets, data hook, buyback, suckers, 721 tiers
├── REVLoans.sol     — Borrow against burned revnet tokens (10-year max, permissionless liquidation)
├── interfaces/
│   ├── IREVDeployer.sol
│   └── IREVLoans.sol
└── structs/         — REVConfig, REVStageConfig, REVLoanSource, REVAutoIssuance, etc.
```

## Key Data Flows

### Revnet Deployment
```
Deployer → REVDeployer.deployFor()
  → Create JB project via JBController
  → Convert REV stages → JBRulesetConfigs
    → Each stage: duration, weight, cashOutTaxRate, splits
    → Auto-issuance: pre-mint tokens to specified beneficiaries per chain
  → Set REVDeployer as data hook (controls pay + cashout behavior)
  → Initialize buyback pools at 1:1 price, configure buyback hook
  → Deploy suckers for cross-chain operation
  → Deploy 721 tiers if specified
  → Compute matching hash for cross-chain deployment verification
```

### Data Hook Behavior
```
Payment → REVDeployer.beforePayRecordedWith()
  → Delegate to buyback hook for swap-vs-mint decision
  → Return pay hook specifications

Cash Out → REVDeployer.beforeCashOutRecordedWith()
  → If caller is a sucker: 0% cash out tax (bridging privilege)
  → Otherwise: apply configured cashOutTaxRate
  → Return cash out hook specifications
```

### Loan Flow
```
Borrower → REVLoans.borrowFrom()
  → Burn borrower's revnet tokens as collateral
  → Calculate max borrow based on bonding curve value
  → Pull funds from treasury via USE_ALLOWANCE
  → Mint loan ERC-721 NFT to borrower

Repay → REVLoans.repayLoan()
  → Accept repayment (principal + prepaid fee)
  → Re-mint collateral tokens to borrower

Liquidate → REVLoans.liquidateExpiredLoansFrom()
  → After 10-year term, anyone can liquidate
  → Collateral permanently destroyed (was burned at borrow time)
```

## Extension Points

| Point | Interface | Purpose |
|-------|-----------|---------|
| Data hook | `IJBRulesetDataHook` | REVDeployer acts as data hook for all revnets |
| Buyback hook | `IJBBuybackHook` | Swap-vs-mint decision on payments |
| Sucker integration | `IJBSucker` | Cross-chain token bridging |
| 721 tiers | `IJB721TiersHook` | NFT tier rewards |

## Dependencies
- `@bananapus/core-v6` — Core protocol
- `@bananapus/721-hook-v6` — NFT tiers
- `@bananapus/buyback-hook-v6` — DEX buyback
- `@bananapus/suckers-v6` — Cross-chain bridging
- `@bananapus/router-terminal-v6` — Payment routing
- `@bananapus/permission-ids-v6` — Permission constants
- `@croptop/core-v6` — Croptop integration
- `@openzeppelin/contracts` — Standard utilities

## Key Design Decisions
- Stages are immutable after deployment — no owner can change ruleset parameters
- Matching hash ensures cross-chain deployments have identical economic parameters
- REVDeployer is the data hook for all revnets it deploys — centralizes behavioral control
- Loans use bonding curve value, not market price — independent of external DEX pricing
