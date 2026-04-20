# Revnet Core Risk Register

This file focuses on the staged-economics, runtime-hook, hidden-supply, and loan risks that matter in Revnets. The main question is whether the deployed economic shape still holds under real runtime behavior.

## How to use this file

- Read `Priority risks` first.
- Use the detailed sections to separate stage design, hook composition, hidden supply, and loan accounting.
- Treat `Accepted Behaviors` and `Invariants to Verify` as the line between intended product tradeoffs and defects.

## Priority risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Borrowability drift from live surplus or cross-chain state | Loans can overextend or under-credit if revnet state is read incorrectly. | Borrowability tests, omnichain-state checks, and cash-out-delay gating. |
| P1 | Stage configuration mistakes | Revnet economics are hard to change after launch, so bad stages are expensive. | Deployment review, stage-transition tests, and launch-time validation. |
| P1 | Hidden-supply and burned-collateral misunderstandings | Hidden tokens and loans both change visible supply in non-obvious ways. | Explicit supply invariants and product-level review. |

## 1. Trust Assumptions

- **`REVDeployer` and `REVOwner` are one design.** Misreading them independently is a review hazard.
- **Core protocol state is still upstream truth.** Revnet economics sit on top of `nana-core-v6`, not outside it.
- **Optional integrations matter.** Buybacks, 721 hooks, and suckers can materially change runtime behavior.
- **Price feeds and source accounting matter for loans.** Cross-currency debt aggregation depends on working feed assumptions.

## 2. Economic Risks

- **Stage immutability cuts both ways.** A bad stage schedule or bad cash-out tax choice is expensive to unwind.
- **Borrowability depends on live economics.** If surplus, supply, or cross-chain state are wrong, loan capacity becomes wrong.
- **Zero or degraded price feeds can undercount debt.** If a source becomes invisible to debt aggregation, later borrowing can become too permissive.
- **Hidden-token mechanics change visible supply.** That affects per-token cash-out value and can change the economics seen by other holders.
- **Auto-issuance dilutes holders predictably but still materially.** Timing is permissionless, even if the amounts are fixed at deployment.
- **Omnichain expansion can corrupt surplus aggregation.** Since borrowability aggregates surplus from all registered terminals across chains, a compromised or misconfigured terminal on a remote chain affects global surplus accounting.

## 3. Loan Risks

- **Burned collateral is not escrow.** Reviewers and integrators who model it as escrow will misread liquidation and repayment behavior.
- **No short-term liquidation model.** Under-collateralized loans can persist until the long expiry model allows cleanup.
- **Loan sources grow over time.** Debt aggregation cost and complexity increase as new source pairs are used.
- **Reallocation still depends on live state.** Reallocate flows can change outcomes around stage boundaries.

## 4. Hidden-Token Risks

- **Visible-supply manipulation is intentional.** Hiding tokens changes visible supply and therefore changes redemption economics.
- **Hidden tokens are not usable collateral while hidden.** They must be revealed before borrowing.
- **Reveal is restoration, not fresh issuance.** It intentionally bypasses reserved-percent behavior.

## 5. Hook-Composition Risks

- **`REVOwner` is a real runtime authority surface.** It composes pay hooks, cash-out hooks, sucker exemptions, and fee logic.
- **Suckers can bypass tax and fee paths by design.** That privilege is safe only if registry and deployer assumptions are correct.
- **Mint-permission surfaces are broad enough to matter.** Loans, hidden tokens, buyback flows, and suckers all touch mint authority in some deployments.

## 6. Access-Control Risks

- **The deployer-held project NFT can be misunderstood.** Revnets are owner-minimized, but the deployer path still matters for the trust model.
- **Split operator mistakes are high-impact.** Narrow powers like price-feed installation, split updates, sucker deployment, or router setup still matter.
- **There is intentionally no broad admin recovery path.** Operational teams may try to reach for powers the design never intended to leave available.

## 7. Invariants to Verify

- Collateral and debt conservation across all active loans.
- Stage immutability after deployment.
- Borrowability dropping to zero when cash-out delay should still block borrowing.
- Hidden-balance conservation across hide and reveal flows.
- Sucker-only privileges staying restricted to real registered suckers.
- Mint permission remaining limited to the documented runtime surfaces.

## 8. Accepted Behaviors

### 8.1 Suckers receive 0% cash-out tax

Trusted suckers are intentionally exempt so bridged value preserves its economic meaning across chains.

### 8.2 There is no short-horizon liquidation model

Revnet loans are designed more like long-dated economic positions than instantly mark-to-market margin loans.

### 8.3 Auto-issuance dilution is permissionless but predictable

Anyone can trigger a valid auto-issuance once a stage is live, but the amount was fixed at deployment.

### 8.4 Surplus manipulation by pure donation is economically self-defeating

The model assumes that attempts to inflate surplus through donations are not profitable once the surrounding bonding-curve math is considered.

### 8.5 Omnichain terminal expansion inherits remote-chain trust

A project that expands to a new chain can register additional terminals on that chain. Because borrowability calculations aggregate surplus from all registered terminals across all chains, a compromised or misconfigured terminal on a remote chain can corrupt the project's surplus accounting globally. This is mitigated by including terminal addresses in the `encodedConfigurationHash` — cross-chain expansions via suckers must use the exact same terminal address as the host chain. Terminal addresses are deterministic across chains (same CREATE2 deployment), so this prevents expansions from silently using a different terminal. Project operators should still treat each chain expansion as a trust-boundary decision since bridge integrity and network assumptions remain outside protocol control.
