// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal placeholder used as the router-terminal slot in revnet test setUps.
/// @dev The directory only does an address-equality duplicate check on terminals at registration; the controller
/// calls `addAccountingContextsFor` on every registered terminal, and the terminal store iterates every project
/// terminal during surplus aggregation. This stub silently accepts any call and returns a single zero word so
/// downstream decoders that expect a `uint256` (e.g. `currentSurplusOf`) get a safe zero. The slot is registered
/// with empty accounting contexts, so it never actually holds or routes funds.
contract MockEmptyTerminal {
    fallback() external payable {
        assembly {
            mstore(0, 0)
            return(0, 32)
        }
    }

    receive() external payable {}
}
