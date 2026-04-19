// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAfterCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterCashOutRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {IREVDeployer} from "./interfaces/IREVDeployer.sol";

/// @notice Handles the runtime data hook and cash out hook behavior for revnets.
/// @dev Separated from `REVDeployer` to stay within the EIP-170 contract size limit.
/// This contract is set as the `dataHook` in each revnet's ruleset metadata.
contract REVOwner is IJBRulesetDataHook, IJBCashOutHook {
    // A library that adds default safety checks to ERC20 functionality.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error REVOwner_AlreadyInitialized();
    error REVOwner_CashOutDelayNotFinished(uint256 cashOutDelay, uint256 blockTimestamp);
    error REVOwner_Unauthorized();

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The cash out fee (as a fraction out of `JBConstants.MAX_FEE`).
    /// @dev Cashout fees are paid to the revnet with the `FEE_REVNET_ID`.
    /// @dev When suckers withdraw funds, they do not pay cash out fees.
    uint256 public constant FEE = 25; // 2.5%

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The buyback hook used as a data hook to route payments through buyback pools.
    IJBBuybackHookRegistry public immutable BUYBACK_HOOK;

    /// @notice The directory of terminals and controllers for Juicebox projects.
    IJBDirectory public immutable DIRECTORY;

    /// @notice The Juicebox project ID of the revnet that receives cash out fees.
    uint256 public immutable FEE_REVNET_ID;

    /// @notice The hidden tokens contract used by all revnets.
    address public immutable HIDDEN_TOKENS;

    /// @notice The loan contract used by all revnets.
    address public immutable LOANS;

    /// @notice Deploys and tracks suckers for revnets.
    IJBSuckerRegistry public immutable SUCKER_REGISTRY;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The timestamp of when cashouts will become available to a specific revnet's participants.
    /// @dev Only applies to existing revnets which are deploying onto a new network.
    /// @custom:param revnetId The ID of the revnet to get the cash out delay for.
    mapping(uint256 revnetId => uint256 cashOutDelay) public cashOutDelayOf;

    /// @notice Each revnet's tiered ERC-721 hook.
    /// @custom:param revnetId The ID of the revnet to get the tiered ERC-721 hook for.
    // slither-disable-next-line uninitialized-state
    mapping(uint256 revnetId => IJB721TiersHook tiered721Hook) public tiered721HookOf;

    /// @notice The deployer that manages revnet state.
    /// @dev Set once via `setDeployer()` using the precomputed canonical REVDeployer address.
    IREVDeployer public DEPLOYER;

    //*********************************************************************//
    // -------------------- private stored properties -------------------- //
    //*********************************************************************//

    /// @notice The account allowed to bind the canonical deployer exactly once.
    address private immutable _DEPLOYER_BINDER;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param buybackHook The buyback hook used to route payments.
    /// @param directory The directory of terminals and controllers.
    /// @param feeRevnetId The Juicebox project ID of the fee revnet.
    /// @param suckerRegistry The sucker registry.
    /// @param loans The loan contract address.
    /// @param hiddenTokens The hidden tokens contract address.
    constructor(
        IJBBuybackHookRegistry buybackHook,
        IJBDirectory directory,
        uint256 feeRevnetId,
        IJBSuckerRegistry suckerRegistry,
        address loans,
        address hiddenTokens
    ) {
        BUYBACK_HOOK = buybackHook;
        DIRECTORY = directory;
        FEE_REVNET_ID = feeRevnetId;
        SUCKER_REGISTRY = suckerRegistry;
        // slither-disable-next-line missing-zero-check
        LOANS = loans;
        // slither-disable-next-line missing-zero-check
        HIDDEN_TOKENS = hiddenTokens;
        _DEPLOYER_BINDER = msg.sender;
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Determine how a cash out from a revnet should be processed.
    /// @dev This function is part of `IJBRulesetDataHook`, and gets called before the revnet processes a cash out.
    /// @dev If a sucker is cashing out, no taxes or fees are imposed.
    /// @dev REVOwner is intentionally not registered as a feeless address. The protocol fee (2.5%) applies on top
    /// of the rev fee — this is by design. The fee hook spec amount sent to `afterCashOutRecordedWith` will have the
    /// protocol fee deducted by the terminal before reaching this contract, so the rev fee is computed on the
    /// post-protocol-fee amount.
    /// @param context Standard Juicebox cash out context. See `JBBeforeCashOutRecordedContext`.
    /// @return cashOutTaxRate The cash out tax rate, which influences the amount of terminal tokens which get cashed
    /// out.
    /// @return cashOutCount The number of revnet tokens that are cashed out.
    /// @return totalSupply The total token supply across all chains (for both proportional reclaim and tax).
    /// @return effectiveSurplusValue The global surplus across all chains for proportional reclaim.
    /// @return hookSpecifications The amount of funds and the data to send to cash out hooks (this contract).
    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        view
        override
        returns (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        // If the cash out is from a sucker, return the full cash out amount without taxes or fees.
        // This relies on the sucker registry to only contain trusted sucker contracts deployed via
        // the registry's own deploySuckersFor flow — external addresses cannot register as suckers.
        if (_isSuckerOf({revnetId: context.projectId, addr: context.holder})) {
            return (0, context.cashOutCount, context.totalSupply, context.surplus.value, hookSpecifications);
        }

        // Keep a reference to the cash out delay of the revnet.
        uint256 cashOutDelay = cashOutDelayOf[context.projectId];

        // Enforce the cash out delay.
        if (cashOutDelay > block.timestamp) {
            revert REVOwner_CashOutDelayNotFinished(cashOutDelay, block.timestamp);
        }

        // Get the terminal that will receive the cash out fee.
        IJBTerminal feeTerminal = DIRECTORY.primaryTerminalOf({projectId: FEE_REVNET_ID, token: context.surplus.token});

        // Compute the cross-chain total supply (local + remote peer chain supplies) for cross-chain-aware bonding
        // curve.
        totalSupply = context.totalSupply;
        effectiveSurplusValue = context.surplus.value;
        if (address(SUCKER_REGISTRY) != address(0)) {
            totalSupply += SUCKER_REGISTRY.remoteTotalSupplyOf(context.projectId);
            effectiveSurplusValue += SUCKER_REGISTRY.remoteSurplusOf({
                projectId: context.projectId,
                decimals: context.surplus.decimals,
                currency: uint256(uint160(context.surplus.token))
            });
        }

        // If there's no cash out tax (100% cash out tax rate), if there's no fee terminal, or if the beneficiary is
        // feeless (e.g. the router terminal routing value between projects), proxy to the buyback hook with our
        // totalSupply and effectiveSurplusValue.
        if (context.cashOutTaxRate == 0 || address(feeTerminal) == address(0) || context.beneficiaryIsFeeless) {
            // slither-disable-next-line unused-return
            (cashOutTaxRate, cashOutCount,,, hookSpecifications) = BUYBACK_HOOK.beforeCashOutRecordedWith(context);
            return (cashOutTaxRate, cashOutCount, totalSupply, effectiveSurplusValue, hookSpecifications);
        }

        // Split the cashed-out tokens into a fee portion and a non-fee portion.
        // The fee is applied to TOKEN COUNT (2.5% of tokens), not to value. The fee revnet receives the bonding-curve
        // reclaim of its 2.5% token share regardless of whether the remaining 97.5% routes through a buyback pool at
        // a better price. This is by design.
        // Micro cash outs (< 40 wei at 2.5% fee) round feeCashOutCount to zero, bypassing the fee.
        // Economically insignificant: the gas cost of the transaction far exceeds the bypassed fee. No fix needed.
        uint256 feeCashOutCount = mulDiv({x: context.cashOutCount, y: FEE, denominator: JBConstants.MAX_FEE});
        uint256 nonFeeCashOutCount = context.cashOutCount - feeCashOutCount;

        // Calculate how much surplus the non-fee tokens can reclaim via the bonding curve.
        // Use effective (cross-chain) surplus; cap at local surplus.
        uint256 postFeeReclaimedAmount = JBCashOuts.cashOutFrom({
            surplus: effectiveSurplusValue,
            cashOutCount: nonFeeCashOutCount,
            totalSupply: totalSupply,
            cashOutTaxRate: context.cashOutTaxRate
        });
        // Cap at local surplus — the bonding curve uses cross-chain effective surplus which can exceed what this
        // chain's terminal actually holds.
        if (postFeeReclaimedAmount > context.surplus.value) postFeeReclaimedAmount = context.surplus.value;

        // Calculate how much the fee tokens reclaim from the remaining surplus after the non-fee reclaim.
        // Use remaining effective surplus; cap at remaining local surplus.
        uint256 feeAmount = JBCashOuts.cashOutFrom({
            surplus: effectiveSurplusValue > postFeeReclaimedAmount
                ? effectiveSurplusValue - postFeeReclaimedAmount
                : 0,
            cashOutCount: feeCashOutCount,
            totalSupply: totalSupply - nonFeeCashOutCount,
            cashOutTaxRate: context.cashOutTaxRate
        });
        // Cap the fee reclaim at remaining local surplus. The bonding curve uses the cross-chain effective surplus,
        // which can exceed what's actually held locally. Without this cap, the terminal would try to send more than
        // it has.
        if (feeAmount > context.surplus.value - postFeeReclaimedAmount) {
            feeAmount = context.surplus.value - postFeeReclaimedAmount;
        }

        // Build a context for the buyback hook using only the non-fee token count.
        JBBeforeCashOutRecordedContext memory buybackHookContext = context;
        buybackHookContext.cashOutCount = nonFeeCashOutCount;

        // Let the buyback hook adjust the cash out parameters and optionally return a hook specification.
        JBCashOutHookSpecification[] memory buybackHookSpecifications;
        (cashOutTaxRate, cashOutCount,,, buybackHookSpecifications) =
            BUYBACK_HOOK.beforeCashOutRecordedWith(buybackHookContext);

        // If the fee rounds down to zero, return the buyback hook's response directly — no fee to process.
        if (feeAmount == 0) {
            return (cashOutTaxRate, cashOutCount, totalSupply, effectiveSurplusValue, buybackHookSpecifications);
        }

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

        return (cashOutTaxRate, cashOutCount, totalSupply, effectiveSurplusValue, hookSpecifications);
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
        // The loans contract, hidden tokens contract, buyback hook (and its delegates), and suckers are allowed to mint
        // the revnet's tokens.
        return addr == LOANS || addr == HIDDEN_TOKENS || addr == address(BUYBACK_HOOK)
            || BUYBACK_HOOK.hasMintPermissionFor({projectId: revnetId, ruleset: ruleset, addr: addr})
            || _isSuckerOf({revnetId: revnetId, addr: addr});
    }

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Processes the fee from a cash out.
    /// @param context Cash out context passed in by the terminal.
    function afterCashOutRecordedWith(JBAfterCashOutRecordedContext calldata context) external payable override {
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
        }) {
            _afterTransferTo({to: address(feeTerminal), token: context.forwardedAmount.token});
        } catch (bytes memory) {
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
            _afterTransferTo({to: msg.sender, token: context.forwardedAmount.token});
        }
    }

    /// @notice Bind the canonical deployer address exactly once.
    /// @dev The deployer address is precomputed and supplied by the account that created this REVOwner instance.
    /// Only that deploy-time binder may call this, which avoids an ambient public initializer where any first caller
    /// could seize the deployer role before the deterministic REVDeployer is actually deployed.
    /// @param deployer The canonical REVDeployer instance that will manage revnet runtime state.
    function setDeployer(IREVDeployer deployer) external {
        // Only the account that deployed this REVOwner may complete the one-time deployer binding.
        if (msg.sender != _DEPLOYER_BINDER) revert REVOwner_Unauthorized();
        // Prevent the deployer binding from being overwritten after initialization.
        if (address(DEPLOYER) != address(0)) revert REVOwner_AlreadyInitialized();
        // Store the canonical REVDeployer that is authorized to manage runtime hook state.
        DEPLOYER = deployer;
    }

    /// @notice Store the cash out delay for a revnet.
    /// @dev Only callable by the deployer.
    /// @param revnetId The ID of the revnet.
    /// @param cashOutDelay The timestamp after which cash outs are allowed.
    function setCashOutDelayOf(uint256 revnetId, uint256 cashOutDelay) external {
        if (msg.sender != address(DEPLOYER)) revert REVOwner_Unauthorized();
        cashOutDelayOf[revnetId] = cashOutDelay;
    }

    /// @notice Store the tiered ERC-721 hook for a revnet.
    /// @dev Only callable by the deployer.
    /// @param revnetId The ID of the revnet.
    /// @param hook The tiered ERC-721 hook.
    function setTiered721HookOf(uint256 revnetId, IJB721TiersHook hook) external {
        if (msg.sender != address(DEPLOYER)) revert REVOwner_Unauthorized();
        tiered721HookOf[revnetId] = hook;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Indicates if this contract adheres to the specified interface.
    /// @dev See `IERC165.supportsInterface`.
    /// @return A flag indicating if the provided interface ID is supported.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IJBRulesetDataHook).interfaceId || interfaceId == type(IJBCashOutHook).interfaceId;
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice A flag indicating whether an address is a revnet's sucker.
    /// @param revnetId The ID of the revnet to check sucker status for.
    /// @param addr The address being checked.
    /// @return isSucker A flag indicating whether the address is one of the revnet's suckers.
    function _isSuckerOf(uint256 revnetId, address addr) internal view returns (bool) {
        return SUCKER_REGISTRY.isSuckerOf({projectId: revnetId, addr: addr});
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

    /// @notice Clears any token allowance granted by `_beforeTransferTo`.
    function _afterTransferTo(address to, address token) internal {
        if (token == JBConstants.NATIVE_TOKEN) return;
        IERC20(token).forceApprove({spender: to, value: 0});
    }
}
