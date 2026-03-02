# revnet-core-v5

## Purpose

Deploy and manage Revnets -- autonomous, unowned Juicebox projects with staged issuance schedules and token-collateralized lending.

## Contracts

| Contract | Role |
|----------|------|
| `REVDeployer` | Deploys revnets, acts as project owner, data hook, and cash out hook. Manages stages, splits, auto-issuance, buyback hooks, 721 hooks, suckers, and split operators. |
| `REVLoans` | Issues token-collateralized loans from revnet treasuries. Each loan is an ERC-721. Burns collateral on borrow, re-mints on repay. Charges tiered fees (REV protocol fee + source fee + prepaid fee). |

## Key Functions

| Function | Contract | What it does |
|----------|----------|--------------|
| `deployFor` | REVDeployer | Deploy a new revnet (or convert an existing Juicebox project) with stages, terminals, buyback hook, suckers, and loans. |
| `deployWith721sFor` | REVDeployer | Same as `deployFor` but also deploys a tiered ERC-721 hook and configures croptop allowed posts. |
| `autoIssueFor` | REVDeployer | Mint pre-configured auto-issuance tokens for a beneficiary once a stage has started. |
| `setSplitOperatorOf` | REVDeployer | Replace the current split operator (only callable by the current split operator). |
| `deploySuckersFor` | REVDeployer | Deploy new cross-chain suckers for an existing revnet (split operator only, ruleset must allow it). |
| `beforePayRecordedWith` | REVDeployer | Data hook callback: returns the buyback hook weight and assembles pay hook specs (721 hook + buyback hook). |
| `beforeCashOutRecordedWith` | REVDeployer | Data hook callback: enforces cash out delay, exempts suckers from fees/taxes, calculates and routes the 2.5% cash out fee. |
| `afterCashOutRecordedWith` | REVDeployer | Cash out hook callback: transfers the fee amount to the fee revnet's terminal. Falls back to returning funds if the fee payment fails. |
| `hasMintPermissionFor` | REVDeployer | Returns true for the loans contract, buyback hook, or any sucker. |
| `borrowFrom` | REVLoans | Open a loan: burn collateral tokens, pull funds from the revnet via `useAllowanceOf`, pay REV fee + source fee, transfer remainder to beneficiary, mint loan NFT. |
| `repayLoan` | REVLoans | Repay (partially or fully): accept repayment funds, return them to the revnet via `addToBalanceOf`, re-mint collateral to beneficiary, burn/replace the loan NFT. |
| `reallocateCollateralFromLoan` | REVLoans | Refinance: remove excess collateral from an existing loan (when collateral has appreciated) and open a new loan with the freed collateral. Burns the original, mints two replacements. |
| `liquidateExpiredLoansFrom` | REVLoans | Clean up loans past the 10-year liquidation duration. Burns their NFTs and decrements accounting totals. |
| `borrowableAmountFrom` | REVLoans | View: calculate how much can be borrowed for a given collateral amount using the bonding curve formula. |
| `determineSourceFeeAmount` | REVLoans | View: calculate the time-proportional source fee for a loan repayment. |

## Integration Points

| Dependency | Import | Used For |
|------------|--------|----------|
| `@bananapus/core-v5` | `IJBController`, `IJBDirectory`, `IJBPermissions`, `IJBProjects`, `IJBTerminal`, `IJBPrices` | Project lifecycle, rulesets, token minting/burning, fund access, terminal payments, price feeds |
| `@bananapus/721-hook-v5` | `IJB721TiersHook`, `IJB721TiersHookDeployer` | Deploying and registering tiered ERC-721 pay hooks |
| `@bananapus/buyback-hook-v5` | `IJBBuybackHook` | Configuring Uniswap buyback pools per revnet |
| `@bananapus/suckers-v5` | `IJBSuckerRegistry` | Deploying cross-chain suckers, checking sucker status for fee exemption |
| `@croptop/core-v5` | `CTPublisher` | Configuring croptop posting criteria for 721 tiers |
| `@bananapus/permission-ids-v5` | `JBPermissionIds` | Permission ID constants (SET_SPLIT_GROUPS, USE_ALLOWANCE, etc.) |
| `@openzeppelin/contracts` | `ERC721`, `ERC2771Context`, `Ownable`, `SafeERC20` | Loan NFTs, meta-transactions, ownership, safe token transfers |
| `@uniswap/permit2` | `IPermit2`, `IAllowanceTransfer` | Gasless token approvals for loan repayments |
| `@prb/math` | `mulDiv` | Precise fixed-point multiplication and division |

## Key Types

| Struct/Enum | Key Fields | Used In |
|-------------|------------|---------|
| `REVConfig` | `description`, `baseCurrency`, `splitOperator`, `stageConfigurations[]`, `loanSources[]`, `loans` | `deployFor`, `deployWith721sFor` |
| `REVStageConfig` | `startsAtOrAfter` (uint48), `initialIssuance` (uint112), `issuanceCutFrequency` (uint32), `issuanceCutPercent` (uint32), `cashOutTaxRate` (uint16), `splitPercent` (uint16), `splits[]`, `autoIssuances[]`, `extraMetadata` (uint16) | Translated into `JBRulesetConfig` by `REVDeployer` |
| `REVDescription` | `name`, `ticker`, `uri`, `salt` | ERC-20 token deployment and project metadata |
| `REVAutoIssuance` | `chainId` (uint32), `count` (uint104), `beneficiary` | Per-stage token auto-minting, cross-chain aware |
| `REVLoan` | `amount` (uint112), `collateral` (uint112), `createdAt` (uint48), `prepaidFeePercent` (uint16), `prepaidDuration` (uint32), `source` | Stored per loan ID in `REVLoans` |
| `REVLoanSource` | `token`, `terminal` (IJBPayoutTerminal) | Identifies which terminal and token a loan draws from |
| `REVBuybackHookConfig` | `dataHook`, `hookToConfigure`, `poolConfigurations[]` | Buyback hook setup during deployment |
| `REVBuybackPoolConfig` | `token`, `fee` (uint24), `twapWindow` (uint32) | Uniswap pool configuration for buyback |
| `REVSuckerDeploymentConfig` | `deployerConfigurations[]`, `salt` | Cross-chain sucker deployment |
| `REVDeploy721TiersHookConfig` | `baseline721HookConfiguration`, `salt`, `splitOperatorCanAdjustTiers`, `splitOperatorCanUpdateMetadata`, `splitOperatorCanMint`, `splitOperatorCanIncreaseDiscountPercent` | 721 hook deployment with operator permissions |
| `REVCroptopAllowedPost` | `category` (uint24), `minimumPrice` (uint104), `minimumTotalSupply` (uint32), `maximumTotalSupply` (uint32), `allowedAddresses[]` | Croptop posting criteria |

## Gotchas

- `REVLoan.amount` and `REVLoan.collateral` are `uint112` -- truncation risk with very large values (Critical audit finding C-1).
- `REVDeployer` stage configuration arrays must have increasing `startsAtOrAfter` values or deployment reverts (array out-of-bounds risk, C-2).
- `REVLoans` token callbacks during borrow/repay create reentrancy surface (C-3). The contract uses burn-before-transfer and mint-after-transfer patterns.
- `hasMintPermissionFor` calls `buybackHookOf[revnetId]` which could be `address(0)` -- the call chain through the buyback hook can revert (C-4).
- The `REVDeployer` project NFT is permanently locked in the deployer contract. There is no function to release it. This is by design -- revnets are ownerless.
- Auto-issuance stage IDs are based on `block.timestamp + i` where `i` is the stage index. If the first stage's `startsAtOrAfter` is 0, it becomes the deployment block timestamp (H-5).
- `cashOutTaxRate` must be strictly less than `MAX_CASH_OUT_TAX_RATE` -- revnets cannot fully disable cash outs.
- Cash out delay is 30 days (`CASH_OUT_DELAY = 2_592_000`), applied only when deploying an existing revnet to a new chain (first stage already started).
- Loan IDs encode the revnet ID: `loanId = revnetId * 1_000_000_000_000 + loanNumber`. Use `revnetIdOfLoanWith(loanId)` to decode.
- Loan liquidation duration is 10 years (`LOAN_LIQUIDATION_DURATION = 3650 days`). After this, collateral is forfeit.
- The split operator has 6 default permissions (SET_SPLIT_GROUPS, SET_BUYBACK_POOL, SET_BUYBACK_TWAP, SET_PROJECT_URI, ADD_PRICE_FEED, SUCKER_SAFETY) plus any extras from 721 hook config.
- `REVLoans` uses `permit2` for ERC-20 transfers as a fallback when standard allowance is insufficient.
- The `FEE` constant is `25` (out of `MAX_FEE = 1000`), meaning a 2.5% cash out fee paid to the fee revnet.
- `REV_PREPAID_FEE_PERCENT` is `10` (1%) -- this is the protocol-level fee on loans paid to the $REV revnet.
- `MIN_PREPAID_FEE_PERCENT` is `25` (2.5%) and `MAX_PREPAID_FEE_PERCENT` is `500` (50%) -- bounds on the borrower-chosen prepaid fee.

## Example Integration

```solidity
import {REVConfig} from "@rev-net/core-v5/src/structs/REVConfig.sol";
import {REVStageConfig} from "@rev-net/core-v5/src/structs/REVStageConfig.sol";
import {REVDescription} from "@rev-net/core-v5/src/structs/REVDescription.sol";
import {REVBuybackHookConfig} from "@rev-net/core-v5/src/structs/REVBuybackHookConfig.sol";
import {REVSuckerDeploymentConfig} from "@rev-net/core-v5/src/structs/REVSuckerDeploymentConfig.sol";
import {IREVDeployer} from "@rev-net/core-v5/src/interfaces/IREVDeployer.sol";

// Deploy a simple revnet with one stage.
function deployRevnet(IREVDeployer deployer, JBTerminalConfig[] memory terminals) external {
    // Define the stage: 1M tokens per unit, 10% issuance cut every 30 days, 20% cash out tax.
    REVStageConfig[] memory stages = new REVStageConfig[](1);
    stages[0] = REVStageConfig({
        startsAtOrAfter: 0, // Start immediately (uses block.timestamp).
        autoIssuances: new REVAutoIssuance[](0),
        splitPercent: 2000, // 20% of new tokens go to splits.
        splits: splits,     // Must have at least one split if splitPercent > 0.
        initialIssuance: 1_000_000e18,
        issuanceCutFrequency: 30 days,
        issuanceCutPercent: 100_000_000, // 10% cut per period.
        cashOutTaxRate: 2000, // 20% tax on cash outs.
        extraMetadata: 0
    });

    REVConfig memory config = REVConfig({
        description: REVDescription({
            name: "My Revnet Token",
            ticker: "MYREV",
            uri: "ipfs://...",
            salt: bytes32(0)
        }),
        baseCurrency: 1, // USD
        splitOperator: msg.sender,
        stageConfigurations: stages,
        loanSources: new REVLoanSource[](0),
        loans: address(0) // No loans contract.
    });

    // revnetId 0 = deploy new.
    deployer.deployFor({
        revnetId: 0,
        configuration: config,
        terminalConfigurations: terminals,
        buybackHookConfiguration: REVBuybackHookConfig({
            dataHook: IJBRulesetDataHook(address(0)),
            hookToConfigure: IJBBuybackHook(address(0)),
            poolConfigurations: new REVBuybackPoolConfig[](0)
        }),
        suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0),
            salt: bytes32(0)
        })
    });
}
```
