// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal mock that returns zeros for all cross-chain queries.
contract MockSuckerRegistry {
    function isSuckerOf(uint256, address) external pure returns (bool) {
        return false;
    }

    function remoteTotalSupplyOf(uint256) external pure returns (uint256) {
        return 0;
    }

    function remoteSurplusOf(uint256, uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}
