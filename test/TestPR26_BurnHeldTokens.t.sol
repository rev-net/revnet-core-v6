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

struct FeeProjectConfig {
    REVConfig configuration;
    JBTerminalConfig[] terminalConfigurations;
    REVBuybackHookConfig buybackHookConfiguration;
    REVSuckerDeploymentConfig suckerDeploymentConfiguration;
}

contract TestPR26_BurnHeldTokens is TestBaseWorkflow, JBTest {
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

    uint256 FEE_PROJECT_ID;
    uint256 REVNET_ID;

    address USER = makeAddr("user");
    address RANDOM_CALLER = makeAddr("randomCaller");

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    function getFeeProjectConfig() internal view returns (FeeProjectConfig memory) {
        uint8 decimals = 18;
        uint256 decimalMultiplier = 10 ** decimals;

        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = JBConstants.SPLITS_TOTAL_PERCENT; // 100% to avoid held tokens on fee project

        stageConfigurations[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 2000,
            splits: splits,
            initialIssuance: uint112(1000 * decimalMultiplier),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 6000,
            extraMetadata: 0
        });

        REVConfig memory revnetConfiguration = REVConfig({
            description: REVDescription("Revnet", "$REV", "ipfs://test", ERC20_SALT),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations,
            loanSources: new REVLoanSource[](0),
            loans: address(0)
        });

        REVBuybackPoolConfig[] memory buybackPoolConfigurations = new REVBuybackPoolConfig[](1);
        buybackPoolConfigurations[0] =
            REVBuybackPoolConfig({token: JBConstants.NATIVE_TOKEN, fee: 10_000, twapWindow: 2 days});
        REVBuybackHookConfig memory buybackHookConfiguration = REVBuybackHookConfig({
            dataHook: IJBRulesetDataHook(address(0)),
            hookToConfigure: IJBBuybackHook(address(0)),
            poolConfigurations: buybackPoolConfigurations
        });

        return FeeProjectConfig({
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            buybackHookConfiguration: buybackHookConfiguration,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0),
                salt: keccak256(abi.encodePacked("REV"))
            })
        });
    }

    /// @notice Deploy a revnet with splits that don't sum to 100%.
    /// The split covers 50% of reserved tokens; the remaining 50% goes to project owner (REVDeployer).
    function _deployRevnetWithPartialSplits() internal returns (uint256 revnetId) {
        uint8 decimals = 18;
        uint256 decimalMultiplier = 10 ** decimals;

        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](1);

        // Splits only cover 50% of reserved tokens — the other 50% goes to REVDeployer.
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = uint32(JBConstants.SPLITS_TOTAL_PERCENT / 2); // 50%

        stageConfigurations[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 2000, // 20% reserved
            splits: splits,
            initialIssuance: uint112(1000 * decimalMultiplier),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 3000,
            extraMetadata: 0
        });

        REVConfig memory revnetConfiguration = REVConfig({
            description: REVDescription("Partial", "$PRT", "ipfs://test", "PRT_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations,
            loanSources: new REVLoanSource[](0),
            loans: address(0)
        });

        REVBuybackPoolConfig[] memory buybackPoolConfigurations = new REVBuybackPoolConfig[](1);
        buybackPoolConfigurations[0] =
            REVBuybackPoolConfig({token: JBConstants.NATIVE_TOKEN, fee: 10_000, twapWindow: 2 days});
        REVBuybackHookConfig memory buybackHookConfiguration = REVBuybackHookConfig({
            dataHook: IJBRulesetDataHook(address(0)),
            hookToConfigure: IJBBuybackHook(address(0)),
            poolConfigurations: buybackPoolConfigurations
        });

        revnetId = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            buybackHookConfiguration: buybackHookConfiguration,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0),
                salt: keccak256(abi.encodePacked("PRT"))
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
        TOKEN = new MockERC20("1/2 ETH", "1/2");

        REV_DEPLOYER = new REVDeployer{salt: REV_DEPLOYER_SALT}(
            jbController(), SUCKER_REGISTRY, FEE_PROJECT_ID, HOOK_DEPLOYER, PUBLISHER, TRUSTED_FORWARDER
        );

        LOANS_CONTRACT = new REVLoans({
            revnets: REV_DEPLOYER,
            revId: FEE_PROJECT_ID,
            owner: address(this),
            permit2: permit2(),
            trustedForwarder: TRUSTED_FORWARDER
        });

        // Deploy fee project.
        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);

        FeeProjectConfig memory feeProjectConfig = getFeeProjectConfig();
        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeProjectConfig.configuration,
            terminalConfigurations: feeProjectConfig.terminalConfigurations,
            buybackHookConfiguration: feeProjectConfig.buybackHookConfiguration,
            suckerDeploymentConfiguration: feeProjectConfig.suckerDeploymentConfiguration
        });

        // Deploy revnet with partial splits.
        REVNET_ID = _deployRevnetWithPartialSplits();

        vm.deal(USER, 100 ether);
    }

    /// @notice Helper: pay into revnet and distribute reserved tokens to get tokens held by REVDeployer.
    function _payAndDistribute() internal {
        // Pay ETH into revnet to create surplus and generate reserved tokens.
        vm.prank(USER);
        jbMultiTerminal().pay{value: 10 ether}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10 ether, USER, 0, "", "");

        // Distribute reserved tokens. Since splits only cover 50%, the other 50% goes to REVDeployer.
        jbController().sendReservedTokensToSplitsOf(REVNET_ID);
    }

    /// @notice Burn held tokens succeeds and reduces REVDeployer balance to 0.
    function test_burnHeldTokens_succeeds() public {
        _payAndDistribute();

        // Verify REVDeployer holds tokens.
        uint256 deployerBalance = jbController().TOKENS().totalBalanceOf(address(REV_DEPLOYER), REVNET_ID);
        assertGt(deployerBalance, 0, "REVDeployer should hold tokens after reserved distribution");

        // Burn held tokens.
        REV_DEPLOYER.burnHeldTokensOf(REVNET_ID);

        // Verify balance is now 0.
        uint256 deployerBalanceAfter = jbController().TOKENS().totalBalanceOf(address(REV_DEPLOYER), REVNET_ID);
        assertEq(deployerBalanceAfter, 0, "REVDeployer balance should be 0 after burn");
    }

    /// @notice Burn held tokens reduces total supply.
    function test_burnHeldTokens_reducesTotalSupply() public {
        _payAndDistribute();

        // Record total supply before burn.
        uint256 totalSupplyBefore = jbController().totalTokenSupplyWithReservedTokensOf(REVNET_ID);

        uint256 deployerBalance = jbController().TOKENS().totalBalanceOf(address(REV_DEPLOYER), REVNET_ID);
        assertGt(deployerBalance, 0, "REVDeployer should hold tokens");

        // Burn held tokens.
        REV_DEPLOYER.burnHeldTokensOf(REVNET_ID);

        // Record total supply after burn.
        uint256 totalSupplyAfter = jbController().totalTokenSupplyWithReservedTokensOf(REVNET_ID);

        assertLt(totalSupplyAfter, totalSupplyBefore, "Total supply should decrease after burn");
        assertEq(
            totalSupplyBefore - totalSupplyAfter,
            deployerBalance,
            "Total supply should decrease by the burned amount"
        );
    }

    /// @notice Burn held tokens reverts with NothingToBurn when balance is 0.
    function test_burnHeldTokens_zeroBalance_reverts() public {
        // Deploy a revnet with 100% splits so REVDeployer gets nothing.
        uint8 decimals = 18;
        uint256 decimalMultiplier = 10 ** decimals;

        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = uint32(JBConstants.SPLITS_TOTAL_PERCENT); // 100%

        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](1);
        stageConfigurations[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 2000,
            splits: splits,
            initialIssuance: uint112(1000 * decimalMultiplier),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 3000,
            extraMetadata: 0
        });

        uint256 fullSplitRevnetId = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: REVConfig({
                description: REVDescription("Full", "$FUL", "ipfs://test", "FUL_TOKEN"),
                baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                splitOperator: multisig(),
                stageConfigurations: stageConfigurations,
                loanSources: new REVLoanSource[](0),
                loans: address(0)
            }),
            terminalConfigurations: terminalConfigurations,
            buybackHookConfiguration: REVBuybackHookConfig({
                dataHook: IJBRulesetDataHook(address(0)),
                hookToConfigure: IJBBuybackHook(address(0)),
                poolConfigurations: new REVBuybackPoolConfig[](0)
            }),
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0),
                salt: keccak256(abi.encodePacked("FUL"))
            })
        });

        // REVDeployer should have no tokens for this revnet.
        uint256 balance = jbController().TOKENS().totalBalanceOf(address(REV_DEPLOYER), fullSplitRevnetId);
        assertEq(balance, 0, "REVDeployer should have 0 balance");

        // Should revert with NothingToBurn.
        vm.expectRevert(abi.encodeWithSignature("REVDeployer_NothingToBurn()"));
        REV_DEPLOYER.burnHeldTokensOf(fullSplitRevnetId);
    }

    /// @notice Anyone can call burnHeldTokensOf — it has no access control.
    function test_burnHeldTokens_anyoneCanCall() public {
        _payAndDistribute();

        // Verify REVDeployer holds tokens.
        uint256 deployerBalance = jbController().TOKENS().totalBalanceOf(address(REV_DEPLOYER), REVNET_ID);
        assertGt(deployerBalance, 0, "REVDeployer should hold tokens");

        // A random caller (not owner, not multisig) can call burnHeldTokensOf.
        vm.prank(RANDOM_CALLER);
        REV_DEPLOYER.burnHeldTokensOf(REVNET_ID);

        // Verify tokens were burned.
        uint256 deployerBalanceAfter = jbController().TOKENS().totalBalanceOf(address(REV_DEPLOYER), REVNET_ID);
        assertEq(deployerBalanceAfter, 0, "Tokens should be burned regardless of caller");
    }
}
