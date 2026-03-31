# User Journeys

## Who This Repo Serves

- founders launching autonomous treasury-backed networks
- participants buying, holding, cashing out, or borrowing against revnet tokens
- operators managing the small set of post-launch controls revnets intentionally preserve

## Journey 1: Launch A Revnet

**Starting state:** you know the staged issuance schedule, accepted terminals, optional NFT tiers, optional suckers, and the split operator.

**Success:** a revnet exists with its economics encoded up front and no human owner key controlling it after launch.

**Flow**
1. Define the `REVConfig`, including description, stages, terminals, and optional auxiliary features.
2. Call `REVDeployer`.
3. The deployer launches the project, stores the long-lived config state, wires `REVOwner` as the runtime hook surface, and grants the bounded permissions the design expects.
4. The deployer contract itself retains project ownership so the revnet behaves as an autonomous system rather than a multisig-managed one.

## Journey 2: Participate In The Revnet Over Time

**Starting state:** the revnet is live and at least one stage is active.

**Success:** participants can enter, hold, and exit according to the revnet's encoded economics.

**Flow**
1. Pay into the revnet through its configured terminals.
2. Receive revnet tokens under the active stage's issuance rate and hook behavior.
3. If optional features are present, also receive 721 tiers, buy through router-assisted paths, or bridge through suckers.
4. Cash out later under the current surplus and stage-driven runtime behavior, including any delayed-cash-out logic the revnet uses.

## Journey 3: Borrow Against Revnet Tokens Instead Of Selling Them

**Starting state:** a holder wants liquidity but does not want immediate full exit through a cash out.

**Success:** the holder receives borrowed value and a loan NFT, with repayment and liquidation behavior defined up front.

**Flow**
1. Choose the source terminal and token pair to borrow against.
2. Call the `REVLoans` borrow flow with the desired collateral amount and prepaid fee percent.
3. The collateral tokens are burned, the loan is represented as an NFT, and the beneficiary receives borrowed funds.
4. The borrower can repay or refinance later, at which point collateral is re-minted.
5. If the loan ages past the liquidation window, anyone can liquidate it.

## Journey 4: Operate The Bounded Post-Launch Controls

**Starting state:** the revnet is live and an operator needs to use the controls the design intentionally leaves adjustable.

**Success:** the operator changes only what the revnet model allows without breaking the promise of autonomy.

**Flow**
1. Use the split-operator-managed surfaces exposed through `REVDeployer`, such as replacing the split operator when that role needs to change.
2. If the revnet was launched with auxiliary systems, operate those through their own contracts and permissions rather than expecting `REVDeployer` to be a universal admin surface.
3. Do not expect to rewrite stage economics after launch. If the stages were wrong, that is a design error, not an operations task.

## Hand-Offs

- Use [nana-buyback-hook-v6](../nana-buyback-hook-v6/USER_JOURNEYS.md), [nana-suckers-v6](../nana-suckers-v6/USER_JOURNEYS.md), and [nana-721-hook-v6](../nana-721-hook-v6/USER_JOURNEYS.md) for the auxiliary systems a revnet may compose with.
