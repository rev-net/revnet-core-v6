// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "./../src/REVDeployer.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@croptop/core-v6/src/CTPublisher.sol";
import {MockBuybackDataHook} from "./mock/MockBuybackDataHook.sol";

// forge-lint: disable-next-line(unaliased-plain-import)
import "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@bananapus/721-hook-v6/script/helpers/Hook721DeploymentLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@bananapus/suckers-v6/script/helpers/SuckerDeploymentLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@croptop/core-v6/script/helpers/CroptopDeploymentLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@bananapus/router-terminal-v6/script/helpers/RouterTerminalDeploymentLib.sol";

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {REVLoans} from "../src/REVLoans.sol";
import {REVLoan} from "../src/structs/REVLoan.sol";
import {REVStageConfig, REVAutoIssuance} from "../src/structs/REVStageConfig.sol";
import {REVLoanSource} from "../src/structs/REVLoanSource.sol";
import {REVDescription} from "../src/structs/REVDescription.sol";
import {IREVLoans} from "./../src/interfaces/IREVLoans.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {REVEmpty721Config} from "./helpers/REVEmpty721Config.sol";
import {REVOwner} from "../src/REVOwner.sol";
import {IREVDeployer} from "../src/interfaces/IREVDeployer.sol";

struct SourceFeeProjectConfig {
    REVConfig configuration;
    JBTerminalConfig[] terminalConfigurations;
    REVSuckerDeploymentConfig suckerDeploymentConfiguration;
}

/// @title REVLoansSourceFeeRecovery
/// @notice Tests for the source fee try-catch in REVLoans._adjust().
/// @dev When loan.source.terminal.pay() reverts during source fee payment, the borrower
///      should receive the source fee amount back instead of losing it.
contract REVLoansSourceFeeRecovery is TestBaseWorkflow {
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 ERC20_SALT = "REV_TOKEN";

    // forge-lint: disable-next-line(mixed-case-variable)
    REVDeployer REV_DEPLOYER;
    // forge-lint: disable-next-line(mixed-case-variable)
    REVOwner REV_OWNER;
    // forge-lint: disable-next-line(mixed-case-variable)
    JB721TiersHook EXAMPLE_HOOK;
    // forge-lint: disable-next-line(mixed-case-variable)
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    // forge-lint: disable-next-line(mixed-case-variable)
    IJB721TiersHookStore HOOK_STORE;
    // forge-lint: disable-next-line(mixed-case-variable)
    IJBAddressRegistry ADDRESS_REGISTRY;
    // forge-lint: disable-next-line(mixed-case-variable)
    IREVLoans LOANS_CONTRACT;
    // forge-lint: disable-next-line(mixed-case-variable)
    IJBSuckerRegistry SUCKER_REGISTRY;
    // forge-lint: disable-next-line(mixed-case-variable)
    CTPublisher PUBLISHER;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockBuybackDataHook MOCK_BUYBACK;

    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 FEE_PROJECT_ID;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 REVNET_ID;

    // forge-lint: disable-next-line(mixed-case-variable)
    address USER = makeAddr("user");
    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    function _getFeeProjectConfig() internal view returns (SourceFeeProjectConfig memory) {
        uint8 decimals = 18;
        uint256 decimalMultiplier = 10 ** decimals;

        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](1);
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

        stageConfigurations[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
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

        REVConfig memory revnetConfiguration = REVConfig({
            description: REVDescription({
                name: "Revnet",
                ticker: "$REV",
                uri: "ipfs://QmNRHT91HcDgMcenebYX7rJigt77cgNcosvuhX21wkF3tx",
                salt: ERC20_SALT
            }),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations
        });

        return SourceFeeProjectConfig({
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("REV"))
            })
        });
    }

    function _getRevnetConfig() internal view returns (SourceFeeProjectConfig memory) {
        uint8 decimals = 18;
        uint256 decimalMultiplier = 10 ** decimals;

        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](1);
        REVAutoIssuance[] memory issuanceConfs = new REVAutoIssuance[](1);
        issuanceConfs[0] = REVAutoIssuance({
            // forge-lint: disable-next-line(unsafe-typecast)
            chainId: uint32(block.chainid),
            // forge-lint: disable-next-line(unsafe-typecast)
            count: uint104(70_000 * decimalMultiplier),
            beneficiary: multisig()
        });

        stageConfigurations[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
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

        REVLoanSource[] memory _loanSources = new REVLoanSource[](1);
        _loanSources[0] = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        REVConfig memory revnetConfiguration = REVConfig({
            description: REVDescription({
                name: "NANA",
                ticker: "$NANA",
                uri: "ipfs://QmNRHT91HcDgMcenebYX7rJigt77cgNxosvuhX21wkF3tx",
                salt: "NANA_TOKEN"
            }),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations
        });

        return SourceFeeProjectConfig({
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("NANA"))
            })
        });
    }

    function setUp() public override {
        super.setUp();

        FEE_PROJECT_ID = jbProjects().createFor(multisig());

        SUCKER_REGISTRY = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig(), address(0));
        HOOK_STORE = new JB721TiersHookStore();
        EXAMPLE_HOOK = new JB721TiersHook(
            jbDirectory(), jbPermissions(), jbPrices(), jbRulesets(), HOOK_STORE, jbSplits(), multisig()
        );
        ADDRESS_REGISTRY = new JBAddressRegistry();
        HOOK_DEPLOYER = new JB721TiersHookDeployer(EXAMPLE_HOOK, HOOK_STORE, ADDRESS_REGISTRY, multisig());
        PUBLISHER = new CTPublisher(jbDirectory(), jbPermissions(), FEE_PROJECT_ID, multisig());
        MOCK_BUYBACK = new MockBuybackDataHook();

        LOANS_CONTRACT = new REVLoans({
            controller: jbController(),
            projects: jbProjects(),
            revId: FEE_PROJECT_ID,
            owner: address(this),
            permit2: permit2(),
            trustedForwarder: TRUSTED_FORWARDER
        });

        REV_OWNER = new REVOwner(
            IJBBuybackHookRegistry(address(MOCK_BUYBACK)),
            jbDirectory(),
            FEE_PROJECT_ID,
            SUCKER_REGISTRY,
            address(LOANS_CONTRACT),
            address(0)
        );

        REV_DEPLOYER = new REVDeployer{salt: REV_DEPLOYER_SALT}(
            jbController(),
            SUCKER_REGISTRY,
            FEE_PROJECT_ID,
            HOOK_DEPLOYER,
            PUBLISHER,
            IJBBuybackHookRegistry(address(MOCK_BUYBACK)),
            address(LOANS_CONTRACT),
            TRUSTED_FORWARDER,
            address(REV_OWNER)
        );

        REV_OWNER.setDeployer(REV_DEPLOYER);

        // Deploy fee project.
        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);

        SourceFeeProjectConfig memory feeProjectConfig = _getFeeProjectConfig();
        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeProjectConfig.configuration,
            terminalConfigurations: feeProjectConfig.terminalConfigurations,
            suckerDeploymentConfiguration: feeProjectConfig.suckerDeploymentConfiguration,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        // Deploy revnet with loans enabled.
        SourceFeeProjectConfig memory revnetConfig = _getRevnetConfig();
        (REVNET_ID,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: revnetConfig.configuration,
            terminalConfigurations: revnetConfig.terminalConfigurations,
            suckerDeploymentConfiguration: revnetConfig.suckerDeploymentConfiguration,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        vm.deal(USER, 1000e18);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _mockLoanPermission(address user) internal {
        // Use vm.mockCall (not mockExpect) to avoid enforcing call counts — repay doesn't always
        // trigger a permission check, but borrow does.
        vm.mockCall(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), user, REVNET_ID, 11, true, true)),
            abi.encode(true)
        );
    }

    function _borrowLoan(address user, uint256 ethAmount) internal returns (uint256 loanId, uint256 tokenCount) {
        vm.prank(user);
        tokenCount =
            jbMultiTerminal().pay{value: ethAmount}(REVNET_ID, JBConstants.NATIVE_TOKEN, ethAmount, user, 0, "", "");

        _mockLoanPermission(user);
        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        vm.prank(user);
        (loanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(user), 25);
    }

    // =========================================================================
    // Test: Source fee try-catch during repay — terminal pay reverts
    // =========================================================================

    /// @notice When the source terminal's pay() reverts during repay, the source fee is returned
    ///         to the borrower and the repayment still succeeds.
    function test_sourceFeeRecovery_repay_nativeToken() public {
        // Step 1: Borrow normally.
        (uint256 loanId,) = _borrowLoan(USER, 10e18);

        // Step 2: Read the loan to get prepaid duration.
        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);

        // Step 3: Warp past the prepaid duration so the source fee accrues.
        vm.warp(block.timestamp + loan.prepaidDuration + 30 days);

        // Step 4: Mock the source terminal's pay() to revert.
        // This affects only `pay` calls, not `addToBalanceOf` (used by _removeFrom).
        vm.mockCallRevert(
            address(jbMultiTerminal()), abi.encodeWithSelector(IJBTerminal.pay.selector), "Source fee terminal failed"
        );

        // Step 5: Repay the full loan. The source fee try-catch should handle the reverting terminal.
        uint256 repayAmount = loan.amount * 2; // Send more than enough to cover loan + fee.
        vm.deal(USER, repayAmount);

        vm.prank(USER);
        LOANS_CONTRACT.repayLoan{value: repayAmount}({
            loanId: loanId,
            maxRepayBorrowAmount: repayAmount,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(USER),
            allowance: JBSingleAllowance({amount: 0, expiration: 0, nonce: 0, sigDeadline: 0, signature: ""})
        });

        // Repay succeeded — the loan should be closed.
        REVLoan memory postRepay = LOANS_CONTRACT.loanOf(loanId);
        assertEq(postRepay.createdAt, 0, "Loan should be cleared after repay");

        // No ETH stuck in loans contract.
        assertEq(address(LOANS_CONTRACT).balance, 0, "No ETH stuck in loans contract");
    }

    /// @notice When the source terminal's pay() works normally during repay, the source fee is
    ///         deducted as expected (regression to confirm baseline).
    function test_sourceFeePayment_repay_normalOperation() public {
        // Borrow normally.
        (uint256 loanId,) = _borrowLoan(USER, 10e18);

        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);

        // Warp past prepaid duration.
        vm.warp(block.timestamp + loan.prepaidDuration + 30 days);

        // Repay normally (no mocking — terminal pay should succeed).
        uint256 repayAmount = loan.amount * 2;
        vm.deal(USER, repayAmount);

        vm.prank(USER);
        LOANS_CONTRACT.repayLoan{value: repayAmount}({
            loanId: loanId,
            maxRepayBorrowAmount: repayAmount,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(USER),
            allowance: JBSingleAllowance({amount: 0, expiration: 0, nonce: 0, sigDeadline: 0, signature: ""})
        });

        // Loan closed.
        REVLoan memory postRepay = LOANS_CONTRACT.loanOf(loanId);
        assertEq(postRepay.createdAt, 0, "Loan should be cleared after normal repay");

        // No ETH stuck.
        assertEq(address(LOANS_CONTRACT).balance, 0, "No ETH stuck");
    }

    /// @notice When the source terminal reverts, the borrower receives more ETH back than when
    ///         it succeeds, because the source fee is returned to them.
    function test_sourceFeeRecovery_borrowerGetsMoreThanNormal() public {
        // Borrow a loan.
        (uint256 loanId,) = _borrowLoan(USER, 10e18);

        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);

        // Warp past prepaid duration.
        vm.warp(block.timestamp + loan.prepaidDuration + 30 days);

        // Compute the expected source fee.
        uint256 sourceFee = LOANS_CONTRACT.determineSourceFeeAmount(loan, loan.amount);
        assertGt(sourceFee, 0, "Source fee should be nonzero after prepaid duration");

        // Snapshot state to compare normal vs. failed scenarios.
        uint256 snap = vm.snapshotState();

        // --- Normal repay ---
        uint256 repayAmount = loan.amount * 2;
        vm.deal(USER, repayAmount);

        uint256 balBefore = USER.balance;
        vm.prank(USER);
        LOANS_CONTRACT.repayLoan{value: repayAmount}({
            loanId: loanId,
            maxRepayBorrowAmount: repayAmount,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(USER),
            allowance: JBSingleAllowance({amount: 0, expiration: 0, nonce: 0, sigDeadline: 0, signature: ""})
        });
        uint256 normalBalance = USER.balance;

        // --- Revert and try with failing terminal ---
        vm.revertToState(snap);

        vm.mockCallRevert(
            address(jbMultiTerminal()), abi.encodeWithSelector(IJBTerminal.pay.selector), "Source fee terminal failed"
        );

        vm.deal(USER, repayAmount);

        balBefore = USER.balance;
        vm.prank(USER);
        LOANS_CONTRACT.repayLoan{value: repayAmount}({
            loanId: loanId,
            maxRepayBorrowAmount: repayAmount,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(USER),
            allowance: JBSingleAllowance({amount: 0, expiration: 0, nonce: 0, sigDeadline: 0, signature: ""})
        });
        uint256 failBalance = USER.balance;

        // The borrower should have more ETH when the source fee terminal fails,
        // because the source fee is returned to them instead of being paid.
        assertGt(failBalance, normalBalance, "Borrower should receive more when source fee terminal fails");
    }

    /// @notice Source fee is zero during the prepaid window — no try-catch path is hit.
    function test_noSourceFeeDuringPrepaidWindow() public {
        (uint256 loanId,) = _borrowLoan(USER, 10e18);

        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);

        // Stay within prepaid duration — no source fee accrues.
        vm.warp(block.timestamp + loan.prepaidDuration / 2);

        uint256 sourceFee = LOANS_CONTRACT.determineSourceFeeAmount(loan, loan.amount);
        assertEq(sourceFee, 0, "No source fee during prepaid window");

        // Repay during prepaid window.
        uint256 repayAmount = loan.amount * 2;
        vm.deal(USER, repayAmount);

        vm.prank(USER);
        LOANS_CONTRACT.repayLoan{value: repayAmount}({
            loanId: loanId,
            maxRepayBorrowAmount: repayAmount,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(USER),
            allowance: JBSingleAllowance({amount: 0, expiration: 0, nonce: 0, sigDeadline: 0, signature: ""})
        });

        REVLoan memory postRepay = LOANS_CONTRACT.loanOf(loanId);
        assertEq(postRepay.createdAt, 0, "Loan should be cleared");
        assertEq(address(LOANS_CONTRACT).balance, 0, "No ETH stuck");
    }

    /// @notice The source fee try-catch during initial borrow (prepaid source fee) also recovers
    ///         gracefully when the source terminal reverts.
    function test_sourceFeeRecovery_initialBorrow() public {
        // Pay into the revnet first.
        vm.prank(USER);
        uint256 tokenCount =
            jbMultiTerminal().pay{value: 10e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, USER, 0, "", "");

        // Now mock the source terminal's pay to revert (for source fee payment).
        // This will also cause the REV fee payment to fail (same terminal), but both are try-caught.
        vm.mockCallRevert(
            address(jbMultiTerminal()), abi.encodeWithSelector(IJBTerminal.pay.selector), "Terminal pay failed"
        );

        _mockLoanPermission(USER);
        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        uint256 balBefore = USER.balance;
        vm.prank(USER);
        LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(USER), 25);

        uint256 received = USER.balance - balBefore;
        assertGt(received, 0, "Borrower should receive ETH even when source fee terminal fails");

        // No ETH stuck.
        assertEq(address(LOANS_CONTRACT).balance, 0, "No ETH stuck in loans contract");
    }
}
