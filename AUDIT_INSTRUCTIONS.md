# Audit Instructions

Revnets are autonomous Juicebox projects with staged economics and token-collateralized loans. Audit this repo as both a privileged deployer layer and a live economic system.

## Objective

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

## System Model

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

## Threat Model

Prioritize:
- surplus manipulation before and after borrowing
- stage-boundary timing attacks
- cash-out delay bypasses
- array or hook-spec assumptions that depend on non-empty returns
- split-weight accounting during 721 compositions
- Permit2 and ERC-2771 assisted loan flows
- operator delegation abuse: `OPEN_LOAN`, `REPAY_LOAN`, `REALLOCATE_LOAN`, `HIDE_TOKENS`, `REVEAL_TOKENS` permission checks — verify collateral and loan NFTs always flow to the holder/owner, never the operator

The best attacker mindsets here are:
- a borrower who can move surplus or stage timing before and after borrowing
- a caller exploiting the fact that revnets are composed from several optional subsystems, not one monolith
- an operator or deployer helper that retained one capability too many
- a delegated operator who tricks a holder into granting permission, then exploits the delegation to extract value (e.g., borrowing on behalf of a holder and directing funds to a beneficiary they control)

## Hotspots

- `REVOwner.beforePayRecordedWith`
- `REVOwner.beforeCashOutRecordedWith`
- deployer-only linkage between `REVDeployer` and `REVOwner`
- `REVLoans` borrowable amount, fee accrual, and liquidation logic
- `REVHiddenTokens.hideTokensOf` and `revealTokensOf` burn/mint symmetry and `HIDE_TOKENS`/`REVEAL_TOKENS` permission checks
- `REVLoans` operator delegation: `OPEN_LOAN`, `REPAY_LOAN`, `REALLOCATE_LOAN` inline permission checks — verify holder/owner receives collateral and loan NFTs in all delegation paths
- any path that assumes a valid tiered 721 hook or sucker mapping exists

## Sequences Worth Replaying

1. Pay into a revnet with 721 and buyback composition enabled, then inspect how weight is scaled before and after hook specs are consumed.
2. Borrow near a stage boundary, then repay, refinance, or liquidate after the next stage becomes active.
3. Borrow after surplus inflation, then force or observe surplus contraction before liquidation.
4. Cash out through a legitimate sucker path versus a near-sucker spoof path.
5. Any path where `REVOwner` expects hook arrays or external replies to be non-empty.
6. Hide tokens, have an accomplice cash out at the inflated rate, then reveal — check whether the net outcome is profitable.

## Finding Bar

The best findings in this repo usually prove one of these:
- a revnet mints or redeems on economics different from the stage schedule users think they are on
- the runtime hook scales payment or cash-out accounting incorrectly during composition
- the loan system can externalize loss to the treasury through timing, surplus movement, or fee math
- a deployer-only or operator-only assumption survives launch and remains exploitable at runtime

## Build And Verification

Standard workflow:
- `npm install`
- `forge build`
- `forge test`

Current tests emphasize:
- lifecycle and invincibility properties
- loan invariants and attacks
- fee recovery
- split-weight adjustments
- regressions around low-severity edge cases

Strong findings in this repo usually combine economics and composition: a bug is especially valuable if it only appears once a revnet is wired into the rest of the ecosystem.
