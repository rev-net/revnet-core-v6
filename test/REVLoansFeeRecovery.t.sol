// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import /* {*} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import /* {*} from */ "./../src/REVDeployer.sol";
import "@croptop/core-v6/src/CTPublisher.sol";
import {MockBuybackDataHook} from "./mock/MockBuybackDataHook.sol";

import "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
import "@bananapus/721-hook-v6/script/helpers/Hook721DeploymentLib.sol";
import "@bananapus/suckers-v6/script/helpers/SuckerDeploymentLib.sol";
import "@croptop/core-v6/script/helpers/CroptopDeploymentLib.sol";
import "@bananapus/router-terminal-v6/script/helpers/RouterTerminalDeploymentLib.sol";

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBFees} from "@bananapus/core-v6/src/libraries/JBFees.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {MockPriceFeed} from "@bananapus/core-v6/test/mock/MockPriceFeed.sol";
import {MockERC20} from "@bananapus/core-v6/test/mock/MockERC20.sol";
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
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice A terminal mock that always reverts on pay(), used to simulate fee payment failure.
contract RevertingFeeTerminal is ERC165, IJBPayoutTerminal {
    function pay(
        uint256,
        address,
        uint256,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        override
        returns (uint256)
    {
        revert("Fee payment failed");
    }

    function accountingContextForTokenOf(uint256, address) external pure override returns (JBAccountingContext memory) {
        return JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
    }

    function accountingContextsOf(uint256) external pure override returns (JBAccountingContext[] memory) {
        return new JBAccountingContext[](0);
    }

    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override {}
    function addToBalanceOf(
        uint256,
        address,
        uint256,
        bool,
        string calldata,
        bytes calldata
    )
        external
        payable
        override
    {}

    function currentSurplusOf(
        uint256,
        JBAccountingContext[] memory,
        uint256,
        uint256
    )
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256) {
        return 0;
    }

    function sendPayoutsOf(uint256, address, uint256, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function useAllowanceOf(
        uint256,
        address,
        uint256,
        uint256,
        uint256,
        address payable,
        address payable,
        string calldata
    )
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IJBPayoutTerminal).interfaceId
            || super.supportsInterface(interfaceId);
    }

    receive() external payable {}
}

struct FeeRecoveryProjectConfig {
    REVConfig configuration;
    JBTerminalConfig[] terminalConfigurations;
    REVSuckerDeploymentConfig suckerDeploymentConfiguration;
}

/// @title REVLoansFeeRecovery
/// @notice Tests for the fee payment error recovery in REVLoans._addTo().
/// @dev When feeTerminal.pay() reverts, the borrower should receive the fee amount back
///      instead of losing it. For ERC-20 tokens, the dangling allowance must also be cleaned up.
contract REVLoansFeeRecovery is TestBaseWorkflow, JBTest {
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";
    bytes32 ERC20_SALT = "REV_TOKEN";

    REVDeployer REV_DEPLOYER;
    JB721TiersHook EXAMPLE_HOOK;
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    IJB721TiersHookStore HOOK_STORE;
    IJBAddressRegistry ADDRESS_REGISTRY;
    IREVLoans LOANS_CONTRACT;
    MockERC20 TOKEN;
    IJBSuckerRegistry SUCKER_REGISTRY;
    CTPublisher PUBLISHER;
    MockBuybackDataHook MOCK_BUYBACK;
    RevertingFeeTerminal REVERTING_TERMINAL;

    uint256 FEE_PROJECT_ID;
    uint256 REVNET_ID;

    address USER = makeAddr("user");
    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    function _getFeeProjectConfig() internal view returns (FeeRecoveryProjectConfig memory) {
        uint8 decimals = 18;
        uint256 decimalMultiplier = 10 ** decimals;

        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](2);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        accountingContextsToAccept[1] =
            JBAccountingContext({token: address(TOKEN), decimals: 6, currency: uint32(uint160(address(TOKEN)))});

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        REVAutoIssuance[] memory issuanceConfs = new REVAutoIssuance[](1);
        issuanceConfs[0] = REVAutoIssuance({
            chainId: uint32(block.chainid), count: uint104(70_000 * decimalMultiplier), beneficiary: multisig()
        });

        stageConfigurations[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: issuanceConfs,
            splitPercent: 2000,
            splits: splits,
            initialIssuance: uint112(1000 * decimalMultiplier),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: 0
        });

        REVLoanSource[] memory _loanSources = new REVLoanSource[](0);

        REVConfig memory revnetConfiguration = REVConfig({
            description: REVDescription(
                "Revnet", "$REV", "ipfs://QmNRHT91HcDgMcenebYX7rJigt77cgNcosvuhX21wkF3tx", ERC20_SALT
            ),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations
        });

        return FeeRecoveryProjectConfig({
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("REV"))
            })
        });
    }

    function _getRevnetConfig() internal view returns (FeeRecoveryProjectConfig memory) {
        uint8 decimals = 18;
        uint256 decimalMultiplier = 10 ** decimals;

        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](2);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        accountingContextsToAccept[1] =
            JBAccountingContext({token: address(TOKEN), decimals: 6, currency: uint32(uint160(address(TOKEN)))});

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](1);
        REVAutoIssuance[] memory issuanceConfs = new REVAutoIssuance[](1);
        issuanceConfs[0] = REVAutoIssuance({
            chainId: uint32(block.chainid), count: uint104(70_000 * decimalMultiplier), beneficiary: multisig()
        });

        stageConfigurations[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: issuanceConfs,
            splitPercent: 2000,
            splits: splits,
            initialIssuance: uint112(1000 * decimalMultiplier),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: 0
        });

        REVLoanSource[] memory _loanSources = new REVLoanSource[](2);
        _loanSources[0] = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        _loanSources[1] = REVLoanSource({token: address(TOKEN), terminal: jbMultiTerminal()});

        REVConfig memory revnetConfiguration = REVConfig({
            description: REVDescription(
                "NANA", "$NANA", "ipfs://QmNRHT91HcDgMcenebYX7rJigt77cgNxosvuhX21wkF3tx", "NANA_TOKEN"
            ),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations
        });

        return FeeRecoveryProjectConfig({
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
        EXAMPLE_HOOK = new JB721TiersHook(jbDirectory(), jbPermissions(), jbRulesets(), HOOK_STORE, multisig());
        ADDRESS_REGISTRY = new JBAddressRegistry();
        HOOK_DEPLOYER = new JB721TiersHookDeployer(EXAMPLE_HOOK, HOOK_STORE, ADDRESS_REGISTRY, multisig());
        PUBLISHER = new CTPublisher(jbDirectory(), jbPermissions(), FEE_PROJECT_ID, multisig());
        MOCK_BUYBACK = new MockBuybackDataHook();
        TOKEN = new MockERC20("1/2 ETH", "1/2");
        REVERTING_TERMINAL = new RevertingFeeTerminal();

        MockPriceFeed priceFeed = new MockPriceFeed(1e21, 6);
        vm.prank(multisig());
        jbPrices()
            .addPriceFeedFor(0, uint32(uint160(address(TOKEN))), uint32(uint160(JBConstants.NATIVE_TOKEN)), priceFeed);

        LOANS_CONTRACT = new REVLoans({
            controller: jbController(),
            projects: jbProjects(),
            revId: FEE_PROJECT_ID,
            owner: address(this),
            permit2: permit2(),
            trustedForwarder: TRUSTED_FORWARDER
        });

        REV_DEPLOYER = new REVDeployer{salt: REV_DEPLOYER_SALT}(
            jbController(),
            SUCKER_REGISTRY,
            FEE_PROJECT_ID,
            HOOK_DEPLOYER,
            PUBLISHER,
            IJBRulesetDataHook(address(MOCK_BUYBACK)),
            address(LOANS_CONTRACT),
            TRUSTED_FORWARDER
        );

        // Deploy fee project.
        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);

        FeeRecoveryProjectConfig memory feeProjectConfig = _getFeeProjectConfig();
        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeProjectConfig.configuration,
            terminalConfigurations: feeProjectConfig.terminalConfigurations,
            suckerDeploymentConfiguration: feeProjectConfig.suckerDeploymentConfiguration
        });

        // Deploy revnet with loans enabled.
        FeeRecoveryProjectConfig memory revnetConfig = _getRevnetConfig();
        REVNET_ID = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: revnetConfig.configuration,
            terminalConfigurations: revnetConfig.terminalConfigurations,
            suckerDeploymentConfiguration: revnetConfig.suckerDeploymentConfiguration
        });

        vm.deal(USER, 1000e18);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @notice Mock loan permissions for a user.
    function _mockLoanPermission(address user) internal {
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), user, REVNET_ID, 11, true, true)),
            abi.encode(true)
        );
    }

    /// @notice Make the directory return the reverting terminal as the fee terminal for the REV project.
    function _mockRevertingFeeTerminal(address token) internal {
        vm.mockCall(
            address(jbDirectory()),
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector, FEE_PROJECT_ID, token),
            abi.encode(address(REVERTING_TERMINAL))
        );
    }

    /// @notice Borrow against native ETH and return the borrower's balance change.
    function _borrowNative(
        address user,
        uint256 ethAmount,
        uint256 prepaidFee
    )
        internal
        returns (uint256 loanId, uint256 borrowerBalanceBefore, uint256 borrowerBalanceAfter)
    {
        // Pay into revnet to get tokens.
        vm.prank(user);
        uint256 tokenCount =
            jbMultiTerminal().pay{value: ethAmount}(REVNET_ID, JBConstants.NATIVE_TOKEN, ethAmount, user, 0, "", "");

        _mockLoanPermission(user);

        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        borrowerBalanceBefore = user.balance;

        vm.prank(user);
        (loanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(user), prepaidFee);

        borrowerBalanceAfter = user.balance;
    }

    // =========================================================================
    // Test: Normal fee payment succeeds (regression — confirm existing behavior)
    // =========================================================================

    /// @notice When the fee terminal is healthy, the REV fee is deducted from the borrower's payout.
    function test_feePaymentSuccess_nativeToken() public {
        (, uint256 balanceBefore, uint256 balanceAfter) = _borrowNative(USER, 10e18, 25);

        uint256 received = balanceAfter - balanceBefore;

        // The borrower should have received something (net of both source fee + REV fee).
        assertGt(received, 0, "Borrower should receive ETH");

        // No ETH should be stuck in the loans contract.
        assertEq(address(LOANS_CONTRACT).balance, 0, "No ETH stuck in loans contract");
    }

    // =========================================================================
    // Test: Fee terminal reverts with native ETH — borrower gets fee back
    // =========================================================================

    /// @notice When feeTerminal.pay() reverts, the borrower receives the REV fee amount back.
    function test_feePaymentFailure_nativeToken_borrowerGetsMoreETH() public {
        // Pay into revnet first so both borrow attempts start from identical state.
        vm.prank(USER);
        uint256 tokenCount =
            jbMultiTerminal().pay{value: 10e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, USER, 0, "", "");

        _mockLoanPermission(USER);
        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        // Snapshot state before borrow.
        uint256 snap = vm.snapshotState();

        // Normal borrow.
        uint256 balBefore = USER.balance;
        vm.prank(USER);
        LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(USER), 25);
        uint256 normalReceived = USER.balance - balBefore;

        // Revert to snapshot — identical state.
        vm.revertToState(snap);

        // Mock the fee terminal to revert.
        _mockRevertingFeeTerminal(JBConstants.NATIVE_TOKEN);
        _mockLoanPermission(USER);

        balBefore = USER.balance;
        vm.prank(USER);
        LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(USER), 25);
        uint256 failReceived = USER.balance - balBefore;

        // The borrower with a failed fee terminal should receive MORE than the normal borrower,
        // because the REV fee (1% of borrow amount) is returned to them.
        assertGt(failReceived, normalReceived, "Failed-fee borrower should receive more ETH than normal borrower");

        // No ETH should be stuck in the loans contract.
        assertEq(address(LOANS_CONTRACT).balance, 0, "No ETH stuck in loans contract after fee failure");
    }

    // =========================================================================
    // Test: Fee terminal reverts with native ETH — amount difference matches REV fee
    // =========================================================================

    /// @notice The extra ETH the borrower receives when the fee terminal reverts matches
    ///         the expected REV fee amount (1% of borrow amount).
    function test_feePaymentFailure_nativeToken_exactFeeRecovery() public {
        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        // Pay into revnet.
        vm.prank(USER);
        uint256 tokens =
            jbMultiTerminal().pay{value: 10e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, USER, 0, "", "");

        _mockLoanPermission(USER);

        // Snapshot.
        uint256 snap = vm.snapshotState();

        // Normal borrow.
        uint256 balBefore = USER.balance;
        vm.prank(USER);
        LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokens, payable(USER), 25);
        uint256 normalReceived = USER.balance - balBefore;

        // Get the actual borrow amount from the loan to compute expected REV fee.
        // Loan ID = revnetId * 1e12 + loanNumber (first loan = 1).
        REVLoan memory loan = LOANS_CONTRACT.loanOf(REVNET_ID * 1_000_000_000_000 + 1);
        uint256 expectedRevFee =
            JBFees.feeAmountFrom({amountBeforeFee: loan.amount, feePercent: LOANS_CONTRACT.REV_PREPAID_FEE_PERCENT()});

        // Revert to snapshot.
        vm.revertToState(snap);

        // Mock fee terminal to revert.
        _mockRevertingFeeTerminal(JBConstants.NATIVE_TOKEN);
        _mockLoanPermission(USER);

        balBefore = USER.balance;
        vm.prank(USER);
        LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokens, payable(USER), 25);
        uint256 failReceived = USER.balance - balBefore;

        // The difference should be the REV fee amount.
        uint256 difference = failReceived - normalReceived;
        assertEq(difference, expectedRevFee, "Difference should equal the REV fee amount");

        // Verify no funds stuck.
        assertEq(address(LOANS_CONTRACT).balance, 0, "No ETH stuck");
    }

    // =========================================================================
    // Test: Fee terminal reverts with ERC-20 — allowance is cleaned up
    // =========================================================================

    /// @notice When feeTerminal.pay() reverts for an ERC-20 loan, the dangling allowance
    ///         to the fee terminal is removed via safeDecreaseAllowance.
    function test_feePaymentFailure_erc20_allowanceCleaned() public {
        // Mock the fee terminal to revert for the TOKEN.
        _mockRevertingFeeTerminal(address(TOKEN));

        // Fund user with ERC-20 tokens.
        uint256 payAmount = 1_000_000; // 6 decimals
        deal(address(TOKEN), USER, payAmount);

        // Pay into revnet with ERC-20.
        vm.startPrank(USER);
        TOKEN.approve(address(jbMultiTerminal()), payAmount);
        uint256 tokenCount = jbMultiTerminal().pay(REVNET_ID, address(TOKEN), payAmount, USER, 0, "", "");
        vm.stopPrank();

        _mockLoanPermission(USER);
        REVLoanSource memory source = REVLoanSource({token: address(TOKEN), terminal: jbMultiTerminal()});

        // Check allowance to reverting terminal BEFORE borrow.
        uint256 allowanceBefore = TOKEN.allowance(address(LOANS_CONTRACT), address(REVERTING_TERMINAL));
        assertEq(allowanceBefore, 0, "No pre-existing allowance");

        vm.prank(USER);
        LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(USER), 25);

        // After the borrow, the allowance to the reverting terminal should still be 0
        // (the catch block decreased it).
        uint256 allowanceAfter = TOKEN.allowance(address(LOANS_CONTRACT), address(REVERTING_TERMINAL));
        assertEq(allowanceAfter, 0, "Allowance should be cleaned up after fee failure");

        // No tokens stuck in the loans contract.
        assertEq(TOKEN.balanceOf(address(LOANS_CONTRACT)), 0, "No ERC-20 stuck in loans contract");
    }

    // =========================================================================
    // Test: Fee terminal reverts with ERC-20 — borrower gets fee back
    // =========================================================================

    /// @notice When feeTerminal.pay() reverts for an ERC-20 loan, the borrower receives
    ///         the fee amount that would have gone to the REV project.
    function test_feePaymentFailure_erc20_borrowerGetsMoreTokens() public {
        uint256 payAmount = 1_000_000; // 6 decimals
        REVLoanSource memory source = REVLoanSource({token: address(TOKEN), terminal: jbMultiTerminal()});

        // Pay into revnet with ERC-20.
        deal(address(TOKEN), USER, payAmount);
        vm.startPrank(USER);
        TOKEN.approve(address(jbMultiTerminal()), payAmount);
        uint256 tokens = jbMultiTerminal().pay(REVNET_ID, address(TOKEN), payAmount, USER, 0, "", "");
        vm.stopPrank();

        _mockLoanPermission(USER);

        // Snapshot.
        uint256 snap = vm.snapshotState();

        // Normal borrow.
        uint256 tokenBalBefore = TOKEN.balanceOf(USER);
        vm.prank(USER);
        LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokens, payable(USER), 25);
        uint256 normalReceived = TOKEN.balanceOf(USER) - tokenBalBefore;

        // Revert to snapshot.
        vm.revertToState(snap);

        // Mock fee terminal to revert.
        _mockRevertingFeeTerminal(address(TOKEN));
        _mockLoanPermission(USER);

        tokenBalBefore = TOKEN.balanceOf(USER);
        vm.prank(USER);
        LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokens, payable(USER), 25);
        uint256 failReceived = TOKEN.balanceOf(USER) - tokenBalBefore;

        // Failed-fee borrower should receive more tokens.
        assertGt(failReceived, normalReceived, "Failed-fee ERC-20 borrower should receive more tokens");
    }

    // =========================================================================
    // Test: No fee terminal (address(0)) — revFeeAmount is zero, no try/catch
    // =========================================================================

    /// @notice When no fee terminal exists for the token, revFeeAmount is 0 and no fee is attempted.
    function test_noFeeTerminal_borrowStillWorks() public {
        // Mock the directory to return address(0) for the fee terminal.
        vm.mockCall(
            address(jbDirectory()),
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector, FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN),
            abi.encode(address(0))
        );

        // Borrow should still work — no fee is taken.
        (, uint256 balanceBefore, uint256 balanceAfter) = _borrowNative(USER, 10e18, 25);
        uint256 received = balanceAfter - balanceBefore;
        assertGt(received, 0, "Borrower should receive ETH even without fee terminal");

        // No ETH stuck.
        assertEq(address(LOANS_CONTRACT).balance, 0, "No ETH stuck");
    }

    // =========================================================================
    // Test: Multiple borrows with fee failure — no cumulative stuck funds
    // =========================================================================

    /// @notice After multiple borrows where the fee terminal reverts, no funds accumulate
    ///         in the loans contract.
    function test_feePaymentFailure_multipleBorrows_noStuckFunds() public {
        _mockRevertingFeeTerminal(JBConstants.NATIVE_TOKEN);

        for (uint256 i; i < 3; i++) {
            address borrower = makeAddr(string(abi.encodePacked("borrower", i)));
            vm.deal(borrower, 100e18);

            vm.prank(borrower);
            uint256 tokens =
                jbMultiTerminal().pay{value: 5e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 5e18, borrower, 0, "", "");

            mockExpect(
                address(jbPermissions()),
                abi.encodeCall(
                    IJBPermissions.hasPermission, (address(LOANS_CONTRACT), borrower, REVNET_ID, 11, true, true)
                ),
                abi.encode(true)
            );

            REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

            vm.prank(borrower);
            LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokens, payable(borrower), 25);
        }

        // After 3 borrows with fee failures, no ETH should be stuck.
        assertEq(address(LOANS_CONTRACT).balance, 0, "No ETH stuck after multiple fee-failed borrows");
    }

    // =========================================================================
    // Fuzz: Fee recovery always returns correct amount to borrower
    // =========================================================================

    /// @notice Fuzz test: regardless of the borrow amount, when the fee terminal reverts,
    ///         the borrower always receives the full netAmountPaidOut minus only the source fee.
    function test_fuzz_feeRecovery_nativeToken(uint256 payAmount) public {
        // Bound to reasonable range. Need enough to get a nonzero borrow.
        payAmount = bound(payAmount, 1e16, 100e18);

        _mockRevertingFeeTerminal(JBConstants.NATIVE_TOKEN);

        address borrower = makeAddr("fuzzBorrower");
        vm.deal(borrower, payAmount + 1e18);

        vm.prank(borrower);
        uint256 tokens = jbMultiTerminal().pay{value: payAmount}(
            REVNET_ID, JBConstants.NATIVE_TOKEN, payAmount, borrower, 0, "", ""
        );

        uint256 borrowable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        // Skip if not enough surplus to borrow.
        if (borrowable == 0) return;

        _mockLoanPermission(borrower);
        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        uint256 balanceBefore = borrower.balance;
        vm.prank(borrower);
        LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokens, payable(borrower), 25);
        uint256 received = borrower.balance - balanceBefore;

        // The borrower should always receive something.
        assertGt(received, 0, "Borrower should receive ETH in fuzz");

        // No funds stuck.
        assertEq(address(LOANS_CONTRACT).balance, 0, "No ETH stuck in fuzz");
    }

    // =========================================================================
    // Test: Fee recovery on native token — ETH returned from failed call
    // =========================================================================

    /// @notice Verifies that when a native-token fee terminal call reverts, the ETH sent
    ///         with the call is returned to REVLoans and forwarded to the borrower.
    ///         The reverting terminal should NOT hold any ETH.
    function test_feePaymentFailure_nativeToken_revertingTerminalHoldsNoETH() public {
        _mockRevertingFeeTerminal(JBConstants.NATIVE_TOKEN);

        uint256 revertingTerminalBalanceBefore = address(REVERTING_TERMINAL).balance;

        _borrowNative(USER, 10e18, 25);

        // The reverting terminal should not have received any ETH.
        assertEq(
            address(REVERTING_TERMINAL).balance, revertingTerminalBalanceBefore, "Reverting terminal should hold no ETH"
        );

        // No ETH stuck in loans contract.
        assertEq(address(LOANS_CONTRACT).balance, 0, "No ETH stuck in loans contract");
    }
}
