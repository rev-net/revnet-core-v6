// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {JB721TiersHookFlags} from "@bananapus/721-hook-v6/src/structs/JB721TiersHookFlags.sol";
import {JBDeploy721TiersHookConfig} from "@bananapus/721-hook-v6/src/structs/JBDeploy721TiersHookConfig.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissioned} from "@bananapus/core-v6/src/interfaces/IJBPermissioned.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBSplitGroupIds} from "@bananapus/core-v6/src/libraries/JBSplitGroupIds.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBAfterCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterCashOutRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBCurrencyAmount} from "@bananapus/core-v6/src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {CTPublisher} from "@croptop/core-v6/src/CTPublisher.sol";
import {CTAllowedPost} from "@croptop/core-v6/src/structs/CTAllowedPost.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {mulDiv, sqrt} from "@prb/math/src/Common.sol";

import {IREVDeployer} from "./interfaces/IREVDeployer.sol";
import {REVAutoIssuance} from "./structs/REVAutoIssuance.sol";
import {REVConfig} from "./structs/REVConfig.sol";
import {REVCroptopAllowedPost} from "./structs/REVCroptopAllowedPost.sol";
import {REVDeploy721TiersHookConfig} from "./structs/REVDeploy721TiersHookConfig.sol";
import {REVStageConfig} from "./structs/REVStageConfig.sol";
import {REVSuckerDeploymentConfig} from "./structs/REVSuckerDeploymentConfig.sol";

/// @notice `REVDeployer` deploys, manages, and operates Revnets.
/// @dev Revnets are unowned Juicebox projects which operate autonomously after deployment.
contract REVDeployer is ERC2771Context, IREVDeployer, IJBRulesetDataHook, IJBCashOutHook, IERC721Receiver {
    // A library that adds default safety checks to ERC20 functionality.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error REVDeployer_AutoIssuanceBeneficiaryZeroAddress();
    error REVDeployer_CashOutDelayNotFinished(uint256 cashOutDelay, uint256 blockTimestamp);
    error REVDeployer_CashOutsCantBeTurnedOffCompletely(uint256 cashOutTaxRate, uint256 maxCashOutTaxRate);
    error REVDeployer_MustHaveSplits();
    error REVDeployer_NothingToAutoIssue();
    error REVDeployer_NothingToBurn();
    error REVDeployer_RulesetDoesNotAllowDeployingSuckers();
    error REVDeployer_StageNotStarted(uint256 stageId);
    error REVDeployer_StagesRequired();
    error REVDeployer_StageTimesMustIncrease();
    error REVDeployer_Unauthorized(uint256 revnetId, address caller);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The number of seconds until a revnet's participants can cash out, starting from the time when that
    /// revnet is deployed to a new network.
    /// - Only applies to existing revnets which are deploying onto a new network.
    /// - To prevent liquidity/arbitrage issues which might arise when an existing revnet adds a brand-new treasury.
    /// @dev 30 days, in seconds.
    uint256 public constant override CASH_OUT_DELAY = 2_592_000;

    /// @notice The cash out fee (as a fraction out of `JBConstants.MAX_FEE`).
    /// Cashout fees are paid to the revnet with the `FEE_REVNET_ID`.
    /// @dev Fees are charged on cashouts if the cash out tax rate is greater than 0%.
    /// @dev When suckers withdraw funds, they do not pay cash out fees.
    uint256 public constant override FEE = 25; // 2.5%

    /// @notice The default Uniswap pool fee tier used when auto-configuring buyback pools.
    /// @dev 10_000 = 1%. This is the standard fee tier for most project token pairs.
    uint24 public constant DEFAULT_BUYBACK_POOL_FEE = 10_000;

    /// @notice The default tick spacing used when auto-configuring buyback pools.
    /// @dev 200 aligns with UniV4DeploymentSplitHook.TICK_SPACING so both target the same pool.
    int24 public constant DEFAULT_BUYBACK_TICK_SPACING = 200;

    /// @notice The default TWAP window used when auto-configuring buyback pools.
    /// @dev 2 days provides robust manipulation resistance.
    uint32 public constant DEFAULT_BUYBACK_TWAP_WINDOW = 2 days;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The buyback hook used as a data hook to route payments through buyback pools.
    IJBBuybackHookRegistry public immutable override BUYBACK_HOOK;

    /// @notice The controller used to create and manage Juicebox projects for revnets.
    IJBController public immutable override CONTROLLER;

    /// @notice The directory of terminals and controllers for Juicebox projects (and revnets).
    IJBDirectory public immutable override DIRECTORY;

    /// @notice The Juicebox project ID of the revnet that receives cash out fees.
    uint256 public immutable override FEE_REVNET_ID;

    /// @notice Deploys tiered ERC-721 hooks for revnets.
    IJB721TiersHookDeployer public immutable override HOOK_DEPLOYER;

    /// @notice The loan contract used by all revnets.
    /// @dev Revnets can offer loans to their participants, collateralized by their tokens.
    /// Participants can borrow up to the current cash out value of their tokens.
    address public immutable override LOANS;

    /// @notice Stores Juicebox project (and revnet) access permissions.
    IJBPermissions public immutable override PERMISSIONS;

    /// @notice Mints ERC-721s that represent Juicebox project (and revnet) ownership and transfers.
    IJBProjects public immutable override PROJECTS;

    /// @notice Manages the publishing of ERC-721 posts to revnet's tiered ERC-721 hooks.
    CTPublisher public immutable override PUBLISHER;

    /// @notice Deploys and tracks suckers for revnets.
    IJBSuckerRegistry public immutable override SUCKER_REGISTRY;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The number of revnet tokens which can be "auto-minted" (minted without payments)
    /// for a specific beneficiary during a stage. Think of this as a per-stage premint.
    /// @dev These tokens can be minted with `autoIssueFor(…)`.
    /// @custom:param revnetId The ID of the revnet to get the auto-mint amount for.
    /// @custom:param stageId The ID of the stage to get the auto-mint amount for.
    /// @custom:param beneficiary The beneficiary of the auto-mint.
    mapping(uint256 revnetId => mapping(uint256 stageId => mapping(address beneficiary => uint256)))
        public
        override amountToAutoIssue;

    /// @notice The timestamp of when cashouts will become available to a specific revnet's participants.
    /// @dev Only applies to existing revnets which are deploying onto a new network.
    /// @custom:param revnetId The ID of the revnet to get the cash out delay for.
    mapping(uint256 revnetId => uint256 cashOutDelay) public override cashOutDelayOf;

    /// @notice The hashed encoded configuration of each revnet.
    /// @dev This is used to ensure that the encoded configuration of a revnet is the same when deploying suckers for
    /// omnichain operations.
    /// @custom:param revnetId The ID of the revnet to get the hashed encoded configuration for.
    mapping(uint256 revnetId => bytes32 hashedEncodedConfiguration) public override hashedEncodedConfigurationOf;

    /// @notice Each revnet's tiered ERC-721 hook.
    /// @custom:param revnetId The ID of the revnet to get the tiered ERC-721 hook for.
    // slither-disable-next-line uninitialized-state
    mapping(uint256 revnetId => IJB721TiersHook tiered721Hook) public override tiered721HookOf;

    //*********************************************************************//
    // ------------------- internal stored properties -------------------- //
    //*********************************************************************//

    /// @notice A list of `JBPermissonIds` indices to grant to the split operator of a specific revnet.
    /// @dev These should be set in the revnet's deployment process.
    /// @custom:param revnetId The ID of the revnet to get the extra operator permissions for.
    // slither-disable-next-line uninitialized-state
    mapping(uint256 revnetId => uint256[]) internal _extraOperatorPermissions;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param controller The controller to use for launching and operating the Juicebox projects which will be revnets.
    /// @param suckerRegistry The registry to use for deploying and tracking each revnet's suckers.
    /// @param feeRevnetId The Juicebox project ID of the revnet that will receive fees.
    /// @param hookDeployer The deployer to use for revnet's tiered ERC-721 hooks.
    /// @param publisher The croptop publisher revnets can use to publish ERC-721 posts to their tiered ERC-721 hooks.
    /// @param buybackHook The buyback hook used as a data hook to route payments through buyback pools.
    /// @param loans The loan contract used by all revnets.
    /// @param trustedForwarder The trusted forwarder for the ERC2771Context.
    constructor(
        IJBController controller,
        IJBSuckerRegistry suckerRegistry,
        uint256 feeRevnetId,
        IJB721TiersHookDeployer hookDeployer,
        CTPublisher publisher,
        IJBBuybackHookRegistry buybackHook,
        address loans,
        address trustedForwarder
    )
        ERC2771Context(trustedForwarder)
    {
        CONTROLLER = controller;
        DIRECTORY = controller.DIRECTORY();
        PROJECTS = controller.PROJECTS();
        PERMISSIONS = IJBPermissioned(address(CONTROLLER)).PERMISSIONS();
        SUCKER_REGISTRY = suckerRegistry;
        FEE_REVNET_ID = feeRevnetId;
        HOOK_DEPLOYER = hookDeployer;
        PUBLISHER = publisher;
        BUYBACK_HOOK = buybackHook;
        // slither-disable-next-line missing-zero-check
        LOANS = loans;

        // Give the sucker registry permission to map tokens for all revnets.
        _setPermission({
            operator: address(SUCKER_REGISTRY), revnetId: 0, permissionId: JBPermissionIds.MAP_SUCKER_TOKEN
        });

        // Give the loan contract permission to use the surplus allowance of all revnets.
        // Uses wildcard revnetId=0 intentionally — the loan contract is a singleton shared by all revnets,
        // and each revnet's surplus allowance limits already constrain how much can be drawn.
        _setPermission({operator: LOANS, revnetId: 0, permissionId: JBPermissionIds.USE_ALLOWANCE});

        // Give the buyback hook (registry) permission to configure pools on all revnets.
        _setPermission({operator: address(BUYBACK_HOOK), revnetId: 0, permissionId: JBPermissionIds.SET_BUYBACK_POOL});
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Determine how a cash out from a revnet should be processed.
    /// @dev This function is part of `IJBRulesetDataHook`, and gets called before the revnet processes a cash out.
    /// @dev If a sucker is cashing out, no taxes or fees are imposed.
    /// @dev REVDeployer is intentionally not registered as a feeless address. The protocol fee (2.5%) applies on top
    /// of the rev fee — this is by design. The fee hook spec amount sent to `afterCashOutRecordedWith` will have the
    /// protocol fee deducted by the terminal before reaching this contract, so the rev fee is computed on the
    /// post-protocol-fee amount.
    /// @param context Standard Juicebox cash out context. See `JBBeforeCashOutRecordedContext`.
    /// @return cashOutTaxRate The cash out tax rate, which influences the amount of terminal tokens which get cashed
    /// out.
    /// @return cashOutCount The number of revnet tokens that are cashed out.
    /// @return totalSupply The total revnet token supply.
    /// @return hookSpecifications The amount of funds and the data to send to cash out hooks (this contract).
    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        view
        override
        returns (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        // If the cash out is from a sucker, return the full cash out amount without taxes or fees.
        // This relies on the sucker registry to only contain trusted sucker contracts deployed via
        // the registry's own deploySuckersFor flow — external addresses cannot register as suckers.
        if (_isSuckerOf({revnetId: context.projectId, addr: context.holder})) {
            return (0, context.cashOutCount, context.totalSupply, hookSpecifications);
        }

        // Keep a reference to the cash out delay of the revnet.
        uint256 cashOutDelay = cashOutDelayOf[context.projectId];

        // Enforce the cash out delay.
        if (cashOutDelay > block.timestamp) {
            revert REVDeployer_CashOutDelayNotFinished(cashOutDelay, block.timestamp);
        }

        // Get the terminal that will receive the cash out fee.
        IJBTerminal feeTerminal = DIRECTORY.primaryTerminalOf({projectId: FEE_REVNET_ID, token: context.surplus.token});

        // If there's no cash out tax (100% cash out tax rate), if there's no fee terminal, or if the beneficiary is
        // feeless (e.g. the router terminal routing value between projects), proxy directly to the buyback hook.
        if (context.cashOutTaxRate == 0 || address(feeTerminal) == address(0) || context.beneficiaryIsFeeless) {
            // slither-disable-next-line unused-return
            return BUYBACK_HOOK.beforeCashOutRecordedWith(context);
        }

        // Split the cashed-out tokens into a fee portion and a non-fee portion.
        // Micro cash outs (< 40 wei at 2.5% fee) round feeCashOutCount to zero, bypassing the fee.
        // Economically insignificant: the gas cost of the transaction far exceeds the bypassed fee. No fix needed.
        uint256 feeCashOutCount = mulDiv({x: context.cashOutCount, y: FEE, denominator: JBConstants.MAX_FEE});
        uint256 nonFeeCashOutCount = context.cashOutCount - feeCashOutCount;

        // Calculate how much surplus the non-fee tokens can reclaim via the bonding curve.
        uint256 postFeeReclaimedAmount = JBCashOuts.cashOutFrom({
            surplus: context.surplus.value,
            cashOutCount: nonFeeCashOutCount,
            totalSupply: context.totalSupply,
            cashOutTaxRate: context.cashOutTaxRate
        });

        // Calculate how much the fee tokens reclaim from the remaining surplus after the non-fee reclaim.
        uint256 feeAmount = JBCashOuts.cashOutFrom({
            surplus: context.surplus.value - postFeeReclaimedAmount,
            cashOutCount: feeCashOutCount,
            totalSupply: context.totalSupply - nonFeeCashOutCount,
            cashOutTaxRate: context.cashOutTaxRate
        });

        // Build a context for the buyback hook using only the non-fee token count.
        JBBeforeCashOutRecordedContext memory buybackHookContext = context;
        buybackHookContext.cashOutCount = nonFeeCashOutCount;

        // Let the buyback hook adjust the cash out parameters and optionally return a hook specification.
        JBCashOutHookSpecification[] memory buybackHookSpecifications;
        (cashOutTaxRate, cashOutCount, totalSupply, buybackHookSpecifications) =
            BUYBACK_HOOK.beforeCashOutRecordedWith(buybackHookContext);

        // If the fee rounds down to zero, return the buyback hook's response directly — no fee to process.
        if (feeAmount == 0) return (cashOutTaxRate, cashOutCount, totalSupply, buybackHookSpecifications);

        // Build a hook spec that routes the fee amount to this contract's `afterCashOutRecordedWith` for processing.
        JBCashOutHookSpecification memory feeSpec = JBCashOutHookSpecification({
            hook: IJBCashOutHook(address(this)), noop: false, amount: feeAmount, metadata: abi.encode(feeTerminal)
        });

        // Compose the final hook specifications: buyback spec (if any) + fee spec.
        // NOTE: Only buybackHookSpecifications[0] is used. If the buyback hook returns multiple
        // specs, the additional ones are silently dropped. This is intentional — the buyback hook is
        // expected to return at most one spec for the cash-out buyback swap.
        if (buybackHookSpecifications.length > 0) {
            // The buyback hook returned a spec — include it before the fee spec.
            hookSpecifications = new JBCashOutHookSpecification[](2);
            hookSpecifications[0] = buybackHookSpecifications[0];
            hookSpecifications[1] = feeSpec;
        } else {
            // No buyback spec — only the fee spec.
            hookSpecifications = new JBCashOutHookSpecification[](1);
            hookSpecifications[0] = feeSpec;
        }

        return (cashOutTaxRate, cashOutCount, totalSupply, hookSpecifications);
    }

    /// @notice Before a revnet processes an incoming payment, determine the weight and pay hooks to use.
    /// @dev This function is part of `IJBRulesetDataHook`, and gets called before the revnet processes a payment.
    /// @param context Standard Juicebox payment context. See `JBBeforePayRecordedContext`.
    /// @return weight The weight which revnet tokens are minted relative to. This can be used to customize how many
    /// tokens get minted by a payment.
    /// @return hookSpecifications Amounts (out of what's being paid in) to be sent to pay hooks instead of being paid
    /// into the revnet. Useful for automatically routing funds from a treasury as payments come in.
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        override
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        // Get the 721 hook's spec and total split amount.
        IJB721TiersHook tiered721Hook = tiered721HookOf[context.projectId];
        JBPayHookSpecification memory tiered721HookSpec;
        uint256 totalSplitAmount;
        bool usesTiered721Hook = address(tiered721Hook) != address(0);
        if (usesTiered721Hook) {
            JBPayHookSpecification[] memory specs;
            // slither-disable-next-line unused-return
            (, specs) = IJBRulesetDataHook(address(tiered721Hook)).beforePayRecordedWith(context);
            // The 721 hook returns a single spec (itself) whose amount is the total split amount.
            if (specs.length > 0) {
                tiered721HookSpec = specs[0];
                totalSplitAmount = tiered721HookSpec.amount;
            }
        }

        // The amount entering the project after tier splits.
        uint256 projectAmount = totalSplitAmount >= context.amount.value ? 0 : context.amount.value - totalSplitAmount;

        // Get the buyback hook's weight and specs. Reduce the amount so it only considers funds entering the project.
        JBPayHookSpecification[] memory buybackHookSpecs;
        {
            JBBeforePayRecordedContext memory buybackHookContext = context;
            buybackHookContext.amount.value = projectAmount;
            (weight, buybackHookSpecs) = BUYBACK_HOOK.beforePayRecordedWith(buybackHookContext);
        }

        // Scale the buyback hook's weight for splits so the terminal mints tokens only for the project's share.
        // The terminal uses the full context.amount.value for minting (tokenCount = amount * weight / weightRatio),
        // but only projectAmount actually enters the project. Without scaling, payers get token credit for the split
        // portion too. Preserves weight=0 from the buyback hook (buying back, not minting).
        if (projectAmount == 0) {
            weight = 0;
        } else if (projectAmount < context.amount.value) {
            weight = mulDiv({x: weight, y: projectAmount, denominator: context.amount.value});
        }

        // Merge hook specifications: 721 hook spec first, then buyback hook spec.
        bool usesBuybackHook = buybackHookSpecs.length > 0;
        hookSpecifications = new JBPayHookSpecification[]((usesTiered721Hook ? 1 : 0) + (usesBuybackHook ? 1 : 0));

        if (usesTiered721Hook) hookSpecifications[0] = tiered721HookSpec;
        if (usesBuybackHook) hookSpecifications[usesTiered721Hook ? 1 : 0] = buybackHookSpecs[0];
    }

    /// @notice A flag indicating whether an address has permission to mint a revnet's tokens on-demand.
    /// @dev Required by the `IJBRulesetDataHook` interface.
    /// @param revnetId The ID of the revnet to check permissions for.
    /// @param ruleset The ruleset to check the mint permission for.
    /// @param addr The address to check the mint permission of.
    /// @return flag A flag indicating whether the address has permission to mint the revnet's tokens on-demand.
    function hasMintPermissionFor(
        uint256 revnetId,
        JBRuleset calldata ruleset,
        address addr
    )
        external
        view
        override
        returns (bool)
    {
        // The loans contract, buyback hook (and its delegates), and suckers are allowed to mint the revnet's tokens.
        return addr == LOANS || addr == address(BUYBACK_HOOK)
            || BUYBACK_HOOK.hasMintPermissionFor({projectId: revnetId, ruleset: ruleset, addr: addr})
            || _isSuckerOf({revnetId: revnetId, addr: addr});
    }

    /// @dev Make sure this contract can only receive project NFTs from `JBProjects`.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        // Make sure the 721 received is from the `JBProjects` contract.
        if (msg.sender != address(PROJECTS)) revert();

        return IERC721Receiver.onERC721Received.selector;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice A flag indicating whether an address is a revnet's split operator.
    /// @param revnetId The ID of the revnet.
    /// @param addr The address to check.
    /// @return flag A flag indicating whether the address is the revnet's split operator.
    function isSplitOperatorOf(uint256 revnetId, address addr) public view override returns (bool) {
        return PERMISSIONS.hasPermissions({
            operator: addr,
            account: address(this),
            projectId: revnetId,
            permissionIds: _splitOperatorPermissionIndexesOf(revnetId),
            includeRoot: false,
            includeWildcardProjectId: false
        });
    }

    /// @notice Indicates if this contract adheres to the specified interface.
    /// @dev See `IERC165.supportsInterface`.
    /// @return A flag indicating if the provided interface ID is supported.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IREVDeployer).interfaceId || interfaceId == type(IJBRulesetDataHook).interfaceId
            || interfaceId == type(IJBCashOutHook).interfaceId || interfaceId == type(IERC721Receiver).interfaceId;
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice If the specified address is not the revnet's current split operator, revert.
    /// @param revnetId The ID of the revnet to check split operator status for.
    /// @param operator The address being checked.
    function _checkIfIsSplitOperatorOf(uint256 revnetId, address operator) internal view {
        if (!isSplitOperatorOf({revnetId: revnetId, addr: operator})) {
            revert REVDeployer_Unauthorized(revnetId, operator);
        }
    }

    /// @notice A flag indicating whether an address is a revnet's sucker.
    /// @param revnetId The ID of the revnet to check sucker status for.
    /// @param addr The address being checked.
    /// @return isSucker A flag indicating whether the address is one of the revnet's suckers.
    function _isSuckerOf(uint256 revnetId, address addr) internal view returns (bool) {
        return SUCKER_REGISTRY.isSuckerOf({projectId: revnetId, addr: addr});
    }

    /// @notice Initialize fund access limits for the loan contract.
    /// @dev Returns an unlimited surplus allowance for each terminal+token pair derived from the terminal
    /// configurations.
    /// @param terminalConfigurations The terminals to set up for the revnet. Used for payments and cash outs.
    /// @return fundAccessLimitGroups The fund access limit groups for the loans.
    function _makeLoanFundAccessLimits(JBTerminalConfig[] calldata terminalConfigurations)
        internal
        pure
        returns (JBFundAccessLimitGroup[] memory fundAccessLimitGroups)
    {
        // Count the total number of accounting contexts across all terminals.
        uint256 count;
        for (uint256 i; i < terminalConfigurations.length; i++) {
            count += terminalConfigurations[i].accountingContextsToAccept.length;
        }

        // Initialize the fund access limit groups.
        fundAccessLimitGroups = new JBFundAccessLimitGroup[](count);

        // Set up the fund access limits.
        uint256 index;
        for (uint256 i; i < terminalConfigurations.length; i++) {
            JBTerminalConfig calldata terminalConfiguration = terminalConfigurations[i];
            for (uint256 j; j < terminalConfiguration.accountingContextsToAccept.length; j++) {
                JBAccountingContext calldata accountingContext = terminalConfiguration.accountingContextsToAccept[j];

                // Set up an unlimited allowance for the loan contract to use.
                JBCurrencyAmount[] memory loanAllowances = new JBCurrencyAmount[](1);
                loanAllowances[0] = JBCurrencyAmount({currency: accountingContext.currency, amount: type(uint224).max});

                // Set up the fund access limits for the loans.
                fundAccessLimitGroups[index++] = JBFundAccessLimitGroup({
                    terminal: address(terminalConfiguration.terminal),
                    token: accountingContext.token,
                    payoutLimits: new JBCurrencyAmount[](0),
                    surplusAllowances: loanAllowances
                });
            }
        }
    }

    /// @notice Make a ruleset configuration for a revnet's stage.
    /// @param baseCurrency The base currency of the revnet.
    /// @param stageConfiguration The stage configuration to make a ruleset for.
    /// @param fundAccessLimitGroups The fund access limit groups to set up for the ruleset.
    /// @return rulesetConfiguration The ruleset configuration.
    function _makeRulesetConfiguration(
        uint32 baseCurrency,
        REVStageConfig calldata stageConfiguration,
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups
    )
        internal
        view
        returns (JBRulesetConfig memory)
    {
        // Set up the ruleset's metadata.
        JBRulesetMetadata memory metadata;
        metadata.reservedPercent = stageConfiguration.splitPercent;
        metadata.cashOutTaxRate = stageConfiguration.cashOutTaxRate;
        metadata.baseCurrency = baseCurrency;
        metadata.useTotalSurplusForCashOuts = true; // Use surplus from all terminals for cash outs.
        metadata.allowOwnerMinting = true; // Allow this contract to auto-mint tokens as the revnet's owner.
        metadata.useDataHookForPay = true; // Call this contract's `beforePayRecordedWith(…)` callback on payments.
        metadata.useDataHookForCashOut = true; // Call this contract's `beforeCashOutRecordedWith(…)` callback on cash
        // outs.
        metadata.dataHook = address(this); // This contract is the data hook.
        metadata.metadata = stageConfiguration.extraMetadata;

        // Package the reserved token splits.
        JBSplitGroup[] memory splitGroups = new JBSplitGroup[](1);
        splitGroups[0] = JBSplitGroup({groupId: JBSplitGroupIds.RESERVED_TOKENS, splits: stageConfiguration.splits});

        return JBRulesetConfig({
            mustStartAtOrAfter: stageConfiguration.startsAtOrAfter,
            duration: stageConfiguration.issuanceCutFrequency,
            weight: stageConfiguration.initialIssuance,
            weightCutPercent: stageConfiguration.issuanceCutPercent,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: metadata,
            splitGroups: splitGroups,
            fundAccessLimitGroups: fundAccessLimitGroups
        });
    }

    /// @notice Returns the next project ID.
    /// @return nextProjectId The next project ID.
    function _nextProjectId() internal view returns (uint256) {
        return PROJECTS.count() + 1;
    }

    /// @notice Returns the permissions that the split operator should be granted for a revnet.
    /// @param revnetId The ID of the revnet to get split operator permissions for.
    /// @return allOperatorPermissions The permissions that the split operator should be granted for the revnet,
    /// including both default and custom permissions.
    function _splitOperatorPermissionIndexesOf(uint256 revnetId)
        internal
        view
        returns (uint256[] memory allOperatorPermissions)
    {
        // Keep a reference to the custom split operator permissions.
        uint256[] memory customSplitOperatorPermissionIndexes = _extraOperatorPermissions[revnetId];

        // Make the array that merges the default and custom operator permissions.
        allOperatorPermissions = new uint256[](9 + customSplitOperatorPermissionIndexes.length);
        allOperatorPermissions[0] = JBPermissionIds.SET_SPLIT_GROUPS;
        allOperatorPermissions[1] = JBPermissionIds.SET_BUYBACK_POOL;
        allOperatorPermissions[2] = JBPermissionIds.SET_BUYBACK_TWAP;
        allOperatorPermissions[3] = JBPermissionIds.SET_PROJECT_URI;
        allOperatorPermissions[4] = JBPermissionIds.ADD_PRICE_FEED;
        allOperatorPermissions[5] = JBPermissionIds.SUCKER_SAFETY;
        allOperatorPermissions[6] = JBPermissionIds.SET_BUYBACK_HOOK;
        allOperatorPermissions[7] = JBPermissionIds.SET_ROUTER_TERMINAL;
        allOperatorPermissions[8] = JBPermissionIds.SET_TOKEN_METADATA;

        // Copy the custom permissions into the array.
        for (uint256 i; i < customSplitOperatorPermissionIndexes.length; i++) {
            allOperatorPermissions[9 + i] = customSplitOperatorPermissionIndexes[i];
        }
    }

    /// @notice Try to initialize a Uniswap V4 buyback pool for a terminal token at its fair issuance price.
    /// @dev Called after the ERC-20 token is deployed so the pool can be initialized in the PoolManager.
    /// Computes `sqrtPriceX96` from `initialIssuance` so the pool starts at the same price as the bonding curve.
    /// Silently catches failures (e.g., if the pool is already initialized).
    /// @param revnetId The ID of the revnet.
    /// @param terminalToken The terminal token to initialize a buyback pool for.
    /// @param initialIssuance The initial issuance rate (project tokens per terminal token, 18 decimals).
    function _tryInitializeBuybackPoolFor(uint256 revnetId, address terminalToken, uint112 initialIssuance) internal {
        uint160 sqrtPriceX96;

        if (initialIssuance == 0) {
            sqrtPriceX96 = uint160(1 << 96);
        } else {
            address normalizedTerminalToken = terminalToken == JBConstants.NATIVE_TOKEN ? address(0) : terminalToken;
            address projectToken = address(CONTROLLER.TOKENS().tokenOf(revnetId));

            if (projectToken == address(0) || projectToken == normalizedTerminalToken) {
                sqrtPriceX96 = uint160(1 << 96);
            } else if (normalizedTerminalToken < projectToken) {
                // token0 = terminal, token1 = project → price = issuance / 1e18
                sqrtPriceX96 = uint160(sqrt(mulDiv(uint256(initialIssuance), 1 << 192, 1e18)));
            } else {
                // token0 = project, token1 = terminal → price = 1e18 / issuance
                sqrtPriceX96 = uint160(sqrt(mulDiv(1e18, 1 << 192, uint256(initialIssuance))));
            }
        }

        // slither-disable-next-line calls-loop
        try BUYBACK_HOOK.initializePoolFor({
            projectId: revnetId,
            fee: DEFAULT_BUYBACK_POOL_FEE,
            tickSpacing: DEFAULT_BUYBACK_TICK_SPACING,
            twapWindow: DEFAULT_BUYBACK_TWAP_WINDOW,
            terminalToken: terminalToken,
            sqrtPriceX96: sqrtPriceX96
        }) {}
            catch {} // Pool may already be initialized — that's OK.
    }

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Processes the fee from a cash out.
    /// @param context Cash out context passed in by the terminal.
    function afterCashOutRecordedWith(JBAfterCashOutRecordedContext calldata context) external payable {
        // No caller validation needed — this hook only pays fees to the fee project using funds forwarded by the
        // caller. A non-terminal caller would just be donating their own funds as fees. There's nothing to exploit.

        // If there's sufficient approval, transfer normally.
        if (context.forwardedAmount.token != JBConstants.NATIVE_TOKEN) {
            IERC20(context.forwardedAmount.token)
                .safeTransferFrom({from: msg.sender, to: address(this), value: context.forwardedAmount.value});
        }

        // Parse the metadata forwarded from the data hook to get the fee terminal.
        // See `beforeCashOutRecordedWith(…)`.
        (IJBTerminal feeTerminal) = abi.decode(context.hookMetadata, (IJBTerminal));

        // Determine how much to pay in `msg.value` (in the native currency).
        uint256 payValue = _beforeTransferTo({
            to: address(feeTerminal), token: context.forwardedAmount.token, amount: context.forwardedAmount.value
        });

        // Pay the fee.
        // slither-disable-next-line arbitrary-send-eth,unused-return
        try feeTerminal.pay{value: payValue}({
            projectId: FEE_REVNET_ID,
            token: context.forwardedAmount.token,
            amount: context.forwardedAmount.value,
            beneficiary: context.holder,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes(abi.encodePacked(context.projectId))
        }) {}
        catch (bytes memory) {
            // Decrease the allowance for the fee terminal if the token is not the native token.
            if (context.forwardedAmount.token != JBConstants.NATIVE_TOKEN) {
                IERC20(context.forwardedAmount.token)
                    .safeDecreaseAllowance({
                        spender: address(feeTerminal), requestedDecrease: context.forwardedAmount.value
                    });
            }

            // If the fee can't be processed, return the funds to the project.
            payValue = _beforeTransferTo({
                to: msg.sender, token: context.forwardedAmount.token, amount: context.forwardedAmount.value
            });

            // slither-disable-next-line arbitrary-send-eth
            IJBTerminal(msg.sender).addToBalanceOf{value: payValue}({
                projectId: context.projectId,
                token: context.forwardedAmount.token,
                amount: context.forwardedAmount.value,
                shouldReturnHeldFees: false,
                memo: "",
                metadata: bytes(abi.encodePacked(FEE_REVNET_ID))
            });
        }
    }

    /// @notice Auto-mint a revnet's tokens from a stage for a beneficiary.
    /// @param revnetId The ID of the revnet to auto-mint tokens from.
    /// @param stageId The ID of the stage auto-mint tokens are available from.
    /// @param beneficiary The address to auto-mint tokens to.
    function autoIssueFor(uint256 revnetId, uint256 stageId, address beneficiary) external override {
        // Get the ruleset for the stage to check if it has started.
        // Stage IDs are `block.timestamp + i` where `i` is the stage index. These match real JB ruleset IDs
        // because JBRulesets assigns IDs the same way: `latestId >= block.timestamp ? latestId + 1 : block.timestamp`
        // (see JBRulesets.sol L172). When all stages are queued in a single deployFor() call, the sequential
        // IDs `block.timestamp`, `block.timestamp + 1`, ... exactly correspond to the JB-assigned ruleset IDs.
        // The returned `ruleset.start` contains the derived start time (from `deriveStartFrom` using the stage's
        // `mustStartAtOrAfter`), NOT the queue timestamp — so the timing guard correctly blocks early claims.
        // slither-disable-next-line unused-return
        (JBRuleset memory ruleset,) = CONTROLLER.getRulesetOf({projectId: revnetId, rulesetId: stageId});

        // Make sure the stage has started.
        if (ruleset.start > block.timestamp) {
            revert REVDeployer_StageNotStarted(stageId);
        }

        // Get a reference to the number of tokens to auto-issue.
        uint256 count = amountToAutoIssue[revnetId][stageId][beneficiary];

        // If there's nothing to auto-mint, return.
        if (count == 0) revert REVDeployer_NothingToAutoIssue();

        // Reset the auto-mint amount.
        amountToAutoIssue[revnetId][stageId][beneficiary] = 0;

        emit AutoIssue({
            revnetId: revnetId, stageId: stageId, beneficiary: beneficiary, count: count, caller: _msgSender()
        });

        // Mint the tokens.
        // slither-disable-next-line unused-return
        CONTROLLER.mintTokensOf({
            projectId: revnetId, tokenCount: count, beneficiary: beneficiary, memo: "", useReservedPercent: false
        });
    }

    /// @notice Burn any of a revnet's tokens held by this contract.
    /// @dev Project tokens can end up here from reserved token distribution when splits don't sum to 100%.
    /// @param revnetId The ID of the revnet whose tokens should be burned.
    function burnHeldTokensOf(uint256 revnetId) external override {
        uint256 balance = CONTROLLER.TOKENS().totalBalanceOf({holder: address(this), projectId: revnetId});
        if (balance == 0) revert REVDeployer_NothingToBurn();
        CONTROLLER.burnTokensOf({holder: address(this), projectId: revnetId, tokenCount: balance, memo: ""});
        // slither-disable-next-line reentrancy-events
        emit BurnHeldTokens(revnetId, balance, _msgSender());
    }

    /// @notice Launch a revnet, or initialize an existing Juicebox project as a revnet.
    /// @dev When initializing an existing project (revnetId != 0):
    /// - The project must not yet have a controller or rulesets. `JBController.launchRulesetsFor` enforces this —
    ///   it reverts if rulesets have already been launched, and `JBDirectory.setControllerOf` only allows setting the
    ///   first controller. This means conversion only works for blank projects (just an ID with no on-chain state).
    /// - This is useful in deploy scripts where the project ID is needed before configuration (e.g. for cross-chain
    ///   sucker peer mappings): create the project first, then initialize it as a revnet here.
    /// - Initialization is a one-way operation: the project's ownership NFT is permanently transferred to this
    ///   REVDeployer, and the project becomes subject to immutable revnet rules. This cannot be undone.
    /// @param revnetId The ID of the Juicebox project to initialize as a revnet. Send 0 to deploy a new revnet.
    /// @param configuration Core revnet configuration. See `REVConfig`.
    /// @param terminalConfigurations The terminals to set up for the revnet. Used for payments and cash outs.
    /// @param suckerDeploymentConfiguration The suckers to set up for the revnet. Suckers facilitate cross-chain
    /// token transfers between peer revnets on different networks.
    /// @param tiered721HookConfiguration How to set up the tiered ERC-721 hook for the revnet.
    /// @param allowedPosts Restrictions on which croptop posts are allowed on the revnet's ERC-721 tiers.
    /// @return revnetId The ID of the newly created revnet.
    /// @return hook The address of the tiered ERC-721 hook that was deployed for the revnet.
    function deployFor(
        uint256 revnetId,
        REVConfig calldata configuration,
        JBTerminalConfig[] calldata terminalConfigurations,
        REVSuckerDeploymentConfig calldata suckerDeploymentConfiguration,
        REVDeploy721TiersHookConfig calldata tiered721HookConfiguration,
        REVCroptopAllowedPost[] calldata allowedPosts
    )
        external
        override
        returns (uint256, IJB721TiersHook hook)
    {
        // Keep a reference to the revnet ID which was passed in.
        bool shouldDeployNewRevnet = revnetId == 0;

        // If the caller is deploying a new revnet, calculate its ID
        // (which will be 1 greater than the current count).
        if (shouldDeployNewRevnet) revnetId = _nextProjectId();

        // Deploy the revnet with the specified tiered ERC-721 hook and croptop posting criteria.
        hook = _deploy721RevnetFor({
            revnetId: revnetId,
            shouldDeployNewRevnet: shouldDeployNewRevnet,
            configuration: configuration,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: suckerDeploymentConfiguration,
            tiered721HookConfiguration: tiered721HookConfiguration,
            allowedPosts: allowedPosts
        });

        return (revnetId, hook);
    }

    /// @inheritdoc IREVDeployer
    function deployFor(
        uint256 revnetId,
        REVConfig calldata configuration,
        JBTerminalConfig[] calldata terminalConfigurations,
        REVSuckerDeploymentConfig calldata suckerDeploymentConfiguration
    )
        external
        override
        returns (uint256, IJB721TiersHook hook)
    {
        bool shouldDeployNewRevnet = revnetId == 0;
        if (shouldDeployNewRevnet) revnetId = _nextProjectId();

        // Deploy the revnet (project, rulesets, ERC-20, suckers, etc.).
        bytes32 encodedConfigurationHash = _deployRevnetFor({
            revnetId: revnetId,
            shouldDeployNewRevnet: shouldDeployNewRevnet,
            configuration: configuration,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: suckerDeploymentConfiguration
        });

        // Deploy a default empty 721 hook for the revnet.
        {
            JBDeploy721TiersHookConfig memory deployConfig;
            deployConfig.tiersConfig.currency = configuration.baseCurrency;
            deployConfig.tiersConfig.decimals = 18;

            hook = HOOK_DEPLOYER.deployHookFor({
                projectId: revnetId,
                deployTiersHookConfig: deployConfig,
                salt: keccak256(abi.encode(bytes32(0), encodedConfigurationHash, _msgSender()))
            });
        }

        // Store the tiered ERC-721 hook.
        tiered721HookOf[revnetId] = hook;

        // Grant the split operator all 721 permissions (no prevent* flags for default config).
        _extraOperatorPermissions[revnetId].push(JBPermissionIds.ADJUST_721_TIERS);
        _extraOperatorPermissions[revnetId].push(JBPermissionIds.SET_721_METADATA);
        _extraOperatorPermissions[revnetId].push(JBPermissionIds.MINT_721);
        _extraOperatorPermissions[revnetId].push(JBPermissionIds.SET_721_DISCOUNT_PERCENT);

        // Give the split operator their permissions (base + 721 extras).
        _setSplitOperatorOf({revnetId: revnetId, operator: configuration.splitOperator});

        return (revnetId, hook);
    }

    /// @notice Deploy new suckers for an existing revnet.
    /// @dev Only the revnet's split operator can deploy new suckers.
    /// @param revnetId The ID of the revnet to deploy suckers for.
    /// See `_makeRulesetConfigurations(…)` for encoding details. Clients can read the encoded configuration
    /// from the `DeployRevnet` event emitted by this contract.
    /// @param suckerDeploymentConfiguration The suckers to set up for the revnet.
    function deploySuckersFor(
        uint256 revnetId,
        REVSuckerDeploymentConfig calldata suckerDeploymentConfiguration
    )
        external
        override
        returns (address[] memory suckers)
    {
        // Make sure the caller is the revnet's split operator.
        _checkIfIsSplitOperatorOf({revnetId: revnetId, operator: _msgSender()});

        // Check if the current ruleset allows deploying new suckers.
        // slither-disable-next-line unused-return
        (, JBRulesetMetadata memory metadata) = CONTROLLER.currentRulesetOf(revnetId);

        // Check the third bit, it indicates if the ruleset allows new suckers to be deployed.
        bool allowsDeployingSuckers = ((metadata.metadata >> 2) & 1) == 1;

        if (!allowsDeployingSuckers) {
            revert REVDeployer_RulesetDoesNotAllowDeployingSuckers();
        }

        // Deploy the suckers.
        suckers = _deploySuckersFor({
            revnetId: revnetId,
            encodedConfigurationHash: hashedEncodedConfigurationOf[revnetId],
            suckerDeploymentConfiguration: suckerDeploymentConfiguration
        });
    }

    /// @notice Change a revnet's split operator.
    /// @dev Only a revnet's current split operator can set a new split operator.
    /// @dev Passing `address(0)` as `newSplitOperator` relinquishes operator powers permanently — the permissions
    /// are granted to the zero address (which cannot execute transactions), effectively burning them.
    /// @param revnetId The ID of the revnet to set the split operator of.
    /// @param newSplitOperator The new split operator's address. Use `address(0)` to relinquish operator powers.
    function setSplitOperatorOf(uint256 revnetId, address newSplitOperator) external override {
        // Enforce permissions.
        _checkIfIsSplitOperatorOf({revnetId: revnetId, operator: _msgSender()});

        emit ReplaceSplitOperator({revnetId: revnetId, newSplitOperator: newSplitOperator, caller: _msgSender()});

        // Remove operator permissions from the old split operator.
        _setPermissionsFor({
            account: address(this), operator: _msgSender(), revnetId: revnetId, permissionIds: new uint8[](0)
        });

        // Set the new split operator.
        _setSplitOperatorOf({revnetId: revnetId, operator: newSplitOperator});
    }

    //*********************************************************************//
    // --------------------- internal transactions ----------------------- //
    //*********************************************************************//

    /// @notice Logic to be triggered before transferring tokens from this contract.
    /// @param to The address the transfer is going to.
    /// @param token The token being transferred.
    /// @param amount The number of tokens being transferred, as a fixed point number with the same number of decimals
    /// as the token specifies.
    /// @return payValue The value to attach to the transaction being sent.
    function _beforeTransferTo(address to, address token, uint256 amount) internal returns (uint256) {
        // If the token is the native token, no allowance needed.
        if (token == JBConstants.NATIVE_TOKEN) return amount;
        IERC20(token).safeIncreaseAllowance({spender: to, value: amount});
        return 0;
    }

    /// @notice Deploy a revnet which sells tiered ERC-721s and (optionally) allows croptop posts to its ERC-721 tiers.
    function _deploy721RevnetFor(
        uint256 revnetId,
        bool shouldDeployNewRevnet,
        REVConfig calldata configuration,
        JBTerminalConfig[] calldata terminalConfigurations,
        REVSuckerDeploymentConfig calldata suckerDeploymentConfiguration,
        REVDeploy721TiersHookConfig memory tiered721HookConfiguration,
        REVCroptopAllowedPost[] memory allowedPosts
    )
        internal
        returns (IJB721TiersHook hook)
    {
        // Deploy the revnet (project, rulesets, ERC-20, suckers, etc.).
        bytes32 encodedConfigurationHash = _deployRevnetFor({
            revnetId: revnetId,
            shouldDeployNewRevnet: shouldDeployNewRevnet,
            configuration: configuration,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: suckerDeploymentConfiguration
        });

        // Convert the REVBaseline721HookConfig to JBDeploy721TiersHookConfig, forcing issueTokensForSplits to false.
        // Revnets do their own weight adjustment for splits, so the 721 hook must not also adjust.
        hook = HOOK_DEPLOYER.deployHookFor({
            projectId: revnetId,
            deployTiersHookConfig: JBDeploy721TiersHookConfig({
                name: tiered721HookConfiguration.baseline721HookConfiguration.name,
                symbol: tiered721HookConfiguration.baseline721HookConfiguration.symbol,
                baseUri: tiered721HookConfiguration.baseline721HookConfiguration.baseUri,
                tokenUriResolver: tiered721HookConfiguration.baseline721HookConfiguration.tokenUriResolver,
                contractUri: tiered721HookConfiguration.baseline721HookConfiguration.contractUri,
                tiersConfig: tiered721HookConfiguration.baseline721HookConfiguration.tiersConfig,
                reserveBeneficiary: tiered721HookConfiguration.baseline721HookConfiguration.reserveBeneficiary,
                flags: JB721TiersHookFlags({
                    noNewTiersWithReserves: tiered721HookConfiguration.baseline721HookConfiguration.flags
                    .noNewTiersWithReserves,
                    noNewTiersWithVotes: tiered721HookConfiguration.baseline721HookConfiguration.flags
                        .noNewTiersWithVotes,
                    noNewTiersWithOwnerMinting: tiered721HookConfiguration.baseline721HookConfiguration.flags
                        .noNewTiersWithOwnerMinting,
                    preventOverspending: tiered721HookConfiguration.baseline721HookConfiguration.flags
                        .preventOverspending,
                    issueTokensForSplits: false
                })
            }),
            salt: keccak256(abi.encode(tiered721HookConfiguration.salt, encodedConfigurationHash, _msgSender()))
        });

        // Store the tiered ERC-721 hook.
        tiered721HookOf[revnetId] = hook;

        // Give the split operator permission to add and remove tiers unless prevented.
        if (!tiered721HookConfiguration.preventSplitOperatorAdjustingTiers) {
            _extraOperatorPermissions[revnetId].push(JBPermissionIds.ADJUST_721_TIERS);
        }

        // Give the split operator permission to set ERC-721 tier metadata unless prevented.
        if (!tiered721HookConfiguration.preventSplitOperatorUpdatingMetadata) {
            _extraOperatorPermissions[revnetId].push(JBPermissionIds.SET_721_METADATA);
        }

        // Give the split operator permission to mint ERC-721s (without a payment)
        // from tiers with `allowOwnerMint` set to true, unless prevented.
        if (!tiered721HookConfiguration.preventSplitOperatorMinting) {
            _extraOperatorPermissions[revnetId].push(JBPermissionIds.MINT_721);
        }

        // Give the split operator permission to increase the discount of a tier unless prevented.
        if (!tiered721HookConfiguration.preventSplitOperatorIncreasingDiscountPercent) {
            _extraOperatorPermissions[revnetId].push(JBPermissionIds.SET_721_DISCOUNT_PERCENT);
        }

        // Give the split operator their permissions (base + 721 extras).
        _setSplitOperatorOf({revnetId: revnetId, operator: configuration.splitOperator});

        // If there are posts to allow, configure them.
        if (allowedPosts.length != 0) {
            // Keep a reference to the formatted allowed posts.
            CTAllowedPost[] memory formattedAllowedPosts = new CTAllowedPost[](allowedPosts.length);

            // Iterate through each post to add it to the formatted list.
            for (uint256 i; i < allowedPosts.length; i++) {
                // Set the post being iterated on.
                REVCroptopAllowedPost memory post = allowedPosts[i];

                // Set the formatted post.
                formattedAllowedPosts[i] = CTAllowedPost({
                    hook: address(hook),
                    category: post.category,
                    minimumPrice: post.minimumPrice,
                    minimumTotalSupply: post.minimumTotalSupply,
                    maximumTotalSupply: post.maximumTotalSupply,
                    maximumSplitPercent: post.maximumSplitPercent,
                    allowedAddresses: post.allowedAddresses
                });
            }

            // Set up the allowed posts in the publisher.
            PUBLISHER.configurePostingCriteriaFor({allowedPosts: formattedAllowedPosts});

            // Give the croptop publisher permission to post new ERC-721 tiers on this contract's behalf.
            _setPermission({
                operator: address(PUBLISHER), revnetId: revnetId, permissionId: JBPermissionIds.ADJUST_721_TIERS
            });
        }
    }

    /// @notice Deploy a revnet, or initialize an existing Juicebox project as a revnet.
    /// @dev When initializing an existing project (`shouldDeployNewRevnet == false`):
    /// - The project must be blank — no controller or rulesets. This is enforced by `JBController.launchRulesetsFor`,
    ///   which reverts if rulesets exist, and by `JBDirectory.setControllerOf`, which only allows setting the first
    ///   controller. Without a controller, no tokens or terminals can exist, so the project is guaranteed to be
    ///   uninitialized.
    /// - The project's JBProjects NFT is permanently transferred to this contract. This is irreversible.
    /// @param revnetId The ID of the Juicebox project to initialize as a revnet. Send 0 to deploy a new revnet.
    /// @param shouldDeployNewRevnet Whether to deploy a new revnet or convert an existing Juicebox project into a
    /// revnet.
    /// @param configuration Core revnet configuration. See `REVConfig`.
    /// @param terminalConfigurations The terminals to set up for the revnet. Used for payments and cash outs.
    /// @param suckerDeploymentConfiguration The suckers to set up for the revnet. Suckers facilitate cross-chain
    /// token transfers between peer revnets on different networks.
    /// @return encodedConfigurationHash A hash that represents the revnet's configuration.
    function _deployRevnetFor(
        uint256 revnetId,
        bool shouldDeployNewRevnet,
        REVConfig calldata configuration,
        JBTerminalConfig[] calldata terminalConfigurations,
        REVSuckerDeploymentConfig calldata suckerDeploymentConfiguration
    )
        internal
        returns (bytes32 encodedConfigurationHash)
    {
        // Normalize and encode the configurations.
        JBRulesetConfig[] memory rulesetConfigurations;
        (rulesetConfigurations, encodedConfigurationHash) = _makeRulesetConfigurations({
            revnetId: revnetId, configuration: configuration, terminalConfigurations: terminalConfigurations
        });
        if (shouldDeployNewRevnet) {
            // If we're deploying a new revnet, launch a Juicebox project for it.
            // Sanity check that we deployed the `revnetId` that we expected to deploy.
            // slither-disable-next-line reentrancy-benign,reentrancy-events
            assert(
                CONTROLLER.launchProjectFor({
                    owner: address(this),
                    projectUri: configuration.description.uri,
                    rulesetConfigurations: rulesetConfigurations,
                    terminalConfigurations: terminalConfigurations,
                    memo: ""
                }) == revnetId
            );
        } else {
            // Keep a reference to the Juicebox project's owner.
            address owner = PROJECTS.ownerOf(revnetId);

            // Make sure the caller is the owner of the Juicebox project.
            if (_msgSender() != owner) revert REVDeployer_Unauthorized(revnetId, _msgSender());

            // Initialize the existing Juicebox project as a revnet by
            // transferring the `JBProjects` NFT to this deployer. This is irreversible.
            IERC721(PROJECTS).safeTransferFrom({from: owner, to: address(this), tokenId: revnetId});

            // Launch the revnet rulesets for the pre-existing project.
            // slither-disable-next-line unused-return
            CONTROLLER.launchRulesetsFor({
                projectId: revnetId,
                rulesetConfigurations: rulesetConfigurations,
                terminalConfigurations: terminalConfigurations,
                memo: ""
            });

            // Set the revnet's URI.
            CONTROLLER.setUriOf({projectId: revnetId, uri: configuration.description.uri});
        }

        // Store the cash out delay of the revnet if its stages are already in progress.
        // This prevents cash out liquidity/arbitrage issues for existing revnets which
        // are deploying to a new chain.
        _setCashOutDelayIfNeeded({revnetId: revnetId, firstStageConfig: configuration.stageConfigurations[0]});

        // Deploy the revnet's ERC-20 token.
        // slither-disable-next-line unused-return
        CONTROLLER.deployERC20For({
            projectId: revnetId,
            name: configuration.description.name,
            symbol: configuration.description.ticker,
            salt: keccak256(abi.encode(configuration.description.salt, encodedConfigurationHash, _msgSender()))
        });

        // Now that the ERC-20 exists, initialize buyback pools for each terminal token.
        for (uint256 i; i < terminalConfigurations.length; i++) {
            JBTerminalConfig calldata terminalConfiguration = terminalConfigurations[i];
            for (uint256 j; j < terminalConfiguration.accountingContextsToAccept.length; j++) {
                // slither-disable-next-line calls-loop
                _tryInitializeBuybackPoolFor({
                    revnetId: revnetId,
                    terminalToken: terminalConfiguration.accountingContextsToAccept[j].token,
                    initialIssuance: configuration.stageConfigurations[0].initialIssuance
                });
            }
        }

        // Deploy the suckers (if applicable).
        if (suckerDeploymentConfiguration.salt != bytes32(0)) {
            _deploySuckersFor({
                revnetId: revnetId,
                encodedConfigurationHash: encodedConfigurationHash,
                suckerDeploymentConfiguration: suckerDeploymentConfiguration
            });
        }

        // Store the hashed encoded configuration.
        hashedEncodedConfigurationOf[revnetId] = encodedConfigurationHash;

        emit DeployRevnet({
            revnetId: revnetId,
            configuration: configuration,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: suckerDeploymentConfiguration,
            rulesetConfigurations: rulesetConfigurations,
            encodedConfigurationHash: encodedConfigurationHash,
            caller: _msgSender()
        });
    }

    /// @param encodedConfigurationHash A hash that represents the revnet's configuration.
    /// See `_makeRulesetConfigurations(…)` for encoding details. Clients can read the encoded configuration
    /// from the `DeployRevnet` event emitted by this contract.
    /// @param suckerDeploymentConfiguration The suckers to set up for the revnet.
    function _deploySuckersFor(
        uint256 revnetId,
        bytes32 encodedConfigurationHash,
        REVSuckerDeploymentConfig calldata suckerDeploymentConfiguration
    )
        internal
        returns (address[] memory suckers)
    {
        emit DeploySuckers({
            revnetId: revnetId,
            encodedConfigurationHash: encodedConfigurationHash,
            suckerDeploymentConfiguration: suckerDeploymentConfiguration,
            caller: _msgSender()
        });

        // Deploy the suckers.
        // slither-disable-next-line unused-return
        suckers = SUCKER_REGISTRY.deploySuckersFor({
            projectId: revnetId,
            salt: keccak256(abi.encode(encodedConfigurationHash, suckerDeploymentConfiguration.salt, _msgSender())),
            configurations: suckerDeploymentConfiguration.deployerConfigurations
        });
    }

    /// @notice Convert a revnet's stages into a series of Juicebox project rulesets.
    /// @dev Stage transitions affect outstanding loan health. When a new stage activates, parameters such as
    /// `cashOutTaxRate` and `weight` change, which directly impact the borrowable amount calculated by
    /// `REVLoans._borrowableAmountFrom`. Loans originated under a previous stage's parameters may become
    /// under-collateralized if the new stage has a higher `cashOutTaxRate` (reducing the borrowable amount per unit
    /// of collateral) or lower issuance weight (reducing the surplus-per-token ratio). Borrowers should monitor
    /// upcoming stage transitions and adjust their positions accordingly, as loans that fall below their required
    /// collateralization may become eligible for liquidation.
    /// @dev `cashOutTaxRate` changes at stage boundaries may allow users to cash out just before a rate increase.
    /// This is accepted behavior — the arbitrage window is bounded by the ruleset design, and all stages are
    /// configured immutably at deployment time.
    /// @param revnetId The ID of the revnet to make rulesets for.
    /// @param configuration The configuration containing the revnet's stages.
    /// @param terminalConfigurations The terminals to set up for the revnet. Used for payments and cash outs.
    /// @return rulesetConfigurations A list of ruleset configurations defined by the stages.
    /// @return encodedConfigurationHash A hash that represents the revnet's configuration. Used for sucker
    /// deployment salts.
    function _makeRulesetConfigurations(
        uint256 revnetId,
        REVConfig calldata configuration,
        JBTerminalConfig[] calldata terminalConfigurations
    )
        internal
        returns (JBRulesetConfig[] memory rulesetConfigurations, bytes32 encodedConfigurationHash)
    {
        // If there are no stages, revert.
        if (configuration.stageConfigurations.length == 0) revert REVDeployer_StagesRequired();

        // Initialize the array of rulesets.
        rulesetConfigurations = new JBRulesetConfig[](configuration.stageConfigurations.length);

        // Add the base configuration to the byte-encoded configuration.
        bytes memory encodedConfiguration = abi.encode(
            configuration.baseCurrency,
            configuration.description.name,
            configuration.description.ticker,
            configuration.description.salt
        );

        // Initialize fund access limit groups for the loan contract.
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups =
            _makeLoanFundAccessLimits({terminalConfigurations: terminalConfigurations});

        // Iterate through each stage to set up its ruleset.
        for (uint256 i; i < configuration.stageConfigurations.length; i++) {
            // Set the stage being iterated on.
            REVStageConfig calldata stageConfiguration = configuration.stageConfigurations[i];

            // Make sure the revnet has at least one split if it has a split percent.
            // Otherwise, the split would go to this contract since its the revnet's owner.
            if (stageConfiguration.splitPercent > 0 && stageConfiguration.splits.length == 0) {
                revert REVDeployer_MustHaveSplits();
            }

            // If the stage's start time is not after the previous stage's start time, revert.
            if (i > 0 && stageConfiguration.startsAtOrAfter <= configuration.stageConfigurations[i - 1].startsAtOrAfter)
            {
                revert REVDeployer_StageTimesMustIncrease();
            }

            // Make sure the revnet doesn't prevent cashouts all together.
            if (stageConfiguration.cashOutTaxRate >= JBConstants.MAX_CASH_OUT_TAX_RATE) {
                revert REVDeployer_CashOutsCantBeTurnedOffCompletely(
                    stageConfiguration.cashOutTaxRate, JBConstants.MAX_CASH_OUT_TAX_RATE
                );
            }

            // Set up the ruleset.
            rulesetConfigurations[i] = _makeRulesetConfiguration({
                baseCurrency: configuration.baseCurrency,
                stageConfiguration: stageConfiguration,
                fundAccessLimitGroups: fundAccessLimitGroups
            });

            // Add the stage's properties to the byte-encoded configuration.
            encodedConfiguration = abi.encode(
                encodedConfiguration,
                // If no start time is provided for the first stage, use the current block's timestamp.
                // In the future, revnets deployed on other networks can match this revnet's encoded stage by specifying
                // the
                // same start time.
                (i == 0 && stageConfiguration.startsAtOrAfter == 0)
                    ? block.timestamp
                    : stageConfiguration.startsAtOrAfter,
                stageConfiguration.splitPercent,
                stageConfiguration.initialIssuance,
                stageConfiguration.issuanceCutFrequency,
                stageConfiguration.issuanceCutPercent,
                stageConfiguration.cashOutTaxRate
            );

            // Add each auto-mint to the byte-encoded representation.
            for (uint256 j; j < stageConfiguration.autoIssuances.length; j++) {
                REVAutoIssuance calldata autoIssuance = stageConfiguration.autoIssuances[j];

                // Make sure the beneficiary is not the zero address.
                if (autoIssuance.beneficiary == address(0)) revert REVDeployer_AutoIssuanceBeneficiaryZeroAddress();

                // If there's nothing to auto-mint, continue.
                if (autoIssuance.count == 0) continue;

                encodedConfiguration = abi.encode(
                    encodedConfiguration, autoIssuance.chainId, autoIssuance.beneficiary, autoIssuance.count
                );

                // If the issuance config is for another chain, skip it.
                if (autoIssuance.chainId != block.chainid) continue;

                // slither-disable-next-line reentrancy-events
                emit StoreAutoIssuanceAmount({
                    revnetId: revnetId,
                    stageId: block.timestamp + i,
                    beneficiary: autoIssuance.beneficiary,
                    count: autoIssuance.count,
                    caller: _msgSender()
                });

                // Store the amount of tokens that can be auto-minted on this chain during this stage.
                // The stage ID is `block.timestamp + i`. This matches the ruleset ID that JBRulesets assigns
                // because JBRulesets uses `latestId >= block.timestamp ? latestId + 1 : block.timestamp`
                // (JBRulesets.sol L172), producing the same sequential IDs when all stages are queued in one tx.
                // `autoIssueFor` later calls `getRulesetOf(revnetId, stageId)` — the returned `ruleset.start`
                // is the derived start time (not the queue time), so the timing guard works correctly.
                // slither-disable-next-line reentrancy-benign
                amountToAutoIssue[revnetId][block.timestamp + i][autoIssuance.beneficiary] += autoIssuance.count;
            }
        }

        // Hash the encoded configuration.
        encodedConfigurationHash = keccak256(encodedConfiguration);
    }

    /// @notice Sets the cash out delay if the revnet's stages are already in progress.
    /// @dev This prevents cash out liquidity/arbitrage issues for existing revnets which
    /// are deploying to a new chain.
    /// @param revnetId The ID of the revnet to set the cash out delay for.
    /// @param firstStageConfig The revnet's first stage.
    function _setCashOutDelayIfNeeded(uint256 revnetId, REVStageConfig calldata firstStageConfig) internal {
        // If this is the first revnet being deployed (with a `startsAtOrAfter` of 0),
        // or if the first stage hasn't started yet, we don't need to set a cash out delay.
        if (firstStageConfig.startsAtOrAfter == 0 || firstStageConfig.startsAtOrAfter >= block.timestamp) return;

        // Calculate the timestamp at which the cash out delay ends.
        uint256 cashOutDelay = block.timestamp + CASH_OUT_DELAY;

        // Store the cash out delay.
        cashOutDelayOf[revnetId] = cashOutDelay;

        emit SetCashOutDelay({revnetId: revnetId, cashOutDelay: cashOutDelay, caller: _msgSender()});
    }

    /// @notice Grants a permission to an address (an "operator").
    /// @param operator The address to give the permission to.
    /// @param revnetId The ID of the revnet to scope the permission for.
    /// @param permissionId The ID of the permission to set. See `JBPermissionIds`.
    function _setPermission(address operator, uint256 revnetId, uint8 permissionId) internal {
        uint8[] memory permissionsIds = new uint8[](1);
        permissionsIds[0] = permissionId;

        // Give the operator the permission.
        _setPermissionsFor({
            account: address(this), operator: operator, revnetId: revnetId, permissionIds: permissionsIds
        });
    }

    /// @notice Grants a permission to an address (an "operator").
    /// @param account The account granting the permission.
    /// @param operator The address to give the permission to.
    /// @param revnetId The ID of the revnet to scope the permission for.
    /// @param permissionIds An array of permission IDs to set. See `JBPermissionIds`.
    function _setPermissionsFor(
        address account,
        address operator,
        uint256 revnetId,
        uint8[] memory permissionIds
    )
        internal
    {
        // Set up the permission data.
        JBPermissionsData memory permissionData =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBPermissionsData({operator: operator, projectId: uint64(revnetId), permissionIds: permissionIds});

        // Set the permissions.
        PERMISSIONS.setPermissionsFor({account: account, permissionsData: permissionData});
    }

    /// @notice Give a split operator their permissions.
    /// @dev Only a revnet's current split operator can set a new split operator, by calling `setSplitOperatorOf(…)`.
    /// @param revnetId The ID of the revnet to set the split operator of.
    /// @param operator The new split operator's address.
    function _setSplitOperatorOf(uint256 revnetId, address operator) internal {
        // Get the permission indexes for the split operator.
        uint256[] memory permissionIndexes = _splitOperatorPermissionIndexesOf(revnetId);
        uint8[] memory permissionIds = new uint8[](permissionIndexes.length);

        for (uint256 i; i < permissionIndexes.length; i++) {
            permissionIds[i] = uint8(permissionIndexes[i]);
        }

        _setPermissionsFor({
            account: address(this), operator: operator, revnetId: revnetId, permissionIds: permissionIds
        });
    }
}
