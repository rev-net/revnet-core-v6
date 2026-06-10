# Revnet Core Risk Register

This file focuses on the staged-economics, runtime-hook, and loan risks that matter in Revnets. The main question is whether the deployed economic shape still holds under real runtime behavior.

## How to use this file

- Read `Priority risks` first.
- Use the detailed sections to separate stage design, hook composition, and loan accounting.
- Treat `Accepted Behaviors` and `Invariants to Verify` as the line between intended product tradeoffs and defects.

## Priority risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Borrowability drift from live surplus or cross-chain state | Loans can overextend or under-credit if revnet state is read incorrectly. | Borrowability tests, omnichain-state checks, and cash-out-delay gating. |
| P1 | Stage configuration mistakes | Revnet economics are hard to change after launch, so bad stages are expensive. | Deployment review, stage-transition tests, and launch-time validation. |
| P1 | Burned-collateral misunderstandings | Loans change visible supply in non-obvious ways. | Explicit supply invariants and product-level review. |

## 1. Trust assumptions

- **`REVDeployer` and `REVOwner` are one design.** Misreading them independently is a review hazard.
- **Core protocol state is still upstream truth.** Revnet economics sit on top of `nana-core-v6`, not outside it.
- **Optional integrations matter.** Buybacks, 721 hooks, and suckers can materially change runtime behavior.
- **Price feeds and source accounting matter for loans.** Cross-currency debt aggregation depends on working feed assumptions.

## 2. Economic risks

- **Stage immutability cuts both ways.** A bad stage schedule or bad cash-out tax choice is expensive to unwind.
- **Borrowability depends on live economics.** If surplus, supply, or cross-chain state are wrong, loan capacity becomes wrong.
- **Zero or degraded price feeds can block cross-currency loan accounting.** Revnet loan and cash-out accounting fail
  closed when a required price is zero, because silently skipping that source would hide outstanding debt and make
  borrowability or holder reclaim math too permissive. If a feed breaks, affected borrowability, repayment, and
  cash-out views can revert until the feed is fixed.
- **Auto-issuance dilutes holders predictably but still materially.** Timing is permissionless, even if the amounts are fixed at deployment.
- **Omnichain expansion can corrupt surplus aggregation.** Since borrowability aggregates surplus from all registered terminals across chains, a compromised or misconfigured terminal on a remote chain affects global surplus accounting.

## 3. Loan risks

- **Burned collateral is not escrow.** Reviewers and integrators who model it as escrow will misread liquidation and repayment behavior.
- **No short-term liquidation model.** Under-collateralized loans can persist until the long expiry model allows cleanup.
- **Loan source tokens grow over time.** Debt aggregation cost and complexity increase as new accepted accounting
  context tokens are used.
- **Reallocation still depends on live state.** Reallocate flows can change outcomes around stage boundaries.
- **Delegated loan permissions move value.** `OPEN_LOAN`, `REALLOCATE_LOAN`, and `REPAY_LOAN` all let the delegate choose beneficiaries in paths that can redirect proceeds or returned collateral.

## 4. Hook-composition risks

- **`REVOwner` is a real runtime authority surface.** It composes pay hooks, cash-out hooks, sucker exemptions, and fee logic.
- **Suckers can bypass tax and fee paths by design.** That privilege is safe only if registry and deployer assumptions are correct.
- **Mint-permission surfaces are broad enough to matter.** Loans, buyback flows, and suckers all touch mint authority in some deployments.

## 5. Access-control risks

- **The deployer-held project NFT can be misunderstood.** Revnets are owner-minimized, but the deployer path still matters for the trust model.
- **Split operator mistakes are high-impact.** Narrow powers like price-feed installation, split updates, sucker deployment, or router setup still matter.
- **Metadata and token-signature permissions are holder-facing.** `SET_PROJECT_URI`, `SET_TOKEN_METADATA`, and `SIGN_FOR_ERC20` are not harmless cosmetics when external integrations rely on project identity or ERC-1271 token-contract signatures.
- **There is intentionally no broad admin recovery path.** Operational teams may try to reach for powers the design never intended to leave available.

## 6. Invariants to verify

- Collateral and debt conservation across all active loans.
- Stage immutability after deployment.
- Borrowability dropping to zero when cash-out delay should still block borrowing.
- Sucker-only privileges staying restricted to real registered suckers.
- Mint permission remaining limited to the documented runtime surfaces.

## 7. Accepted behaviors

### 7.1 Suckers receive 0% cash-out tax

Trusted suckers are intentionally exempt so bridged value preserves its economic meaning across chains.

Sucker cash-outs are also intentionally priced against the local chain's supply and surplus, even when the revnet's
ordinary holder cash-outs are unscoped and aggregate remote snapshots. A sucker cash-out is the bridge movement path:
the funds leaving this chain should be proportional to this chain's local backing, not to the theoretical global
backing across all chains.

### 7.2 There is no short-horizon liquidation model

Revnet loans are designed more like long-dated economic positions than instantly mark-to-market margin loans.

### 7.3 Auto-issuance dilution is permissionless but predictable

Anyone can trigger a valid auto-issuance once a stage is live, but the amount was fixed at deployment.

Cash-out and borrow math denominate against the *currently minted* token supply, not against committed-but-unclaimed
`amountToAutoIssue` balances. Between the moment a stage starts and the moment `autoIssueFor` is called for a given
beneficiary, those committed tokens are absent from the supply denominator. A holder cashing out (or borrowing
against the surplus) in that window therefore captures a slightly disproportionate share of treasury value at the
expense of the unclaimed auto-issuance beneficiary. The economic magnitude scales with
`pendingAutoIssuance / circulatingSupply`, and is intentional: auto-issuance beneficiaries are expected to claim
promptly, and the protocol does not pre-credit unminted tokens to the cash-out denominator. Beneficiaries who want
to avoid this dilution should call `autoIssueFor` at or near stage start.

### 7.4 Surplus manipulation by pure donation is economically self-defeating

The model assumes that attempts to inflate surplus through donations are not profitable once the surrounding bonding-curve math is considered.

### 7.5 Revnet terminal set is deployer-pinned

New revnet configs choose accounting contexts, not terminal addresses. `REVDeployer` assumes its constructor-pinned
`MULTI_TERMINAL` and `ROUTER_TERMINAL_REGISTRY` are valid deployment-time dependencies. It registers
`MULTI_TERMINAL` with the revnet's accounting contexts and, when distinct, also registers
`ROUTER_TERMINAL_REGISTRY` with no accounting contexts. `ROUTER_TERMINAL_REGISTRY` is the project terminal that
forwards alternate payment routes to the selected router terminal implementation.

This keeps treasury balances, loan allowances, and borrow-source accounting anchored to the canonical multi-terminal
while still allowing users to pay through the router registry. It also removes the old arbitrary-terminal deployment
surface: a revnet deploy call cannot introduce a phantom terminal or select the router registry as a loan source.
Loans identify their source by token only; `REVLoans` and `REVOwner` derive decimals and currency from the canonical
multi-terminal's current accounting context for that token.
The revnet identity commits to the registry address, not the registry's current default or project-specific router
selection; those choices remain registry-level risk routing and do not become loan-accounting sources.

Changing or removing a canonical multi-terminal accounting context after loans exist can make that token's outstanding
debt unpriceable until a valid context is restored. That discontinuity is accepted as an accounting-context migration
risk: new revnet launches should treat accepted contexts as part of the revnet's durable economic shape.
Returning a zero price for an otherwise valid cross-currency source is treated the same way: the affected accounting
path reverts instead of omitting that source's debt.

### 7.6 Omnichain terminal expansion inherits remote-chain trust

A project that expands to a new chain can register the canonical terminal set on that chain. Because borrowability
calculations aggregate surplus from all registered terminals across chains, a compromised or misconfigured remote
chain can still corrupt global surplus accounting through its canonical deployments or sucker snapshots. This is
mitigated by constructor-pinning `MULTI_TERMINAL` and `ROUTER_TERMINAL_REGISTRY` in the deployer itself instead of
letting revnet configs pick terminals. The per-revnet `encodedConfigurationHash` does not repeat those terminal
addresses, because they are deployment dependencies of the canonical deployer. Project operators should still treat
each chain expansion as a trust-boundary decision since bridge integrity, deployer provenance, and network assumptions
remain outside protocol control.

Reserved-token split recipients are intentionally excluded from this hash. They can be reconfigured over time, so only split weights participate in the identity commitment.

### 7.7 Cross-chain surplus staleness

`REVLoans._borrowableAmountFrom` and ordinary unscoped holder cash-outs in `REVOwner.beforeCashOutRecordedWith` add
`remoteSurplusOf()` and `remoteTotalSupplyOf()` to local values. These remote values update only when `toRemote()` is
called on the peer chain -- no heartbeat or staleness check. Stale data can inflate per-token borrowable amounts when
remote supply has grown since the last bridge message. Primary safeguard: borrowable is capped at `localSurplus`, and
the preview plus the open-borrow path are additionally capped at the live treasury surplus, preventing extraction
beyond what the local terminal holds.

This does not apply to the registered-sucker cash-out branch. Sucker cash-outs are the cross-chain token movement path
and deliberately use local supply/surplus so the bridge can move value out of a chain in proportion to that chain's
funds.

### 7.8 REVLoans callback ordering during loan adjustments

`REVLoans._adjust` still performs terminal, token, and native-token beneficiary calls before every aggregate loan
counter has finished updating. This ordering is part of the loan flow: funds must move through the canonical terminal,
fees may be paid, collateral is burned or re-minted, and native-token borrowers may be contracts with `receive()`
callbacks.

The loan-changing entrypoints (`borrowFrom`, `reallocateCollateralFromLoan`, and `repayLoan`) hold a transient
reentrancy lock while these callbacks are in progress. A callback can observe the in-progress state, but it cannot
nest another loan-changing action that would price against partially updated `totalCollateralOf` or
`totalBorrowedFrom` accounting.

### 7.9 Omnichain cash-outs settle at local liquidity, not theoretical global share

When omnichain effective surplus exceeds the local terminal balance for an ordinary holder cash-out,
`REVOwner.beforeCashOutRecordedWith` proportionally scales the bonding-curve reclaim and the protocol fee so their sum
equals local liquidity, then lowers the `effectiveSurplusValue` it reports to `JBTerminalStore` by the same ratio so
the store's recomputed reclaim leaves exact room for the fee spec. The user still burns the full requested
`cashOutCount` and receives `localSurplus - feeAmount` -- strictly less than the global-surplus formula would suggest.

This is intentional: reverting with `InadequateTerminalStoreBalance` would make cross-chain cash-outs unusable when the
global formula exceeds local liquidity. The protocol fee is **never** zeroed by the scaling; the current implementation
avoids the older `feeAmount = max(localSurplus - reclaim, 0)` formulation, which dropped to zero whenever the unscaled
reclaim consumed all local surplus.

Holders with `minReclaimAmount` set on their `cashOutTokensOf` call are protected from getting less than they expect. Holders without minimums should be aware that local liquidity caps their reclaim; the surplus on other chains is reachable by cashing out there (or by waiting for bridge messages to rebalance local surplus).

### 7.10 Remote loan corrections depend on fresh adjusted peer snapshots

`_borrowableAmountFrom` adds back local `totalBorrowed` and `totalCollateral` to reconstitute pre-loan economic state
for the bonding curve. Revnet peer-chain snapshots export the same correction through
`REVOwner.peerChainAdjustedAccountsOf(...)`: `JBSuckerLib.buildSnapshotMessage(...)` reads the active data hook via
`IJBPeerChainAdjustedAccounts` and folds the returned loan collateral/debt into `sourceTotalSupply`, `sourceSurplus`,
and `sourceBalance`.

This means canonical Revnet suckers do not intentionally omit remote loan state. The remaining risk is freshness and availability: peer snapshots are asynchronous, best-effort, and soft-fail if the remote data hook does not expose the optional interface or the sucker cannot deliver the latest root.

Peer snapshots encode each source's debt in `uint128` surplus and balance fields. If a single source's outstanding debt
does not fit that wire type, `REVOwner.peerChainAdjustedAccountsOf(...)` reverts instead of wrapping the debt downward.

This is accepted because:

1. Suckers remain a general-purpose bridging layer: project-specific mechanics are provided by the active data hook, not hard-coded into the sucker.
2. The `localSurplus` cap prevents borrowing more than the local economic surplus, and the preview plus the open-borrow path additionally cap at the live treasury surplus, so neither can promise or draw more than what the local terminal can actually disburse at that moment.
3. The over-lending exposure from a stale or missing adjusted snapshot is bounded by the difference between the latest delivered remote snapshot and current remote loan state.

Project operators deploying cross-chain revnets with active loan markets on multiple chains should understand that local borrowability calculations account for remote loans only as of the latest accepted peer snapshot.

### 7.11 There is no hidden-token supply bucket in V6

Revnet cash-out and loan denominators ultimately start from core's `totalTokenSupplyWithReservedTokensOf()`: live
credits, live ERC-20 supply, and pending reserved tokens. Revnet loan math then adds `totalCollateralOf[revnetId]`
because loan collateral is burned while the borrower still has a repayable claim on it.

Ordinary voluntary burns are different: they destroy the holder's tokens or credits and are not tracked as a hidden
balance that can later be reclaimed. Burning can only shift value to the remaining live holders by deleting the
burner's own claim. A malicious or misconfigured registered terminal can still corrupt surplus accounting, as covered
by the terminal-trust sections above and the phantom-terminal regression test, but there is no separate hidden-token
multiplier in this V6 codebase.

### 7.12 Native cash-out fee hooks are value-balanced

`REVOwner.afterCashOutRecordedWith` is intentionally callable by any address: a non-terminal caller can donate their
own funds into the fee revnet using the same hook path. For native-token fees, the hook requires `msg.value` to exactly
match `context.forwardedAmount.value`, so forced or accidentally stranded ETH in the hook cannot be spent by an
arbitrary caller. For ERC-20 fees, `msg.value` must be zero and the forwarded amount is pulled from the caller.

### 7.13 Cash-out fees floor in token-count space on low-supply revnets

`REVOwner.beforeCashOutRecordedWith` derives the fee portion of a cash-out by applying `JBFees.standardFeeAmountFrom`
to `context.cashOutCount` (the count of tokens being cashed out). That helper computes `amount / 40` — the integer
quotient of the 2.5% standard fee — so any individual cash-out with `cashOutCount < 40` rounds to `feeCashOutCount == 0`
and skips the fee hook entirely. The fee revnet collects nothing on those cash-outs.

The threshold is per-call, in raw token units, against the count being cashed out — not against the revnet's total
supply or the reclaim value. For an 18-decimal revnet token, 40 raw units is dust (4e-17 tokens). In practice the
floor only bites for either (a) revnets whose accepted token is a very-low-decimal asset where 40 raw units is a
meaningful balance, or (b) deliberately-tiny cash-outs by a holder large enough to repeatedly split below the floor.
Splitting to evade fees is gas-bounded — each sub-40-token cash-out costs more in gas than the avoided fee — and
splitting attackers still pay the terminal-side protocol fee on the reclaim amount because that fee floors in value
space, not count space.

This is accepted behavior, not a bug to patch:

- Restoring a `feeCashOutCount = 1` floor would change cash-out semantics for legitimate small flows (e.g. router
  terminals routing dust amounts on every settlement) and would push a unit of token-burn responsibility onto the fee
  hook regardless of the cashed-out count.
- The fee-revnet revenue lost across all real-world revnets is bounded by the count-floor boundary times the per-call
  gas cost — economically negligible against the gas baseline of any cash-out transaction.
- The cash-out *holder* receives the same reclaim regardless of whether the fee floor triggers; only the fee revnet
  is affected.

Operators planning revnets that will accept very-low-decimal source tokens, or revnets whose primary cash-out flows
are deliberately small, should not expect the fee revnet to collect the standard 2.5% on every cash-out at those
sizes. Treat fee-revnet accumulation as a percentage of *median* cash-out volume, not as a strict per-cash-out
invariant.

### 7.14 Fee paths fail-open when the fee revnet has no terminal for the source token

`REVOwner.beforeCashOutRecordedWith` and `REVLoans._addTo` both gate fee collection on
`DIRECTORY.primaryTerminalOf({projectId: FEE_REVNET_ID, token: sourceToken})`. When that returns `address(0)` —
i.e. the fee revnet hasn't been deployed on this chain yet, or it has been deployed but doesn't accept that
specific token through any of its registered terminals — the fee path is skipped: cash-outs proxy straight
through the buyback hook with no fee hook spec, and loan borrows zero the 1% REV fee. The protocol still
processes the cash-out / loan; the fee revnet just doesn't collect on that flow.

The fail-open is intentional. The alternative would be to revert cash-outs and loans on any chain or token
that the fee revnet hadn't yet wired, which would DoS legitimate flows whenever the fee revnet's terminal
coverage lagged a new revnet's deployment. Reverting also doesn't recover the fee value — it just blocks the
user.

In practice this matters for two operational patterns:

- **New-chain rollouts.** When `deploy-all-v6` brings the protocol to a new chain, the fee revnet (project #1
  on that chain) is deployed first and its terminal registered. Any revnet deployed *before* that step would
  silently bypass fees until the fee revnet catches up. The standard deploy ordering already prevents this on
  canonical chains.
- **New-token onboarding.** If a revnet starts accepting a new accounting context whose token the fee revnet's
  primary terminal doesn't already support, that revnet's cash-outs and loans against that token bypass the fee
  until the fee revnet adds the token. This is a chain-by-chain operational concern, not a per-revnet revert.

Operators wiring revnets that accept tokens outside the fee revnet's current terminal set should expect those
flows to bypass fees until terminal coverage is added. Treat fee-revnet revenue as conditional on fee-revnet
terminal coverage, not as a per-cash-out invariant. There is no on-chain hold queue for missed fees — value
that would have been a fee remains with the cashing-out holder or the borrower.

### 7.15 Delegated loan permissions include beneficiary control

Loan permissions should be presented as value-moving permissions, not as narrow maintenance permissions.

`OPEN_LOAN` lets a delegate borrow against the holder's tokens and choose the proceeds beneficiary.
`REALLOCATE_LOAN` lets a delegate remove collateral from an existing loan and open the paired replacement/new loan
created by the reallocation path; when that path produces fresh borrowed proceeds, the delegate also chooses the
beneficiary for those proceeds. `REPAY_LOAN` lets a delegate repay partially or fully and choose where returned
collateral is reminted, including cases where overcollateralization means little or no debt repayment is needed for
the requested collateral return.

These powers are permission-gated and may be intentional, but frontends, runbooks, and operator policies should label
them accordingly: `REALLOCATE_LOAN` is debt-creation/proceeds-redirection authority, and `REPAY_LOAN` is
collateral-withdrawal/beneficiary-redirection authority.

### 7.16 Operator metadata and ERC-20 signing authority remain live

The default revnet operator set includes `SET_PROJECT_URI`, `SET_TOKEN_METADATA`, and `SIGN_FOR_ERC20`.
`SET_PROJECT_URI` and `SET_TOKEN_METADATA` can change holder-facing project metadata, ERC-20 name, and ERC-20 symbol
after launch. `SIGN_FOR_ERC20` makes signatures by the operator valid through the project token's ERC-1271
`isValidSignature` surface wherever an external integration accepts signatures "from" the token contract.

These powers do not by themselves drain the treasury, but they are not immutable-launch facts. Integrations and
monitoring should treat them as identity and external-integration authority.
