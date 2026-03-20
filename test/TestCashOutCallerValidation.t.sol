// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {MockERC20} from "@bananapus/core-v6/test/mock/MockERC20.sol";
import {REVLoans} from "../src/REVLoans.sol";
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

struct FeeProjectConfig {
    REVConfig configuration;
    JBTerminalConfig[] terminalConfigurations;
    REVSuckerDeploymentConfig suckerDeploymentConfiguration;
}

contract TestCashOutCallerValidation is TestBaseWorkflow {
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 ERC20_SALT = "REV_TOKEN";

    // forge-lint: disable-next-line(mixed-case-variable)
    REVDeployer REV_DEPLOYER;
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
    // forge-lint: disable-next-line(mixed-case-variable)
    address RANDOM_CALLER = makeAddr("randomCaller");

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    function getFeeProjectConfig() internal view returns (FeeProjectConfig memory) {
        string memory name = "Revnet";
        string memory symbol = "$REV";
        string memory projectUri = "ipfs://QmNRHT91HcDgMcenebYX7rJigt77cgNcosvuhX21wkF3tx";
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

        {
            REVAutoIssuance[] memory issuanceConfs = new REVAutoIssuance[](0);
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
        }

        REVConfig memory revnetConfiguration = REVConfig({
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription(name, symbol, projectUri, ERC20_SALT),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations
        });

        return FeeProjectConfig({
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("REV"))
            })
        });
    }

    function getRevnetConfig() internal view returns (FeeProjectConfig memory) {
        string memory name = "NANA";
        string memory symbol = "$NANA";
        string memory projectUri = "ipfs://QmNRHT91HcDgMcenebYX7rJigt77cgNxosvuhX21wkF3tx";
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

        {
            REVAutoIssuance[] memory issuanceConfs = new REVAutoIssuance[](0);
            stageConfigurations[0] = REVStageConfig({
                startsAtOrAfter: uint40(block.timestamp),
                autoIssuances: issuanceConfs,
                splitPercent: 2000,
                splits: splits,
                // forge-lint: disable-next-line(unsafe-typecast)
                initialIssuance: uint112(1000 * decimalMultiplier),
                issuanceCutFrequency: 90 days,
                issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
                cashOutTaxRate: 3000,
                extraMetadata: 0
            });
        }

        REVLoanSource[] memory loanSources = new REVLoanSource[](1);
        loanSources[0] = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        REVConfig memory revnetConfiguration = REVConfig({
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription(name, symbol, projectUri, "NANA_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations
        });

        return FeeProjectConfig({
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
        TOKEN = new MockERC20("1/2 ETH", "1/2");

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
            IJBBuybackHookRegistry(address(MOCK_BUYBACK)),
            address(LOANS_CONTRACT),
            TRUSTED_FORWARDER
        );

        // Approve the deployer to configure the fee project.
        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);

        // Deploy the fee project.
        FeeProjectConfig memory feeProjectConfig = getFeeProjectConfig();
        vm.prank(multisig());
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeProjectConfig.configuration,
            terminalConfigurations: feeProjectConfig.terminalConfigurations,
            suckerDeploymentConfiguration: feeProjectConfig.suckerDeploymentConfiguration,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        // Deploy the revnet.
        FeeProjectConfig memory revnetConfig = getRevnetConfig();
        (REVNET_ID,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: revnetConfig.configuration,
            terminalConfigurations: revnetConfig.terminalConfigurations,
            suckerDeploymentConfiguration: revnetConfig.suckerDeploymentConfiguration,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        vm.deal(USER, 100 ether);
    }

    /// @notice Test that a normal cash out flow processes fees correctly to the fee project.
    function test_normalCashOutFlow_feeProcessedCorrectly() public {
        // Pay ETH into revnet to get tokens.
        vm.prank(USER);
        uint256 tokenCount =
            jbMultiTerminal().pay{value: 10 ether}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10 ether, USER, 0, "", "");
        assertGt(tokenCount, 0, "Should have received tokens");

        // Record fee project balance before cash out.
        uint256 feeProjectBalanceBefore =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), REVNET_ID, JBConstants.NATIVE_TOKEN);
        assertGt(feeProjectBalanceBefore, 0, "Revnet should have balance");

        // Warp past CASH_OUT_DELAY.
        uint256 delay = REV_DEPLOYER.CASH_OUT_DELAY();
        vm.warp(block.timestamp + delay + 1);

        // Record fee project terminal balance before.
        uint256 feeBalanceBefore =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN);

        // Cash out tokens.
        vm.prank(USER);
        uint256 reclaimed = jbMultiTerminal()
            .cashOutTokensOf({
                holder: USER,
                projectId: REVNET_ID,
                cashOutCount: tokenCount,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(USER),
                metadata: ""
            });

        assertGt(reclaimed, 0, "Should have reclaimed some ETH");

        // Verify fee project balance increased (it received the fee).
        uint256 feeBalanceAfter =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN);
        assertGt(feeBalanceAfter, feeBalanceBefore, "Fee project balance should increase from cash out fee");
    }

    /// @notice Revnet cash-out fees and buyback sell-side specs are composed together.
    function test_beforeCashOutRecordedWith_proxiesIntoBuybackAndAppendsFeeSpec() public {
        bytes memory buybackMetadata = abi.encode(uint256(123));
        MOCK_BUYBACK.configureCashOutResult({
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
            cashOutCount: 0,
            totalSupply: 0,
            hookAmount: 0,
            hookMetadata: buybackMetadata
        });

        JBBeforeCashOutRecordedContext memory context = JBBeforeCashOutRecordedContext({
            terminal: address(jbMultiTerminal()),
            holder: USER,
            projectId: REVNET_ID,
            rulesetId: 0,
            cashOutCount: 1000,
            totalSupply: 10_000,
            surplus: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                value: 100 ether,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            }),
            useTotalSurplus: true,
            cashOutTaxRate: 3000,
            beneficiaryIsFeeless: false,
            metadata: ""
        });

        (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            JBCashOutHookSpecification[] memory hookSpecifications
        ) = REV_DEPLOYER.beforeCashOutRecordedWith(context);

        uint256 feeCashOutCount = context.cashOutCount * REV_DEPLOYER.FEE() / JBConstants.MAX_FEE;
        uint256 nonFeeCashOutCount = context.cashOutCount - feeCashOutCount;
        uint256 postFeeReclaimedAmount = JBCashOuts.cashOutFrom({
            surplus: context.surplus.value,
            cashOutCount: nonFeeCashOutCount,
            totalSupply: context.totalSupply,
            cashOutTaxRate: context.cashOutTaxRate
        });
        uint256 feeAmount = JBCashOuts.cashOutFrom({
            surplus: context.surplus.value - postFeeReclaimedAmount,
            cashOutCount: feeCashOutCount,
            totalSupply: context.totalSupply - nonFeeCashOutCount,
            cashOutTaxRate: context.cashOutTaxRate
        });

        assertEq(cashOutTaxRate, JBConstants.MAX_CASH_OUT_TAX_RATE, "Buyback cash out tax rate should be forwarded");
        assertEq(cashOutCount, nonFeeCashOutCount, "Buyback should receive the non-fee cash out count");
        assertEq(totalSupply, context.totalSupply, "Total supply should pass through");
        assertEq(hookSpecifications.length, 2, "Buyback spec and revnet fee spec should both be returned");

        assertEq(address(hookSpecifications[0].hook), address(MOCK_BUYBACK), "First hook spec should come from buyback");
        assertEq(hookSpecifications[0].amount, 0, "Buyback sell-side spec should preserve its forwarded amount");
        assertEq(hookSpecifications[0].metadata, buybackMetadata, "Buyback metadata should be preserved");

        assertEq(address(hookSpecifications[1].hook), address(REV_DEPLOYER), "Second hook spec should charge fee");
        assertEq(hookSpecifications[1].amount, feeAmount, "Fee spec amount should match the revnet fee math");
        assertEq(
            hookSpecifications[1].metadata,
            abi.encode(jbMultiTerminal()),
            "Fee spec metadata should encode the fee terminal"
        );
    }

    /// @notice Test that afterCashOutRecordedWith has no access control — anyone can call it.
    /// A non-terminal caller would just be donating their own funds as fees.
    function test_nonTerminalCaller_justDonatesOwnFunds() public {
        // Fund the random caller with ETH.
        vm.deal(RANDOM_CALLER, 10 ether);

        // Build a minimal JBAfterCashOutRecordedContext.
        // The key point: afterCashOutRecordedWith does NOT check msg.sender against any terminal registry.
        // If a non-terminal calls it with native ETH, the ETH just goes to the fee project as a donation.
        JBAfterCashOutRecordedContext memory context = JBAfterCashOutRecordedContext({
            holder: RANDOM_CALLER,
            projectId: REVNET_ID,
            rulesetId: 0,
            cashOutCount: 0,
            reclaimedAmount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: 0
            }),
            forwardedAmount: JBTokenAmount({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                value: 1 ether
            }),
            cashOutTaxRate: 0,
            beneficiary: payable(RANDOM_CALLER),
            hookMetadata: abi.encode(jbMultiTerminal()),
            cashOutMetadata: ""
        });

        // Record fee project balance before.
        uint256 feeBalanceBefore =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN);

        // Call afterCashOutRecordedWith from a random (non-terminal) address.
        // This should NOT revert with any authorization error.
        // The caller sends ETH which gets paid as a fee to the fee project.
        vm.prank(RANDOM_CALLER);
        REV_DEPLOYER.afterCashOutRecordedWith{value: 1 ether}(context);

        // Verify the fee project received the ETH (donation).
        uint256 feeBalanceAfter =
            jbTerminalStore().balanceOf(address(jbMultiTerminal()), FEE_PROJECT_ID, JBConstants.NATIVE_TOKEN);
        assertGt(feeBalanceAfter, feeBalanceBefore, "Fee project should receive the donated ETH");
    }
}
