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

- `REVDeployer` holds the project NFT and therefore remains part of the ownership model.
- Revnet economics are mainly fixed at deployment through staged rulesets.
- `REVOwner` provides live runtime policy, but not broad human governance.
- Split operators can hold narrow powers depending on stage and deployment config.
- `REVLoans` has a cosmetic global owner surface, but loan economics are still bounded by revnet logic.

## Roles

| Role | How Assigned | Scope | Notes |
| --- | --- | --- | --- |
| `REVDeployer` | Deployed singleton | Global launcher and project-NFT holder | Part of the ownership model |
| Split operator | Deployment config | Per revnet | Holds only the allowed operator envelope |
| Auto-issuance beneficiary | Deployment config | Per stage | Can receive preconfigured stage issuance |
| Borrower or delegated loan operator | Token holder plus permission | Per holder or loan | Can open or manage loans within loan rules |
| `REVLoans` owner | Constructor owner | Global cosmetic/admin surface; controls `setTokenUriResolver` and `setReferralProjectId` | Does not turn Revnets back into ordinary governed projects |

## Privileged Surfaces

- `deployFor(...)` defines the revnet's long-lived shape
- operator paths can manage only the permissions left open by deployment, including explicit sucker-peer selection
  when cross-chain suckers are deployed
- `autoIssueFor(...)` consumes preconfigured stage issuance
- loan operators can redirect borrowed value if a holder delegates loan permissions
- `REVLoans.setReferralProjectId(projectId, chainId)` — `onlyOwner`; retargets the fee-volume referrer credited on every `useAllowanceOf` call this contract makes. Stores the packed `(chainId << 48) | projectId` value `JBMultiTerminal` expects on its `referralProjectId` argument. Defaults to `(1, REV_ID)` at construction so credit lands on the REV revnet on Ethereum mainnet regardless of which chain the loan originates from. Passing `(0, 0)` disables the credit entirely. Bounded so the pack is lossless: `projectId <= type(uint48).max`, `chainId <= type(uint208).max`.
- `REVLoans.setTokenUriResolver(resolver)` — `onlyOwner`; swaps the token-URI resolver for loan NFTs. Pure cosmetic; does not affect loan economics.
## Immutable And One-Way

- Stage configuration is effectively permanent after deployment.
- The deployer-held project NFT is not a normal owner-recovery tool.
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
