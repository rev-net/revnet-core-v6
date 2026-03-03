// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import /* {*} from */ "@bananapus/core-v5/test/helpers/TestBaseWorkflow.sol";
import /* {*} from "@bananapus/721-hook-v5/src/JB721TiersHookDeployer.sol";
    import /* {*} from */ "./../src/REVDeployer.sol";
import "@croptop/core-v5/src/CTPublisher.sol";
import "@bananapus/core-v5/script/helpers/CoreDeploymentLib.sol";
import "@bananapus/721-hook-v5/script/helpers/Hook721DeploymentLib.sol";
import "@bananapus/suckers-v5/script/helpers/SuckerDeploymentLib.sol";
import "@croptop/core-v5/script/helpers/CroptopDeploymentLib.sol";
import "@bananapus/swap-terminal-v5/script/helpers/SwapTerminalDeploymentLib.sol";
import "@bananapus/buyback-hook-v5/script/helpers/BuybackDeploymentLib.sol";
import {JBConstants} from "@bananapus/core-v5/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v5/src/structs/JBAccountingContext.sol";
import {MockPriceFeed} from "@bananapus/core-v5/test/mock/MockPriceFeed.sol";
import {MockERC20} from "@bananapus/core-v5/test/mock/MockERC20.sol";
import {REVLoans} from "../src/REVLoans.sol";
import {REVLoan} from "../src/structs/REVLoan.sol";
import {REVStageConfig, REVAutoIssuance} from "../src/structs/REVStageConfig.sol";
import {REVLoanSource} from "../src/structs/REVLoanSource.sol";
import {REVDescription} from "../src/structs/REVDescription.sol";
import {REVBuybackPoolConfig} from "../src/structs/REVBuybackPoolConfig.sol";
import {IREVLoans} from "./../src/interfaces/IREVLoans.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v5/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v5/src/JBSuckerRegistry.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v5/src/JB721TiersHookDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v5/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v5/src/JB721TiersHookStore.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v5/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v5/src/interfaces/IJBAddressRegistry.sol";

/// @notice Tests for PR #32: liquidation boundary, reallocate msg.value, and decimal normalization fixes.
contract TestPR32_MixedFixes is TestBaseWorkflow, JBTest {
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";

    REVDeployer REV_DEPLOYER;
    JB721TiersHook EXAMPLE_HOOK;
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    IJB721TiersHookStore HOOK_STORE;
    IJBAddressRegistry ADDRESS_REGISTRY;
    REVLoans LOANS_CONTRACT;
    MockERC20 TOKEN;
    IJBSuckerRegistry SUCKER_REGISTRY;
    CTPublisher PUBLISHER;

    uint256 FEE_PROJECT_ID;
    uint256 REVNET_ID;

    address USER = makeAddr("user");

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    function setUp() public override {
        super.setUp();
        FEE_PROJECT_ID = jbProjects().createFor(multisig());
        SUCKER_REGISTRY = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig(), address(0));
        HOOK_STORE = new JB721TiersHookStore();
        EXAMPLE_HOOK = new JB721TiersHook(jbDirectory(), jbPermissions(), jbRulesets(), HOOK_STORE, multisig());
        ADDRESS_REGISTRY = new JBAddressRegistry();
        HOOK_DEPLOYER = new JB721TiersHookDeployer(EXAMPLE_HOOK, HOOK_STORE, ADDRESS_REGISTRY, multisig());
        PUBLISHER = new CTPublisher(jbDirectory(), jbPermissions(), FEE_PROJECT_ID, multisig());
        TOKEN = new MockERC20("1/2 ETH", "1/2");
        MockPriceFeed priceFeed = new MockPriceFeed(1e21, 6);
        vm.prank(multisig());
        jbPrices().addPriceFeedFor(0, uint32(uint160(address(TOKEN))), uint32(uint160(JBConstants.NATIVE_TOKEN)), priceFeed);
        REV_DEPLOYER = new REVDeployer{salt: REV_DEPLOYER_SALT}(jbController(), SUCKER_REGISTRY, FEE_PROJECT_ID, HOOK_DEPLOYER, PUBLISHER, TRUSTED_FORWARDER);
        LOANS_CONTRACT = new REVLoans({revnets: REV_DEPLOYER, revId: FEE_PROJECT_ID, owner: address(this), permit2: permit2(), trustedForwarder: TRUSTED_FORWARDER});
        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);
        _deployFeeProject();
        _deployRevnet();
        vm.deal(USER, 1000e18);
    }

    function _deployFeeProject() internal {
        JBAccountingContext[] memory acc = new JBAccountingContext[](2);
        acc[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
        acc[1] = JBAccountingContext({token: address(TOKEN), decimals: 6, currency: uint32(uint160(address(TOKEN)))});
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});
        REVStageConfig[] memory stages = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;
        REVAutoIssuance[] memory ai = new REVAutoIssuance[](1);
        ai[0] = REVAutoIssuance({chainId: uint32(block.chainid), count: uint104(70_000e18), beneficiary: multisig()});
        stages[0] = REVStageConfig({startsAtOrAfter: uint40(block.timestamp), autoIssuances: ai, splitPercent: 2000, splits: splits, initialIssuance: uint112(1000e18), issuanceCutFrequency: 90 days, issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2, cashOutTaxRate: 6000, extraMetadata: 0});
        REVConfig memory cfg = REVConfig({description: REVDescription("Revnet", "$REV", "ipfs://test", "REV_TOKEN"), baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)), splitOperator: multisig(), stageConfigurations: stages, loanSources: new REVLoanSource[](0), loans: address(0)});
        REVBuybackHookConfig memory bbh = REVBuybackHookConfig({dataHook: IJBRulesetDataHook(address(0)), hookToConfigure: IJBBuybackHook(address(0)), poolConfigurations: new REVBuybackPoolConfig[](0)});
        vm.prank(multisig());
        REV_DEPLOYER.deployFor({revnetId: FEE_PROJECT_ID, configuration: cfg, terminalConfigurations: tc, buybackHookConfiguration: bbh, suckerDeploymentConfiguration: REVSuckerDeploymentConfig({deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("FEE")})});
    }

    function _deployRevnet() internal {
        JBAccountingContext[] memory acc = new JBAccountingContext[](2);
        acc[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
        acc[1] = JBAccountingContext({token: address(TOKEN), decimals: 6, currency: uint32(uint160(address(TOKEN)))});
        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});
        REVStageConfig[] memory stages = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;
        REVAutoIssuance[] memory ai = new REVAutoIssuance[](1);
        ai[0] = REVAutoIssuance({chainId: uint32(block.chainid), count: uint104(70_000e18), beneficiary: multisig()});
        stages[0] = REVStageConfig({startsAtOrAfter: uint40(block.timestamp), autoIssuances: ai, splitPercent: 2000, splits: splits, initialIssuance: uint112(1000e18), issuanceCutFrequency: 90 days, issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2, cashOutTaxRate: 6000, extraMetadata: 0});
        REVLoanSource[] memory ls = new REVLoanSource[](1);
        ls[0] = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        REVConfig memory cfg = REVConfig({description: REVDescription("NANA", "$NANA", "ipfs://test2", "NANA_TOKEN"), baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)), splitOperator: multisig(), stageConfigurations: stages, loanSources: ls, loans: address(LOANS_CONTRACT)});
        REVBuybackHookConfig memory bbh = REVBuybackHookConfig({dataHook: IJBRulesetDataHook(address(0)), hookToConfigure: IJBBuybackHook(address(0)), poolConfigurations: new REVBuybackPoolConfig[](0)});
        REVNET_ID = REV_DEPLOYER.deployFor({revnetId: 0, configuration: cfg, terminalConfigurations: tc, buybackHookConfiguration: bbh, suckerDeploymentConfiguration: REVSuckerDeploymentConfig({deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256("NANA")})});
    }

    function _setupLoan(address user, uint256 ethAmount, uint256 prepaidFee) internal returns (uint256 loanId, uint256 tokenCount, uint256 borrowAmount) {
        vm.prank(user);
        tokenCount = jbMultiTerminal().pay{value: ethAmount}(REVNET_ID, JBConstants.NATIVE_TOKEN, ethAmount, user, 0, "", "");
        borrowAmount = LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokenCount, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        if (borrowAmount == 0) return (0, tokenCount, 0);
        mockExpect(address(jbPermissions()), abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), user, REVNET_ID, 10, true, true)), abi.encode(true));
        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});
        vm.prank(user);
        (loanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(user), prepaidFee);
    }

    /// @notice At exactly LOAN_LIQUIDATION_DURATION, determineSourceFeeAmount should revert with LoanExpired (>= boundary).
    function test_liquidationBoundary_exactDuration_isLiquidatable() public {
        (uint256 loanId,,) = _setupLoan(USER, 10e18, 25);
        require(loanId != 0, "Loan setup failed");

        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);

        // Warp to exactly LOAN_LIQUIDATION_DURATION after creation
        vm.warp(loan.createdAt + LOANS_CONTRACT.LOAN_LIQUIDATION_DURATION());

        // With the >= fix, this should revert because timeSinceLoanCreated == LOAN_LIQUIDATION_DURATION
        vm.expectRevert(
            abi.encodeWithSelector(
                REVLoans.REVLoans_LoanExpired.selector,
                LOANS_CONTRACT.LOAN_LIQUIDATION_DURATION(),
                LOANS_CONTRACT.LOAN_LIQUIDATION_DURATION()
            )
        );
        LOANS_CONTRACT.determineSourceFeeAmount(loan, loan.amount);
    }

    /// @notice At LOAN_LIQUIDATION_DURATION - 1, the loan should still be manageable (not expired).
    function test_liquidationBoundary_oneBefore_notLiquidatable() public {
        (uint256 loanId,,) = _setupLoan(USER, 10e18, 25);
        require(loanId != 0, "Loan setup failed");

        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);

        // Warp to one second before the liquidation boundary
        vm.warp(loan.createdAt + LOANS_CONTRACT.LOAN_LIQUIDATION_DURATION() - 1);

        // This should NOT revert — the loan is still within the liquidation window
        uint256 fee = LOANS_CONTRACT.determineSourceFeeAmount(loan, loan.amount);

        // Fee should be > 0 since we're past the prepaid duration but before liquidation
        assertTrue(fee > 0, "Fee should be nonzero for a loan past its prepaid period");
    }

    /// @notice Sending ETH to the non-payable reallocateCollateralFromLoan should revert.
    /// @dev Since the function is not payable, Solidity prevents sending ETH at compile time.
    /// We use a low-level call to bypass this and verify the EVM-level revert.
    function test_reallocate_withETHValue_reverts() public {
        (uint256 loanId, uint256 tokenCount,) = _setupLoan(USER, 10e18, 25);
        require(loanId != 0, "Loan setup failed");

        // Encode the function call
        bytes memory callData = abi.encodeWithSelector(
            LOANS_CONTRACT.reallocateCollateralFromLoan.selector,
            loanId,
            tokenCount / 10,
            REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()}),
            0,
            0,
            USER,
            25
        );

        // Low-level call with msg.value to bypass Solidity's payable check
        vm.prank(USER);
        (bool success,) = address(LOANS_CONTRACT).call{value: 1 ether}(callData);
        assertFalse(success, "Sending ETH to non-payable reallocate should revert");
    }

    /// @notice Calling reallocateCollateralFromLoan without ETH should work (given valid params).
    function test_reallocate_withoutETHValue_succeeds() public {
        (uint256 loanId, uint256 tokenCount,) = _setupLoan(USER, 10e18, 25);
        require(loanId != 0, "Loan setup failed");

        // Inflate surplus so collateral removal is viable
        address donor = makeAddr("donor");
        vm.deal(donor, 500e18);
        vm.prank(donor);
        jbMultiTerminal().addToBalanceOf{value: 500e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 500e18, false, "", "");

        // Get extra tokens to add as collateral to the new loan
        vm.prank(USER);
        uint256 extraTokens = jbMultiTerminal().pay{value: 50e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 50e18, USER, 0, "", "");

        uint256 collateralToTransfer = tokenCount / 10;

        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        // Mock burn permission
        mockExpect(address(jbPermissions()), abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), USER, REVNET_ID, 10, true, true)), abi.encode(true));

        // Call without msg.value — should succeed
        vm.prank(USER);
        (uint256 reallocatedLoanId, uint256 newLoanId,,) = LOANS_CONTRACT.reallocateCollateralFromLoan(
            loanId,
            collateralToTransfer,
            source,
            0,
            extraTokens,
            payable(USER),
            25
        );

        assertTrue(reallocatedLoanId != 0, "Reallocated loan should exist");
        assertTrue(newLoanId != 0, "New loan should exist");
    }
}
