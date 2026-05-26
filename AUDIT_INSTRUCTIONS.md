# Audit Instructions

Revnet is a staged, owner-minimized product layer on top of Juicebox core. Audit it as an economic system, not only a deployer plus a loan contract.

## Audit Objective

There is a billion dollars of well-meaning projects' money in the Juicebox Money Engine, growing exponentially. Your job is to hack it before anyone else. Whoever hacks it first saves/steals the money, and you are obsessed with being this winner, while also being a steward of the protocol and wanting it to keep growing safely.

Suggestions of where to look:

- break stage progression or let users act under the wrong stage assumptions
- overstate or understate borrowability
- mis-handle burned-collateral accounting
- give operators or integrations more power than the revnet model intends
- make omnichain supply, surplus, or sucker assumptions drift from runtime behavior

## Scope

In scope:

- `src/REVDeployer.sol`
- `src/REVOwner.sol`
- `src/REVLoans.sol`
- structs, interfaces, and deployment helpers

## Start Here

1. `src/REVDeployer.sol`
2. `src/REVOwner.sol`
3. `src/REVLoans.sol`

## Security Model

Revnet composes several sensitive systems:

- staged rulesets and launch-time immutability
- runtime pay and cash-out policy in `REVOwner`
- burned-collateral lending in `REVLoans`

The main audit mindset is composition:

- stage economics affect borrowability
- omnichain state can affect reclaim and borrowing power
- optional integrations can widen the effective trust surface

## Roles And Privileges

| Role | Powers | How constrained |
|------|--------|-----------------|
| Revnet deployer path | Define long-lived stage and operator shape | Must not retain unexpected mutable governance |
| Split operator | Use the allowed runtime envelope | Must stay within deployment-defined permissions |
| Borrower or delegated operator | Open or manage loans | Must not escape collateral, delay, or source limits |

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
4. Optional integrations do not silently widen revnet authority or mint rights.

## Attack Surfaces

- stage-transition boundaries
- live borrowability and cross-currency debt aggregation
- omnichain surplus and sucker exemptions
- payment and cash-out hook composition in `REVOwner`

## Accepted Risks Or Behaviors

- Revnets intentionally trade recoverability for predictable launch-time economics.
- Some economic surfaces are conservative by design and may refuse otherwise-valid actions rather than risk an unsafe result.

## Verification

- `npm install`
- `forge build --deny notes`
- `forge test --deny notes`
