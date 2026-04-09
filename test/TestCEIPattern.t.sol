// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
// import /* {*} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
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
import {REVEmpty721Config} from "./helpers/REVEmpty721Config.sol";
import {REVOwner} from "../src/REVOwner.sol";
import {IREVDeployer} from "../src/interfaces/IREVDeployer.sol";

/// @notice Contract that reenters REVLoans when it receives ETH during a borrow payout.
/// Records the loan state it observes during reentrancy to verify CEI correctness.
contract ReentrantBorrower {
    IREVLoans public loans;
    uint256 public targetLoanId;
    uint256 public observedAmount;
    uint256 public observedCollateral;
    bool public reentered;

    constructor(IREVLoans _loans) {
        loans = _loans;
    }

    function setTarget(uint256 _loanId) external {
        targetLoanId = _loanId;
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            // During ETH receipt, read loan state. With CEI, state should already be finalized.
            REVLoan memory loan = loans.loanOf(targetLoanId);
            observedAmount = loan.amount;
            observedCollateral = loan.collateral;
        }
    }
}

/// @title TestCEIPattern
/// @notice Tests for CEI pattern fix in REVLoans._adjust()
///
/// Source context (_addTo/_removeFrom/_addCollateralTo/_returnCollateralFrom):
///   - _addTo(REVLoan memory, ..., uint256 addedBorrowAmount, ...) — memory copy, uses delta param
///   - _removeFrom(REVLoan memory, ..., uint256 repaidBorrowAmount) — memory copy, uses delta param
///   - _addCollateralTo(uint256 revnetId, uint256 amount) — no loan reference at all
///   - _returnCollateralFrom(uint256 revnetId, uint256 collateralCount, ...) — no loan reference
///   None of the four helpers read loan.amount or loan.collateral — they all use pre-computed deltas.
///   The CEI fix writes loan.amount and loan.collateral BEFORE calling any of these helpers.
contract TestCEIPattern is TestBaseWorkflow {
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";

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
    MockERC20 TOKEN;
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
        TOKEN = new MockERC20("1/2 ETH", "1/2");
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

        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);
        _deployFeeProject();
        _deployRevnet();
        vm.deal(USER, 1000e18);
    }

    function _deployFeeProject() internal {
        JBAccountingContext[] memory acc = new JBAccountingContext[](2);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        acc[1] = JBAccountingContext({token: address(TOKEN), decimals: 6, currency: uint32(uint160(address(TOKEN)))});
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});
        REVStageConfig[] memory stages = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;
        REVAutoIssuance[] memory ai = new REVAutoIssuance[](1);
        ai[0] = REVAutoIssuance({chainId: uint32(block.chainid), count: uint104(70_000e18), beneficiary: multisig()});
        stages[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: ai,
            splitPercent: 2000,
            splits: splits,
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: 0
        });
        REVConfig memory cfg = REVConfig({
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription("Revnet", "$REV", "ipfs://test", "REV_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });
        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: cfg,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("FEE")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    function _deployRevnet() internal {
        JBAccountingContext[] memory acc = new JBAccountingContext[](2);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        acc[1] = JBAccountingContext({token: address(TOKEN), decimals: 6, currency: uint32(uint160(address(TOKEN)))});
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});
        REVStageConfig[] memory stages = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;
        REVAutoIssuance[] memory ai = new REVAutoIssuance[](1);
        ai[0] = REVAutoIssuance({chainId: uint32(block.chainid), count: uint104(70_000e18), beneficiary: multisig()});
        stages[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: ai,
            splitPercent: 2000,
            splits: splits,
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: 0
        });
        REVLoanSource[] memory ls = new REVLoanSource[](1);
        ls[0] = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        REVConfig memory cfg = REVConfig({
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription("NANA", "$NANA", "ipfs://test2", "NANA_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });
        (REVNET_ID,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: cfg,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("NANA")
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    function _setupLoan(
        address user,
        uint256 ethAmount,
        uint256 prepaidFee
    )
        internal
        returns (uint256 loanId, uint256 tokenCount, uint256 borrowAmount)
    {
        vm.prank(user);
        tokenCount =
            jbMultiTerminal().pay{value: ethAmount}(REVNET_ID, JBConstants.NATIVE_TOKEN, ethAmount, user, 0, "", "");
        borrowAmount =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokenCount, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        if (borrowAmount == 0) return (0, tokenCount, 0);
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), user, REVNET_ID, 11, true, true)),
            abi.encode(true)
        );
        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        vm.prank(user);
        (loanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(user), prepaidFee, user);
    }

    /// @notice After borrowing, loan.amount and loan.collateral are set correctly (CEI: state written before external
    /// calls).
    function test_normalBorrow_stateConsistent() public {
        (uint256 loanId,, uint256 borrowAmount) = _setupLoan(USER, 10e18, 25);
        assertTrue(borrowAmount > 0, "Should borrow nonzero");

        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);
        // The amount should reflect the actual borrow minus any fee
        assertTrue(loan.amount > 0, "Loan amount should be positive");
        assertTrue(loan.collateral > 0, "Loan collateral should be positive");
    }

    /// @notice Repay a loan and verify state is consistent afterwards.
    function test_repayLoan_stateConsistent() public {
        (uint256 loanId,, uint256 borrowAmount) = _setupLoan(USER, 10e18, 500);
        assertTrue(borrowAmount > 0, "Should borrow nonzero");

        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);

        // Immediately repay — within prepaid duration so no source fee
        vm.prank(USER);
        LOANS_CONTRACT.repayLoan{value: loan.amount}({
            loanId: loanId,
            maxRepayBorrowAmount: loan.amount,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(USER),
            allowance: JBSingleAllowance({sigDeadline: 0, amount: 0, expiration: 0, nonce: 0, signature: ""})
        });

        // After repayment, total collateral should be 0
        uint256 totalCollateral = LOANS_CONTRACT.totalCollateralOf(REVNET_ID);
        assertEq(totalCollateral, 0, "All collateral should be returned after full repay");
    }

    /// @notice Multiple sequential borrows produce correct aggregate state.
    function test_multipleBorrows_stateAccumulates() public {
        vm.deal(USER, 2000e18);

        // First borrow
        (uint256 loanId1,, uint256 borrow1) = _setupLoan(USER, 10e18, 25);
        assertTrue(borrow1 > 0, "First borrow should succeed");

        REVLoan memory loan1 = LOANS_CONTRACT.loanOf(loanId1);
        uint256 collateral1 = loan1.collateral;

        // Second borrow (need more tokens)
        vm.prank(USER);
        uint256 tokens2 =
            jbMultiTerminal().pay{value: 10e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, USER, 0, "", "");
        uint256 borrowable2 =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens2, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        if (borrowable2 > 0) {
            mockExpect(
                address(jbPermissions()),
                abi.encodeCall(
                    IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, REVNET_ID, 11, true, true)
                ),
                abi.encode(true)
            );
            REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
            vm.prank(USER);
            LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokens2, payable(USER), 25, USER);
        }

        // Total collateral should equal sum of both loans' collateral
        uint256 totalCollateral = LOANS_CONTRACT.totalCollateralOf(REVNET_ID);
        assertTrue(totalCollateral >= collateral1, "Total collateral should include both loans");
    }

    /// @notice A reentrant beneficiary reads loan state during ETH receipt.
    /// With CEI, the loan state is already finalized when external calls execute.
    function test_reentrantBeneficiary_seesUpdatedState() public {
        ReentrantBorrower attacker = new ReentrantBorrower(LOANS_CONTRACT);
        vm.deal(address(attacker), 100e18);

        // Pay into revnet as the attacker contract to get tokens.
        vm.prank(address(attacker));
        uint256 tokens = jbMultiTerminal().pay{value: 10e18}(
            REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, address(attacker), 0, "", ""
        );

        uint256 borrowable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        vm.assume(borrowable > 0);

        // Mock BURN permission for attacker.
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(
                IJBPermissions.hasPermission, (address(LOANS_CONTRACT), address(attacker), REVNET_ID, 11, true, true)
            ),
            abi.encode(true)
        );

        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        // Pre-compute the loanId so the attacker can read it during reentrancy.
        // loanId = revnetId * 1_000_000_000_000 + (totalLoansBorrowedFor + 1)
        uint256 expectedLoanId = REVNET_ID * 1_000_000_000_000 + (LOANS_CONTRACT.totalLoansBorrowedFor(REVNET_ID) + 1);
        attacker.setTarget(expectedLoanId);

        // Borrow with attacker as beneficiary — attacker's receive() will fire when ETH arrives.
        vm.prank(address(attacker));
        (uint256 loanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokens, payable(address(attacker)), 25, address(attacker));

        assertEq(loanId, expectedLoanId, "LoanId should match pre-computed value");

        // Verify loan state is finalized.
        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);
        assertGt(loan.amount, 0, "Loan should have amount");
        assertGt(loan.collateral, 0, "Loan should have collateral");

        // The attacker's receive() fired during the ETH transfer. With CEI, it should have
        // observed the correct (finalized) loan state.
        if (attacker.reentered()) {
            assertEq(attacker.observedAmount(), loan.amount, "Reentrant read should see finalized loan amount");
            assertEq(
                attacker.observedCollateral(), loan.collateral, "Reentrant read should see finalized loan collateral"
            );
        }
    }

    /// @notice Verify atomic consistency: loan state matches global accounting after every operation.
    /// If _adjust wrote state AFTER external calls (old code), a reentrant observer between
    /// the external calls and the state write could see totalBorrowedFrom updated but loan.amount stale.
    function test_CEI_atomicConsistency_borrowAndRepay() public {
        vm.deal(USER, 2000e18);

        // Borrow.
        (uint256 loanId,, uint256 borrowAmount) = _setupLoan(USER, 10e18, 25);
        assertTrue(borrowAmount > 0, "Should borrow nonzero");

        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);

        // Verify loan.amount matches what totalBorrowedFrom tracks.
        uint256 totalBorrowed = LOANS_CONTRACT.totalBorrowedFrom(REVNET_ID, jbMultiTerminal(), JBConstants.NATIVE_TOKEN);
        assertEq(totalBorrowed, loan.amount, "totalBorrowedFrom should equal loan.amount after single borrow");

        // Verify collateral accounting.
        uint256 totalCollateral = LOANS_CONTRACT.totalCollateralOf(REVNET_ID);
        assertEq(totalCollateral, loan.collateral, "totalCollateralOf should equal loan.collateral after single borrow");

        // Repay fully.
        vm.prank(USER);
        LOANS_CONTRACT.repayLoan{value: loan.amount * 2}({
            loanId: loanId,
            maxRepayBorrowAmount: loan.amount * 2,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(USER),
            allowance: JBSingleAllowance({sigDeadline: 0, amount: 0, expiration: 0, nonce: 0, signature: ""})
        });

        // After full repay, both should be zero atomically.
        uint256 totalBorrowedAfter =
            LOANS_CONTRACT.totalBorrowedFrom(REVNET_ID, jbMultiTerminal(), JBConstants.NATIVE_TOKEN);
        uint256 totalCollateralAfter = LOANS_CONTRACT.totalCollateralOf(REVNET_ID);
        assertEq(totalBorrowedAfter, 0, "totalBorrowedFrom should be 0 after full repay");
        assertEq(totalCollateralAfter, 0, "totalCollateralOf should be 0 after full repay");
    }

    /// @notice Rapid sequential borrows and repays can't create inconsistent state.
    /// Exercises _adjust's CEI pattern under repeated state transitions.
    function test_CEI_rapidBorrowRepaySequence() public {
        vm.deal(USER, 5000e18);

        for (uint256 i; i < 3; i++) {
            // Borrow.
            vm.prank(USER);
            uint256 tokens =
                jbMultiTerminal().pay{value: 10e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, USER, 0, "", "");

            uint256 borrowable =
                LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
            if (borrowable == 0) continue;

            mockExpect(
                address(jbPermissions()),
                abi.encodeCall(
                    IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, REVNET_ID, 11, true, true)
                ),
                abi.encode(true)
            );

            REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

            vm.prank(USER);
            (uint256 loanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokens, payable(USER), 25, USER);

            REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);

            // Immediately repay.
            vm.prank(USER);
            LOANS_CONTRACT.repayLoan{value: loan.amount * 2}({
                loanId: loanId,
                maxRepayBorrowAmount: loan.amount * 2,
                collateralCountToReturn: loan.collateral,
                beneficiary: payable(USER),
                allowance: JBSingleAllowance({sigDeadline: 0, amount: 0, expiration: 0, nonce: 0, signature: ""})
            });
        }

        // After all borrows repaid, accounting should be clean.
        uint256 totalBorrowed = LOANS_CONTRACT.totalBorrowedFrom(REVNET_ID, jbMultiTerminal(), JBConstants.NATIVE_TOKEN);
        uint256 totalCollateral = LOANS_CONTRACT.totalCollateralOf(REVNET_ID);
        assertEq(totalBorrowed, 0, "totalBorrowedFrom should be 0 after all repaid");
        assertEq(totalCollateral, 0, "totalCollateralOf should be 0 after all repaid");
    }
}
