// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBPayoutTerminal} from "@bananapus/core-v6/src/interfaces/IJBPayoutTerminal.sol";

/// @custom:member token The token to loan.
/// @custom:member terminal The terminal to loan from.
struct REVLoanSource {
    address token;
    IJBPayoutTerminal terminal;
}
