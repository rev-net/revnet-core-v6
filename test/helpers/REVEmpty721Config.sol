// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {JB721InitTiersConfig} from "@bananapus/721-hook-v6/src/structs/JB721InitTiersConfig.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {REVBaseline721HookConfig} from "../../src/structs/REVBaseline721HookConfig.sol";
import {REVDeploy721TiersHookConfig} from "../../src/structs/REVDeploy721TiersHookConfig.sol";
import {REV721TiersHookFlags} from "../../src/structs/REV721TiersHookFlags.sol";
import {REVCroptopAllowedPost} from "../../src/structs/REVCroptopAllowedPost.sol";

/// @notice Helpers for constructing empty 721 hook configs in tests.
library REVEmpty721Config {
    function empty721Config() internal pure returns (REVDeploy721TiersHookConfig memory) {
        return REVDeploy721TiersHookConfig({
            baseline721HookConfiguration: REVBaseline721HookConfig({
                name: "",
                symbol: "",
                baseUri: "",
                tokenUriResolver: IJB721TokenUriResolver(address(0)),
                contractUri: "",
                tiersConfig: JB721InitTiersConfig({
                    tiers: new JB721TierConfig[](0),
                    currency: 0,
                    decimals: 18,
                    prices: IJBPrices(address(0))
                }),
                reserveBeneficiary: address(0),
                flags: REV721TiersHookFlags({
                    noNewTiersWithReserves: false,
                    noNewTiersWithVotes: false,
                    noNewTiersWithOwnerMinting: false,
                    preventOverspending: false
                })
            }),
            salt: bytes32(0),
            splitOperatorCanAdjustTiers: false,
            splitOperatorCanUpdateMetadata: false,
            splitOperatorCanMint: false,
            splitOperatorCanIncreaseDiscountPercent: false
        });
    }

    function emptyAllowedPosts() internal pure returns (REVCroptopAllowedPost[] memory) {
        return new REVCroptopAllowedPost[](0);
    }
}
