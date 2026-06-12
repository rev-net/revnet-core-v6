// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";

import {IREVDeployer} from "../../src/interfaces/IREVDeployer.sol";
import {IREVLoans} from "../../src/interfaces/IREVLoans.sol";
import {REVOwner} from "../../src/REVOwner.sol";

contract DeployOrderingTest is Test {
    function testSetDeployerRevertsWhenPredictedDeployerHasNoCode() public {
        address predictedDeployer = makeAddr("predicted undeployed REVDeployer");
        assertEq(predictedDeployer.code.length, 0);

        REVOwner owner = new REVOwner({
            buybackHook: IJBBuybackHookRegistry(makeAddr("buyback hook")),
            directory: IJBDirectory(makeAddr("directory")),
            feeRevnetId: 1,
            suckerRegistry: IJBSuckerRegistry(makeAddr("sucker registry")),
            loans: IREVLoans(makeAddr("loans")),
            trustedForwarder: address(0),
            deployerAddress: address(this)
        });

        vm.expectRevert();
        owner.setDeployer(IREVDeployer(predictedDeployer));
    }
}
