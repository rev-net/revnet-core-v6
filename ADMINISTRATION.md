# Administration

Admin privileges and their scope in revnet-core-v6. Revnets are designed to be autonomous Juicebox projects with no traditional owner. This document covers what privileged operations exist, who can perform them, and -- critically -- what is intentionally made impossible.

## Roles

### Split Operator

- **How assigned:** Specified at deployment via `REVConfig.splitOperator`. After deployment, only the current split operator can transfer the role to a new address by calling `setSplitOperatorOf()`.
- **Scope:** Per-revnet. Each revnet has at most one split operator. The operator is the only human-controlled role in a deployed revnet.
- **Cannot be removed:** The split operator can be replaced but there is no mechanism to entirely revoke the role (it can be set to an unreachable address like `address(0)` to effectively disable it).

### REVLoans Owner (Ownable)

- **How assigned:** Set at `REVLoans` contract deployment via the `owner` constructor parameter. Transferable via OpenZeppelin `Ownable.transferOwnership()`.
- **Scope:** Global across all revnets using this loans contract. Controls only the loan NFT metadata URI resolver -- has no power over loan parameters, collateral, or funds.

### REVDeployer (as Juicebox project owner)

- **How assigned:** Automatic. When a revnet is deployed, the `REVDeployer` contract becomes the permanent owner of the Juicebox project NFT. If initializing an existing project, the caller's project NFT is irreversibly transferred to `REVDeployer`.
- **Scope:** The deployer holds the project NFT and uses its owner authority to enforce revnet rules. It acts as a protocol-level constraint layer, not as a discretionary admin. No human can exercise this ownership.

### Loan NFT Owner

- **How assigned:** The `_msgSender()` who calls `borrowFrom()` receives the loan ERC-721. Transferable like any ERC-721.
- **Scope:** Per-loan. Only the current NFT owner can repay the loan, return collateral, or reallocate collateral to a new loan.

### Anyone (Permissionless)

- **Scope:** Several functions are callable by any address with no access control, as documented in the Privileged Functions tables below.

## Privileged Functions

### REVDeployer

| Function | Required Role | Permission ID | What It Does |
|----------|--------------|---------------|-------------|
| `deployFor()` | Anyone (new revnet) or Juicebox project owner (existing project) | None | Deploys a new revnet or irreversibly converts an existing Juicebox project into a revnet. |
| `deployWith721sFor()` | Anyone (new revnet) or Juicebox project owner (existing project) | None | Same as `deployFor()` but also deploys a tiered ERC-721 hook and optional croptop posting rules. |
| `deploySuckersFor()` | Split Operator | Checked via `_checkIfIsSplitOperatorOf()` | Deploys new cross-chain suckers for an existing revnet. Also requires the current ruleset's `extraMetadata` bit 2 to be set (allows deploying suckers). |
| `setSplitOperatorOf()` | Split Operator | Checked via `_checkIfIsSplitOperatorOf()` | Replaces the current split operator with a new address. Revokes all operator permissions from the caller and grants them to the new address. |
| `autoIssueFor()` | Anyone | None | Mints pre-configured auto-issuance tokens for a beneficiary once the relevant stage has started. Amounts are set at deployment and can only be claimed once. |
| `burnHeldTokensOf()` | Anyone | None | Burns any of a revnet's tokens held by the `REVDeployer` contract (e.g., from reserved token splits that did not sum to 100%). |
| `afterCashOutRecordedWith()` | Anyone (called by terminal) | None | Processes cash-out fees. No caller validation needed because a non-terminal caller would only be donating their own funds. |

### Split Operator Permissions (granted via JBPermissions)

The split operator receives the following Juicebox permission IDs, scoped to its revnet:

| Permission ID | What It Allows |
|---------------|----------------|
| `SET_SPLIT_GROUPS` | Change how reserved tokens are distributed among split recipients. |
| `SET_BUYBACK_POOL` | Configure which Uniswap V4 pool is used for the buyback hook. |
| `SET_BUYBACK_TWAP` | Adjust the TWAP window for the buyback hook. |
| `SET_PROJECT_URI` | Update the revnet's metadata URI. |
| `ADD_PRICE_FEED` | Add a new price feed for the revnet. |
| `SUCKER_SAFETY` | Manage sucker safety settings (e.g., emergency hatch). |
| `SET_BUYBACK_HOOK` | Configure the buyback hook. |
| `SET_ROUTER_TERMINAL` | Set the router terminal. |

Optional 721 permissions (granted only if enabled at deployment via `REVDeploy721TiersHookConfig`):

| Permission ID | Deployment Flag | What It Allows |
|---------------|----------------|----------------|
| `ADJUST_721_TIERS` | `splitOperatorCanAdjustTiers` | Add or remove ERC-721 tiers. |
| `SET_721_METADATA` | `splitOperatorCanUpdateMetadata` | Update ERC-721 tier metadata. |
| `MINT_721` | `splitOperatorCanMint` | Mint ERC-721s without payment from tiers with `allowOwnerMint`. |
| `SET_721_DISCOUNT_PERCENT` | `splitOperatorCanIncreaseDiscountPercent` | Increase the discount percentage of a tier. |

### REVLoans

| Function | Required Role | Access Control | What It Does |
|----------|--------------|----------------|-------------|
| `borrowFrom()` | Anyone (must hold revnet tokens) | None -- but caller's tokens are burned as collateral | Opens a loan against revnet token collateral. |
| `repayLoan()` | Loan NFT Owner | `_ownerOf(loanId) == _msgSender()` | Repays a loan (partially or fully) and returns collateral. |
| `reallocateCollateralFromLoan()` | Loan NFT Owner | `_ownerOf(loanId) == _msgSender()` | Splits excess collateral from an existing loan into a new loan. |
| `liquidateExpiredLoansFrom()` | Anyone | None | Liquidates loans that have exceeded the 10-year liquidation duration. Permanently destroys collateral. |
| `setTokenUriResolver()` | REVLoans Owner | `onlyOwner` (OpenZeppelin Ownable) | Sets the contract that resolves loan NFT metadata URIs. |

### Constructor-Level Permissions (set once at deployment)

These permissions are granted in the `REVDeployer` constructor and apply globally (wildcard `projectId = 0`):

| Grantee | Permission ID | Purpose |
|---------|---------------|---------|
| `SUCKER_REGISTRY` | `MAP_SUCKER_TOKEN` | Allows the sucker registry to map tokens for all revnets. |
| `LOANS` | `USE_ALLOWANCE` | Allows the loans contract to use surplus allowance from all revnets to fund loans. |

## Autonomous Design

Revnets are designed to operate without a traditional project owner. The following mechanisms enforce autonomy:

- **Ownership transfer is permanent.** When a revnet is deployed, the Juicebox project NFT is transferred to the `REVDeployer` contract. No human holds the project NFT. There is no function to transfer it back.
- **No ruleset queuing.** The `REVDeployer` does not expose any function to queue new rulesets after deployment. The stage progression is fully determined at deploy time. Nobody -- not the split operator, not the deployer, not anyone -- can change the issuance schedule, cash-out tax rates, or stage timing after deployment.
- **No approval hooks.** All rulesets are deployed with `approvalHook = address(0)`. There is no mechanism to block or delay stage transitions.
- **Cash outs cannot be fully disabled.** The deployer enforces `cashOutTaxRate < MAX_CASH_OUT_TAX_RATE` for every stage, guaranteeing that token holders always retain some ability to cash out.
- **Data hook is the deployer itself.** The `REVDeployer` is set as the data hook (`metadata.dataHook = address(this)`) for all rulesets, ensuring consistent fee and sucker logic without external admin control.
- **Mint permission is restricted.** Only the loans contract, the buyback hook (and its delegates), and registered suckers can mint tokens. The split operator cannot mint fungible revnet tokens.
- **No held fee manipulation.** The deployer has no function to process or return held fees arbitrarily.
- **Owner minting is constrained.** While `allowOwnerMinting = true` is set in ruleset metadata, the "owner" is the `REVDeployer` contract. It only uses this to mint auto-issuance tokens (amounts fixed at deployment) and to return loan collateral.

## Loan Administration

The `REVLoans` contract has minimal admin surface by design:

- **All economic parameters are constants.** Loan liquidation duration (10 years), fee percentages (MIN 2.5%, MAX 50%), and the REV fee (1%) are hardcoded as immutable constants. No admin can change them.
- **The only admin function is `setTokenUriResolver()`**, which controls how loan NFTs render their metadata. This is purely cosmetic and has no effect on loan economics, collateral, or fund flows.
- **Loan management is permissioned to NFT holders only.** Repayment, collateral reallocation, and refinancing require ownership of the specific loan's ERC-721 NFT.
- **Liquidation is permissionless.** Anyone can call `liquidateExpiredLoansFrom()` for loans past the 10-year duration.

## Immutable Configuration

The following parameters are set at deployment and can never be changed:

### REVDeployer (per-revnet, set at `deployFor` / `deployWith721sFor` time)
- Stage schedule (start times, issuance rates, cut frequencies, cut percentages)
- Cash-out tax rates per stage
- Split percentages per stage
- Auto-issuance amounts and beneficiaries
- Base currency
- ERC-20 token name and symbol
- Encoded configuration hash (used for cross-chain sucker deployment verification)

### REVDeployer (global, set at contract deployment)
- `CONTROLLER` -- the Juicebox controller
- `DIRECTORY` -- the Juicebox directory
- `PROJECTS` -- the Juicebox projects NFT contract
- `PERMISSIONS` -- the Juicebox permissions contract
- `SUCKER_REGISTRY` -- the sucker registry
- `BUYBACK_HOOK` -- the buyback hook / data hook
- `HOOK_DEPLOYER` -- the 721 tiers hook deployer
- `PUBLISHER` -- the croptop publisher
- `LOANS` -- the loans contract address
- `FEE_REVNET_ID` -- the project ID that receives cash-out fees
- `FEE` -- the cash-out fee (2.5%)
- `CASH_OUT_DELAY` -- 30 days for cross-chain deployments

### REVLoans (global, set at contract deployment)
- `CONTROLLER`, `DIRECTORY`, `PRICES`, `PROJECTS` -- protocol infrastructure
- `REV_ID` -- the REV revnet that receives loan fees
- `PERMIT2` -- the permit2 contract
- `LOAN_LIQUIDATION_DURATION` -- 10 years (3650 days)
- `MIN_PREPAID_FEE_PERCENT` -- 2.5% (`25` out of `MAX_FEE = 1000`)
- `MAX_PREPAID_FEE_PERCENT` -- 50% (`500` out of `MAX_FEE = 1000`)
- `REV_PREPAID_FEE_PERCENT` -- 1% (`10` out of `MAX_FEE = 1000`)

## Admin Boundaries

What admins **cannot** do -- this is the most important section for understanding revnet security guarantees:

### The Split Operator Cannot:
- Change issuance rates, schedules, or weight decay
- Modify cash-out tax rates
- Queue new rulesets or stages
- Pause or disable cash outs
- Mint fungible revnet tokens (only 721 minting if explicitly enabled at deploy)
- Access or redirect treasury funds (no payout limit control)
- Upgrade or migrate the revnet's controller
- Change the revnet's terminals
- Transfer the project NFT
- Modify fund access limits or surplus allowances
- Change the data hook or approval hook
- Affect loan parameters or collateral

### The REVLoans Owner Cannot:
- Change loan interest rates, fees, or liquidation timing
- Access or redirect collateral or borrowed funds
- Prevent loan creation, repayment, or liquidation
- Mint or burn tokens
- Affect any revnet's configuration

### The REVDeployer Contract Cannot (even though it holds the project NFT):
- Queue new rulesets (no public or internal function exists for this)
- Transfer the project NFT to any other address
- Change terminals or the controller
- Modify fund access limits after deployment
- Override the data hook logic
- Selectively block cash outs (beyond the time-limited `CASH_OUT_DELAY` for cross-chain deployments)

### Nobody Can:
- Change a revnet's stage schedule after deployment
- Prevent token holders from eventually cashing out
- Extract funds from the treasury without going through the bonding curve
- Modify the fee structure (2.5% cash-out fee, loan fees)
- Change which contract is the data hook for a revnet
- Alter auto-issuance amounts after deployment (they can only be claimed, not changed)
