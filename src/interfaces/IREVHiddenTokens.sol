// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";

/// @notice Manages hiding (burning) and revealing (re-minting) revnet tokens to exclude them from totalSupply.
interface IREVHiddenTokens {
    /// @notice Emitted when tokens are hidden (burned and tracked for later reveal).
    /// @param revnetId The ID of the revnet whose tokens are hidden.
    /// @param tokenCount The number of tokens hidden.
    /// @param holder The address whose tokens are hidden.
    /// @param caller The address that hid the tokens.
    event HideTokens(uint256 indexed revnetId, uint256 tokenCount, address holder, address caller);

    /// @notice Emitted when previously hidden tokens are revealed (re-minted).
    /// @param revnetId The ID of the revnet whose tokens are revealed.
    /// @param tokenCount The number of tokens revealed.
    /// @param beneficiary The address receiving the revealed tokens.
    /// @param holder The address whose hidden balance is decremented.
    /// @param caller The address that revealed the tokens.
    event RevealTokens(
        uint256 indexed revnetId, uint256 tokenCount, address beneficiary, address holder, address caller
    );

    /// @notice The controller that manages revnets using this contract.
    /// @return The controller contract.
    function CONTROLLER() external view returns (IJBController);

    /// @notice The number of tokens a holder has hidden for a given revnet.
    /// @param holder The address of the token holder.
    /// @param revnetId The ID of the revnet.
    /// @return The number of hidden tokens.
    function hiddenBalanceOf(address holder, uint256 revnetId) external view returns (uint256);

    /// @notice The total number of hidden tokens for a revnet.
    /// @param revnetId The ID of the revnet.
    /// @return The total hidden token count.
    function totalHiddenOf(uint256 revnetId) external view returns (uint256);

    /// @notice Hide tokens by burning them and tracking them for later reveal.
    /// @dev The holder must have granted BURN_TOKENS permission to this contract.
    /// @param revnetId The ID of the revnet whose tokens to hide.
    /// @param tokenCount The number of tokens to hide.
    /// @param holder The address whose tokens to hide.
    function hideTokensOf(uint256 revnetId, uint256 tokenCount, address holder) external;

    /// @notice Reveal previously hidden tokens by re-minting them.
    /// @param revnetId The ID of the revnet whose tokens to reveal.
    /// @param tokenCount The number of tokens to reveal.
    /// @param beneficiary The address that will receive the revealed tokens.
    /// @param holder The address whose hidden balance to decrement.
    function revealTokensOf(uint256 revnetId, uint256 tokenCount, address beneficiary, address holder) external;
}
