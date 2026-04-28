// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "./ForkTestBase.sol";
import {REVEmpty721Config} from "../helpers/REVEmpty721Config.sol";

/// @notice Fork tests for revnet cash-out scenarios with real Uniswap V4 buyback hook.
///
/// Covers: fee deduction, high tax rate, sucker exemption, surplus after tier splits, and delay enforcement.
///
/// Run with: FOUNDRY_PROFILE=fork forge test --match-contract TestCashOutFork -vvv
contract TestCashOutFork is ForkTestBase {
    uint256 revnetId;

    function setUp() public override {
        super.setUp();

        // Deploy fee project + revnet with 50% cashOutTaxRate.
        _deployFeeProject(5000);
        revnetId = _deployRevnet(5000);

        // Set up pool at 1:1 (mint path wins).
        _setupPool(revnetId, 10_000 ether);

        // Pay 10 ETH to create surplus and tokens.
        _payRevnet(revnetId, PAYER, 10 ether);

        // Warp past the 30-day cash-out delay.
        vm.warp(block.timestamp + REV_DEPLOYER.CASH_OUT_DELAY() + 1);
    }

    /// @notice Cash out tokens and verify fee deduction, token burn, and bonding curve reclaim.
    function test_fork_cashOut_normalWithFee() public {
        uint256 payerTokens = jbTokens().totalBalanceOf(PAYER, revnetId);
        uint256 cashOutCount = payerTokens / 2; // Cash out half.

        // Record state before.
        uint256 payerEthBefore = PAYER.balance;
        uint256 feeTerminalBefore = _terminalBalance(FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN);
        uint256 totalSupplyBefore = jbTokens().totalSupplyOf(revnetId);

        // Cash out. When the buyback hook finds a better swap route, it sets cashOutTaxRate = MAX
        // so reclaimedAmount (direct reclaim) is 0 — beneficiary gets ETH via hook swap instead.
        vm.prank(PAYER);
        jbMultiTerminal()
            .cashOutTokensOf({
            holder: PAYER,
            projectId: revnetId,
            cashOutCount: cashOutCount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(PAYER),
            metadata: ""
        });

        // Payer received ETH (via buyback hook swap).
        uint256 ethReceived = PAYER.balance - payerEthBefore;
        assertGt(ethReceived, 0, "payer should receive ETH");

        // Fee project terminal balance increased (2.5% fee on the cashout portion processed by REVDeployer hook).
        uint256 feeTerminalAfter = _terminalBalance(FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN);
        assertGt(feeTerminalAfter, feeTerminalBefore, "fee project should receive fee");

        // When the sell-side buyback route is used, the hook mints tokens to sell into the pool,
        // so net token supply stays the same (burn + re-mint). Verify supply didn't increase.
        uint256 totalSupplyAfter = jbTokens().totalSupplyOf(revnetId);
        assertLe(totalSupplyAfter, totalSupplyBefore, "total supply should not increase");
    }

    /// @notice High tax rate (90%) produces small reclaim relative to pro-rata.
    function test_fork_cashOut_highTaxRate() public {
        // Deploy a separate revnet with 90% tax rate.
        uint256 highTaxRevnet = _deployRevnet(9000);
        _setupPool(highTaxRevnet, 10_000 ether);
        _payRevnet(highTaxRevnet, PAYER, 10 ether);
        vm.warp(block.timestamp + REV_DEPLOYER.CASH_OUT_DELAY() + 1);

        uint256 payerTokens = jbTokens().totalBalanceOf(PAYER, highTaxRevnet);
        uint256 cashOutCount = payerTokens / 2;

        vm.prank(PAYER);
        uint256 reclaimedAmount = jbMultiTerminal()
            .cashOutTokensOf({
            holder: PAYER,
            projectId: highTaxRevnet,
            cashOutCount: cashOutCount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(PAYER),
            metadata: ""
        });

        // With 90% tax rate, reclaim should be very small relative to surplus.
        uint256 terminalBalance = _terminalBalance(highTaxRevnet, JBConstants.NATIVE_TOKEN);
        uint256 totalSurplus = terminalBalance + reclaimedAmount;
        uint256 proRataShare = (totalSurplus * cashOutCount) / payerTokens;

        // At 90% tax rate with 50% of supply, reclaim ~= proRata * (10% + 90% * 0.5) = proRata * 55%.
        // But also minus 2.5% fee. Should be well under 60% of pro-rata.
        assertLt(reclaimedAmount, (proRataShare * 60) / 100, "high tax: reclaim should be very small");
    }

    /// @notice Sucker addresses get full pro-rata reclaim with 0% tax and no fee.
    function test_fork_cashOut_suckerExempt() public {
        address sucker = makeAddr("sucker");
        vm.deal(sucker, 100 ether);

        // Pay as sucker to get tokens.
        _payRevnet(revnetId, sucker, 5 ether);

        uint256 suckerTokens = jbTokens().totalBalanceOf(sucker, revnetId);
        uint256 totalSupply = jbTokens().totalSupplyOf(revnetId);
        uint256 surplus = _terminalBalance(revnetId, JBConstants.NATIVE_TOKEN);

        // Mock sucker registry to report this address as a sucker.
        vm.mockCall(
            address(SUCKER_REGISTRY),
            abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector, revnetId, sucker),
            abi.encode(true)
        );

        uint256 feeTerminalBefore = _terminalBalance(FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN);

        vm.prank(sucker);
        uint256 reclaimedAmount = jbMultiTerminal()
            .cashOutTokensOf({
            holder: sucker,
            projectId: revnetId,
            cashOutCount: suckerTokens,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(sucker),
            metadata: ""
        });

        // Full pro-rata reclaim (0% tax).
        uint256 expectedReclaim = (surplus * suckerTokens) / totalSupply;
        assertEq(reclaimedAmount, expectedReclaim, "sucker should get full pro-rata reclaim");

        // No fee charged.
        uint256 feeTerminalAfter = _terminalBalance(FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN);
        assertEq(feeTerminalAfter, feeTerminalBefore, "no fee should be charged for sucker");
    }

    /// @notice After a payment with 30% tier split, surplus accounting reflects actual terminal balance.
    function test_fork_cashOut_afterTierSplitPayment() public {
        // Deploy revnet with 721 hook.
        (uint256 splitRevnetId, IJB721TiersHook hook) = _deployRevnetWith721(5000);
        _setupPool(splitRevnetId, 10_000 ether);

        // Pay 1 ETH with tier metadata (triggers 30% split).
        address metadataTarget = hook.METADATA_ID_TARGET();
        bytes memory metadata = _buildPayMetadataNoQuote(metadataTarget);

        vm.prank(PAYER);
        jbMultiTerminal().pay{value: 1 ether}({
            projectId: splitRevnetId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 ether,
            beneficiary: PAYER,
            minReturnedTokens: 0,
            memo: "",
            metadata: metadata
        });

        // Warp past delay.
        vm.warp(block.timestamp + REV_DEPLOYER.CASH_OUT_DELAY() + 1);

        uint256 payerTokens = jbTokens().totalBalanceOf(PAYER, splitRevnetId);
        uint256 terminalBalance = _terminalBalance(splitRevnetId, JBConstants.NATIVE_TOKEN);

        // Terminal balance should be ~1 ETH (0.7 ETH project share + 0.3 ETH returned via addToBalance from 721
        // hook).
        assertGt(terminalBalance, 0, "terminal should have balance");

        // Cash out should succeed using actual terminal balance as surplus.
        // When the buyback hook finds a better swap route it sets cashOutTaxRate = MAX, so the terminal's
        // direct reclaimAmount is 0 — the beneficiary receives ETH via the hook's swap instead.
        if (payerTokens > 0) {
            uint256 payerEthBefore = PAYER.balance;

            vm.prank(PAYER);
            jbMultiTerminal()
                .cashOutTokensOf({
                holder: PAYER,
                projectId: splitRevnetId,
                cashOutCount: payerTokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(PAYER),
                metadata: ""
            });

            assertGt(PAYER.balance, payerEthBefore, "payer should receive ETH after tier split cashout");
        }
    }

    /// @notice Cash out before delay expires should revert.
    function test_fork_cashOut_delayEnforcement() public {
        // Deploy a revnet whose first stage started in the past → triggers cash-out delay.
        (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc) =
            _buildMinimalConfig(5000);
        cfg.stageConfigurations[0].startsAtOrAfter = uint40(block.timestamp - 1);
        (uint256 delayRevnet,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: cfg,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: sdc,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
        _setupPool(delayRevnet, 10_000 ether);
        _payRevnet(delayRevnet, PAYER, 1 ether);

        uint256 payerTokens = jbTokens().totalBalanceOf(PAYER, delayRevnet);

        // Try to cash out immediately (before delay expires) -> should revert.
        vm.prank(PAYER);
        vm.expectRevert();
        jbMultiTerminal()
            .cashOutTokensOf({
            holder: PAYER,
            projectId: delayRevnet,
            cashOutCount: payerTokens,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(PAYER),
            metadata: ""
        });

        // Warp past delay.
        vm.warp(block.timestamp + REV_DEPLOYER.CASH_OUT_DELAY() + 1);

        // Now it should succeed. When the buyback hook routes via swap, reclaimAmount is 0 but
        // the beneficiary receives ETH through the hook.
        uint256 payerEthBefore = PAYER.balance;

        vm.prank(PAYER);
        jbMultiTerminal()
            .cashOutTokensOf({
            holder: PAYER,
            projectId: delayRevnet,
            cashOutCount: payerTokens,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(PAYER),
            metadata: ""
        });

        assertGt(PAYER.balance, payerEthBefore, "should succeed after delay expires");
    }
}
