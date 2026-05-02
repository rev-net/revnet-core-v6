// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
// import /* {*} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "./../src/REVDeployer.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "./../src/REVLoans.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@croptop/core-v6/src/CTPublisher.sol";
import {MockBuybackDataHook} from "./mock/MockBuybackDataHook.sol";
import {REVEmpty721Config} from "./helpers/REVEmpty721Config.sol";

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
import {REVStageConfig, REVAutoIssuance} from "../src/structs/REVStageConfig.sol";
import {REVLoanSource} from "../src/structs/REVLoanSource.sol";
import {REVDescription} from "../src/structs/REVDescription.sol";
import {IREVLoans} from "./../src/interfaces/IREVLoans.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/JB721CheckpointsDeployer.sol";
import {IJB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721CheckpointsDeployer.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {JBTest} from "@bananapus/core-v6/test/helpers/JBTest.sol";
import {REVOwner} from "../src/REVOwner.sol";
import {IREVDeployer} from "../src/interfaces/IREVDeployer.sol";
import {MockSuckerRegistry} from "./mock/MockSuckerRegistry.sol";

struct FeeProjectConfig {
    REVConfig configuration;
    JBTerminalConfig[] terminalConfigurations;
    REVSuckerDeploymentConfig suckerDeploymentConfiguration;
}

contract REVLoansCallHandler is JBTest {
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 public COLLATERAL_SUM;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 public COLLATERAL_RETURNED;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 public BORROWED_SUM;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 public RUNS;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 REVNET_ID;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 LAST_LOAN_MODIFIED;
    // forge-lint: disable-next-line(mixed-case-variable)
    address USER;

    // forge-lint: disable-next-line(mixed-case-variable)
    IJBMultiTerminal TERMINAL;
    // forge-lint: disable-next-line(mixed-case-variable)
    IREVLoans LOANS;
    // forge-lint: disable-next-line(mixed-case-variable)
    IJBPermissions PERMS;
    // forge-lint: disable-next-line(mixed-case-variable)
    IJBTokens TOKENS;

    constructor(
        IJBMultiTerminal terminal,
        IREVLoans loans,
        IJBPermissions permissions,
        IJBTokens tokens,
        uint256 revnetId,
        address beneficiary
    ) {
        TERMINAL = terminal;
        LOANS = loans;
        PERMS = permissions;
        TOKENS = tokens;
        REVNET_ID = revnetId;
        USER = beneficiary;
    }

    modifier useActor() {
        vm.startPrank(USER);
        _;
        vm.stopPrank();
    }

    function payBorrow(uint256 amount, uint16 prepaid) public virtual useActor {
        uint256 payAmount = bound(amount, 1 ether, 10 ether);
        uint256 prepaidFee = bound(uint256(prepaid), 25, 500);

        vm.deal(USER, payAmount);

        uint256 receivedTokens = TERMINAL.pay{value: payAmount}(REVNET_ID, JBConstants.NATIVE_TOKEN, 0, USER, 0, "", "");
        uint256 borrowable =
            LOANS.borrowableAmountFrom(REVNET_ID, receivedTokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        // User must give the loans contract permission, similar to an "approve" call, we're just spoofing to save time.
        mockExpect(
            address(PERMS),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS), USER, 2, 11, true, true)),
            abi.encode(true)
        );

        REVLoanSource memory sauce = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: TERMINAL});
        (, REVLoan memory lastLoan) =
            LOANS.borrowFrom(REVNET_ID, sauce, borrowable, receivedTokens, payable(USER), prepaidFee, USER);

        COLLATERAL_SUM += receivedTokens;
        BORROWED_SUM += lastLoan.amount;
        ++RUNS;
    }

    function repayLoan(uint16 percentToPay, uint8 daysToFastForward) public virtual useActor {
        // Skip this if there are no loans to pay down
        if (RUNS == 0) {
            return;
        }

        uint256 denominator = 10_000;
        uint256 percentToPayDown = bound(percentToPay, 1000, denominator - 1);
        uint256 daysToWarp = bound(daysToFastForward, 10, 100);
        daysToWarp = daysToWarp * 1 days;

        vm.warp(block.timestamp + daysToWarp);

        // get the loan ID
        uint256 id = (REVNET_ID * 1_000_000_000_000) + RUNS;
        REVLoan memory latestLoan = LOANS.loanOf(id);

        // skip if we don't find the loan
        try IERC721(address(LOANS)).ownerOf(id) {}
        catch {
            return;
        }

        // skip if we don't find a loan
        if (latestLoan.amount == 0) return;

        // calc percentage to pay down
        uint256 amountPaidDown;

        uint256 collateralReturned = mulDiv(latestLoan.collateral, percentToPayDown, 10_000);

        uint256 newCollateral = latestLoan.collateral - collateralReturned;
        uint256 borrowableFromNewCollateral =
            LOANS.borrowableAmountFrom(REVNET_ID, newCollateral, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        // Needed for edge case seeds like 17721, 11407, 334
        if (borrowableFromNewCollateral > 0) borrowableFromNewCollateral -= 1;

        uint256 amountDiff =
            borrowableFromNewCollateral > latestLoan.amount ? 0 : latestLoan.amount - borrowableFromNewCollateral;

        amountPaidDown = amountDiff;

        // Calculate the fee.
        {
            // Keep a reference to the time since the loan was created.
            uint256 timeSinceLoanCreated = block.timestamp - latestLoan.createdAt;

            // If the loan period has passed the prepaid time frame, take a fee.
            if (timeSinceLoanCreated > latestLoan.prepaidDuration) {
                // Calculate the prepaid fee for the amount being paid back.
                uint256 prepaidAmount =
                    JBFees.feeAmountFrom({amountBeforeFee: amountDiff, feePercent: latestLoan.prepaidFeePercent});

                // Calculate the fee as a linear proportion given the amount of time that has passed.
                // sourceFeeAmount = mulDiv(amount, timeSinceLoanCreated, LOAN_LIQUIDATION_DURATION) - prepaidAmount;
                amountPaidDown += JBFees.feeAmountFrom({
                    amountBeforeFee: amountDiff - prepaidAmount,
                    feePercent: mulDiv(timeSinceLoanCreated, JBConstants.MAX_FEE, 3650 days)
                });
            }
        }

        // empty allowance data
        JBSingleAllowance memory allowance;

        vm.deal(USER, type(uint256).max);
        (, REVLoan memory adjustedOrNewLoan) =
            LOANS.repayLoan{value: amountPaidDown}(id, amountPaidDown, collateralReturned, payable(USER), allowance);

        COLLATERAL_RETURNED += collateralReturned;
        COLLATERAL_SUM -= collateralReturned;
        if (BORROWED_SUM >= amountDiff) BORROWED_SUM -= (latestLoan.amount - adjustedOrNewLoan.amount);
    }

    /// @notice Advance time by a random amount to test time-dependent behavior.
    function advanceTime(uint8 daysToAdvance) public {
        uint256 daysToWarp = bound(uint256(daysToAdvance), 1, 365);
        vm.warp(block.timestamp + daysToWarp * 1 days);
    }

    /// @notice Attempt to liquidate expired loans.
    function liquidateLoans(uint8 count) public {
        uint256 loanCount = bound(uint256(count), 1, 10);
        if (RUNS == 0) return;

        uint256 startingLoanId = (REVNET_ID * 1_000_000_000_000) + 1;
        try LOANS.liquidateExpiredLoansFrom(REVNET_ID, startingLoanId, loanCount) {} catch {}
    }

    function reallocateCollateralFromLoan(
        uint16 collateralPercent,
        uint256 amountToPay,
        uint16 prepaid
    )
        public
        virtual
        useActor
    {
        // used later for the new borrow
        uint256 prepaidFeePercent = bound(uint256(prepaid), 25, 500);

        // Skip this if there are no loans to refinance
        if (RUNS == 0) {
            return;
        }

        // 0.0001-99%
        uint256 collateralPercentToTransfer = bound(uint256(collateralPercent), 1, 9999);
        amountToPay = bound(amountToPay, 10 ether, 1000e18);

        // get the loan ID
        uint256 id = (REVNET_ID * 1_000_000_000_000) + RUNS;

        try IERC721(address(LOANS)).ownerOf(id) {}
        catch {
            return;
        }

        REVLoan memory latestLoan = LOANS.loanOf(id);

        // skip if we don't find a loan
        if (latestLoan.amount == 0) return;

        // pay in
        vm.deal(USER, amountToPay);
        uint256 collateralToAdd =
            TERMINAL.pay{value: amountToPay}(REVNET_ID, JBConstants.NATIVE_TOKEN, 0, USER, 0, "", "");

        // 0.0001-100% in token terms
        uint256 collateralToTransfer = mulDiv(latestLoan.collateral, collateralPercentToTransfer, 10_000);

        // get the new amount to borrow
        uint256 newAmountInFull = LOANS.borrowableAmountFrom(
            REVNET_ID, collateralToTransfer + collateralToAdd, 18, uint32(uint160(JBConstants.NATIVE_TOKEN))
        );

        (,,, REVLoan memory newLoan) = LOANS.reallocateCollateralFromLoan(
            id,
            collateralToTransfer,
            REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: TERMINAL}),
            newAmountInFull,
            collateralToAdd,
            payable(USER),
            prepaidFeePercent
        );

        COLLATERAL_SUM += collateralToAdd;
        BORROWED_SUM += (newLoan.amount);
    }
}

contract InvariantREVLoansTests is StdInvariant, TestBaseWorkflow {
    // A library that parses the packed ruleset metadata into a friendlier format.
    using JBRulesetMetadataResolver for JBRuleset;

    /// @notice the salts that are used to deploy the contracts.
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 REV_DEPLOYER_SALT = "REVDeployer";
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 ERC20_SALT = "REV_TOKEN";

    // Handlers
    // forge-lint: disable-next-line(mixed-case-variable)
    REVLoansCallHandler PAY_HANDLER;

    // forge-lint: disable-next-line(mixed-case-variable)
    REVDeployer REV_DEPLOYER;
    // forge-lint: disable-next-line(mixed-case-variable)
    REVOwner REV_OWNER;
    // forge-lint: disable-next-line(mixed-case-variable)
    JB721TiersHook EXAMPLE_HOOK;

    /// @notice Deploys tiered ERC-721 hooks for revnets.
    // forge-lint: disable-next-line(mixed-case-variable)
    IJB721TiersHookDeployer HOOK_DEPLOYER;
    // forge-lint: disable-next-line(mixed-case-variable)
    IJB721TiersHookStore HOOK_STORE;
    // forge-lint: disable-next-line(mixed-case-variable)
    IJBAddressRegistry ADDRESS_REGISTRY;

    // forge-lint: disable-next-line(mixed-case-variable)
    IREVLoans LOANS_CONTRACT;

    /// @notice Deploys and tracks suckers for revnets.
    // forge-lint: disable-next-line(mixed-case-variable)
    IJBSuckerRegistry SUCKER_REGISTRY;

    // forge-lint: disable-next-line(mixed-case-variable)
    CTPublisher PUBLISHER;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockBuybackDataHook MOCK_BUYBACK;

    // When the second project is deployed, track the block.timestamp.
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 INITIAL_TIMESTAMP;

    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 FEE_PROJECT_ID;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 REVNET_ID;

    // forge-lint: disable-next-line(mixed-case-variable)
    address USER = makeAddr("user");

    /// @notice The address that is allowed to forward calls.
    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    function getFeeProjectConfig() internal view returns (FeeProjectConfig memory) {
        // Define constants
        string memory name = "Revnet";
        string memory symbol = "$REV";
        string memory projectUri = "ipfs://QmNRHT91HcDgMcenebYX7rJigt77cgNcosvuhX21wkF3tx";
        uint8 decimals = 18;
        uint256 decimalMultiplier = 10 ** decimals;

        // The tokens that the project accepts and stores.
        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);

        // Accept the chain's native currency through the multi terminal.
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        // The terminals that the project will accept funds through.
        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        // The project's revnet stage configurations.
        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](3);

        {
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
                splitPercent: 2000, // 20%
                splits: splits,
                // forge-lint: disable-next-line(unsafe-typecast)
                initialIssuance: uint112(1000 * decimalMultiplier),
                issuanceCutFrequency: 90 days,
                issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
                cashOutTaxRate: 6000, // 0.6
                extraMetadata: 0
            });
        }

        stageConfigurations[1] = REVStageConfig({
            startsAtOrAfter: uint40(stageConfigurations[0].startsAtOrAfter + 720 days),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 2000, // 20%
            splits: splits,
            initialIssuance: 0, // inherit from previous cycle.
            issuanceCutFrequency: 180 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 1000, //0.1
            extraMetadata: 0
        });

        stageConfigurations[2] = REVStageConfig({
            startsAtOrAfter: uint40(stageConfigurations[1].startsAtOrAfter + (20 * 365 days)),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: 1,
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 500, // 0.05
            extraMetadata: 0
        });

        // The project's revnet configuration
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

    function getSecondProjectConfig() internal view returns (FeeProjectConfig memory) {
        // Define constants
        string memory name = "NANA";
        string memory symbol = "$NANA";
        string memory projectUri = "ipfs://QmNRHT91HcDgMcenebYX7rJigt77cgNxosvuhX21wkF3tx";
        uint8 decimals = 18;
        uint256 decimalMultiplier = 10 ** decimals;

        // The tokens that the project accepts and stores.
        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);

        // Accept the chain's native currency through the multi terminal.
        accountingContextsToAccept[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        // The terminals that the project will accept funds through.
        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: accountingContextsToAccept});

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        // The project's revnet stage configurations.
        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](3);

        {
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
                splitPercent: 2000, // 20%
                splits: splits,
                // forge-lint: disable-next-line(unsafe-typecast)
                initialIssuance: uint112(1000 * decimalMultiplier),
                issuanceCutFrequency: 90 days,
                issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
                cashOutTaxRate: 6000, // 0.6
                extraMetadata: 0
            });
        }

        stageConfigurations[1] = REVStageConfig({
            startsAtOrAfter: uint40(stageConfigurations[0].startsAtOrAfter + 365 days),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 9000, // 90%
            splits: splits,
            initialIssuance: 0, // this is a special number that is as close to max price as we can get.
            issuanceCutFrequency: 180 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: 0, // 0.0%
            extraMetadata: 0
        });

        stageConfigurations[2] = REVStageConfig({
            startsAtOrAfter: uint40(stageConfigurations[1].startsAtOrAfter + (20 * 365 days)),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: 0, // this is a special number that is as close to max price as we can get.
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 500, // 0.05
            extraMetadata: 0
        });

        // The project's revnet configuration
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
            jbDirectory(),
            jbPermissions(),
            jbPrices(),
            jbRulesets(),
            HOOK_STORE,
            jbSplits(),
            IJB721CheckpointsDeployer(address(new JB721CheckpointsDeployer(HOOK_STORE))),
            multisig()
        );

        ADDRESS_REGISTRY = new JBAddressRegistry();

        HOOK_DEPLOYER = new JB721TiersHookDeployer(EXAMPLE_HOOK, HOOK_STORE, ADDRESS_REGISTRY, multisig());

        PUBLISHER = new CTPublisher(jbDirectory(), jbPermissions(), FEE_PROJECT_ID, multisig());
        MOCK_BUYBACK = new MockBuybackDataHook();

        LOANS_CONTRACT = new REVLoans({
            controller: jbController(),
            suckerRegistry: IJBSuckerRegistry(address(new MockSuckerRegistry())),
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

        // Approve the basic deployer to configure the project.
        vm.prank(address(multisig()));
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);

        // Build the config.
        FeeProjectConfig memory feeProjectConfig = getFeeProjectConfig();

        // Configure the project.
        vm.prank(address(multisig()));
        (REVNET_ID,) = REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID, // Zero to deploy a new revnet
            configuration: feeProjectConfig.configuration,
            terminalConfigurations: feeProjectConfig.terminalConfigurations,
            suckerDeploymentConfiguration: feeProjectConfig.suckerDeploymentConfiguration,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        // Configure second revnet
        FeeProjectConfig memory fee2Config = getSecondProjectConfig();

        // Configure the second project.
        (REVNET_ID,) = REV_DEPLOYER.deployFor({
            revnetId: 0, // Zero to deploy a new revnet
            configuration: fee2Config.configuration,
            terminalConfigurations: fee2Config.terminalConfigurations,
            suckerDeploymentConfiguration: fee2Config.suckerDeploymentConfiguration,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        INITIAL_TIMESTAMP = block.timestamp;

        // Deploy handlers and assign them as targets
        PAY_HANDLER =
            new REVLoansCallHandler(jbMultiTerminal(), LOANS_CONTRACT, jbPermissions(), jbTokens(), REVNET_ID, USER);

        // Calls to perform via the handler
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = REVLoansCallHandler.payBorrow.selector;
        selectors[1] = REVLoansCallHandler.repayLoan.selector;
        selectors[2] = REVLoansCallHandler.reallocateCollateralFromLoan.selector;
        selectors[3] = REVLoansCallHandler.advanceTime.selector;
        selectors[4] = REVLoansCallHandler.liquidateLoans.selector;

        targetContract(address(PAY_HANDLER));
        targetSelector(FuzzSelector({addr: address(PAY_HANDLER), selectors: selectors}));
    }

    function invariant_A_User_Balance_And_Collateral() public view {
        IJBToken token = jbTokens().tokenOf(REVNET_ID);

        uint256 userTokenBalance = token.balanceOf(USER);
        if (PAY_HANDLER.RUNS() > 0) assertGe(userTokenBalance, PAY_HANDLER.COLLATERAL_RETURNED());

        // Ensure REVLoans and our handler/user have the same provided collateral amounts.
        assertEq(PAY_HANDLER.COLLATERAL_SUM(), LOANS_CONTRACT.totalCollateralOf(REVNET_ID));
    }

    function invariant_B_TotalBorrowed() public view {
        uint256 expectedTotalBorrowed = PAY_HANDLER.BORROWED_SUM();

        // Get the actual total borrowed amount from the contract
        uint256 actualTotalBorrowed = _getTotalBorrowedFromContract(REVNET_ID);

        // Assert that the expected and actual total borrowed amounts match
        assertEq(actualTotalBorrowed, expectedTotalBorrowed, "Total borrowed amount mismatch");
    }

    function _calculateExpectedTotalBorrowed(uint256 _revnetId) internal view returns (uint256 totalBorrowed) {
        // Access loan sources from the Loans contract
        REVLoanSource[] memory sources = LOANS_CONTRACT.loanSourcesOf(_revnetId);

        // Iterate through loan sources to calculate the total borrowed amount
        for (uint256 i = 0; i < sources.length; i++) {
            totalBorrowed += LOANS_CONTRACT.totalBorrowedFrom(_revnetId, sources[i].terminal, sources[i].token);
        }
    }

    function _getTotalBorrowedFromContract(uint256 _revnetId) internal view returns (uint256) {
        return LOANS_CONTRACT.totalBorrowedFrom(_revnetId, jbMultiTerminal(), JBConstants.NATIVE_TOKEN);
    }

    /// @notice INV-RL-3: loan.amount <= type(uint112).max for all active loans.
    /// @dev Verifies that no loan amount exceeds the uint112 storage boundary.
    function invariant_C_LoanAmountFitsUint112() public view {
        if (PAY_HANDLER.RUNS() == 0) return;

        for (uint256 i = 1; i <= PAY_HANDLER.RUNS(); i++) {
            uint256 loanId = (REVNET_ID * 1_000_000_000_000) + i;

            // Skip if loan was liquidated/burned
            try IERC721(address(LOANS_CONTRACT)).ownerOf(loanId) {}
            catch {
                continue;
            }

            REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);
            if (loan.amount == 0) continue;

            assertLe(uint256(loan.amount), uint256(type(uint112).max), "INV-RL-3: loan.amount must fit in uint112");
            assertLe(
                uint256(loan.collateral), uint256(type(uint112).max), "INV-RL-3: loan.collateral must fit in uint112"
            );
        }
    }

    /// @notice INV-RL-4: Active loans always have non-zero collateral.
    /// @dev Borrowable amounts can decrease as the revnet evolves (new payments change the
    ///      cashout curve), so we only check that collateral > 0 for active loans.
    function invariant_D_ActiveLoansHaveCollateral() public view {
        if (PAY_HANDLER.RUNS() == 0) return;

        for (uint256 i = 1; i <= PAY_HANDLER.RUNS(); i++) {
            uint256 loanId = (REVNET_ID * 1_000_000_000_000) + i;

            // Skip if loan was liquidated/burned
            try IERC721(address(LOANS_CONTRACT)).ownerOf(loanId) {}
            catch {
                continue;
            }

            REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);
            if (loan.amount == 0) continue;

            // Active loans must have non-zero collateral backing them.
            assertGt(uint256(loan.collateral), 0, "INV-RL-4: Active loan must have non-zero collateral");
        }
    }

    /// @notice INV-RL-5: Total collateral tracked by handler matches contract state.
    /// @dev This is already checked by invariant_A, but we add an explicit named check.
    function invariant_E_CollateralConsistency() public view {
        assertEq(
            PAY_HANDLER.COLLATERAL_SUM(),
            LOANS_CONTRACT.totalCollateralOf(REVNET_ID),
            "INV-RL-5: Handler collateral sum must match contract totalCollateralOf"
        );
    }
}
