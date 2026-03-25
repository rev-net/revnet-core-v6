// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "./ForkTestBase.sol";
import {REVEmpty721Config} from "../helpers/REVEmpty721Config.sol";

/// @notice Fork tests for revnet auto-issuance (per-stage premint) mechanics.
///
/// Verifies that `autoIssueFor()` mints tokens to the beneficiary at the correct time,
/// bypasses the reserved percent, and properly prevents double claims and early claims.
///
/// Run with: FOUNDRY_PROFILE=fork forge test --match-contract TestAutoIssuanceFork -vvv
contract TestAutoIssuanceFork is ForkTestBase {
    // forge-lint: disable-next-line(mixed-case-variable)
    address AUTO_BENEFICIARY = makeAddr("autoBeneficiary");
    uint104 constant AUTO_ISSUE_COUNT = 500e18; // 500 tokens

    /// @notice Deploy a revnet with auto-issuance configured for the first stage.
    /// @param splitPercent The reserved percent (splitPercent) for the stage.
    /// @param startsInFuture If true, the stage starts 1 day in the future; otherwise starts now.
    /// @return revnetId The deployed revnet's project ID.
    /// @return stageId The stage ID (ruleset ID) for the auto-issuance.
    function _deployRevnetWithAutoIssuance(
        uint16 splitPercent,
        bool startsInFuture
    )
        internal
        returns (uint256 revnetId, uint256 stageId)
    {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});

        // Configure auto-issuance for this chain.
        REVAutoIssuance[] memory autoIssuances = new REVAutoIssuance[](1);
        autoIssuances[0] =
            REVAutoIssuance({chainId: uint32(block.chainid), count: AUTO_ISSUE_COUNT, beneficiary: AUTO_BENEFICIARY});

        REVStageConfig[] memory stages = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        uint48 startTime = startsInFuture ? uint48(block.timestamp + 1 days) : uint48(block.timestamp);

        stages[0] = REVStageConfig({
            startsAtOrAfter: uint40(startTime),
            autoIssuances: autoIssuances,
            splitPercent: splitPercent,
            splits: splits,
            initialIssuance: INITIAL_ISSUANCE,
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 5000,
            extraMetadata: 0
        });

        REVConfig memory cfg = REVConfig({
            description: REVDescription("AutoIssue Test", "AUTO", "ipfs://auto", "AUTO_SALT"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });

        REVSuckerDeploymentConfig memory sdc = REVSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("AUTO_TEST"))
        });

        // The stageId is block.timestamp + 0 (first stage index is 0).
        stageId = block.timestamp;

        (revnetId,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: cfg,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: sdc,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    function setUp() public override {
        super.setUp();
        _deployFeeProject(5000);
    }

    /// @notice Calling autoIssueFor before the stage starts should revert with REVDeployer_StageNotStarted.
    function testFork_AutoIssueBeforeStageReverts() public {
        (uint256 revnetId, uint256 stageId) = _deployRevnetWithAutoIssuance({splitPercent: 0, startsInFuture: true});

        // Stage starts in the future, so autoIssueFor should revert.
        vm.expectRevert(abi.encodeWithSelector(REVDeployer.REVDeployer_StageNotStarted.selector, stageId));
        REV_DEPLOYER.autoIssueFor(revnetId, stageId, AUTO_BENEFICIARY);
    }

    /// @notice After the stage starts, autoIssueFor mints the exact configured count to the beneficiary.
    function testFork_AutoIssueAfterStageStart() public {
        (uint256 revnetId, uint256 stageId) = _deployRevnetWithAutoIssuance({splitPercent: 0, startsInFuture: false});

        // Verify beneficiary has no tokens initially.
        uint256 balanceBefore = jbTokens().totalBalanceOf(AUTO_BENEFICIARY, revnetId);
        assertEq(balanceBefore, 0, "beneficiary should have no tokens before auto-issue");

        // Auto-issue tokens.
        REV_DEPLOYER.autoIssueFor(revnetId, stageId, AUTO_BENEFICIARY);

        // Verify beneficiary received exactly AUTO_ISSUE_COUNT tokens.
        uint256 balanceAfter = jbTokens().totalBalanceOf(AUTO_BENEFICIARY, revnetId);
        assertEq(balanceAfter, AUTO_ISSUE_COUNT, "beneficiary should receive exactly the configured token count");
    }

    /// @notice A second call to autoIssueFor for the same beneficiary/stage reverts with NothingToAutoIssue.
    function testFork_AutoIssueDoubleClaimReverts() public {
        (uint256 revnetId, uint256 stageId) = _deployRevnetWithAutoIssuance({splitPercent: 0, startsInFuture: false});

        // First claim succeeds.
        REV_DEPLOYER.autoIssueFor(revnetId, stageId, AUTO_BENEFICIARY);

        // Second claim should revert — amount was reset to 0.
        vm.expectRevert(REVDeployer.REVDeployer_NothingToAutoIssue.selector);
        REV_DEPLOYER.autoIssueFor(revnetId, stageId, AUTO_BENEFICIARY);
    }

    /// @notice Auto-issued tokens bypass the reserved percent — 100% goes to the beneficiary.
    function testFork_AutoIssueBypassesReservedPercent() public {
        // Deploy with 50% splitPercent (reserved percent).
        (uint256 revnetId, uint256 stageId) = _deployRevnetWithAutoIssuance({splitPercent: 5000, startsInFuture: false});

        // Auto-issue tokens.
        REV_DEPLOYER.autoIssueFor(revnetId, stageId, AUTO_BENEFICIARY);

        // The beneficiary should receive the FULL count, not reduced by reserved percent.
        uint256 balance = jbTokens().totalBalanceOf(AUTO_BENEFICIARY, revnetId);
        assertEq(
            balance, AUTO_ISSUE_COUNT, "auto-issued tokens should bypass reserved percent - full amount to beneficiary"
        );

        // Verify no pending reserved tokens were accumulated from the auto-issue.
        // The mintTokensOf call uses useReservedPercent: false, so pendingReservedTokenBalanceOf should be 0.
        uint256 pending = jbController().pendingReservedTokenBalanceOf(revnetId);
        assertEq(pending, 0, "no reserved tokens should be pending from auto-issue");
    }
}
