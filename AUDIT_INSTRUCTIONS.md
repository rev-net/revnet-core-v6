# Audit Instructions

Revnets are autonomous Juicebox projects with staged economics and token-collateralized loans. Audit this repo as both a privileged deployer layer and a live economic system.

## Audit Objective

Find issues that:
- let a participant borrow more than intended against revnet collateral
- break stage transitions or immutable revnet economics
- mis-scale weights, fees, or split behavior in composed payment flows
- grant owner-like or operator-like powers outside the documented model
- leave deployed revnets or loans in states that cannot settle safely

## Scope

In scope:
- `src/REVDeployer.sol`
- `src/REVOwner.sol`
- `src/REVLoans.sol`
- `src/REVHiddenTokens.sol`
- `src/interfaces/`
- `src/structs/`
- deployment scripts in `script/`

Key dependencies:
- `nana-core-v6`
- `nana-721-hook-v6`
- `nana-buyback-hook-v6`
- `nana-suckers-v6`
- `croptop-core-v6`

## Start Here

Read in this order:
- `REVOwner`
- `REVDeployer`
- `REVLoans`

`REVOwner` is the fastest way to understand how a live revnet differs from plain Juicebox behavior.
`REVDeployer` explains why that behavior exists.
`REVLoans` is where those economics are turned into extractable collateral value.

## Security Model

The repo splits responsibilities:
- `REVDeployer`: launches revnets, encodes stage configs, manages optional 721 and sucker composition
- `REVOwner`: runtime data/cash-out hook used by deployed revnets
- `REVLoans`: loan system that burns collateral on borrow and re-mints on repayment
- `REVHiddenTokens`: temporary token hiding that burns tokens to exclude from totalSupply and re-mints on reveal

Important composition behavior:
- revnet payments may be proxied through 721 and buyback hooks
- cash-out behavior may be altered for suckers or by revnet-specific fee handling
- loan health depends on bonding-curve value and surplus, so core accounting and stage timing directly matter

Two mental models help here:
- `REVDeployer` is mostly a launch-time authority that permanently shapes economics
- `REVOwner` is a runtime hook that can make a launched revnet behave very differently from a plain Juicebox project

## Roles And Privileges

| Role | Powers | How constrained |
|------|--------|-----------------|
| Revnet launcher | Set the stage schedule and optional compositions | Must not retain hidden runtime privilege |
| `REVOwner` | Alter payment and cash-out behavior at runtime | Must remain narrowly scoped to documented economics |
| Borrower or operator | Open, repay, reallocate, hide, or reveal with delegated permissions | Must not redirect collateral or proceeds away from the holder |

## Integration Assumptions

| Dependency | Assumption | What breaks if wrong |
|------------|------------|----------------------|
| `nana-core-v6` | Surplus and issuance accounting remain coherent | Borrow limits and stage economics become unsound |
| `nana-721-hook-v6` and `nana-buyback-hook-v6` | Optional composition does not distort accounting unexpectedly | Runtime economics diverge from the stage design |
| `nana-suckers-v6` | Omnichain privilege surfaces identify real suckers only | Fee-free or mint exemptions widen |

## Critical Invariants

1. Stage immutability
Once a revnet is launched, future stage economics must follow the encoded schedule and not become mutable through helper paths.

2. Payment accounting is scaled correctly
If only part of a payment enters the treasury because of split or hook routing, token issuance must reflect only that treasury-entering portion.

3. Loan collateralization is sound
Borrow, repay, refinance, and liquidation paths must never let a borrower extract more value than the design permits.

4. Hook privilege stays narrow
`REVOwner` and deployer-only setters must not be callable by arbitrary actors or stale deployment helpers.

5. Sucker and operator exemptions are precise
Fee-free or mint-enabled paths meant for registered omnichain components must not be reusable by arbitrary callers.

6. Collateral burn/remint symmetry holds
Loan collateral that is burned on borrow and re-minted on repay must not be duplicable, strandable, or recoverable by the wrong party.

7. Hidden token accounting is sound
Tokens hidden via REVHiddenTokens must be exactly recoverable on reveal. The hidden balance must not allow minting more tokens than were burned, and totalHiddenOf must equal the sum of all per-holder hidden balances.

8. Stage transitions do not create hidden refinancing windows
Changes in issuance or cash-out economics across stages must not let a borrower lock in value that the system intended to become unavailable.

## Attack Surfaces

- `REVOwner.beforePayRecordedWith`
- `REVOwner.beforeCashOutRecordedWith`
- deployer-only linkage between `REVDeployer` and `REVOwner`
- `REVLoans` borrowable amount, fee accrual, and liquidation logic
- `REVHiddenTokens.hideTokensOf` and `revealTokensOf` burn/mint symmetry and `HIDE_TOKENS`/`REVEAL_TOKENS` permission checks
- `REVLoans` operator delegation: `OPEN_LOAN`, `REPAY_LOAN`, `REALLOCATE_LOAN` inline permission checks — verify holder/owner receives collateral and loan NFTs in all delegation paths
- any path that assumes a valid tiered 721 hook or sucker mapping exists

Replay these sequences:
1. pay into a revnet with 721 and buyback composition enabled and inspect weight scaling
2. borrow near a stage boundary, then repay, refinance, or liquidate in the next stage
3. borrow after surplus inflation, then contract surplus before liquidation
4. cash out through a legitimate sucker path versus a near-sucker spoof path
5. hide tokens, let another actor cash out, then reveal

## Accepted Risks Or Behaviors

- Composition is the default audit target here, not an edge case.

## Verification

- `npm install`
- `forge build`
- `forge test`
