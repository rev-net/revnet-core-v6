// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {REVDescription} from "./REVDescription.sol";
import {REVStageConfig} from "./REVStageConfig.sol";

/// @custom:member description The description of the revnet.
/// @custom:member baseCurrency The currency that the issuance is based on.
/// @custom:member splitOperator The address that will receive the token premint and initial production split,
/// and who is allowed to change who the operator is. Only the operator can replace itself after deployment.
/// @custom:member stageConfigurations The periods of changing constraints.
// forge-lint: disable-next-line(pascal-case-struct)
struct REVConfig {
    REVDescription description;
    uint32 baseCurrency;
    address splitOperator;
    REVStageConfig[] stageConfigurations;
}
