# User Journeys

## Repo Purpose

This repo packages autonomous Revnets: staged Juicebox projects whose runtime behavior is intentionally constrained
after launch. It owns deploy-time stage encoding, runtime enforcement, hidden-token mechanics, and lending against
Revnet token exposure. It does not turn the project back into an ordinary owner-governed treasury after deployment.

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

## Journey 2: Participate In The Revnet Across Stage Transitions

**Actor:** participant.

**Intent:** buy, hold, and exit Revnet exposure across stage changes.

**Preconditions**
- the Revnet is already live
- the participant understands active stage parameters can change behavior over time

**Main Flow**
1. Pay through the configured terminal or router.
2. Let `REVOwner` enforce runtime behavior such as pay handling, delayed exits, and stage-sensitive constraints.
3. As stages advance, later pays and exits follow the new active parameters while identity stays constant.

**Failure Modes**
- stage parameters are misread as mutable when they are fixed
- delayed cash-out behavior is misunderstood
- optional integrations materially change the participant experience in ways the caller ignored

**Postconditions**
- the participant's buys and exits now follow the active stage's constraints

## Journey 3: Claim Stage-Based Auto-Issuance When It Becomes Available

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
- the stage allocation is either claimed once or remains reserved until it becomes valid

## Journey 3a: Hide Tokens To Increase Cash-Out Value For Remaining Holders

**Actor:** holder or authorized operator.

**Intent:** remove tokens from visible supply temporarily and later restore them.

**Preconditions**
- the holder granted the required permissions
- the holder accepts the supply and collateral implications of hiding tokens

**Main Flow**
1. Grant `BURN_TOKENS` to `REVHiddenTokens`.
2. Call `hideTokensOf(...)` to burn tokens and track the hidden balance.
3. The lower visible supply changes per-token cash-out value.
4. Later call `revealTokensOf(...)` to re-mint hidden tokens.

**Failure Modes**
- more tokens are revealed than were hidden
- holders forget revealed tokens increase visible supply again
- hidden tokens are assumed to remain usable as loan collateral

**Postconditions**
- visible supply is reduced or restored according to the holder's hidden-token state

## Journey 4: Borrow Against Revnet Tokens Instead Of Selling Them

**Actor:** holder or delegated loan operator.

**Intent:** borrow against Revnet exposure instead of selling it.

**Preconditions**
- the holder has eligible Revnet token exposure
- the holder trusts any delegated operator with `OPEN_LOAN`

**Main Flow**
1. Interact with `REVLoans` using eligible token exposure as collateral.
2. The system burns the collateralized token exposure and mints a loan NFT.
3. Borrowed value is issued under live Revnet economics.
4. The borrower can later repay, reallocate, transfer, or face liquidation.

**Failure Modes**
- delegated operators redirect value in ways the holder did not intend
- reviewers model the loan system as escrowed collateral when it is burned-collateral lending

**Postconditions**
- collateralized exposure is transformed into a live loan position under Revnet economics

## Journey 5: Repay, Transfer, Or Liquidate A Loan Position

**Actor:** borrower, loan owner, or liquidator.

**Intent:** change or settle an existing loan position.

**Preconditions**
- a loan already exists
- the actor has the rights or economic incentives required for the chosen path

**Main Flow**
1. Repay to burn debt and restore the collateralized exposure.
2. Transfer the loan NFT if ownership of the debt position should move.
3. Liquidate if the encoded conditions permit it.

**Failure Modes**
- cross-ruleset behavior is misread
- zero-value or sourced-versus-unsourced paths are handled incorrectly by integrations

**Postconditions**
- the loan position is repaid, transferred, or liquidated according to the chosen path

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
- post-launch control remains inside the bounded envelope the deployment left available

## Journey 7: Receive Cross-Chain Payments With Correct Hook Routing

**Actor:** remote participant or integrator using suckers.

**Intent:** preserve the real beneficiary during cross-chain payments into a Revnet.

**Preconditions**
- the Revnet is configured with suckers and optional hooks that depend on the beneficiary
- relay-beneficiary metadata is provided correctly

**Main Flow**
1. The sucker calls `terminal.pay()` with relay-beneficiary metadata.
2. `REVOwner.beforePayRecordedWith()` resolves the real beneficiary when the payer is a registered sucker.
3. Downstream hooks observe the remote user rather than the sucker contract.

**Failure Modes**
- relay metadata is absent or malformed
- downstream hooks accidentally attribute minting or routing to the sucker instead of the user

**Postconditions**
- cross-chain payments preserve the intended remote beneficiary through the Revnet hook stack

## Trust Boundaries

- `REVDeployer` is trusted for the launch-time envelope the Revnet will live inside
- `REVOwner` is economically binding runtime logic, not advisory middleware
- optional integrations such as 721 hooks, buybacks, router terminals, and suckers materially alter the resulting network

## Hand-Offs

- Use [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md) for the underlying project, terminal, and ruleset mechanics that Revnets package and constrain.
- Use [nana-721-hook-v6](../nana-721-hook-v6/USER_JOURNEYS.md), [nana-buyback-hook-v6](../nana-buyback-hook-v6/USER_JOURNEYS.md), and [nana-suckers-v6](../nana-suckers-v6/USER_JOURNEYS.md) when a Revnet deployment enables those optional features.
