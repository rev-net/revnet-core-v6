// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";

/// @notice Minimal placeholder used as the router-terminal slot in revnet test setUps.
/// @dev The directory only does an address-equality duplicate check on terminals at registration; the controller
/// calls `addAccountingContextsFor` on every registered terminal, and the terminal store iterates every project
/// terminal during surplus aggregation. This stub only implements those two selectors so future tests fail loudly if
/// they accidentally rely on a broader terminal surface. The slot is registered with empty accounting contexts, so it
/// never actually holds or routes funds.
contract MockEmptyTerminal {
    /// @notice Thrown when a test calls a selector this placeholder is not meant to satisfy.
    /// @param selector The unexpected selector.
    error MockEmptyTerminal_UnexpectedCall(bytes4 selector);

    /// @notice Accepts the controller's setup call for the placeholder terminal.
    /// @dev The router-terminal slot is intentionally registered with no accounting contexts in these tests.
    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external {}

    /// @notice Returns zero surplus for the placeholder terminal during aggregate surplus reads.
    /// @dev Any nonzero value would make this fake terminal participate in the economic assertions.
    function currentSurplusOf(uint256, address[] calldata, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    /// @notice Reverts for every selector outside the two setup/read selectors above.
    fallback() external payable {
        revert MockEmptyTerminal_UnexpectedCall({selector: msg.sig});
    }

    receive() external payable {}
}
