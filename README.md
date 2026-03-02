# revnet-core-v5

Deploy and operate Revnets: unowned Juicebox projects that run autonomously according to predefined stages, with built-in token-collateralized loans.

## Architecture

| Contract | Description |
|----------|-------------|
| [`REVDeployer`](src/REVDeployer.sol) | Deploys revnets as Juicebox projects owned by the deployer contract itself (no human owner). Translates stage configurations into Juicebox rulesets, manages buyback hooks, tiered 721 hooks, suckers, split operators, auto-issuance, and cash out fees. Acts as the ruleset data hook and cash out hook for every revnet it deploys. |
| [`REVLoans`](src/REVLoans.sol) | Lets participants borrow against their revnet tokens. Collateral tokens are burned on borrow and re-minted on repayment. Each loan is an ERC-721 NFT. Charges a prepaid fee (2.5% min, 50% max) that determines the interest-free duration; after that window, a time-proportional source fee accrues. Loans liquidate after 10 years. |

### How they relate

`REVDeployer` owns every revnet's Juicebox project NFT and holds all administrative permissions. During deployment it grants `REVLoans` the `USE_ALLOWANCE` permission so loans can pull funds from the revnet's terminal. `REVLoans` verifies that a revnet was deployed by its expected `REVDeployer` before issuing any loan.

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
