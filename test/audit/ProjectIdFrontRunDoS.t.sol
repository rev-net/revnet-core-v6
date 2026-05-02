// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

contract ProjectIdFrontRunDoSTest is Test {
    function test_vulnerableCountBasedRevnetLaunchCanBeFrontRun() public {
        MockProjects projects = new MockProjects(17, 19);
        MockController controller = new MockController(19);
        MockHookDeployer hookDeployer = new MockHookDeployer();
        VulnerableREVDeployerHarness harness = new VulnerableREVDeployerHarness(projects, controller, hookDeployer);

        vm.expectRevert();
        harness.deployFor(0);
    }

    function test_reservedRevnetIdCannotBeInvalidatedByEarlierCreations() public {
        MockProjects projects = new MockProjects(17, 19);
        MockController controller = new MockController(19);
        MockHookDeployer hookDeployer = new MockHookDeployer();
        FixedREVDeployerHarness harness = new FixedREVDeployerHarness(projects, controller, hookDeployer);

        (uint256 revnetId,) = harness.deployFor(0);

        assertEq(revnetId, 19);
        assertEq(projects.lastOwner(), address(harness));
        assertEq(controller.lastLaunchedProjectId(), 19);
        assertEq(hookDeployer.lastHookProjectId(), 19);
    }
}

contract VulnerableREVDeployerHarness {
    MockProjects internal immutable PROJECTS;
    MockController internal immutable CONTROLLER;
    MockHookDeployer internal immutable HOOK_DEPLOYER;

    constructor(MockProjects projects, MockController controller, MockHookDeployer hookDeployer) {
        PROJECTS = projects;
        CONTROLLER = controller;
        HOOK_DEPLOYER = hookDeployer;
    }

    function deployFor(uint256 revnetId) external returns (uint256, uint256) {
        bool shouldDeployNewRevnet = revnetId == 0;
        if (shouldDeployNewRevnet) revnetId = PROJECTS.count() + 1;

        if (shouldDeployNewRevnet) {
            assert(CONTROLLER.launchProjectFor() == revnetId);
        }

        HOOK_DEPLOYER.deployHookFor(revnetId);
        return (revnetId, revnetId);
    }
}

contract FixedREVDeployerHarness {
    MockProjects internal immutable PROJECTS;
    MockController internal immutable CONTROLLER;
    MockHookDeployer internal immutable HOOK_DEPLOYER;

    constructor(MockProjects projects, MockController controller, MockHookDeployer hookDeployer) {
        PROJECTS = projects;
        CONTROLLER = controller;
        HOOK_DEPLOYER = hookDeployer;
    }

    function deployFor(uint256 revnetId) external returns (uint256, uint256) {
        bool shouldDeployNewRevnet = revnetId == 0;
        if (shouldDeployNewRevnet) revnetId = PROJECTS.createFor(address(this));

        if (shouldDeployNewRevnet) {
            CONTROLLER.launchRulesetsFor(revnetId);
        }

        HOOK_DEPLOYER.deployHookFor(revnetId);
        return (revnetId, revnetId);
    }
}

contract MockProjects {
    uint256 internal immutable _count;
    uint256 internal immutable _reservedId;

    address public lastOwner;

    constructor(uint256 count_, uint256 reservedId_) {
        _count = count_;
        _reservedId = reservedId_;
    }

    function count() external view returns (uint256) {
        return _count;
    }

    function createFor(address owner) external returns (uint256) {
        lastOwner = owner;
        return _reservedId;
    }
}

contract MockController {
    uint256 internal immutable _launchedId;

    uint256 public lastLaunchedProjectId;

    constructor(uint256 launchedId_) {
        _launchedId = launchedId_;
    }

    function launchProjectFor() external view returns (uint256) {
        return _launchedId;
    }

    function launchRulesetsFor(uint256 projectId) external {
        require(projectId == _launchedId, "BAD_PROJECT_ID");
        lastLaunchedProjectId = projectId;
    }
}

contract MockHookDeployer {
    uint256 public lastHookProjectId;

    function deployHookFor(uint256 projectId) external {
        lastHookProjectId = projectId;
    }
}
