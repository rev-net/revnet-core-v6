// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title TestLoansAndDeployerFixes
/// @notice Regression tests for approval cleanup, stale source skip, and stage ordering.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBPayoutTerminal} from "@bananapus/core-v6/src/interfaces/IJBPayoutTerminal.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {REVLoanSource} from "../../src/structs/REVLoanSource.sol";
import {REVLoan} from "../../src/structs/REVLoan.sol";
import {REVStageConfig, REVAutoIssuance} from "../../src/structs/REVStageConfig.sol";
import {REVConfig} from "../../src/structs/REVConfig.sol";
import {REVDescription} from "../../src/structs/REVDescription.sol";
import {REVSuckerDeploymentConfig} from "../../src/structs/REVSuckerDeploymentConfig.sol";
import {REVDeployer} from "../../src/REVDeployer.sol";
import {REVLoans} from "../../src/REVLoans.sol";
import {REVEmpty721Config} from "../helpers/REVEmpty721Config.sol";
import {REVLoansFeeRecovery, FeeRecoveryProjectConfig} from "../REVLoansFeeRecovery.t.sol";

// ============================================================================
// Main test contract — extends REVLoansFeeRecovery to reuse full setup.
// ============================================================================

contract TestLoansAndDeployerFixes is REVLoansFeeRecovery {
    // ========================================================================
    // Helpers
    // ========================================================================

    /// @notice Mock the burn-tokens permission without requiring it to be called.
    /// Use this instead of _mockLoanPermission when the borrow may revert before
    /// the burn is reached, or in other cases where vm.expectCall would cause a
    /// spurious failure.
    function _mockLoanPermissionNoExpect(address user) internal {
        vm.mockCall(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), user, REVNET_ID, 11, true, true)),
            abi.encode(true)
        );
    }

    /// @notice Mock the repay-loan permission without requiring it to be called.
    /// repayLoan calls _requirePermissionFrom(loanOwner, ..., REPAY_LOAN), but when
    /// sender == loanOwner the hasPermission call is skipped entirely. We still mock
    /// the call in case the path changes, but do not set expectCall.
    function _mockRepayPermissionNoExpect(address user) internal {
        vm.mockCall(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (user, user, REVNET_ID, 12, true, true)),
            abi.encode(true)
        );
    }

    // ========================================================================
    // Stale ERC20 Approval Cleanup
    // ========================================================================
    // After _tryPayFee (in _addTo) or _removeFrom, the ERC20 allowance from
    // the LOANS_CONTRACT to the terminal must be zero. The _afterTransferTo
    // call now force-approves to 0 after successful transfers, and the catch
    // block in _tryPayFee uses safeDecreaseAllowance on failure.
    // ========================================================================

    /// @notice After an ERC20 borrow, the allowance from LOANS_CONTRACT to the terminal is 0.
    function test_erc20BorrowLeavesZeroAllowanceToTerminal() public {
        uint256 payAmount = 1_000_000; // 6 decimals for TOKEN
        deal(address(TOKEN), USER, payAmount);

        // Pay into revnet with ERC-20.
        vm.startPrank(USER);
        TOKEN.approve(address(jbMultiTerminal()), payAmount);
        uint256 tokenCount = jbMultiTerminal().pay(REVNET_ID, address(TOKEN), payAmount, USER, 0, "", "");
        vm.stopPrank();

        _mockLoanPermission(USER);
        REVLoanSource memory source = REVLoanSource({token: address(TOKEN), terminal: jbMultiTerminal()});

        vm.prank(USER);
        LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(USER), 25, USER);

        // Allowance to the terminal must be zero after successful borrow.
        assertEq(
            IERC20(address(TOKEN)).allowance(address(LOANS_CONTRACT), address(jbMultiTerminal())),
            0,
            "Stale allowance to terminal after ERC20 borrow"
        );
    }

    /// @notice After a native ETH borrow, verify no stale state (native token has no allowance concept, but
    /// the loans contract balance must be zero).
    function test_nativeBorrowLeavesNoFundsStuck() public {
        (, uint256 balanceBefore, uint256 balanceAfter) = _borrowNative(USER, 10e18, 25);

        uint256 received = balanceAfter - balanceBefore;
        assertGt(received, 0, "Borrower should receive ETH");

        // No ETH stuck in the loans contract.
        assertEq(address(LOANS_CONTRACT).balance, 0, "No ETH stuck in loans contract after native borrow");
    }

    /// @notice After an ERC20 borrow where the fee terminal reverts, the allowance from
    /// LOANS_CONTRACT to the fee terminal is also 0 (catch block cleans it up).
    function test_erc20BorrowWithRevertingFeeTerminalCleansAllowance() public {
        // Mock the fee terminal to revert for TOKEN.
        _mockRevertingFeeTerminal(address(TOKEN));

        uint256 payAmount = 1_000_000;
        deal(address(TOKEN), USER, payAmount);

        vm.startPrank(USER);
        TOKEN.approve(address(jbMultiTerminal()), payAmount);
        uint256 tokenCount = jbMultiTerminal().pay(REVNET_ID, address(TOKEN), payAmount, USER, 0, "", "");
        vm.stopPrank();

        _mockLoanPermission(USER);
        REVLoanSource memory source = REVLoanSource({token: address(TOKEN), terminal: jbMultiTerminal()});

        vm.prank(USER);
        LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(USER), 25, USER);

        // Allowance to the REVERTING terminal must be 0 (catch block cleaned it up).
        assertEq(
            IERC20(address(TOKEN)).allowance(address(LOANS_CONTRACT), address(REVERTING_TERMINAL)),
            0,
            "Stale allowance to reverting fee terminal after borrow"
        );

        // Allowance to the regular terminal must also be 0.
        assertEq(
            IERC20(address(TOKEN)).allowance(address(LOANS_CONTRACT), address(jbMultiTerminal())),
            0,
            "Stale allowance to terminal after borrow with reverting fee terminal"
        );

        // No tokens stuck.
        assertEq(IERC20(address(TOKEN)).balanceOf(address(LOANS_CONTRACT)), 0, "No ERC20 stuck in loans contract");
    }

    /// @notice After a full ERC20 loan repayment (_removeFrom path), the allowance to the terminal is 0.
    function test_erc20RepaymentLeavesZeroAllowance() public {
        uint256 payAmount = 1_000_000;
        deal(address(TOKEN), USER, payAmount * 2); // Extra for repayment

        // Pay into revnet.
        vm.startPrank(USER);
        TOKEN.approve(address(jbMultiTerminal()), payAmount);
        uint256 tokenCount = jbMultiTerminal().pay(REVNET_ID, address(TOKEN), payAmount, USER, 0, "", "");
        vm.stopPrank();

        _mockLoanPermission(USER);
        REVLoanSource memory source = REVLoanSource({token: address(TOKEN), terminal: jbMultiTerminal()});

        // Borrow.
        vm.prank(USER);
        (uint256 loanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(USER), 25, USER);

        // Read loan details to get repay amount.
        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);

        // Mock repay permission (no expectCall — sender == loanOwner so hasPermission is skipped).
        _mockRepayPermissionNoExpect(USER);

        // Approve the loans contract to pull tokens for repayment via permit2 or direct transfer.
        uint256 maxRepay = loan.amount * 2; // Generous max to cover fees.
        deal(address(TOKEN), USER, maxRepay);
        vm.startPrank(USER);
        TOKEN.approve(address(LOANS_CONTRACT), maxRepay);
        LOANS_CONTRACT.repayLoan({
            loanId: loanId,
            maxRepayBorrowAmount: maxRepay,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(USER),
            allowance: JBSingleAllowance({sigDeadline: 0, amount: 0, expiration: 0, nonce: 0, signature: ""})
        });
        vm.stopPrank();

        // After repayment (_removeFrom), allowance to terminal must be 0.
        assertEq(
            IERC20(address(TOKEN)).allowance(address(LOANS_CONTRACT), address(jbMultiTerminal())),
            0,
            "Stale allowance to terminal after ERC20 repayment"
        );
    }

    // ========================================================================
    // Stale Loan Source DoS Prevention
    // ========================================================================
    // _totalBorrowedFrom must skip sources with zero balance (totalBorrowedFrom == 0)
    // BEFORE calling accountingContextForTokenOf on the terminal. This prevents DoS
    // when a stale terminal starts reverting.
    // ========================================================================

    /// @notice After fully repaying a loan, if the source terminal starts reverting on
    /// accountingContextForTokenOf, subsequent borrows from other sources still work.
    function test_staleLoanSourceDoesNotBlockNewBorrows() public {
        // Step 1: Borrow from native ETH source.
        vm.prank(USER);
        uint256 nativeTokens =
            jbMultiTerminal().pay{value: 10e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, USER, 0, "", "");

        _mockLoanPermission(USER);
        REVLoanSource memory nativeSource =
            REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        vm.prank(USER);
        (uint256 loanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, nativeSource, 0, nativeTokens, payable(USER), 25, USER);

        // Step 2: Fully repay the native loan so totalBorrowedFrom goes to 0.
        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);

        // Mock repay permission (no expectCall — sender == loanOwner so hasPermission is skipped).
        _mockRepayPermissionNoExpect(USER);

        uint256 maxRepay = loan.amount * 2;
        vm.deal(USER, USER.balance + maxRepay);
        vm.prank(USER);
        LOANS_CONTRACT.repayLoan{value: maxRepay}({
            loanId: loanId,
            maxRepayBorrowAmount: maxRepay,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(USER),
            allowance: JBSingleAllowance({sigDeadline: 0, amount: 0, expiration: 0, nonce: 0, signature: ""})
        });

        // Confirm the totalBorrowedFrom for native source is now 0.
        assertEq(
            LOANS_CONTRACT.totalBorrowedFrom(REVNET_ID, jbMultiTerminal(), JBConstants.NATIVE_TOKEN),
            0,
            "totalBorrowedFrom should be 0 after full repay"
        );

        // Step 3: Mock the terminal to revert on accountingContextForTokenOf for native token.
        // This simulates a stale terminal that has been removed or broken.
        vm.mockCallRevert(
            address(jbMultiTerminal()),
            abi.encodeWithSelector(
                IJBTerminal.accountingContextForTokenOf.selector, REVNET_ID, JBConstants.NATIVE_TOKEN
            ),
            "terminal removed"
        );

        // Step 4: Pay into revnet with ERC20 and borrow from ERC20 source.
        // The _totalBorrowedFrom loop should skip the native source (balance is 0)
        // without calling accountingContextForTokenOf on it.
        uint256 payAmount = 1_000_000;
        deal(address(TOKEN), USER, payAmount);

        // We need to clear the mock for ERC20-related calls on the terminal.
        // The mock only targets native token, so ERC20 calls should still work.
        vm.startPrank(USER);
        TOKEN.approve(address(jbMultiTerminal()), payAmount);
        uint256 erc20Tokens = jbMultiTerminal().pay(REVNET_ID, address(TOKEN), payAmount, USER, 0, "", "");
        vm.stopPrank();

        _mockLoanPermission(USER);
        REVLoanSource memory erc20Source = REVLoanSource({token: address(TOKEN), terminal: jbMultiTerminal()});

        // This should NOT revert despite the native source terminal reverting on accountingContextForTokenOf.
        vm.prank(USER);
        LOANS_CONTRACT.borrowFrom(REVNET_ID, erc20Source, 0, erc20Tokens, payable(USER), 25, USER);

        // If we got here, the zero-balance source was successfully skipped.
        assertGt(
            LOANS_CONTRACT.totalBorrowedFrom(REVNET_ID, jbMultiTerminal(), address(TOKEN)),
            0,
            "ERC20 borrow should succeed despite stale native source"
        );
    }

    /// @notice Verify that _totalBorrowedFrom correctly counts non-zero sources.
    function test_nonZeroSourcesStillCounted() public {
        // Borrow from native source (leave it outstanding).
        vm.prank(USER);
        uint256 nativeTokens =
            jbMultiTerminal().pay{value: 10e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, USER, 0, "", "");

        _mockLoanPermission(USER);
        REVLoanSource memory nativeSource =
            REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        vm.prank(USER);
        LOANS_CONTRACT.borrowFrom(REVNET_ID, nativeSource, 0, nativeTokens, payable(USER), 25, USER);

        // Confirm totalBorrowedFrom is non-zero.
        assertGt(
            LOANS_CONTRACT.totalBorrowedFrom(REVNET_ID, jbMultiTerminal(), JBConstants.NATIVE_TOKEN),
            0,
            "totalBorrowedFrom should be non-zero for outstanding loan"
        );

        // Now borrow from ERC20 source as well — _totalBorrowedFrom should read both.
        uint256 payAmount = 1_000_000;
        deal(address(TOKEN), USER, payAmount);
        vm.startPrank(USER);
        TOKEN.approve(address(jbMultiTerminal()), payAmount);
        uint256 erc20Tokens = jbMultiTerminal().pay(REVNET_ID, address(TOKEN), payAmount, USER, 0, "", "");
        vm.stopPrank();

        _mockLoanPermission(USER);
        REVLoanSource memory erc20Source = REVLoanSource({token: address(TOKEN), terminal: jbMultiTerminal()});

        // This call internally invokes _totalBorrowedFrom which reads both sources.
        // If it incorrectly skips non-zero sources, the borrowable amount calculation would be wrong.
        vm.prank(USER);
        LOANS_CONTRACT.borrowFrom(REVNET_ID, erc20Source, 0, erc20Tokens, payable(USER), 25, USER);

        assertGt(
            LOANS_CONTRACT.totalBorrowedFrom(REVNET_ID, jbMultiTerminal(), address(TOKEN)),
            0,
            "ERC20 borrow should record totalBorrowedFrom"
        );
    }

    // ========================================================================
    // Cross-Chain startsAtOrAfter Normalization
    // ========================================================================
    // When stage 0 has startsAtOrAfter=0, it is normalized to block.timestamp.
    // Stage 1 must have startsAtOrAfter > block.timestamp (the normalized value),
    // otherwise REVDeployer_StageTimesMustIncrease is reverted.
    // ========================================================================

    /// @notice Deploying a revnet where stage 0 startsAtOrAfter=0 and stage 1 startsAtOrAfter=1
    /// (less than block.timestamp) must revert with REVDeployer_StageTimesMustIncrease.
    function test_stageTimesRevertWhenStage1BeforeBlockTimestamp() public {
        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](2);
        uint256 decimalMultiplier = 10 ** 18;

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        REVAutoIssuance[] memory issuanceConfs = new REVAutoIssuance[](1);
        issuanceConfs[0] = REVAutoIssuance({
            // forge-lint: disable-next-line(unsafe-typecast)
            chainId: uint32(block.chainid),
            // forge-lint: disable-next-line(unsafe-typecast)
            count: uint104(70_000 * decimalMultiplier),
            beneficiary: multisig()
        });

        // Stage 0: startsAtOrAfter = 0 (normalized to block.timestamp).
        stageConfigurations[0] = REVStageConfig({
            startsAtOrAfter: 0, // Normalized to block.timestamp
            autoIssuances: issuanceConfs,
            splitPercent: 2000,
            splits: splits,
            // forge-lint: disable-next-line(unsafe-typecast)
            initialIssuance: uint112(1000 * decimalMultiplier),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: 0
        });

        // Stage 1: startsAtOrAfter = 1 (definitely < block.timestamp).
        stageConfigurations[1] = REVStageConfig({
            startsAtOrAfter: 1, // 1 < block.timestamp, should fail
            autoIssuances: issuanceConfs,
            splitPercent: 2000,
            splits: splits,
            // forge-lint: disable-next-line(unsafe-typecast)
            initialIssuance: uint112(500 * decimalMultiplier),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: 0
        });

        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        REVConfig memory config = REVConfig({
            description: REVDescription({
                name: "StageOrderTest", ticker: "$SOT", uri: "ipfs://test", salt: "STAGE_ORDER_SALT_REVERT"
            }),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations
        });

        REVSuckerDeploymentConfig memory suckerConfig = REVSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0),
            salt: keccak256(abi.encodePacked("STAGE_ORDER_REVERT"))
        });

        // This should revert because stage 1 start (1) < block.timestamp (the normalized stage 0 start).
        vm.expectRevert(abi.encodeWithSelector(REVDeployer.REVDeployer_StageTimesMustIncrease.selector));
        REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: config,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: suckerConfig,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    /// @notice Deploying with stage 0 startsAtOrAfter=0 and stage 1 startsAtOrAfter > block.timestamp
    /// should succeed.
    function test_stageTimesSucceedWhenStage1AfterBlockTimestamp() public {
        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](2);
        uint256 decimalMultiplier = 10 ** 18;

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        REVAutoIssuance[] memory issuanceConfs = new REVAutoIssuance[](1);
        issuanceConfs[0] = REVAutoIssuance({
            // forge-lint: disable-next-line(unsafe-typecast)
            chainId: uint32(block.chainid),
            // forge-lint: disable-next-line(unsafe-typecast)
            count: uint104(70_000 * decimalMultiplier),
            beneficiary: multisig()
        });

        // Stage 0: startsAtOrAfter = 0 (normalized to block.timestamp).
        stageConfigurations[0] = REVStageConfig({
            startsAtOrAfter: 0,
            autoIssuances: issuanceConfs,
            splitPercent: 2000,
            splits: splits,
            // forge-lint: disable-next-line(unsafe-typecast)
            initialIssuance: uint112(1000 * decimalMultiplier),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: 0
        });

        // Stage 1: startsAtOrAfter = block.timestamp + 100 (after normalized stage 0 start).
        stageConfigurations[1] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp + 100),
            autoIssuances: issuanceConfs,
            splitPercent: 2000,
            splits: splits,
            // forge-lint: disable-next-line(unsafe-typecast)
            initialIssuance: uint112(500 * decimalMultiplier),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: 0
        });

        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        REVConfig memory config = REVConfig({
            description: REVDescription({
                name: "StageOrderTestOK", ticker: "$SOTOK", uri: "ipfs://test", salt: "STAGE_ORDER_SALT_SUCCESS"
            }),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations
        });

        REVSuckerDeploymentConfig memory suckerConfig = REVSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0),
            salt: keccak256(abi.encodePacked("STAGE_ORDER_SUCCESS"))
        });

        // This should succeed because stage 1 start > block.timestamp (the normalized stage 0 start).
        (uint256 newRevnetId,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: config,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: suckerConfig,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        assertGt(newRevnetId, 0, "Deployment should succeed and return a valid revnet ID");
    }

    /// @notice Stage 1 startsAtOrAfter == block.timestamp (equal to normalized stage 0) must also revert
    /// because the check is strictly greater-than.
    function test_stageTimesRevertWhenStage1EqualsBlockTimestamp() public {
        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](2);
        uint256 decimalMultiplier = 10 ** 18;

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        REVAutoIssuance[] memory issuanceConfs = new REVAutoIssuance[](1);
        issuanceConfs[0] = REVAutoIssuance({
            // forge-lint: disable-next-line(unsafe-typecast)
            chainId: uint32(block.chainid),
            // forge-lint: disable-next-line(unsafe-typecast)
            count: uint104(70_000 * decimalMultiplier),
            beneficiary: multisig()
        });

        // Stage 0: startsAtOrAfter = 0 (normalized to block.timestamp).
        stageConfigurations[0] = REVStageConfig({
            startsAtOrAfter: 0,
            autoIssuances: issuanceConfs,
            splitPercent: 2000,
            splits: splits,
            // forge-lint: disable-next-line(unsafe-typecast)
            initialIssuance: uint112(1000 * decimalMultiplier),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: 0
        });

        // Stage 1: startsAtOrAfter = block.timestamp (same as normalized stage 0, must fail).
        stageConfigurations[1] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: issuanceConfs,
            splitPercent: 2000,
            splits: splits,
            // forge-lint: disable-next-line(unsafe-typecast)
            initialIssuance: uint112(500 * decimalMultiplier),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: 0
        });

        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        REVConfig memory config = REVConfig({
            description: REVDescription({
                name: "StageOrderEqual", ticker: "$SOTEQ", uri: "ipfs://test", salt: "STAGE_ORDER_SALT_EQUAL"
            }),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations
        });

        REVSuckerDeploymentConfig memory suckerConfig = REVSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0),
            salt: keccak256(abi.encodePacked("STAGE_ORDER_EQUAL"))
        });

        // This should revert because stage 1 start == block.timestamp == normalized stage 0 start.
        // The check is `effectiveStart <= previousStageStart`, so equality triggers revert.
        vm.expectRevert(abi.encodeWithSelector(REVDeployer.REVDeployer_StageTimesMustIncrease.selector));
        REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: config,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: suckerConfig,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }
}
