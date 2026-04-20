# Administration

## At A Glance

| Item | Details |
| --- | --- |
| Scope | Revnet deployment shape, split-operator runtime authority, and cosmetic `REVLoans` ownership |
| Control posture | Mostly immutable economics with a narrow runtime operator |
| Highest-risk actions | Deploying the wrong stage design, assigning the wrong split operator, and overestimating `REVLoans` owner power |
| Recovery posture | Core economic mistakes require new revnets; some optional integrations can be corrected by the split operator |

## Purpose

`revnet-core-v6` is designed to minimize ongoing human control. The core split is between deployment-time shape, the limited split-operator role, the globally owned-but-cosmetic `REVLoans` metadata surface, and the intentionally ownerless project pattern enforced through `REVDeployer` and `REVOwner`.

## Control Model

- Deployment-time configuration is the real place where revnet economics are chosen.
- The split operator is the only intended human-controlled runtime role for a revnet.
- `REVLoans` owner only controls loan NFT metadata rendering.
- `REVDeployer` holds the project NFT structurally, not as a discretionary human admin.
- Many economically sensitive behaviors are intentionally not mutable after deployment.

## Roles

| Role | How Assigned | Scope | Notes |
| --- | --- | --- | --- |
| Split operator | `REVConfig.splitOperator` at deployment | Per revnet | Narrow runtime operator surface |
| `REVLoans` owner | `Ownable(owner)` on `REVLoans` | Global | Cosmetic metadata role, not economic admin |
| Loan NFT owner | ERC-721 loan ownership | Per loan | Can repay or reallocate subject to checks |
| Hidden-token caller or delegate | Holder or delegated permission | Per holder | Manages hide and reveal flows |
| Anyone | No assignment | Global or per revnet | Some lifecycle functions are permissionless |

## Privileged Surfaces

| Contract | Function | Who Can Call | Effect |
| --- | --- | --- | --- |
| `REVDeployer` | `deployFor(...)` | Anyone for new deployments, or current owner for conversion path | Creates or converts a project into a revnet |
| `REVDeployer` | `deploySuckersFor(...)` | Split operator | Adds sucker infra where the revnet config allows it |
| `REVDeployer` | `setSplitOperatorOf(...)` | Current split operator | Replaces or burns the split-operator role |
| `REVLoans` | `setTokenUriResolver(...)` | `REVLoans` owner | Cosmetic loan-NFT metadata control |
| `REVLoans` | `borrowFrom(...)`, `repayLoan(...)`, `reallocateCollateralFromLoan(...)` | Holder or delegated loan operator | Position-level administration, not protocol-level governance |

## Immutable And One-Way

- Stage schedule and core economics are chosen at deployment and then fixed.
- Converting an existing project into a revnet is effectively irreversible.
- Burning the split-operator role to `address(0)` is final.
- `REVDeployer` structurally retains project-NFT ownership in the design.
- Expired loans can eventually liquidate into permanently lost collateral if they are not repaid within the long liquidation window.

## Operational Notes

- Use the split operator only for the intentionally narrow surfaces left mutable.
- Treat buyback, router, sucker, and optional 721 adjustments as operational extensions around a fixed economic core.
- Keep `REVLoans` owner power limited to URI resolver maintenance.
- Treat loan operations as position management with real long-tail irreversibility; after the liquidation duration expires, collateral recovery is no longer available.

## Machine Notes

- Do not infer broad control from `REVDeployer` holding the project NFT; the design is intentionally constrained.
- Treat `src/REVDeployer.sol`, `src/REVOwner.sol`, and `src/REVLoans.sol` together when crawling authority.
- If stage config or split-operator assumptions differ from deployed state, stop; those are foundational revnet assumptions, not cosmetic metadata.

## Recovery

- Wrong stage design is not realistically recoverable in place; deploy a new revnet.
- Wrong optional integration can sometimes be corrected if the split operator still has the required scoped power.
- There is no broad admin escape hatch that can rewrite revnet economics after launch.
- Liquidated loan collateral is not an admin-recoverable asset; recovery must happen before liquidation through borrower action.

## Admin Boundaries

- The split operator cannot rewrite issuance schedule, cash-out tax, or stage timing.
- `REVLoans` owner cannot redirect collateral or treasury funds.
- `REVDeployer` cannot act like a normal human owner despite holding the project NFT.
- Nobody can change the revnet's fundamental staged design after deployment.
- Nobody can administratively restore collateral after an expired loan has been liquidated.

## Source Map

- `src/REVDeployer.sol`
- `src/REVOwner.sol`
- `src/REVLoans.sol`
- `src/REVHiddenTokens.sol`
- `test/`
