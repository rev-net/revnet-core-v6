// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IREVDeployer} from "./IREVDeployer.sol";

/// @notice Interface for the REVOwner contract that handles runtime data hook and cash out hook behavior for revnets.
interface IREVOwner {
    /// @notice The hidden tokens contract used by the revnet owner hook.
    /// @return The hidden tokens contract address.
    function HIDDEN_TOKENS() external view returns (address);

    /// @notice The timestamp of when cashouts will become available to a specific revnet's participants.
    /// @param revnetId The ID of the revnet.
    /// @return The cash out delay timestamp.
    function cashOutDelayOf(uint256 revnetId) external view returns (uint256);

    /// @notice Bind the canonical deployer exactly once.
    /// @param deployer The revnet deployer instance.
    function setDeployer(IREVDeployer deployer) external;
}
