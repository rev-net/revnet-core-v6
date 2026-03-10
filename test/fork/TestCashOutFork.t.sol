// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./ForkTestBase.sol";
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";

/// @notice Fork tests for revnet cash-out scenarios with real Uniswap V4 buyback hook.
///
/// Covers: fee deduction, high tax rate, sucker exemption, surplus after tier splits, and delay enforcement.
///
/// Run with: FOUNDRY_PROFILE=fork forge test --match-contract TestCashOutFork -vvv
contract TestCashOutFork is ForkTestBase {
    uint256 revnetId;

    function setUp() public override {
        super.setUp();

        // Skip if no fork available.
        string memory rpcUrl = vm.envOr("RPC_ETHEREUM_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) return;

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
    function test_fork_cashOut_normalWithFee() public onlyFork {
        uint256 payerTokens = jbTokens().totalBalanceOf(PAYER, revnetId);
        uint256 cashOutCount = payerTokens / 2; // Cash out half.

        // Record state before.
        uint256 payerEthBefore = PAYER.balance;
        uint256 feeTerminalBefore = _terminalBalance(FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN);
        uint256 totalSupplyBefore = jbTokens().totalSupplyOf(revnetId);

        // Cash out.
        vm.prank(PAYER);
        uint256 reclaimedAmount = jbMultiTerminal()
            .cashOutTokensOf({
                holder: PAYER,
                projectId: revnetId,
                cashOutCount: cashOutCount,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(PAYER),
                metadata: ""
            });

        // Payer received ETH.
        assertGt(PAYER.balance, payerEthBefore, "payer should receive ETH");
        assertEq(PAYER.balance - payerEthBefore, reclaimedAmount, "reclaimed amount should match balance change");

        // Fee project terminal balance increased (2.5% fee on the cashout portion processed by the hook).
        uint256 feeTerminalAfter = _terminalBalance(FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN);
        assertGt(feeTerminalAfter, feeTerminalBefore, "fee project should receive fee");

        // Token supply decreased.
        uint256 totalSupplyAfter = jbTokens().totalSupplyOf(revnetId);
        assertEq(totalSupplyAfter, totalSupplyBefore - cashOutCount, "total supply should decrease by cashOutCount");

        // Reclaim is less than pro-rata share due to 50% tax rate.
        uint256 surplus = _terminalBalance(revnetId, JBConstants.NATIVE_TOKEN) + reclaimedAmount
            + (feeTerminalAfter - feeTerminalBefore);
        // Pro-rata share = surplus * cashOutCount / totalSupply
        // With 50% tax, reclaim should be roughly 75% of pro-rata (from bonding curve formula).
        uint256 proRataShare = (surplus * cashOutCount) / totalSupplyBefore;
        assertLt(reclaimedAmount, proRataShare, "reclaim should be less than pro-rata due to tax");
    }

    /// @notice High tax rate (90%) produces small reclaim relative to pro-rata.
    function test_fork_cashOut_highTaxRate() public onlyFork {
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
    function test_fork_cashOut_suckerExempt() public onlyFork {
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
    function test_fork_cashOut_afterTierSplitPayment() public onlyFork {
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
        if (payerTokens > 0) {
            vm.prank(PAYER);
            uint256 reclaimedAmount = jbMultiTerminal()
                .cashOutTokensOf({
                    holder: PAYER,
                    projectId: splitRevnetId,
                    cashOutCount: payerTokens,
                    tokenToReclaim: JBConstants.NATIVE_TOKEN,
                    minTokensReclaimed: 0,
                    beneficiary: payable(PAYER),
                    metadata: ""
                });

            assertGt(reclaimedAmount, 0, "should reclaim some ETH after tier split payment");
        }
    }

    /// @notice Cash out before delay expires should revert.
    function test_fork_cashOut_delayEnforcement() public onlyFork {
        // Deploy a fresh revnet (delay starts from deploy time).
        uint256 delayRevnet = _deployRevnet(5000);
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

        // Now it should succeed.
        vm.prank(PAYER);
        uint256 reclaimedAmount = jbMultiTerminal()
            .cashOutTokensOf({
                holder: PAYER,
                projectId: delayRevnet,
                cashOutCount: payerTokens,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(PAYER),
                metadata: ""
            });

        assertGt(reclaimedAmount, 0, "should succeed after delay expires");
    }
}
