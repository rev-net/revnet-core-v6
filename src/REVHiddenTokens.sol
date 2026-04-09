// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";

import {IREVHiddenTokens} from "./interfaces/IREVHiddenTokens.sol";

/// @notice Allows revnet token holders to temporarily hide (burn) tokens, excluding them from totalSupply and
/// increasing cash-out value for remaining holders. Hidden tokens can be revealed (re-minted) at any time.
contract REVHiddenTokens is ERC2771Context, IREVHiddenTokens {
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
    constructor(IJBController controller, address trustedForwarder) ERC2771Context(trustedForwarder) {
        CONTROLLER = controller;
    }

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Hide tokens by burning them and tracking them for later reveal.
    /// @dev The caller must have granted BURN_TOKENS permission to this contract.
    /// @param revnetId The ID of the revnet whose tokens to hide.
    /// @param tokenCount The number of tokens to hide.
    function hideTokensOf(uint256 revnetId, uint256 tokenCount) external override {
        // Increment the caller's hidden balance.
        hiddenBalanceOf[_msgSender()][revnetId] += tokenCount;

        // Increment the revnet's total hidden count.
        totalHiddenOf[revnetId] += tokenCount;

        // Burn the tokens. The caller must have granted BURN_TOKENS permission.
        CONTROLLER.burnTokensOf({holder: _msgSender(), projectId: revnetId, tokenCount: tokenCount, memo: ""});

        emit HideTokens({revnetId: revnetId, tokenCount: tokenCount, caller: _msgSender()});
    }

    /// @notice Reveal previously hidden tokens by re-minting them.
    /// @param revnetId The ID of the revnet whose tokens to reveal.
    /// @param tokenCount The number of tokens to reveal.
    /// @param beneficiary The address that will receive the revealed tokens.
    function revealTokensOf(uint256 revnetId, uint256 tokenCount, address beneficiary) external override {
        uint256 hidden = hiddenBalanceOf[_msgSender()][revnetId];

        // Make sure the caller has enough hidden tokens.
        if (hidden < tokenCount) {
            revert REVHiddenTokens_InsufficientHiddenBalance({hiddenBalance: hidden, requested: tokenCount});
        }

        // Decrement the caller's hidden balance.
        hiddenBalanceOf[_msgSender()][revnetId] = hidden - tokenCount;

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
            caller: _msgSender()
        });
    }
}
