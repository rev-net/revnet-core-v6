// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @custom:member noNewTiersWithReserves A flag indicating if new tiers with non-zero reserve frequency are forbidden.
/// @custom:member noNewTiersWithVotes A flag indicating if new tiers with voting units are forbidden.
/// @custom:member noNewTiersWithOwnerMinting A flag indicating if new tiers with owner minting are forbidden.
/// @custom:member preventOverspending A flag indicating if payments exceeding the price of minted NFTs should be
/// prevented.
struct REV721TiersHookFlags {
    bool noNewTiersWithReserves;
    bool noNewTiersWithVotes;
    bool noNewTiersWithOwnerMinting;
    bool preventOverspending;
}
