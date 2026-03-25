// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// forge-lint: disable-next-line(unaliased-plain-import)
import "./ForkTestBase.sol";
import {REVEmpty721Config} from "../helpers/REVEmpty721Config.sol";

/// @notice Fork tests for revnet issuance decay (weight cut) mechanics.
///
/// Verifies that `issuanceCutFrequency` maps to `JBRulesetConfig.duration` and
/// `issuanceCutPercent` maps to `weightCutPercent`, producing geometric token decay.
///
/// Run with: FOUNDRY_PROFILE=fork forge test --match-contract TestIssuanceDecayFork -vvv
contract TestIssuanceDecayFork is ForkTestBase {
    /// @notice Deploy a revnet with custom issuance cut parameters.
    /// @param issuanceCutFrequency The duration in seconds between decay steps (maps to ruleset duration).
    /// @param issuanceCutPercent The percentage to cut issuance each cycle (out of 1_000_000_000).
    /// @param cashOutTaxRate The cash out tax rate.
    /// @return revnetId The deployed revnet's project ID.
    function _deployRevnetWithDecay(
        uint32 issuanceCutFrequency,
        uint32 issuanceCutPercent,
        uint16 cashOutTaxRate
    )
        internal
        returns (uint256 revnetId)
    {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});

        REVStageConfig[] memory stages = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;
        stages[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: INITIAL_ISSUANCE,
            issuanceCutFrequency: issuanceCutFrequency,
            issuanceCutPercent: issuanceCutPercent,
            cashOutTaxRate: cashOutTaxRate,
            extraMetadata: 0
        });

        REVConfig memory cfg = REVConfig({
            description: REVDescription("Decay Test", "DECAY", "ipfs://decay", "DECAY_SALT"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });

        REVSuckerDeploymentConfig memory sdc = REVSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("DECAY_TEST"))
        });

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

    /// @notice After one cycle with 10% issuance cut, paying 1 ETH yields ~90% of the day-0 tokens.
    function testFork_IssuanceDecaysSingleCycle() public {
        // 10% cut per cycle, 1-day cycles.
        uint256 revnetId = _deployRevnetWithDecay({
            issuanceCutFrequency: 86_400, // 1 day
            issuanceCutPercent: 100_000_000, // 10% of 1e9
            cashOutTaxRate: 5000
        });

        // Set up pool so buyback hook doesn't interfere (mint path wins at 1:1).
        _setupPool(revnetId, 10_000 ether);

        // Day 0: pay 1 ETH.
        uint256 t0 = _payRevnet(revnetId, PAYER, 1 ether);
        assertGt(t0, 0, "day 0 tokens should be > 0");

        // Warp 1 day (one full cycle).
        vm.warp(block.timestamp + 86_400);

        // Day 1: pay 1 ETH again.
        address payer2 = makeAddr("payer2");
        vm.deal(payer2, 10 ether);
        uint256 t1 = _payRevnet(revnetId, payer2, 1 ether);

        // T1 should be approximately T0 * 0.9 (within 1% tolerance for rounding).
        uint256 expected = (t0 * 9) / 10;
        uint256 tolerance = expected / 100; // 1%
        assertGt(t1, expected - tolerance, "T1 should be >= T0*0.9 - 1%");
        assertLt(t1, expected + tolerance, "T1 should be <= T0*0.9 + 1%");
    }

    /// @notice After two cycles with 10% issuance cut, paying 1 ETH yields ~81% of the day-0 tokens.
    function testFork_IssuanceDecaysMultipleCycles() public {
        // 10% cut per cycle, 1-day cycles.
        uint256 revnetId = _deployRevnetWithDecay({
            issuanceCutFrequency: 86_400, issuanceCutPercent: 100_000_000, cashOutTaxRate: 5000
        });

        _setupPool(revnetId, 10_000 ether);

        // Day 0: pay 1 ETH to establish baseline.
        uint256 t0 = _payRevnet(revnetId, PAYER, 1 ether);

        // Warp 2 days (two full cycles).
        vm.warp(block.timestamp + 86_400 * 2);

        // Day 2: pay 1 ETH.
        address payer2 = makeAddr("payer2");
        vm.deal(payer2, 10 ether);
        uint256 t2 = _payRevnet(revnetId, payer2, 1 ether);

        // T2 should be approximately T0 * 0.9 * 0.9 = T0 * 0.81 (within 1% tolerance).
        uint256 expected = (t0 * 81) / 100;
        uint256 tolerance = expected / 100; // 1%
        assertGt(t2, expected - tolerance, "T2 should be >= T0*0.81 - 1%");
        assertLt(t2, expected + tolerance, "T2 should be <= T0*0.81 + 1%");
    }

    /// @notice With 0% issuance cut, weight never changes and T0 == T1.
    function testFork_IssuanceDecayZeroPercent() public {
        // 0% cut per cycle, 1-day cycles.
        uint256 revnetId =
            _deployRevnetWithDecay({issuanceCutFrequency: 86_400, issuanceCutPercent: 0, cashOutTaxRate: 5000});

        _setupPool(revnetId, 10_000 ether);

        // Day 0: pay 1 ETH.
        uint256 t0 = _payRevnet(revnetId, PAYER, 1 ether);

        // Warp 1 day.
        vm.warp(block.timestamp + 86_400);

        // Day 1: pay 1 ETH.
        address payer2 = makeAddr("payer2");
        vm.deal(payer2, 10 ether);
        uint256 t1 = _payRevnet(revnetId, payer2, 1 ether);

        // With 0% cut, tokens should be identical.
        assertEq(t1, t0, "with 0% cut, tokens should be the same across cycles");
    }
}
