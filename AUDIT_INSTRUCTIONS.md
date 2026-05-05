# Audit Instructions

Revnet is a staged, owner-minimized product layer on top of Juicebox core. Audit it as an economic system, not just a deployer plus a loan contract.

## Audit Objective

Find issues that:

- break stage progression or let users act under the wrong stage assumptions
- overstate or understate borrowability
- mis-handle hidden tokens or burned-collateral accounting
- give operators or integrations more power than the revnet model intends
- make omnichain supply, surplus, or sucker assumptions drift from runtime behavior

## Scope

In scope:

- `src/REVDeployer.sol`
- `src/REVOwner.sol`
- `src/REVLoans.sol`
- `src/REVHiddenTokens.sol`
- structs, interfaces, and deployment helpers

## Start Here

1. `src/REVDeployer.sol`
2. `src/REVOwner.sol`
3. `src/REVLoans.sol`
4. `src/REVHiddenTokens.sol`

## Security Model

Revnet composes several sensitive systems:

- staged rulesets and launch-time immutability
- runtime pay and cash-out policy in `REVOwner`
- burned-collateral lending in `REVLoans`
- hidden-token supply exclusion in `REVHiddenTokens`

The main audit mindset is composition:

- stage economics affect borrowability
- hidden supply affects cash-out math
- omnichain state can affect reclaim and borrowing power
- optional integrations can widen the effective trust surface

## Roles And Privileges

| Role | Powers | How constrained |
|------|--------|-----------------|
| Revnet deployer path | Define long-lived stage and operator shape | Must not retain unexpected mutable governance |
| Split operator | Use the allowed runtime envelope | Must stay within deployment-defined permissions |
| Borrower or delegated operator | Open or manage loans | Must not escape collateral, delay, or source limits |
| Hidden-token user or delegate | Burn and reveal visible supply | Must not create extra supply or break accounting |

## Integration Assumptions

| Dependency | Assumption | What breaks if wrong |
|------------|------------|----------------------|
| `nana-core-v6` | Rulesets, reclaim math, and surplus views stay coherent | Stage and cash-out behavior drift |
| `nana-suckers-v6` | Remote supply/surplus snapshots are authentic | Omnichain reclaim and borrowability drift |
| Buyback and 721 integrations | Hook composition remains consistent with revnet expectations | Pay-path and mint-permission behavior drift |

## Critical Invariants

1. Stage progression stays monotonic and follows deployed timing.
2. Borrowability respects cash-out delay, surplus, supply, and source limits.
3. Burned collateral is not accidentally treated like escrowed collateral.
4. Hidden-token accounting preserves total claims while changing visible supply intentionally.
5. Optional integrations do not silently widen revnet authority or mint rights.

## Attack Surfaces

- stage-transition boundaries
- live borrowability and cross-currency debt aggregation
- hidden-token burn and reveal flows
- omnichain surplus and sucker exemptions
- payment and cash-out hook composition in `REVOwner`

## Accepted Risks Or Behaviors

- Revnets intentionally trade recoverability for predictable launch-time economics.
- Some economic surfaces are conservative by design and may refuse otherwise-valid actions rather than risk an unsafe result.

## Verification

- `npm install`
- `forge build --deny notes`
- `forge test --deny notes`
