# User Journeys

## Repo Purpose

This repo packages autonomous Revnets: staged Juicebox projects whose runtime behavior is intentionally constrained after launch. It owns deploy-time stage encoding, runtime enforcement, hidden-token mechanics, and lending against revnet token exposure.

## Primary Actors

- teams launching autonomous Revnets with encoded stage transitions
- participants buying, holding, and cashing out Revnet exposure over time
- borrowers using Revnet tokens as collateral instead of selling them
- operators working inside the narrow post-launch envelope the deployer allows

## Key Surfaces

- `REVDeployer`: launch-time packaging, stage config, and operator envelope
- `REVOwner`: runtime pay and cash-out behavior for active Revnets
- `REVLoans`: borrowing, repayment, transfer, reallocation, and liquidation
- `REVHiddenTokens`: temporarily hide and later reveal token supply
- `autoIssueFor(...)`, `hideTokensOf(...)`, `revealTokensOf(...)`, `borrowFrom(...)`: high-signal runtime entrypoints

## Journey 1: Launch A Revnet With Its Long-Lived Rules Encoded Up Front

**Actor:** launch team.

**Intent:** deploy a Revnet whose economic envelope is encoded up front and stays bounded afterward.

**Preconditions**

- the team knows the stage schedule, issuance behavior, operator envelope, and optional integrations
- the team accepts that many choices become expensive or impossible to change later

**Main Flow**

1. Use `REVDeployer` with the staged config, split operators, and optional integrations.
2. The deployer launches the underlying project and preserves the intended ownership model.
3. Stage and auxiliary behavior are committed at launch instead of left to ordinary owner discretion.
4. The Revnet can now accept payments and progress through stages under the encoded rules.

**Failure Modes**

- teams assume deploy-time parameters can be revisited casually
- optional integrations are enabled without auditing their effect on the resulting network

**Postconditions**

- the Revnet launches with its long-lived stage envelope encoded up front

## Journey 2: Participate Across Stage Transitions

**Actor:** participant.

**Intent:** buy, hold, and exit Revnet exposure across stage changes.

**Preconditions**

- the Revnet is already live
- the participant understands active stage parameters can change behavior over time

**Main Flow**

1. Pay through the configured terminal or router.
2. Let `REVOwner` enforce runtime behavior such as pay handling, delayed exits, and stage-sensitive constraints.
3. As stages advance, later pays and exits follow the new active parameters while project identity stays constant.

**Failure Modes**

- stage parameters are misread as mutable when they are fixed
- delayed cash-out behavior is misunderstood
- optional integrations materially change the participant experience

**Postconditions**

- the participant's buys and exits follow the active stage's constraints

## Journey 3: Claim Stage-Based Auto-Issuance

**Actor:** auto-issuance beneficiary.

**Intent:** claim stage-specific issuance only when it is actually live.

**Preconditions**

- the Revnet was deployed with auto-issuance allocations
- the target stage has started

**Main Flow**

1. Check `amountToAutoIssue(...)`.
2. Call `autoIssueFor(...)` once the stage is active.
3. The stored allocation is consumed and cannot be claimed twice.

**Failure Modes**

- callers try to claim before the stage is active
- reviewers assume auto-issuance is a generic mint path rather than a bounded stage allocation

**Postconditions**

- the stage allocation is either claimed once or remains reserved until valid

## Journey 4: Hide Tokens To Change Visible Supply

**Actor:** holder or authorized operator.

**Intent:** remove tokens from visible supply temporarily and later restore them.

**Preconditions**

- the holder granted `BURN_TOKENS` to `REVHiddenTokens`
- either the holder has been allowlisted for hidden-token actions, or the caller is the project owner / an operator with `HIDE_TOKENS`
- the holder accepts the supply and collateral implications of hiding tokens

**Main Flow**

1. Grant `BURN_TOKENS` to `REVHiddenTokens`.
2. An operator calls `setTokenHidingAllowedFor(...)` to allow the holder to hide their own tokens.
3. The holder, project owner, or a `HIDE_TOKENS` operator calls `hideTokensOf(...)` to burn tokens and track the hidden balance.
4. The lower visible supply changes per-token cash-out value.
5. Later, the holder calls `revealTokensOf(...)` to remint hidden tokens back to themselves.

**Failure Modes**

- more tokens are revealed than were hidden
- holders attempt to hide tokens without being allowlisted
- non-holders attempt to reveal hidden tokens
- hidden tokens are assumed to remain usable as loan collateral

**Postconditions**

- visible supply is reduced or restored according to the holder's hidden-token state

## Journey 5: Borrow Against Revnet Tokens Instead Of Selling Them

**Actor:** holder or delegated loan operator.

**Intent:** borrow against Revnet exposure instead of selling it.

**Preconditions**

- the holder has eligible Revnet token exposure
- the holder trusts any delegated operator with `OPEN_LOAN`

**Main Flow**

1. Interact with `REVLoans` using eligible token exposure as collateral.
2. The system burns the collateralized exposure and mints a loan NFT.
3. Borrowed value is issued under live Revnet economics.
4. The borrower can later repay, reallocate, transfer, or face liquidation.

**Failure Modes**

- delegated operators redirect value in ways the holder did not intend
- reviewers model the loan system as escrowed collateral when it is burned-collateral lending

**Postconditions**

- collateralized exposure becomes a live loan position under Revnet economics

## Journey 6: Operate Inside The Bounded Post-Launch Control Envelope

**Actor:** operator with ongoing powers.

**Intent:** use the sanctioned post-launch controls without violating the autonomous model.

**Preconditions**

- the Revnet is live
- the operator knows exactly which controls the deployment left available

**Main Flow**

1. Review what `REVDeployer` allowed.
2. Use only those sanctioned surfaces.
3. Audit cross-package behavior whenever optional integrations are enabled.

**Failure Modes**

- operators behave as though the Revnet were a normal owner-governed project
- reviewers inspect controls in isolation and miss integrated runtime behavior

**Postconditions**

- post-launch control remains inside the bounded envelope left by deployment

## Trust Boundaries

- this repo is trusted for revnet-specific economics and runtime policy
- treasury accounting still comes from core
- optional integrations materially change revnet behavior and must be reviewed together with the local code

## Hand-Offs

- Use [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md) for underlying terminal and project accounting.
- Use [nana-buyback-hook-v6](../nana-buyback-hook-v6/USER_JOURNEYS.md), [nana-suckers-v6](../nana-suckers-v6/USER_JOURNEYS.md), and [nana-721-hook-v6](../nana-721-hook-v6/USER_JOURNEYS.md) when those integrations are enabled.
