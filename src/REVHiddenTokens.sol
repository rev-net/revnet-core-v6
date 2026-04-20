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
/// governance weight. Hidden tokens are burned from circulating supply, so they also stop contributing to
/// cash-out and borrow valuations until revealed again.
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

    /// @notice Whether a holder is allowed to hide their own tokens.
    /// @custom:param holder The holder whose tokens are being managed.
    /// @custom:param revnetId The ID of the revnet.
    mapping(address holder => mapping(uint256 revnetId => bool isAllowed)) public override tokenHidingIsAllowedFor;

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

    /// @notice Hide tokens by burning them and tracking them for later reveal.
    /// @dev An allowlisted holder can hide their own tokens. The project owner and operators with
    /// `HIDE_TOKENS` can also hide tokens for any holder.
    /// @dev The holder must have granted BURN_TOKENS permission to this contract.
    /// @param revnetId The ID of the revnet whose tokens to hide.
    /// @param tokenCount The number of tokens to hide.
    /// @param holder The address whose tokens to hide.
    function hideTokensOf(uint256 revnetId, uint256 tokenCount, address holder) external override {
        address caller = _msgSender();
        bool isHolderHidingOwnTokens = caller == holder && tokenHidingIsAllowedFor[holder][revnetId];
        bool isPermissionedOperator =
            _hasPermissionFrom(caller, PROJECTS.ownerOf(revnetId), revnetId, JBPermissionIds.HIDE_TOKENS);

        if (!isHolderHidingOwnTokens && !isPermissionedOperator) {
            revert REVHiddenTokens_Unauthorized(revnetId, caller);
        }

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
    /// @dev Any holder can reveal their own hidden tokens without special permissions.
    /// Revealed tokens always return to the holder.
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
        if (caller != holder) revert REVHiddenTokens_Unauthorized(revnetId, caller);
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

    /// @notice Allow or disallow a holder to hide their own tokens.
    /// @dev The caller must have `HIDE_TOKENS` permission for the revnet.
    /// @param revnetId The ID of the revnet.
    /// @param holder The holder to update.
    /// @param isAllowed Whether the holder should be allowed.
    function setTokenHidingAllowedFor(uint256 revnetId, address holder, bool isAllowed) external override {
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(revnetId), projectId: revnetId, permissionId: JBPermissionIds.HIDE_TOKENS
        });

        tokenHidingIsAllowedFor[holder][revnetId] = isAllowed;

        emit SetTokenHidingAllowed({revnetId: revnetId, holder: holder, isAllowed: isAllowed});
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
