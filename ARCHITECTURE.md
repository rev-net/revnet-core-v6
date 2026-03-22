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
  → Convert REV stages → JBRulesetConfigs (see Stage-to-Ruleset Mapping below)
    → Each stage: duration, weight, cashOutTaxRate, splits
    → Auto-issuance: record per-beneficiary token counts for later claiming
  → Set REVDeployer as data hook (controls pay + cashout behavior)
  → Initialize buyback pools at fair issuance price (derived from initialIssuance)
  → Deploy suckers for cross-chain operation
  → Deploy tiered ERC-721 hook (always — empty by default, pre-configured if specified)
  → Compute matching hash and store it for cross-chain sucker deployment
```

#### Matching Hash

The matching hash ensures that revnet deployments on different chains share identical economic parameters. It is computed inside `_makeRulesetConfigurations` by incrementally ABI-encoding the configuration fields, then taking the `keccak256` of the result.

Fields included in the hash (in encoding order):
1. **Base fields:** `baseCurrency`, `description.name`, `description.ticker`, `description.salt`
2. **Per-stage fields** (appended for each stage): `startsAtOrAfter` (defaults to `block.timestamp` for the first stage if zero), `splitPercent`, `initialIssuance`, `issuanceCutFrequency`, `issuanceCutPercent`, `cashOutTaxRate`
3. **Per-auto-issuance fields** (appended for each auto-issuance within a stage): `chainId`, `beneficiary`, `count`

The hash is stored in `hashedEncodedConfigurationOf[revnetId]` and used as part of the CREATE2 salt when deploying suckers via `SUCKER_REGISTRY.deploySuckersFor`. This guarantees that cross-chain sucker peers can only be deployed for revnets whose economic configuration matches exactly — a deployment on Chain B with different stage parameters would produce a different hash, a different salt, and therefore a different sucker address, preventing it from peering with Chain A's suckers.

Note that `splits` (the specific split recipient addresses) are **not** included in the hash. Splits may contain chain-specific addresses, so they are excluded to allow legitimate cross-chain deployments where the only difference is the split recipient addresses.

#### Auto-Issuance

Auto-issuance pre-allocates tokens to specified beneficiaries when a stage begins. Each `REVAutoIssuance` entry specifies a `chainId`, a `beneficiary` address, and a token `count`.

During deployment, the deployer records auto-issuance amounts in `amountToAutoIssue[revnetId][stageId][beneficiary]` — but only for entries whose `chainId` matches `block.chainid`. Entries for other chains are still included in the matching hash (ensuring cross-chain consistency) but are skipped for on-chain storage.

Claiming is a separate step: anyone can call `autoIssueFor(revnetId, stageId, beneficiary)` after the stage has started. This function verifies the stage's ruleset has begun (`ruleset.start <= block.timestamp`), zeroes the stored amount, and calls `CONTROLLER.mintTokensOf` to mint tokens directly to the beneficiary — bypassing the reserved percent so the full count goes to the beneficiary.

Stage IDs are assigned as `block.timestamp + i` (where `i` is the stage index), matching the JBRulesets ID assignment scheme when all stages are queued in a single transaction.

### Data Hook Behavior
```
Payment → REVDeployer.beforePayRecordedWith()
  → Query 721 tier hook for tier split specs (if configured)
  → Delegate remaining amount to buyback hook for swap-vs-mint decision
  → Scale weight so tokens are only minted for the project's share (after tier splits)
  → Return merged hook specifications (721 hook + buyback hook)

Cash Out → REVDeployer.beforeCashOutRecordedWith()
  → If caller is a sucker: 0% cash out tax, full reclaim (bridging privilege)
  → Enforce cash out delay (for cross-chain deployments of existing revnets)
  → If no tax, no fee terminal, or feeless beneficiary: delegate directly to buyback hook
  → Otherwise: split tokens into fee/non-fee portions via bonding curve
  → Delegate non-fee portion to buyback hook
  → Build fee hook spec routing fee amount to afterCashOutRecordedWith for processing
  → Return merged hook specifications (buyback hook + fee hook)
```

### Loan Flow
```
Borrower → REVLoans.borrowFrom()
  → Burn borrower's revnet tokens as collateral
  → Calculate borrow amount from bonding curve value of collateral
  → Pull funds from treasury via USE_ALLOWANCE
  → Mint loan ERC-721 NFT to borrower

Repay → REVLoans.repayLoan()
  → Accept repayment (principal + prepaid fee)
  → Re-mint collateral tokens to borrower

Liquidate → REVLoans.liquidateExpiredLoansFrom()
  → After 10-year term, anyone can liquidate
  → Collateral permanently destroyed (was burned at borrow time)
```

## Stage-to-Ruleset Mapping

Each `REVStageConfig` is converted to a `JBRulesetConfig` by `_makeRulesetConfiguration`. The mapping is direct — revnet stages are a constrained interface over Juicebox rulesets:

| REVStageConfig field | JBRulesetConfig field | Notes |
|---|---|---|
| `startsAtOrAfter` | `mustStartAtOrAfter` | Passed through directly |
| `issuanceCutFrequency` | `duration` | How often the issuance rate decays |
| `initialIssuance` | `weight` | Tokens per unit of base currency |
| `issuanceCutPercent` | `weightCutPercent` | Percent decrease each cycle (out of 1,000,000,000) |
| `splitPercent` | `metadata.reservedPercent` | Percent of new tokens split to recipients (out of 10,000) |
| `cashOutTaxRate` | `metadata.cashOutTaxRate` | Bonding curve tax on cash outs (out of 10,000) |
| `splits` | `splitGroups[0].splits` | Reserved token split recipients (group ID: RESERVED_TOKENS) |
| `extraMetadata` | `metadata.metadata` | 14-bit field for hook-specific flags |

Fields set automatically by the deployer (not configurable per stage):
- `metadata.baseCurrency` — from `REVConfig.baseCurrency`
- `metadata.useTotalSurplusForCashOuts` — always `true`
- `metadata.allowOwnerMinting` — always `true` (required for auto-issuance)
- `metadata.useDataHookForPay` — always `true`
- `metadata.useDataHookForCashOut` — always `true`
- `metadata.dataHook` — always `address(REVDeployer)`
- `approvalHook` — always `address(0)` (no approval hook; stages are immutable)
- `fundAccessLimitGroups` — set to `uint224.max` surplus allowance per terminal token for loan withdrawals

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
- `@prb/math` — Fixed-point math (`mulDiv`, `sqrt`)
- `@uniswap/permit2` — Permit2 token allowances (REVLoans)

## Key Design Decisions
- Stages are immutable after deployment — no owner can change ruleset parameters
- Matching hash ensures cross-chain deployments have identical economic parameters. It covers all economic fields (issuance, decay, tax rates, auto-issuances) but intentionally excludes split recipient addresses, which may differ by chain. The hash is used as a CREATE2 salt component for sucker deployment, so mismatched configs produce different sucker addresses that cannot peer with each other.
- REVDeployer is the data hook for all revnets it deploys — centralizes behavioral control
- Loans use bonding curve value, not market price — independent of external DEX pricing
- Auto-issuance is deferred, not instant — token amounts are recorded at deploy time but minted via a separate `autoIssueFor` call after the stage starts. This separates deployment from issuance, allows anyone to trigger the mint permissionlessly, and ensures tokens are not minted before their stage is active.
- No approval hook — revnet rulesets set `approvalHook` to `address(0)` because stages are configured immutably at deployment. There is no governance or owner who could queue a change that would need approval.
