// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Interface for the REVOwner contract that handles runtime data hook and cash out hook behavior for revnets.
interface IREVOwner {
    /// @notice The timestamp of when cashouts will become available to a specific revnet's participants.
    /// @param revnetId The ID of the revnet.
    /// @return The cash out delay timestamp.
    function cashOutDelayOf(uint256 revnetId) external view returns (uint256);
}
