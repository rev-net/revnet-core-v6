# User Journeys

## Who This Repo Serves

- teams launching autonomous Revnets with encoded stage transitions
- participants buying, holding, and cashing out Revnet exposure over time
- borrowers using Revnet tokens as collateral instead of selling them
- operators working inside the narrow post-launch envelope the deployer allows

## Journey 1: Launch A Revnet With Its Long-Lived Rules Encoded Up Front

**Starting state:** you know the stage schedule, issuance behavior, optional integrations, and runtime controls the Revnet should allow.

**Success:** the Revnet launches as a Juicebox project whose deploy-time shape already encodes its economic envelope.

**Flow**
1. Use `REVDeployer` with the staged config, split operators, and optional integrations such as 721 hooks, buyback routing, router terminal support, or suckers.
2. The deployer launches the underlying project and keeps the ownership model aligned with the Revnet runtime contracts.
3. Stage config, issuance behavior, and auxiliary surfaces are committed as part of the launch instead of being left to human operators later.
4. The network can now accept payments and transition across stages without ordinary project-owner governance.

## Journey 2: Participate In The Revnet Across Stage Transitions

**Starting state:** the Revnet is live and a participant wants to pay in, hold exposure, or cash out later.

**Success:** participation follows the current stage's rules without requiring the user to reason about every deploy-time parameter directly.

**Flow**
1. Users pay through the configured terminal or router surface.
2. `REVOwner` enforces runtime behavior such as pay handling, cash-out rules, delayed exits, and other stage-sensitive constraints.
3. As stages advance, later pays and cash outs follow the newly active parameters while the project identity stays constant.

**Failure cases that matter:** assuming a stage parameter is mutable when it is fixed at launch, misreading delayed cash-out behavior, and forgetting that optional integrations materially change the participant experience.

## Journey 3: Claim Stage-Based Auto-Issuance When It Becomes Available

**Starting state:** the Revnet was deployed with auto-issuance allocations for one or more beneficiaries.

**Success:** the beneficiary claims the right amount for the right stage only after that stage is actually live.

**Flow**
1. Check `amountToAutoIssue(...)` for the revnet, stage, and beneficiary.
2. Call `autoIssueFor(...)` only once the target stage has started.
3. The stored allocation is consumed so the same stage allocation cannot be claimed twice.

## Journey 3a: Hide Tokens To Increase Cash-Out Value For Remaining Holders

**Starting state:** a holder wants to temporarily exclude some tokens from totalSupply without permanently giving them up.

**Success:** the holder burns tokens via REVHiddenTokens, reducing totalSupply and increasing the per-token cash-out value for everyone else. The holder can reveal (re-mint) their hidden tokens at any time.

**Flow**
1. The holder grants `BURN_TOKENS` permission to the `REVHiddenTokens` contract for the revnet.
2. Call `hideTokensOf(revnetId, tokenCount)` to burn the tokens and track the hidden balance.
3. The bonding curve now sees a smaller totalSupply, so each remaining token is worth more on cash out.
4. When the holder wants their tokens back, call `revealTokensOf(revnetId, tokenCount, beneficiary)` to re-mint them.

**Failure cases that matter:** trying to reveal more tokens than were hidden, forgetting that revealed tokens increase totalSupply again (reducing per-token cash-out value), and not realizing that hidden tokens must be revealed before they can be used as loan collateral.

## Journey 4: Borrow Against Revnet Tokens Instead Of Selling Them

**Starting state:** a holder wants liquidity but does not want to exit the Revnet position.

**Success:** the holder opens a loan, receives borrowed value, and keeps an NFT loan position representing the debt.

**Flow**
1. The holder interacts with `REVLoans` using the eligible Revnet token exposure as collateral.
2. The system burns or escrows the relevant token exposure and mints a loan-position NFT.
3. Loan terms depend on the live Revnet economics rather than a static side system.
4. The borrower can later repay, transfer the loan NFT, or face liquidation if conditions require it.

## Journey 5: Repay, Transfer, Or Liquidate A Loan Position

**Starting state:** a loan already exists and either the borrower or another actor needs to change its state.

**Success:** the debt path settles cleanly and the collateral outcome matches the Revnet's current rules.

**Flow**
1. Repayment burns the debt and remints or releases the collateralized Revnet token position.
2. Transfers move the loan NFT, not the original collateralized exposure.
3. Liquidation consumes the loan under the rules encoded by `REVLoans` and the current Revnet state.

**Edge conditions that change user experience:** cross-ruleset loan behavior, zero-amount or zero-price edge cases, and sourced versus unsourced loan paths.

## Journey 6: Operate Inside The Bounded Post-Launch Control Envelope

**Starting state:** the Revnet is live and an operator wants to use whatever ongoing controls the deployment allowed.

**Success:** the operator can use sanctioned controls without escaping the "autonomous after launch" model.

**Flow**
1. Review what `REVDeployer` allowed for split operators, stage evolution, and auxiliary integrations.
2. Use only those surfaces rather than treating the project like a normal owner-governed Juicebox project.
3. Audit cross-package behavior whenever the Revnet enabled buybacks, 721 hooks, router terminals, or suckers.

## Hand-Offs

- Use [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md) for the underlying project, terminal, and ruleset mechanics that Revnets package and constrain.
- Use [nana-721-hook-v6](../nana-721-hook-v6/USER_JOURNEYS.md), [nana-buyback-hook-v6](../nana-buyback-hook-v6/USER_JOURNEYS.md), and [nana-suckers-v6](../nana-suckers-v6/USER_JOURNEYS.md) when a Revnet deployment enables those optional features.
