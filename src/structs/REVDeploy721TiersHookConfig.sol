// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {REVBaseline721HookConfig} from "./REVBaseline721HookConfig.sol";

/// @custom:member baseline721HookConfiguration The baseline config.
/// @custom:member salt The salt to base the collection's address on.
/// @custom:member preventSplitOperatorAdjustingTiers A flag indicating if the revnet's split operator should be
/// prevented from adding tiers and removing tiers that are allowed to be removed.
/// @custom:member preventSplitOperatorUpdatingMetadata A flag indicating if the revnet's split operator should be
/// prevented from updating the 721's metadata.
/// @custom:member preventSplitOperatorMinting A flag indicating if the revnet's split operator should be prevented from
/// minting 721's from tiers that allow it.
/// @custom:member preventSplitOperatorIncreasingDiscountPercent A flag indicating if the revnet's split operator should
/// be prevented from increasing the discount of a tier.
// forge-lint: disable-next-line(pascal-case-struct)
struct REVDeploy721TiersHookConfig {
    REVBaseline721HookConfig baseline721HookConfiguration;
    bytes32 salt;
    bool preventSplitOperatorAdjustingTiers;
    bool preventSplitOperatorUpdatingMetadata;
    bool preventSplitOperatorMinting;
    bool preventSplitOperatorIncreasingDiscountPercent;
}
