// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Criteria for allowed posts.
/// @custom:member category The category to allow posts for.
/// @custom:member minimumPrice The minimum price a post to the specified category must cost.
/// @custom:member minimumTotalSupply The minimum total supply of NFTs to make available when minting.
/// @custom:member maxTotalSupply The max total supply of NFTs to make available when minting. Leave as 0 for unlimited.
/// @custom:member maximumSplitPercent The maximum split percent (out of JBConstants.SPLITS_TOTAL_PERCENT) a poster can
/// set. 0 means splits are not allowed.
/// @custom:member allowedAddresses The addresses allowed to post on the category through Croptop.
struct REVCroptopAllowedPost {
    uint24 category;
    uint104 minimumPrice;
    uint32 minimumTotalSupply;
    uint32 maximumTotalSupply;
    uint32 maximumSplitPercent;
    address[] allowedAddresses;
}
