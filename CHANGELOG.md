# V5 to V6 Changelog

## Scope

This is a V5-to-V6 migration changelog, not a package release log or commit history. It compares `revnet-core-v5` in `../../v5/evm` with the current `revnet-core-v6` repo.

## Current V6 Surface

- `REVDeployer`
- `REVOwner`
- `REVLoans`
- `IREVDeployer`
- `IREVOwner`
- `IREVLoans`
- revnet structs and loan helper libraries under `src/`

## Summary

- Every revnet deployment is oriented around a tiered 721 hook. V5's separate `deployWith721sFor(...)` path is gone.
- `REVOwner` is a new runtime contract and interface. Hook behavior, auto-issuance, operator state, and project-NFT ownership no longer live only on `REVDeployer`.
- `REVOwner` is ERC-2771-aware like `REVDeployer` and `REVLoans`; its trusted forwarder is constructor-pinned and exposed through the inherited views.
- Buyback configuration moved from caller-supplied per-revnet config to shared registry/deployer wiring.
- Loans are shared infrastructure rather than per-revnet deployment state, and loan sources are tracked by token.
- Loan operator delegation uses V6 permission IDs for opening, reallocating, and repaying loans on behalf of holders/loan owners.
- Omnichain surplus handling uses the V6 sucker registry's per-context remote surplus API.

## ABI, Event, and Error Changes

- Removed functions:
  - `IREVDeployer.deployWith721sFor(...)`
  - `IREVDeployer.buybackHookOf(...)`
  - `IREVDeployer.loansOf(...)`
  - `IREVDeployer.setSplitOperatorOf(...)`
- Added functions and runtime addresses:
  - `IREVDeployer.BUYBACK_HOOK()`
  - `IREVDeployer.LOANS()`
  - `IREVDeployer.OWNER()`
  - `IREVDeployer.ROUTER_TERMINAL_REGISTRY()`
  - `IREVOwner` and its runtime state views
  - `REVOwner.trustedForwarder()` and `REVOwner.isTrustedForwarder(address)`
  - `REVDeployer` implements `IJBPayerTracker` and exposes the transient `originalPayer()`, advertising the resolved fee payer while forwarding a project-creation fee to `JBProjects.createFor` so the fee receiver credits the end user instead of the deployer.
- Changed functions:
  - `deployFor(...)` overloads return `(uint256 revnetId, IJB721TiersHook hook)`.
  - `REVLoans.borrowableAmountFrom(...)` returns `(borrowableNow, borrowableCapacity)` instead of one value.
  - `REVLoans.borrowFrom(...)` takes an `address holder` parameter; the holder's tokens are collateral and the holder receives the loan NFT.
  - `REVLoans.isLoanSourceOf(...)`, `loanSourceTokensOf(...)`, and `totalBorrowedFrom(...)` use token-oriented source tracking instead of the V5 `REVLoanSource` terminal/token pair surface.
- Changed structs:
  - `REVConfig` no longer carries V5 loan/buyback-hook config fields.
  - `REVDeploy721TiersHookConfig` now uses `REVBaseline721HookConfig` and V6 721 flags.
  - `REVLoan` and loan source tracking changed with token-oriented sources.
- Added events:
  - `InitializeRevnet`
  - `ReplaceOperator`
  - `AutoIssue` on `REVOwner`
  - `BurnHeldTokens`
- Changed events:
  - `DeployRevnet` no longer includes the V5 `REVBuybackHookConfig`.
  - loan events use V6 loan/token source fields.

## Machine-Checked ABI Coverage

Generated from Foundry `out/**/*.json` artifacts, filtered to this repo's own runtime source roots and excluding tests, scripts, and dependencies.

- V5 comparison package: `revnet-core-v5`.
- Own-source ABI artifacts compared: V6 `7`, V5 `13`.
- Contract/interface coverage: `3` added, `9` removed, `4` shared names with ABI changes, `0` shared names ABI-identical.
- Shared-name ABI item deltas: `69` added, `79` removed, `8` modified.

Added V6 ABI artifacts:
- `IREVOwner` from `src/interfaces/IREVOwner.sol`: `18` functions, `4` events, `0` errors.
- `REVLoansSourceFees` from `src/libraries/REVLoansSourceFees.sol`: `0` functions, `0` events, `1` errors.
- `REVOwner` from `src/REVOwner.sol`: `27` functions, `4` events, `15` errors.

Removed V5 ABI artifacts:
- `REVAutoIssuance` from `src/structs/REVAutoIssuance.sol`: `0` functions, `0` events, `0` errors.
- `REVConfig` from `src/structs/REVConfig.sol`: `0` functions, `0` events, `0` errors.
- `REVCroptopAllowedPost` from `src/structs/REVCroptopAllowedPost.sol`: `0` functions, `0` events, `0` errors.
- `REVDeploy721TiersHookConfig` from `src/structs/REVDeploy721TiersHookConfig.sol`: `0` functions, `0` events, `0` errors.
- `REVDescription` from `src/structs/REVDescription.sol`: `0` functions, `0` events, `0` errors.
- `REVLoan` from `src/structs/REVLoan.sol`: `0` functions, `0` events, `0` errors.
- `REVLoanSource` from `src/structs/REVLoanSource.sol`: `0` functions, `0` events, `0` errors.
- `REVStageConfig` from `src/structs/REVStageConfig.sol`: `0` functions, `0` events, `0` errors.
- `REVSuckerDeploymentConfig` from `src/structs/REVSuckerDeploymentConfig.sol`: `0` functions, `0` events, `0` errors.

Shared ABI artifacts with changes:
- `IREVDeployer`: `10` added, `17` removed, `0` modified ABI items.
- `IREVLoans`: `13` added, `12` removed, `3` modified ABI items.
- `REVDeployer`: `17` added, `32` removed, `1` modified ABI items.
- `REVLoans`: `29` added, `18` removed, `4` modified ABI items.

Generated event/error name deltas:
- Event names added:
  - `AutoIssue`, `Borrow`, `BurnHeldTokens`, `DeployRevnet`, `DeploySuckers`, `InitializeRevnet`, `Liquidate`, `ReallocateCollateral`.
  - `RepayLoan`, `ReplaceOperator`.
- Event names removed or replaced:
  - `AutoIssue`, `Borrow`, `BurnHeldTokens`, `DeployRevnet`, `DeploySuckers`, `Liquidate`, `ReallocateCollateral`, `RepayLoan`.
  - `ReplaceSplitOperator`, `SetAdditionalOperator`.
- Error names added:
  - `JBPermissioned_Unauthorized`, `PRBMath_MulDiv_Overflow`, `REVDeployer_AutoIssuanceBeneficiaryZeroAddress`, `REVDeployer_MustHaveSplits`, `REVDeployer_ProjectCreationFeeNotNeeded`, `REVDeployer_RulesetDoesNotAllowDeployingSuckers`, `REVDeployer_StageTimesMustIncrease`, `REVDeployer_StagesRequired`.
  - `REVLoans_CashOutDelayNotFinished`, `REVLoans_FeeAmountExceedsNetPayout`, `REVLoans_FeeOnTransferSourceUnsupported`, `REVLoans_InvalidAccountingContext`, `REVLoans_LoanExpired`, `REVLoans_LoanIdOverflow`, `REVLoans_LoanOwnerChanged`, `REVLoans_NoMsgValueAllowed`, `REVLoans_NotEnoughCollateral`.
  - `REVLoans_NothingToRepay`, `REVLoans_ReentrantLoanAction`, `REVLoans_SourceMismatch`, `REVLoans_ZeroBorrowAmount`, `REVLoans_ZeroCollateralLoanIsInvalid`, `REVLoans_ZeroPrice`, `REVOwner_AlreadyInitialized`, `REVOwner_CashOutDelayNotFinished`.
  - `REVOwner_InvalidLoanSourceToken`, `REVOwner_NativeFeeValueMismatch`, `REVOwner_NothingToAutoIssue`, `REVOwner_NothingToBurn`, `REVOwner_OverflowAlert`, `REVOwner_StageNotStarted`, `REVOwner_TooManyBuybackHookSpecifications`, `REVOwner_Unauthorized`.
  - `REVOwner_UnauthorizedOperator`, `REVOwner_ZeroPrice`, `SafeERC20FailedDecreaseAllowance`, `SafeERC20FailedOperation`.
- Error names removed or replaced:
  - `REVDeployer_AutoIssuanceBeneficiaryZeroAddress`, `REVDeployer_CashOutDelayNotFinished`, `REVDeployer_MustHaveSplits`, `REVDeployer_NothingToAutoIssue`, `REVDeployer_NothingToBurn`, `REVDeployer_RulesetDoesNotAllowDeployingSuckers`, `REVDeployer_StageNotStarted`, `REVDeployer_StageTimesMustIncrease`.
  - `REVDeployer_StagesRequired`, `REVLoans_NoMsgValueAllowed`, `REVLoans_NotEnoughCollateral`, `REVLoans_NothingToRepay`, `REVLoans_SourceMismatch`, `REVLoans_Unauthorized`, `REVLoans_ZeroCollateralLoanIsInvalid`, `SafeERC20FailedDecreaseAllowance`.
  - `SafeERC20FailedOperation`.

## Migration Notes

- Re-check any integration that assumed `REVDeployer` was the only important runtime address. `REVOwner` now matters.
- Update deployment and indexing code for the default-721-hook assumption and `deployFor(...)` return values.
- Update loan dashboards and operators for the two-value borrow preview and holder-based borrow delegation.
- Do not carry V5 buyback-hook config structs into V6 revnet deployment.
