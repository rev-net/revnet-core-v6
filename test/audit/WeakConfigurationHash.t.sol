// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TestTerminalEncodingInHash} from "../TestTerminalEncodingInHash.t.sol";

import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {JBSplitGroupIds} from "@bananapus/core-v6/src/libraries/JBSplitGroupIds.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";

import {REVConfig} from "../../src/structs/REVConfig.sol";
import {REVSuckerDeploymentConfig} from "../../src/structs/REVSuckerDeploymentConfig.sol";

contract WeakConfigurationHashTest is TestTerminalEncodingInHash {
    function test_configurationHashExcludesSplitOperatorAuthority() public {
        address operatorA = makeAddr("operatorA");
        address operatorB = makeAddr("operatorB");
        uint256 snapshot = vm.snapshotState();

        REVConfig memory configA = _baseRevConfig("HASH_SPLIT_OPERATOR");
        configA.splitOperator = operatorA;
        uint256 revnetA = _deployPlainRevnet(configA);
        bytes32 hashA = REV_DEPLOYER.hashedEncodedConfigurationOf(revnetA);

        assertTrue(REV_DEPLOYER.isSplitOperatorOf(revnetA, operatorA), "operator A should control revnet A");
        assertFalse(REV_DEPLOYER.isSplitOperatorOf(revnetA, operatorB), "operator B should not control revnet A");

        vm.revertToState(snapshot);

        REVConfig memory configB = _baseRevConfig("HASH_SPLIT_OPERATOR");
        configB.splitOperator = operatorB;
        uint256 revnetB = _deployPlainRevnet(configB);
        bytes32 hashB = REV_DEPLOYER.hashedEncodedConfigurationOf(revnetB);

        assertEq(hashA, hashB, "split operator differences should not affect the configuration hash");
        assertTrue(REV_DEPLOYER.isSplitOperatorOf(revnetB, operatorB), "operator B should control revnet B");
        assertFalse(REV_DEPLOYER.isSplitOperatorOf(revnetB, operatorA), "operator A should not control revnet B");
    }

    function test_configurationHashExcludesReservedSplitRouting() public {
        address splitBeneficiaryA = makeAddr("splitBeneficiaryA");
        address splitBeneficiaryB = makeAddr("splitBeneficiaryB");
        uint256 snapshot = vm.snapshotState();

        REVConfig memory configA = _baseRevConfig("HASH_SPLITS");
        configA.stageConfigurations[0].splitPercent = 5000;
        configA.stageConfigurations[0].splits = _singleReservedSplit(splitBeneficiaryA);
        uint256 revnetA = _deployPlainRevnet(configA);
        bytes32 hashA = REV_DEPLOYER.hashedEncodedConfigurationOf(revnetA);

        (JBRuleset memory rulesetA,) = jbController().currentRulesetOf(revnetA);
        JBSplit[] memory storedSplitsA = jbSplits().splitsOf(revnetA, rulesetA.id, JBSplitGroupIds.RESERVED_TOKENS);

        assertEq(storedSplitsA.length, 1, "setup: revnet A should store one reserved split");
        assertEq(storedSplitsA[0].beneficiary, splitBeneficiaryA, "revnet A should route reserved tokens to A");

        vm.revertToState(snapshot);

        REVConfig memory configB = _baseRevConfig("HASH_SPLITS");
        configB.stageConfigurations[0].splitPercent = 5000;
        configB.stageConfigurations[0].splits = _singleReservedSplit(splitBeneficiaryB);
        uint256 revnetB = _deployPlainRevnet(configB);
        bytes32 hashB = REV_DEPLOYER.hashedEncodedConfigurationOf(revnetB);

        (JBRuleset memory rulesetB,) = jbController().currentRulesetOf(revnetB);
        JBSplit[] memory storedSplitsB = jbSplits().splitsOf(revnetB, rulesetB.id, JBSplitGroupIds.RESERVED_TOKENS);

        assertEq(hashA, hashB, "reserved split routing differences should not affect the configuration hash");
        assertEq(storedSplitsB.length, 1, "setup: revnet B should store one reserved split");
        assertEq(storedSplitsB[0].beneficiary, splitBeneficiaryB, "revnet B should route reserved tokens to B");
    }

    function test_configurationHashIncludesExtraMetadataPolicyBits() public {
        uint256 snapshot = vm.snapshotState();

        REVConfig memory configA = _baseRevConfig("HASH_EXTRA_METADATA");
        configA.stageConfigurations[0].extraMetadata = 0;
        uint256 revnetA = _deployPlainRevnet(configA);
        bytes32 hashA = REV_DEPLOYER.hashedEncodedConfigurationOf(revnetA);

        (, JBRulesetMetadata memory metadataA) = jbController().currentRulesetOf(revnetA);
        assertEq((metadataA.metadata >> 2) & 1, 0, "revnet A should forbid later sucker deployment");

        vm.revertToState(snapshot);

        REVConfig memory configB = _baseRevConfig("HASH_EXTRA_METADATA");
        configB.stageConfigurations[0].extraMetadata = 1 << 2;
        uint256 revnetB = _deployPlainRevnet(configB);
        bytes32 hashB = REV_DEPLOYER.hashedEncodedConfigurationOf(revnetB);

        (, JBRulesetMetadata memory metadataB) = jbController().currentRulesetOf(revnetB);

        assertNotEq(hashA, hashB, "extraMetadata differences should affect the configuration hash");
        assertEq((metadataB.metadata >> 2) & 1, 1, "revnet B should allow later sucker deployment");
    }

    function _deployPlainRevnet(REVConfig memory configuration) internal returns (uint256 revnetId) {
        (revnetId,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: configuration,
            terminalConfigurations: _terminalConfigs(jbMultiTerminal()),
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32(0)
            })
        });
    }

    function _singleReservedSplit(address beneficiary) internal pure returns (JBSplit[] memory splits) {
        splits = new JBSplit[](1);
        splits[0] = JBSplit({
            percent: 1_000_000_000,
            projectId: 0,
            beneficiary: payable(beneficiary),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });
    }
}
