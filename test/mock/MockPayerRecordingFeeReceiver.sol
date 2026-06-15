// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBPayerTracker} from "@bananapus/core-v6/src/interfaces/IJBPayerTracker.sol";

/// @notice A creation fee receiver that records the original payer advertised by its `pay`-tracking sender.
/// @dev Stands in for a `pay`-routing fee receiver: when `JBProjects` forwards the creation fee, it queries this
/// contract's caller (`JBProjects`, itself an `IJBPayerTracker`) for the resolved `originalPayer` and credits that
/// account instead of the forwarding deployer. Tests assert `recordedPayer` matches the end user who called
/// `REVDeployer.deployFor`.
contract MockPayerRecordingFeeReceiver {
    /// @notice The original payer advertised by the fee sender during the most recent fee transfer.
    address public recordedPayer;

    /// @notice Records the original payer the fee sender advertises, then accepts the forwarded creation fee.
    receive() external payable {
        recordedPayer = IJBPayerTracker(msg.sender).originalPayer();
    }
}
