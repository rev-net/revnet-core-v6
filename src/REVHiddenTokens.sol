// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBPermissioned} from "@bananapus/core-v6/src/interfaces/IJBPermissioned.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

import {IREVHiddenTokens} from "./interfaces/IREVHiddenTokens.sol";

/// @notice Allows revnet token holders to temporarily hide (burn) tokens, excluding them from totalSupply and
/// increasing cash-out value for remaining holders. Hidden tokens can be revealed (re-minted) at any time.
contract REVHiddenTokens is ERC2771Context, JBPermissioned, IREVHiddenTokens {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error REVHiddenTokens_InsufficientHiddenBalance(uint256 hiddenBalance, uint256 requested);

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The controller that manages revnets using this contract.
    IJBController public immutable override CONTROLLER;

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
    }

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Hide tokens by burning them and tracking them for later reveal.
    /// @dev The holder must have granted BURN_TOKENS permission to this contract.
    /// @param revnetId The ID of the revnet whose tokens to hide.
    /// @param tokenCount The number of tokens to hide.
    /// @param holder The address whose tokens to hide.
    function hideTokensOf(uint256 revnetId, uint256 tokenCount, address holder) external override {
        // Only the holder or a permissioned operator can hide tokens.
        _requirePermissionFrom(holder, revnetId, JBPermissionIds.HIDE_TOKENS);

        // Increment the holder's hidden balance.
        hiddenBalanceOf[holder][revnetId] += tokenCount;

        // Increment the revnet's total hidden count.
        totalHiddenOf[revnetId] += tokenCount;

        // Burn the tokens from the holder. The holder must have granted BURN_TOKENS permission.
        CONTROLLER.burnTokensOf({holder: holder, projectId: revnetId, tokenCount: tokenCount, memo: ""});

        emit HideTokens({revnetId: revnetId, tokenCount: tokenCount, holder: holder, caller: _msgSender()});
    }

    /// @notice Reveal previously hidden tokens by re-minting them.
    /// @param revnetId The ID of the revnet whose tokens to reveal.
    /// @param tokenCount The number of tokens to reveal.
    /// @param beneficiary The address that will receive the revealed tokens.
    /// @param holder The address whose hidden balance to decrement.
    function revealTokensOf(uint256 revnetId, uint256 tokenCount, address beneficiary, address holder) external override {
        // Only the holder or a permissioned operator can reveal tokens.
        _requirePermissionFrom(holder, revnetId, JBPermissionIds.REVEAL_TOKENS);

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
        CONTROLLER.mintTokensOf({
            projectId: revnetId,
            tokenCount: tokenCount,
            beneficiary: beneficiary,
            memo: "",
            useReservedPercent: false
        });

        emit RevealTokens({
            revnetId: revnetId,
            tokenCount: tokenCount,
            beneficiary: beneficiary,
            holder: holder,
            caller: _msgSender()
        });
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
