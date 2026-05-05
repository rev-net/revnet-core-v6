// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";

/// @custom:member deployerConfigurations The configuration for bridging tokens to other chains.
/// @custom:member salt The salt to use for deterministic sucker addresses across chains.
struct REVSuckerDeploymentConfig {
    JBSuckerDeployerConfig[] deployerConfigurations;
    bytes32 salt;
}
