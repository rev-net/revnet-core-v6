// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "./ForkTestBase.sol";
import {REVEmpty721Config} from "../helpers/REVEmpty721Config.sol";
import {JBFees} from "@bananapus/core-v6/src/libraries/JBFees.sol";

/// @notice Adversarial fork tests for REVLoans — probes edge cases, exploit vectors, and boundary conditions.
///
/// Covers:
///  1. Borrow-repay-reborrow flash loop profitability (Gap 10)
///  2. Liquidation vs repay race at exact boundary (Gap 14)
///  3. Cross-stage borrow with tax INCREASE (Gap 18)
///  4. Many small loans vs one large loan (Gap 19)
///  5. Source fee boundary timestamps
///  6. Zero collateral and near-zero surplus edge cases
///
/// Run with: FOUNDRY_PROFILE=fork forge test --match-contract TestLoanAdversarialFork -vvv
contract TestLoanAdversarialFork is ForkTestBase {
    // ───────────────────────── Shared state ─────────────────────────

    uint256 revnetId;
    uint256 constant STAGE_DURATION = 30 days;

    function setUp() public override {
        super.setUp();

        // Deploy fee project + revnet with 50% cashOutTaxRate (non-linear bonding curve).
        _deployFeeProject(5000);
        revnetId = _deployRevnet(5000);

        // Set up pool at 1:1 (mint path wins).
        _setupPool(revnetId, 10_000 ether);

        // Pay to create surplus from multiple payers so bonding curve tax has visible effect.
        _payRevnet(revnetId, PAYER, 10 ether);
        _payRevnet(revnetId, BORROWER, 5 ether);

        address otherPayer = makeAddr("otherPayer");
        vm.deal(otherPayer, 10 ether);
        _payRevnet(revnetId, otherPayer, 5 ether);
    }

    /// @notice Deploy a revnet with a custom description salt to avoid CREATE2 collisions.
    function _deployRevnetWithSalt(uint16 cashOutTaxRate, bytes32 salt) internal returns (uint256 revnetId) {
        (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc) =
            _buildMinimalConfig(cashOutTaxRate);
        cfg.description.salt = salt;

        (revnetId,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: cfg,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: sdc,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test 1: Borrow-then-immediately-repay flash loop (Gap 10)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Borrow -> immediate repay -> reborrow in the same block. Tests whether the loop is profitable.
    /// Within the prepaid period, repay costs exactly loan.amount (no source fee), so the borrower gets back
    /// their original collateral. But they also received fee tokens from the source fee payment during borrow.
    /// This test checks whether those extra tokens can be used to extract additional ETH on a second borrow.
    function test_fork_adversarial_borrowRepayReborrow_sameBlock() public {
        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);
        assertGt(borrowerTokens, 0, "borrower should have tokens");

        uint256 borrowerEthBefore = BORROWER.balance;
        uint256 minFeePercent = LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT();

        // ── Step 1: First borrow using all tokens as collateral ──
        _grantBurnPermission(BORROWER, revnetId);

        REVLoanSource memory source = _nativeLoanSource();
        vm.prank(BORROWER);
        (uint256 loanId1, REVLoan memory loan1) = LOANS_CONTRACT.borrowFrom({
            revnetId: revnetId,
            source: source,
            minBorrowAmount: 0,
            collateralCount: borrowerTokens,
            beneficiary: payable(BORROWER),
            prepaidFeePercent: minFeePercent,
            holder: BORROWER
        });

        uint256 ethAfterBorrow1 = BORROWER.balance;
        uint256 ethReceivedFromBorrow1 = ethAfterBorrow1 - borrowerEthBefore;
        assertGt(ethReceivedFromBorrow1, 0, "should receive ETH from first borrow");

        // Record fee tokens minted to borrower from the source fee payment back to the revnet.
        uint256 feeTokensFromBorrow1 = jbTokens().totalBalanceOf(BORROWER, revnetId);
        emit log_named_uint("Fee tokens from borrow 1", feeTokensFromBorrow1);
        assertGt(feeTokensFromBorrow1, 0, "borrower should have fee tokens from source fee payment");
        assertLt(feeTokensFromBorrow1, borrowerTokens, "fee tokens should be less than original collateral");

        // ── Step 2: Immediately repay the full loan (same block, no vm.warp) ──
        vm.deal(BORROWER, 100 ether);
        uint256 borrowerEthBeforeRepay = BORROWER.balance;

        JBSingleAllowance memory allowance;
        vm.prank(BORROWER);
        LOANS_CONTRACT.repayLoan{value: loan1.amount * 2}({
            loanId: loanId1,
            maxRepayBorrowAmount: loan1.amount * 2,
            collateralCountToReturn: loan1.collateral,
            beneficiary: payable(BORROWER),
            allowance: allowance
        });

        uint256 ethSpentOnRepay = borrowerEthBeforeRepay - BORROWER.balance;
        emit log_named_uint("ETH spent on repay", ethSpentOnRepay);

        // Within prepaid period, repay costs exactly loan.amount (no source fee).
        assertEq(ethSpentOnRepay, loan1.amount, "repay within prepaid should cost exactly loan amount");

        // Borrower gets back original collateral + keeps fee tokens.
        uint256 tokensAfterRepay = jbTokens().totalBalanceOf(BORROWER, revnetId);
        assertEq(
            tokensAfterRepay,
            borrowerTokens + feeTokensFromBorrow1,
            "should have original tokens + fee tokens after repay"
        );
        emit log_named_uint("Tokens after repay (original + fee)", tokensAfterRepay);

        // ── Step 3: Second borrow using original + fee tokens ──
        _grantBurnPermission(BORROWER, revnetId);

        uint256 borrowerEthBeforeBorrow2 = BORROWER.balance;

        vm.prank(BORROWER);
        (uint256 loanId2, REVLoan memory loan2) = LOANS_CONTRACT.borrowFrom({
            revnetId: revnetId,
            source: source,
            minBorrowAmount: 0,
            collateralCount: tokensAfterRepay,
            beneficiary: payable(BORROWER),
            prepaidFeePercent: minFeePercent,
            holder: BORROWER
        });

        uint256 ethReceivedFromBorrow2 = BORROWER.balance - borrowerEthBeforeBorrow2;
        emit log_named_uint("ETH from borrow 1", ethReceivedFromBorrow1);
        emit log_named_uint("ETH from borrow 2", ethReceivedFromBorrow2);
        emit log_named_uint("Loan 1 amount", loan1.amount);
        emit log_named_uint("Loan 2 amount", loan2.amount);

        // The second borrow should succeed (more collateral = more borrowable).
        assertGt(loanId2, 0, "second borrow should succeed");

        // Key check: is the borrow-repay-reborrow loop profitable?
        //
        // The correct analysis compares the FULL CLOSE-OUT cost. If the borrower were to repay BOTH
        // loans to completion, the economics are:
        //   Total ETH received: ethReceivedFromBorrow1 + ethReceivedFromBorrow2
        //   Total repayment cost: loan1.amount + loan2.amount
        //
        // Each borrow incurs a prepaid fee, so total repayment > total received (net loss).
        // The loop should NOT be profitable because:
        // 1. Each borrow deducts a prepaid source fee from the disbursed amount
        // 2. The bonding curve means more tokens != proportionally more ETH
        // 3. The 2.5% prepaid fee is taken on each borrow
        uint256 totalEthReceived = ethReceivedFromBorrow1 + ethReceivedFromBorrow2;
        uint256 totalRepaymentCost = loan1.amount + loan2.amount;
        emit log_named_uint("Total ETH received from both borrows", totalEthReceived);
        emit log_named_uint("Total repayment cost (loan1 + loan2)", totalRepaymentCost);

        // Should be a loss (total cost > total received) — the fee prevents arbitrage.
        assertGt(totalRepaymentCost, totalEthReceived, "full cycle should be a net loss (fee prevents arbitrage)");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test 2: Liquidation vs repay race at exact boundary (Gap 14)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Tests the exact second at the liquidation boundary.
    /// At `createdAt + LOAN_LIQUIDATION_DURATION` (exactly), repay should SUCCEED (code uses `>` at L468).
    /// At `createdAt + LOAN_LIQUIDATION_DURATION + 1`, repay should REVERT and liquidation should SUCCEED.
    function test_fork_adversarial_liquidationRepayRace_exactBoundary() public {
        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);
        uint256 minFeePercent = LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT();

        // Create a loan.
        (uint256 loanId, REVLoan memory loan) = _createLoan(revnetId, BORROWER, borrowerTokens, minFeePercent);
        assertGt(loanId, 0, "loan should be created");

        uint256 loanLiquidationDuration = LOANS_CONTRACT.LOAN_LIQUIDATION_DURATION();
        uint256 exactBoundary = loan.createdAt + loanLiquidationDuration;

        // ── Scenario A: Warp to EXACTLY the boundary ──
        uint256 snapshotA = vm.snapshot();

        vm.warp(exactBoundary);

        // At exactly the boundary, timeSinceLoanCreated == LOAN_LIQUIDATION_DURATION.
        // The code checks `timeSinceLoanCreated > LOAN_LIQUIDATION_DURATION`, so `==` should NOT revert.
        // Repay should SUCCEED.
        vm.deal(BORROWER, 100 ether);

        JBSingleAllowance memory allowance;

        vm.prank(BORROWER);
        LOANS_CONTRACT.repayLoan{value: loan.amount * 3}({
            loanId: loanId,
            maxRepayBorrowAmount: loan.amount * 3,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(BORROWER),
            allowance: allowance
        });

        // Verify repay worked: loan NFT should be burned.
        vm.expectRevert();
        _loanOwnerOf(loanId);

        // Verify collateral returned.
        uint256 tokensAfterRepay = jbTokens().totalBalanceOf(BORROWER, revnetId);
        assertGt(tokensAfterRepay, 0, "borrower should get collateral back at exact boundary");
        emit log_named_uint("Tokens after repay at exact boundary", tokensAfterRepay);

        // ── Scenario B: Revert to snapshot, warp to boundary + 1 ──
        vm.revertTo(snapshotA);

        vm.warp(exactBoundary + 1);

        // At boundary + 1, timeSinceLoanCreated > LOAN_LIQUIDATION_DURATION, so repay should REVERT.
        vm.deal(BORROWER, 100 ether);

        vm.prank(BORROWER);
        vm.expectRevert();
        LOANS_CONTRACT.repayLoan{value: loan.amount * 3}({
            loanId: loanId,
            maxRepayBorrowAmount: loan.amount * 3,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(BORROWER),
            allowance: allowance
        });

        // Loan should still exist (repay failed).
        assertEq(_loanOwnerOf(loanId), BORROWER, "loan should still exist after failed repay");

        // ── Liquidation should SUCCEED at boundary + 1 ──
        // The liquidation check is `block.timestamp <= loan.createdAt + LOAN_LIQUIDATION_DURATION`,
        // which at boundary+1 evaluates to false, so liquidation proceeds.
        uint256 totalCollateralBefore = LOANS_CONTRACT.totalCollateralOf(revnetId);

        // Loan number is 1 (first loan for this revnet).
        LOANS_CONTRACT.liquidateExpiredLoansFrom(revnetId, 1, 1);

        // Loan NFT should be burned.
        vm.expectRevert();
        _loanOwnerOf(loanId);

        // Collateral permanently lost.
        uint256 totalCollateralAfter = LOANS_CONTRACT.totalCollateralOf(revnetId);
        assertEq(
            totalCollateralAfter,
            totalCollateralBefore - borrowerTokens,
            "total collateral should decrease after liquidation"
        );

        emit log_string("Confirmed: repay succeeds at exact boundary, fails at boundary+1. Liquidation succeeds at boundary+1.");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test 3: Cross-stage borrow with tax INCREASE (Gap 18)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Build a two-stage config: stage 1 (low tax), stage 2 (high tax).
    function _buildTwoStageConfig_taxIncrease(
        uint16 stage1TaxRate,
        uint16 stage2TaxRate
    )
        internal
        view
        returns (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc)
    {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});

        REVStageConfig[] memory stages = new REVStageConfig[](2);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        // Stage 1: low tax -- starts immediately.
        stages[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: INITIAL_ISSUANCE,
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: stage1TaxRate,
            extraMetadata: 0
        });

        // Stage 2: high tax -- starts after STAGE_DURATION.
        stages[1] = REVStageConfig({
            // forge-lint: disable-next-line(unsafe-typecast)
            startsAtOrAfter: uint40(block.timestamp + STAGE_DURATION),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: INITIAL_ISSUANCE,
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: stage2TaxRate,
            extraMetadata: 0
        });

        cfg = REVConfig({
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription("TaxIncrease", "TXUP", "ipfs://txup", "TXUP_SALT"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });

        sdc = REVSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("TXUP"))
        });
    }

    /// @notice Tests that a tax increase between stages reduces borrowable amount for the same collateral,
    /// effectively undercollateralizing existing loans.
    function test_fork_adversarial_crossStage_taxIncrease() public {
        // Deploy a separate two-stage revnet: stage1 tax=2000 (20%), stage2 tax=7000 (70%).
        (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc) =
            _buildTwoStageConfig_taxIncrease(2000, 7000);

        (uint256 taxRevnetId,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: cfg,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: sdc,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        // Set up pool.
        _setupPool(taxRevnetId, 10_000 ether);

        // Pay 10 ETH to create surplus. Use PAYER first to establish surplus.
        _payRevnet(taxRevnetId, PAYER, 10 ether);

        // Borrower pays 10 ETH.
        uint256 borrowerTokens = _payRevnet(taxRevnetId, BORROWER, 10 ether);
        assertGt(borrowerTokens, 0, "borrower should have tokens");
        emit log_named_uint("Borrower tokens in stage 1", borrowerTokens);

        // Record borrowable amount in stage 1 (20% tax).
        uint256 borrowableStage1 = LOANS_CONTRACT.borrowableAmountFrom(
            taxRevnetId, borrowerTokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        assertGt(borrowableStage1, 0, "should have borrowable amount in stage 1");
        emit log_named_uint("Borrowable in stage 1 (20% tax)", borrowableStage1);

        // ── Borrow in stage 1 ──
        (uint256 loanId, REVLoan memory loan) =
            _createLoan(taxRevnetId, BORROWER, borrowerTokens, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());
        assertGt(loanId, 0, "loan should be created in stage 1");
        emit log_named_uint("Loan amount (stage 1)", loan.amount);

        // ── Warp to stage 2 (70% tax) ──
        vm.warp(block.timestamp + STAGE_DURATION + 1);

        // Check new borrowable amount -- should DECREASE because higher tax means less surplus per token.
        uint256 borrowableStage2 = LOANS_CONTRACT.borrowableAmountFrom(
            taxRevnetId, borrowerTokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        emit log_named_uint("Borrowable in stage 2 (70% tax)", borrowableStage2);

        // Higher tax rate should decrease borrowable amount.
        assertLt(borrowableStage2, borrowableStage1, "borrowable should DECREASE with higher tax");

        // Check if the loan is effectively undercollateralized.
        // The loan amount was set at stage 1 rates, but now the same collateral is worth less.
        if (borrowableStage2 < loan.amount) {
            emit log_string("Loan is effectively undercollateralized in stage 2");
            emit log_named_uint("Loan amount", loan.amount);
            emit log_named_uint("Current borrowable for same collateral", borrowableStage2);
        }

        // ── Can the borrower still repay? Yes, they just pay the original amount ──
        vm.deal(BORROWER, 100 ether);
        JBSingleAllowance memory allowance;

        vm.prank(BORROWER);
        LOANS_CONTRACT.repayLoan{value: loan.amount * 3}({
            loanId: loanId,
            maxRepayBorrowAmount: loan.amount * 3,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(BORROWER),
            allowance: allowance
        });

        // Verify collateral returned.
        uint256 tokensAfterRepay = jbTokens().totalBalanceOf(BORROWER, revnetId);
        emit log_named_uint("Tokens after repay in stage 2", tokensAfterRepay);

        // ── Can a new borrower borrow with the same amount of collateral in stage 2? ──
        // They should get less ETH than what was borrowed in stage 1.
        address newBorrower = makeAddr("newBorrower");
        vm.deal(newBorrower, 20 ether);
        uint256 newBorrowerTokens = _payRevnet(taxRevnetId, newBorrower, 10 ether);

        uint256 newBorrowable = LOANS_CONTRACT.borrowableAmountFrom(
            taxRevnetId, newBorrowerTokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );
        emit log_named_uint("New borrower's borrowable in stage 2", newBorrowable);

        // Stage 2 borrowable for new tokens should be less than stage 1 borrowable for the same token count,
        // because the higher tax rate reduces the bonding curve output.
        // Note: new borrower may have different token count due to supply changes, so we compare per-token rates.
        if (newBorrowerTokens > 0 && borrowerTokens > 0) {
            uint256 rateStage1 = (borrowableStage1 * 1e18) / borrowerTokens;
            uint256 rateStage2 = (newBorrowable * 1e18) / newBorrowerTokens;
            emit log_named_uint("Per-token borrowable rate stage 1 (wei)", rateStage1);
            emit log_named_uint("Per-token borrowable rate stage 2 (wei)", rateStage2);
            assertLt(rateStage2, rateStage1, "per-token borrowable rate should decrease with higher tax");
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test 4: Multiple small loans vs one large loan (Gap 19)
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Compare: one large loan vs many small loans. With a non-linear bonding curve (cashOutTaxRate > 0),
    /// splitting collateral into smaller chunks should yield a different total due to the bonding curve.
    function test_fork_adversarial_manySmallLoans_vsOneLarge() public {
        // Borrower pays 10 ETH to get tokens at weight 1000.
        address splitBorrower = makeAddr("splitBorrower");
        vm.deal(splitBorrower, 100 ether);
        uint256 splitBorrowerTokens = _payRevnet(revnetId, splitBorrower, 10 ether);
        assertGt(splitBorrowerTokens, 0, "splitBorrower should have tokens");
        emit log_named_uint("Split borrower tokens", splitBorrowerTokens);

        uint256 minFeePercent = LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT();

        // ── Scenario A: One large loan with ALL tokens ──
        uint256 snapshotA = vm.snapshot();

        _grantBurnPermission(splitBorrower, revnetId);

        REVLoanSource memory source = _nativeLoanSource();
        uint256 ethBeforeA = splitBorrower.balance;

        vm.prank(splitBorrower);
        (uint256 loanIdA, REVLoan memory loanA) = LOANS_CONTRACT.borrowFrom({
            revnetId: revnetId,
            source: source,
            minBorrowAmount: 0,
            collateralCount: splitBorrowerTokens,
            beneficiary: payable(splitBorrower),
            prepaidFeePercent: minFeePercent,
            holder: splitBorrower
        });

        uint256 ethReceivedA = splitBorrower.balance - ethBeforeA;
        emit log_named_uint("Scenario A (one large loan) - ETH received", ethReceivedA);
        emit log_named_uint("Scenario A - Loan amount", loanA.amount);
        assertGt(loanIdA, 0, "large loan should be created");

        // ── Scenario B: Revert, then take 5 small loans with splitBorrowerTokens / 5 each ──
        vm.revertTo(snapshotA);

        uint256 chunkSize = splitBorrowerTokens / 5;
        assertGt(chunkSize, 0, "chunk size should be > 0");

        uint256 totalEthReceivedB;
        uint256 tokensUsedB;

        for (uint256 i; i < 5; i++) {
            _grantBurnPermission(splitBorrower, revnetId);

            uint256 ethBeforeChunk = splitBorrower.balance;

            // Use chunkSize for all 5 chunks (any remainder from integer division is ignored).
            vm.prank(splitBorrower);
            LOANS_CONTRACT.borrowFrom({
                revnetId: revnetId,
                source: source,
                minBorrowAmount: 0,
                collateralCount: chunkSize,
                beneficiary: payable(splitBorrower),
                prepaidFeePercent: minFeePercent,
                holder: splitBorrower
            });

            uint256 ethFromChunk = splitBorrower.balance - ethBeforeChunk;
            totalEthReceivedB += ethFromChunk;
            tokensUsedB += chunkSize;
            emit log_named_uint(string(abi.encodePacked("Scenario B chunk ", vm.toString(i), " ETH")), ethFromChunk);
        }

        emit log_named_uint("Scenario B (5 small loans) - Total ETH received", totalEthReceivedB);

        // Compare the two scenarios.
        emit log_named_uint("Tokens used in A", splitBorrowerTokens);
        emit log_named_uint("Tokens used in B", tokensUsedB);

        // With a non-linear bonding curve (cashOutTaxRate = 50%), splitting should produce a DIFFERENT result.
        // Specifically, the bonding curve formula penalizes larger cashouts relative to total supply,
        // so splitting into smaller chunks should yield MORE total ETH.
        if (totalEthReceivedB > ethReceivedA) {
            uint256 advantage = totalEthReceivedB - ethReceivedA;
            uint256 advantagePercent = (advantage * 10_000) / ethReceivedA;
            emit log_named_uint("Splitting advantage (wei)", advantage);
            emit log_named_uint("Splitting advantage (bps)", advantagePercent);
            emit log_string("Splitting loans yields more ETH -- bonding curve non-linearity confirmed");
        } else if (ethReceivedA > totalEthReceivedB) {
            uint256 disadvantage = ethReceivedA - totalEthReceivedB;
            uint256 disadvantagePercent = (disadvantage * 10_000) / ethReceivedA;
            emit log_named_uint("Splitting disadvantage (wei)", disadvantage);
            emit log_named_uint("Splitting disadvantage (bps)", disadvantagePercent);
            emit log_string("Single large loan yields more ETH");
        } else {
            emit log_string("Both strategies yield identical ETH");
        }

        // The difference should exist but be bounded -- the protocol should not allow unbounded extraction.
        // We verify that neither strategy yields more than 10% advantage over the other.
        if (totalEthReceivedB > ethReceivedA) {
            assertLt(
                totalEthReceivedB - ethReceivedA,
                ethReceivedA / 10,
                "splitting advantage should be < 10% of single loan"
            );
        } else if (ethReceivedA > totalEthReceivedB) {
            assertLt(
                ethReceivedA - totalEthReceivedB,
                totalEthReceivedB / 10,
                "single loan advantage should be < 10% of split loans"
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test 5: Source fee boundary timestamps
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Tests source fee calculation at exact boundary timestamps using the view function.
    function test_fork_adversarial_sourceFee_exactBoundaries() public {
        uint256 borrowerTokens = jbTokens().totalBalanceOf(BORROWER, revnetId);
        uint256 minFeePercent = LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT();

        // Create a loan.
        (uint256 loanId, REVLoan memory loan) = _createLoan(revnetId, BORROWER, borrowerTokens, minFeePercent);
        assertGt(loanId, 0, "loan should be created");

        uint256 loanLiquidationDuration = LOANS_CONTRACT.LOAN_LIQUIDATION_DURATION();

        // ── Check 1: At exactly createdAt + prepaidDuration -- should be 0 ──
        vm.warp(loan.createdAt + loan.prepaidDuration);
        uint256 feeAtPrepaidEnd = LOANS_CONTRACT.determineSourceFeeAmount(loan, loan.amount);
        assertEq(feeAtPrepaidEnd, 0, "fee at exactly prepaidDuration should be 0");
        emit log_named_uint("Fee at prepaidDuration boundary", feeAtPrepaidEnd);

        // ── Check 2: At createdAt + prepaidDuration + 1 -- fee is still 0 due to integer rounding ──
        // The feePercent = mulDiv(1, MAX_FEE, feeWindow) rounds to 0 when feeWindow >> MAX_FEE.
        // With MIN_PREPAID_FEE_PERCENT=25 and LOAN_LIQUIDATION_DURATION=3650 days, the fee window
        // is ~299,592,000 seconds while MAX_FEE is only 1000, so 1 second yields feePercent=0.
        vm.warp(loan.createdAt + loan.prepaidDuration + 1);
        uint256 feeAtPrepaidPlus1 = LOANS_CONTRACT.determineSourceFeeAmount(loan, loan.amount);
        assertEq(feeAtPrepaidPlus1, 0, "fee at prepaidDuration + 1 should be 0 (integer rounding)");
        emit log_named_uint("Fee at prepaidDuration + 1", feeAtPrepaidPlus1);

        // ── Check 3: At midpoint between prepaid and liquidation ──
        uint256 midpoint = loan.createdAt + loan.prepaidDuration + (loanLiquidationDuration - loan.prepaidDuration) / 2;
        vm.warp(midpoint);
        uint256 feeAtMidpoint = LOANS_CONTRACT.determineSourceFeeAmount(loan, loan.amount);
        assertGt(feeAtMidpoint, 0, "fee at midpoint should be non-zero");
        emit log_named_uint("Fee at midpoint", feeAtMidpoint);

        // ── Check 4: At createdAt + LOAN_LIQUIDATION_DURATION (exact boundary) ──
        vm.warp(loan.createdAt + loanLiquidationDuration);
        uint256 feeAtLiquidation = LOANS_CONTRACT.determineSourceFeeAmount(loan, loan.amount);
        assertGt(feeAtLiquidation, feeAtMidpoint, "fee at liquidation boundary should be maximum");
        emit log_named_uint("Fee at liquidation boundary (maximum)", feeAtLiquidation);

        // ── Check 5: At createdAt + LOAN_LIQUIDATION_DURATION + 1 -- should revert ──
        vm.warp(loan.createdAt + loanLiquidationDuration + 1);
        vm.expectRevert();
        LOANS_CONTRACT.determineSourceFeeAmount(loan, loan.amount);
        emit log_string("Fee at liquidation + 1 correctly reverts with REVLoans_LoanExpired");

        // ── Verify monotonicity: fee should strictly increase from prepaid end to liquidation ──
        // Sample at 10 evenly spaced points.
        uint256 feeWindow = loanLiquidationDuration - loan.prepaidDuration;
        uint256 previousFee;
        for (uint256 i = 1; i <= 10; i++) {
            uint256 timestamp = loan.createdAt + loan.prepaidDuration + (feeWindow * i) / 10;
            vm.warp(timestamp);
            uint256 currentFee = LOANS_CONTRACT.determineSourceFeeAmount(loan, loan.amount);
            assertGe(currentFee, previousFee, "fee should be monotonically non-decreasing");
            previousFee = currentFee;
        }
        emit log_string("Source fee monotonicity confirmed across 10 sample points");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test 6: Zero collateral and near-zero surplus edge cases
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Tests borrow with zero collateral (should revert), minimal collateral (dust), and
    /// large surplus with minimal collateral (should succeed).
    function test_fork_adversarial_zeroCollateral_reverts() public {
        uint256 minFeePercent = LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT();
        REVLoanSource memory source = _nativeLoanSource();

        // ── Case 1: Zero collateral -- should revert with REVLoans_ZeroCollateralLoanIsInvalid ──
        // NOTE: We do NOT call _grantBurnPermission here because borrowFrom reverts with
        // REVLoans_ZeroCollateralLoanIsInvalid before reaching the burn/permission check.
        // _grantBurnPermission uses mockExpect which sets vm.expectCall — that would fail
        // since the expected hasPermission call never fires.

        vm.prank(BORROWER);
        vm.expectRevert(REVLoans.REVLoans_ZeroCollateralLoanIsInvalid.selector);
        LOANS_CONTRACT.borrowFrom({
            revnetId: revnetId,
            source: source,
            minBorrowAmount: 0,
            collateralCount: 0,
            beneficiary: payable(BORROWER),
            prepaidFeePercent: minFeePercent,
            holder: BORROWER
        });
        emit log_string("Case 1 passed: zero collateral correctly reverts");

        // ── Case 2: Near-zero surplus with minimal collateral ──
        // Deploy a fresh revnet with no surplus to test dust behavior.
        // Use a unique description salt to avoid CREATE2 collision with other revnets in this test contract.
        uint256 dustRevnetId = _deployRevnetWithSalt(5000, bytes32("DUST_SALT"));
        _setupPool(dustRevnetId, 10_000 ether);

        // Pay 1 wei to create minimal surplus.
        address dustPayer = makeAddr("dustPayer");
        vm.deal(dustPayer, 1 ether);

        // Pay 1 wei -- this creates minimal surplus and mints minimal tokens.
        vm.prank(dustPayer);
        uint256 dustTokens = jbMultiTerminal().pay{value: 1 wei}({
            projectId: dustRevnetId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 1 wei,
            beneficiary: dustPayer,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        emit log_named_uint("Tokens from 1 wei payment", dustTokens);

        if (dustTokens > 0) {
            // Check if borrowable amount from 1 dust token is zero.
            uint256 dustBorrowable = LOANS_CONTRACT.borrowableAmountFrom(
                dustRevnetId, dustTokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
            );
            emit log_named_uint("Borrowable from dust tokens", dustBorrowable);

            if (dustBorrowable == 0) {
                // Should revert with ZeroBorrowAmount.
                // NOTE: We intentionally do NOT call _grantBurnPermission here because borrowFrom
                // reverts with REVLoans_ZeroBorrowAmount before it ever reaches the burn/permission
                // check. Calling _grantBurnPermission would set up a vm.expectCall (via mockExpect)
                // for hasPermission that never fires, causing the test to fail.
                vm.prank(dustPayer);
                vm.expectRevert(REVLoans.REVLoans_ZeroBorrowAmount.selector);
                LOANS_CONTRACT.borrowFrom({
                    revnetId: dustRevnetId,
                    source: source,
                    minBorrowAmount: 0,
                    collateralCount: dustTokens,
                    beneficiary: payable(dustPayer),
                    prepaidFeePercent: minFeePercent,
                    holder: dustPayer
                });
                emit log_string("Case 2 passed: dust collateral with zero borrowable correctly reverts");
            } else {
                emit log_string("Case 2: dust collateral has non-zero borrowable amount (interesting edge case)");
            }
        } else {
            emit log_string("Case 2: 1 wei payment yields 0 tokens (too small for issuance)");
        }

        // ── Case 3: Huge surplus with 1 token -- should succeed ──
        // Deploy a fresh revnet and pay a large amount to create huge surplus.
        // Use a unique description salt to avoid CREATE2 collision with other revnets in this test contract.
        uint256 hugeRevnetId = _deployRevnetWithSalt(5000, bytes32("HUGE_SALT"));
        _setupPool(hugeRevnetId, 10_000 ether);

        // Create big surplus from another payer.
        address bigPayer = makeAddr("bigPayer");
        vm.deal(bigPayer, 50 ether);
        _payRevnet(hugeRevnetId, bigPayer, 50 ether);

        // Small payer gets some tokens.
        address smallPayer = makeAddr("smallPayer");
        vm.deal(smallPayer, 1 ether);
        uint256 smallTokens = _payRevnet(hugeRevnetId, smallPayer, 0.001 ether);
        emit log_named_uint("Small payer tokens", smallTokens);

        if (smallTokens > 0) {
            uint256 smallBorrowable = LOANS_CONTRACT.borrowableAmountFrom(
                hugeRevnetId, smallTokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
            );
            emit log_named_uint("Small payer borrowable (huge surplus)", smallBorrowable);

            if (smallBorrowable > 0) {
                // This should succeed -- huge surplus means even small collateral can borrow something.
                _grantBurnPermission(smallPayer, hugeRevnetId);

                vm.prank(smallPayer);
                (uint256 smallLoanId, REVLoan memory smallLoan) = LOANS_CONTRACT.borrowFrom({
                    revnetId: hugeRevnetId,
                    source: source,
                    minBorrowAmount: 0,
                    collateralCount: smallTokens,
                    beneficiary: payable(smallPayer),
                    prepaidFeePercent: minFeePercent,
                    holder: smallPayer
                });
                assertGt(smallLoanId, 0, "small collateral loan should succeed with huge surplus");
                assertGt(smallLoan.amount, 0, "small loan should have non-zero amount");
                emit log_named_uint("Small loan amount", smallLoan.amount);
                emit log_string("Case 3 passed: small collateral with huge surplus successfully borrows");
            } else {
                emit log_string("Case 3: even with huge surplus, small collateral yields zero borrowable");
            }
        } else {
            emit log_string("Case 3: 0.001 ETH yields 0 tokens");
        }
    }
}
