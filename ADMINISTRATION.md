# Administration

## At A Glance

| Item | Details |
| --- | --- |
| Scope | Revnet deployment shape, bounded runtime operators, loan-owner cosmetics, and optional integration control surfaces |
| Control posture | Intentionally narrow and mostly deployment-defined |
| Highest-risk actions | Bad stage design, wrong operator assignment, and misunderstanding which runtime surfaces stay live after launch |
| Recovery posture | Usually replacement, not patching; the design intentionally avoids easy admin escape hatches |

## Purpose

`revnet-core-v6` is designed to collapse ordinary post-launch governance into deployment-time decisions plus a small set of bounded runtime roles. The main administration task is understanding which power still exists and which power was intentionally removed.

## Control Model

- `REVOwner` holds the project NFT for every Revnet and is therefore the authoritative on-chain project owner. It also manages operator permissions and exposes the post-deploy administrative surface (`autoIssueFor`, `burnHeldTokensOf`, `setOperatorOf`).
- `REVDeployer` is a deploy-only factory. It creates and configures each Revnet, then transfers the project NFT to `REVOwner`. It retains `deploySuckersFor` so the same address remains responsible for ongoing sucker registrations.
- Revnet economics are mainly fixed at deployment through staged rulesets.
- `REVOwner` provides live runtime policy as the data hook, but not broad human governance.
- Split operators can hold narrow powers depending on stage and deployment config.
- `REVLoans` has a cosmetic global owner surface, but loan economics are still bounded by revnet logic.

## Roles

| Role | How Assigned | Scope | Notes |
| --- | --- | --- | --- |
| `REVOwner` | Deployed singleton | Project-NFT holder + operator-permission grantor for every Revnet | The authoritative on-chain owner |
| `REVDeployer` | Deployed singleton | Global launcher and sucker-deploy entrypoint | Deploy-only factory; hands the project NFT to `REVOwner` at the end of `deployFor` |
| Split operator | Deployment config | Per revnet | Holds only the allowed operator envelope |
| Auto-issuance beneficiary | Deployment config | Per stage | Can receive preconfigured stage issuance |
| Borrower or delegated loan operator | Token holder plus permission | Per holder or loan | Can open or manage loans within loan rules |
| `REVLoans` owner | Constructor owner | Global cosmetic/admin surface; controls `setTokenUriResolver` and `setReferralProjectId` | Does not turn Revnets back into ordinary governed projects |

## Privileged Surfaces

- `REVDeployer.deployFor(...)` defines the revnet's long-lived shape
- `REVDeployer.deploySuckersFor(...)` adds new suckers post-deploy when the active ruleset allows it; gated by the operator
- `REVOwner.autoIssueFor(...)` consumes preconfigured stage issuance
- `REVOwner.burnHeldTokensOf(...)` burns reserved-token leftovers that accrue on the owner contract
- `REVOwner.setOperatorOf(...)` rotates the operator (current operator only)
- operator paths can manage only the permissions left open by deployment
- loan operators can redirect borrowed value if a holder delegates loan permissions
- `REVLoans.setReferralProjectId(projectId, chainId)` — `onlyOwner`; retargets the fee-volume referrer credited on every `useAllowanceOf` call this contract makes. Stores the packed `(chainId << 48) | projectId` value `JBMultiTerminal` expects on its `referralProjectId` argument. Defaults to `(1, REV_ID)` at construction so credit lands on the REV revnet on Ethereum mainnet regardless of which chain the loan originates from. Passing `(0, 0)` disables the credit entirely. Bounded so the pack is lossless: `projectId <= type(uint48).max`, `chainId <= type(uint208).max`.
- `REVLoans.setTokenUriResolver(resolver)` — `onlyOwner`; swaps the token-URI resolver for loan NFTs. Pure cosmetic; does not affect loan economics.
## Immutable And One-Way

- Stage configuration is effectively permanent after deployment.
- The `REVOwner`-held project NFT is not a normal owner-recovery tool.
- Loan collateral is burned at borrow time and only reminted through repayment or documented flows.
## Operational Notes

- Treat revnet launch as the real governance decision.
- Validate stage timing, operator scope, and optional integrations before deployment.
- Review cash-out delay and loan permissions together.
- Do not assume there is a broad admin override for bad economics after launch.

## Machine Notes

- Do not describe Revnets as fully adminless if the deployer-held NFT still matters for the trust model.
- Also do not describe them as ordinary owner-controlled projects. The point is that the available control surface is intentionally narrow.
- If a question is about runtime cash-outs, buybacks, or mint permissions, inspect `REVOwner` before inferring behavior from deployment prose.

## Recovery

- If launch-time economics are wrong, recovery usually means replacement, not in-place repair.
- If optional integrations are misconfigured, fix only where the code still exposes a valid path.
- If the design intentionally omitted a recovery path, do not invent one in documentation or ops guidance.

## Admin Boundaries

- No ordinary owner can casually rewrite staged economics after launch.
- Split operators are not general-purpose governors.
- Loan mechanics and cash-out policy remain bounded by the deployed revnet logic.
- This repo should not be documented as if it had a normal mutable project-owner model.
