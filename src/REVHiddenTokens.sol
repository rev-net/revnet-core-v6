// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBPermissioned} from "@bananapus/core-v6/src/interfaces/IJBPermissioned.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

import {IREVHiddenTokens} from "./interfaces/IREVHiddenTokens.sol";

/// @notice Allows authorized operators to hide (burn) revnet tokens on behalf of holders, excluding them from
/// governance weight. Hidden tokens remain counted in totalSupply for cash-out/borrow valuations (via
/// `totalSupplyIncludingHiddenOf`) so hiding has NO economic benefit — it only reduces governance power.
/// Hidden tokens can be revealed (re-minted) at any time.
contract REVHiddenTokens is ERC2771Context, JBPermissioned, IREVHiddenTokens {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error REVHiddenTokens_InsufficientHiddenBalance(uint256 hiddenBalance, uint256 requested);
    error REVHiddenTokens_InvalidBeneficiary(address beneficiary, address holder);
    error REVHiddenTokens_Unauthorized(uint256 revnetId, address caller);

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The controller that manages revnets using this contract.
    IJBController public immutable override CONTROLLER;

    /// @notice The projects contract used to resolve revnet owners.
    IJBProjects public immutable PROJECTS;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The number of tokens a holder has hidden for a given revnet.
    /// @custom:param holder The address of the token holder.
    /// @custom:param revnetId The ID of the revnet.
    mapping(address holder => mapping(uint256 revnetId => uint256 count)) public override hiddenBalanceOf;

    /// @notice The total number of hidden tokens for a revnet.
    /// @custom:param revnetId The ID of the revnet.
    mapping(uint256 revnetId => uint256 count) public override totalHiddenOf;

    /// @notice Whether a delegate is allowed to hide and reveal a holder's tokens.
    /// @custom:param holder The holder whose tokens are being managed.
    /// @custom:param revnetId The ID of the revnet.
    /// @custom:param delegate The delegate address.
    mapping(address holder => mapping(uint256 revnetId => mapping(address delegate => bool isAllowed)))
        public
        override tokenHidingIsAllowedFor;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param controller The controller that manages revnets.
    /// @param trustedForwarder The trusted forwarder for ERC-2771 meta-transactions.
    constructor(
        IJBController controller,
        address trustedForwarder
    )
        ERC2771Context(trustedForwarder)
        JBPermissioned(IJBPermissioned(address(controller)).PERMISSIONS())
    {
        CONTROLLER = controller;
        PROJECTS = controller.PROJECTS();
    }

    //*********************************************************************//
    // ----------------------- public views ------------------------------ //
    //*********************************************************************//

    /// @notice The total token supply including hidden tokens for a revnet.
    /// @dev Use this for cash-out and borrow valuation calculations instead of raw totalSupply.
    /// Hidden tokens are added back so that hiding has no economic benefit — only governance effect.
    /// @param revnetId The ID of the revnet.
    /// @return supply The total supply including both circulating and hidden tokens.
    function totalSupplyIncludingHiddenOf(uint256 revnetId) public view override returns (uint256 supply) {
        supply = CONTROLLER.totalTokenSupplyWithReservedTokensOf(revnetId) + totalHiddenOf[revnetId];
    }

    /// @notice Hide tokens by burning them and tracking them for later reveal.
    /// @dev Callers with `HIDE_TOKENS` permission can hide their own tokens and can explicitly allow delegates
    /// to hide tokens on their behalf.
    /// @dev The holder must have granted BURN_TOKENS permission to this contract.
    /// @param revnetId The ID of the revnet whose tokens to hide.
    /// @param tokenCount The number of tokens to hide.
    /// @param holder The address whose tokens to hide.
    function hideTokensOf(uint256 revnetId, uint256 tokenCount, address holder) external override {
        address caller = _msgSender();
        _requireCanManageHiddenTokensOf({revnetId: revnetId, holder: holder, caller: caller});

        // Increment the holder's hidden balance.
        hiddenBalanceOf[holder][revnetId] += tokenCount;

        // Increment the revnet's total hidden count.
        totalHiddenOf[revnetId] += tokenCount;

        // Burn the tokens from the holder. The holder must have granted BURN_TOKENS permission.
        // slither-disable-next-line reentrancy-events
        CONTROLLER.burnTokensOf({holder: holder, projectId: revnetId, tokenCount: tokenCount, memo: ""});

        emit HideTokens({revnetId: revnetId, tokenCount: tokenCount, holder: holder, caller: _msgSender()});
    }

    /// @notice Reveal previously hidden tokens by re-minting them.
    /// @dev Callers with `HIDE_TOKENS` permission can reveal their own tokens and can explicitly allow delegates
    /// to reveal tokens on their behalf. Revealed tokens always return to the holder.
    /// @param revnetId The ID of the revnet whose tokens to reveal.
    /// @param tokenCount The number of tokens to reveal.
    /// @param beneficiary The address that will receive the revealed tokens.
    /// @param holder The address whose hidden balance to decrement.
    function revealTokensOf(
        uint256 revnetId,
        uint256 tokenCount,
        address beneficiary,
        address holder
    )
        external
        override
    {
        address caller = _msgSender();
        _requireCanManageHiddenTokensOf({revnetId: revnetId, holder: holder, caller: caller});
        if (beneficiary != holder) revert REVHiddenTokens_InvalidBeneficiary(beneficiary, holder);

        uint256 hidden = hiddenBalanceOf[holder][revnetId];

        // Make sure the holder has enough hidden tokens.
        if (hidden < tokenCount) {
            revert REVHiddenTokens_InsufficientHiddenBalance({hiddenBalance: hidden, requested: tokenCount});
        }

        // Decrement the holder's hidden balance.
        hiddenBalanceOf[holder][revnetId] = hidden - tokenCount;

        // Decrement the revnet's total hidden count.
        totalHiddenOf[revnetId] -= tokenCount;

        // Mint the tokens to the beneficiary without applying the reserved percent.
        // slither-disable-next-line unused-return,reentrancy-events
        CONTROLLER.mintTokensOf({
            projectId: revnetId, tokenCount: tokenCount, beneficiary: beneficiary, memo: "", useReservedPercent: false
        });

        emit RevealTokens({
            revnetId: revnetId, tokenCount: tokenCount, beneficiary: beneficiary, holder: holder, caller: _msgSender()
        });
    }

    /// @notice Allow or disallow a delegate to hide and reveal the caller's tokens.
    /// @dev The caller must have `HIDE_TOKENS` permission for the revnet.
    /// @param revnetId The ID of the revnet.
    /// @param delegate The delegate to update.
    /// @param isAllowed Whether the delegate should be allowed.
    function setTokenHidingAllowanceOf(uint256 revnetId, address delegate, bool isAllowed) external override {
        address caller = _msgSender();
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(revnetId), projectId: revnetId, permissionId: JBPermissionIds.HIDE_TOKENS
        });

        tokenHidingIsAllowedFor[caller][revnetId][delegate] = isAllowed;

        emit SetTokenHidingAllowance({revnetId: revnetId, holder: caller, delegate: delegate, isAllowed: isAllowed});
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice Require the caller to be allowed to manage hidden tokens for the specified holder.
    /// @param revnetId The ID of the revnet.
    /// @param holder The holder whose tokens are being managed.
    /// @param caller The caller attempting to manage the holder's hidden tokens.
    function _requireCanManageHiddenTokensOf(uint256 revnetId, address holder, address caller) internal view {
        if (caller == holder) {
            _requirePermissionFrom({
                account: PROJECTS.ownerOf(revnetId), projectId: revnetId, permissionId: JBPermissionIds.HIDE_TOKENS
            });
            return;
        }

        if (!tokenHidingIsAllowedFor[holder][revnetId][caller]) {
            revert REVHiddenTokens_Unauthorized(revnetId, caller);
        }
    }

    //*********************************************************************//
    // ------------------------ internal overrides ----------------------- //
    //*********************************************************************//

    /// @dev Resolve the `_msgSender` conflict between `ERC2771Context` and `Context` (from `JBPermissioned`).
    /// Prefer the ERC2771 version.
    function _msgSender() internal view override(ERC2771Context, Context) returns (address) {
        return ERC2771Context._msgSender();
    }

    /// @dev Resolve the `_msgData` conflict between `ERC2771Context` and `Context` (from `JBPermissioned`).
    /// Prefer the ERC2771 version.
    function _msgData() internal view override(ERC2771Context, Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @dev Resolve the `_contextSuffixLength` conflict between `ERC2771Context` and `Context`.
    function _contextSuffixLength() internal view override(ERC2771Context, Context) returns (uint256) {
        return ERC2771Context._contextSuffixLength();
    }
}
