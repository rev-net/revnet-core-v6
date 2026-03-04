# revnet-core-v5

Deploy and operate Revnets: unowned Juicebox projects that run autonomously according to predefined stages, with built-in token-collateralized loans.

## What is a Revnet?

A Revnet is a Retailistic network — a treasury-backed token that runs itself. No owners, no governors, no multisigs. Once deployed, a revnet follows its predefined stages forever, backed by the Juicebox and Uniswap protocols.

For a Retailism TLDR, see [Retailism](https://jango.eth.sucks/9E01E72C-6028-48B7-AD04-F25393307132/).

For more Retailism information, see:

- [A Retailistic View on CAC and LTV](https://jango.eth.limo/572BD957-0331-4977-8B2D-35F84D693276/)
- [Modeling Retailism](https://jango.eth.limo/B762F3CC-AEFE-4DE0-B08C-7C16400AF718/)
- [Retailism for Devs, Investors, and Customers](https://jango.eth.limo/3EB05292-0376-4B7D-AFCF-042B70673C3D/)
- [Observations: Network dynamics similar between atoms, cells, organisms, groups, dance parties](https://jango.eth.limo/CF40F5D2-7BFE-43A3-9C15-1C6547FBD15C/)

Join the conversation: [Discord](https://discord.gg/nT3XqbzNEr)

## Architecture

| Contract | Description |
|----------|-------------|
| [`REVDeployer`](src/REVDeployer.sol) | Deploys revnets as Juicebox projects owned by the deployer contract itself (no human owner). Translates stage configurations into Juicebox rulesets, manages buyback hooks, tiered 721 hooks, suckers, split operators, auto-issuance, and cash out fees. Acts as the ruleset data hook and cash out hook for every revnet it deploys. |
| [`REVLoans`](src/REVLoans.sol) | Lets participants borrow against their revnet tokens. Collateral tokens are burned on borrow and re-minted on repayment. Each loan is an ERC-721 NFT. Charges a prepaid fee (2.5% min, 50% max) that determines the interest-free duration; after that window, a time-proportional source fee accrues. Loans liquidate after 10 years. |

### How they relate

`REVDeployer` owns every revnet's Juicebox project NFT and holds all administrative permissions. During deployment it grants `REVLoans` the `USE_ALLOWANCE` permission so loans can pull funds from the revnet's terminal. `REVLoans` verifies that a revnet was deployed by its expected `REVDeployer` before issuing any loan.

### Deployer Variants

This repo includes several deployer patterns for different use cases:

- **Basic revnet** — Deploy a simple revnet with `REVDeployer` using stage configurations that map to Juicebox rulesets.
- **Pay hook revnet** — Accept additional pay hooks that run throughout the revnet's lifetime as it receives payments.
- **Tiered 721 revnet** — Deploy a tiered 721 pay hook (NFT tiers) that mints NFTs as people pay into the revnet.
- **Croptop revnet** — A tiered 721 revnet where the public can post content through the [Croptop](https://croptop.eth.limo) publisher contract.

You can use these contracts to deploy treasuries from Etherscan, or wherever else they've been exposed from.

## Install

```bash
npm install @rev-net/core-v5
```

## Develop

This repo uses [npm](https://www.npmjs.com/) for package management and [Foundry](https://github.com/foundry-rs/foundry) for builds and tests.

```bash
npm install && forge install
```

If `forge install` has issues, try `git submodule update --init --recursive`.

| Command | Description |
|---------|-------------|
| `forge build` | Compile contracts |
| `forge test` | Run tests |
| `forge test -vvvv` | Run tests with full traces |
| `forge fmt` | Lint |
| `forge coverage` | Generate test coverage report |
| `forge build --sizes` | Get contract sizes |
