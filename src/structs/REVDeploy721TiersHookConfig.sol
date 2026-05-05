// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {REVBaseline721HookConfig} from "./REVBaseline721HookConfig.sol";

/// @custom:member baseline721HookConfiguration The baseline 721 hook config.
/// @custom:member salt The salt to derive the collection's address from.
/// @custom:member preventSplitOperatorAdjustingTiers Whether to prevent the split operator from adding and removing
/// tiers.
/// @custom:member preventSplitOperatorUpdatingMetadata Whether to prevent the split operator from updating the 721's
/// metadata.
/// @custom:member preventSplitOperatorMinting Whether to prevent the split operator from minting 721s from tiers that
/// allow it.
/// @custom:member preventSplitOperatorIncreasingDiscountPercent Whether to prevent the split operator from increasing
/// the discount of a tier.
struct REVDeploy721TiersHookConfig {
    REVBaseline721HookConfig baseline721HookConfiguration;
    bytes32 salt;
    bool preventSplitOperatorAdjustingTiers;
    bool preventSplitOperatorUpdatingMetadata;
    bool preventSplitOperatorMinting;
    bool preventSplitOperatorIncreasingDiscountPercent;
}
