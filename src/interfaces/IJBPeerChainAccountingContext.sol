// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Optional project-specific accounting to add to peer-chain sucker snapshots.
interface IJBPeerChainAccountingContext {
    function peerChainAccountingContextOf(
        uint256 projectId,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        returns (uint256 supply, uint256 surplus);
}
