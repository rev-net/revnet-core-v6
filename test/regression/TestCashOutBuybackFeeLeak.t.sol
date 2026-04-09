// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import /* {*} from */ "../../src/REVDeployer.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@croptop/core-v6/src/CTPublisher.sol";

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";

import {REVConfig} from "../../src/structs/REVConfig.sol";
import {REVDescription} from "../../src/structs/REVDescription.sol";
import {REVStageConfig} from "../../src/structs/REVStageConfig.sol";
import {REVAutoIssuance} from "../../src/structs/REVAutoIssuance.sol";
import {REVSuckerDeploymentConfig} from "../../src/structs/REVSuckerDeploymentConfig.sol";
import {REVLoans} from "../../src/REVLoans.sol";
import {REVEmpty721Config} from "../helpers/REVEmpty721Config.sol";
import {MockBuybackCashOutRecorder} from "../mock/MockBuybackCashOutRecorder.sol";
import {REVOwner} from "../../src/REVOwner.sol";
import {IREVDeployer} from "../../src/interfaces/IREVDeployer.sol";

/// @title TestCashOutBuybackFeeLeak
/// @notice Proves the buyback hook callback receives only the non-fee cashOutCount (not the full count).
/// Before the fix, the buyback hook reminted and sold `context.cashOutCount` tokens — more than REVDeployer
/// intended. The fee portion was monetized through the pool sale AND the fee was also extracted from treasury.
contract TestCashOutBuybackFeeLeak is TestBaseWorkflow {
    bytes32 private constant REV_DEPLOYER_SALT = "REVDeployer";
    bytes32 private constant ERC20_SALT = "REV_TOKEN";
    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    REVDeployer internal revDeployer;
    REVOwner internal revOwner;
    MockBuybackCashOutRecorder internal mockBuyback;
    JB721TiersHook internal exampleHook;
    IJB721TiersHookDeployer internal hookDeployer;
    IJBAddressRegistry internal addressRegistry;
    JB721TiersHookStore internal hookStore;
    JBSuckerRegistry internal suckerRegistry;
    CTPublisher internal publisher;
    REVLoans internal loans;

    uint256 internal feeProjectId;
    uint256 internal revnetId;
    address internal user = makeAddr("user");

    function setUp() public override {
        super.setUp();

        feeProjectId = jbProjects().createFor(multisig());
        suckerRegistry = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig(), address(0));
        hookStore = new JB721TiersHookStore();
        exampleHook = new JB721TiersHook(
            jbDirectory(), jbPermissions(), jbPrices(), jbRulesets(), hookStore, jbSplits(), multisig()
        );
        addressRegistry = new JBAddressRegistry();
        hookDeployer = new JB721TiersHookDeployer(exampleHook, hookStore, addressRegistry, multisig());
        publisher = new CTPublisher(jbDirectory(), jbPermissions(), feeProjectId, multisig());
        mockBuyback = new MockBuybackCashOutRecorder();
        loans = new REVLoans({
            controller: jbController(),
            revId: feeProjectId,
            owner: address(this),
            permit2: permit2(),
            trustedForwarder: TRUSTED_FORWARDER
        });

        revOwner = new REVOwner(
            IJBBuybackHookRegistry(address(mockBuyback)),
            jbDirectory(),
            feeProjectId,
            IJBSuckerRegistry(address(suckerRegistry)),
            address(loans),
            address(0)
        );

        revDeployer = new REVDeployer{salt: REV_DEPLOYER_SALT}(
            jbController(),
            suckerRegistry,
            feeProjectId,
            hookDeployer,
            publisher,
            IJBBuybackHookRegistry(address(mockBuyback)),
            address(loans),
            TRUSTED_FORWARDER,
            address(revOwner)
        );

        revOwner.setDeployer(revDeployer);

        vm.prank(multisig());
        jbProjects().approve(address(revDeployer), feeProjectId);

        // Deploy fee project.
        vm.prank(multisig());
        _deployRevnet("Fee", "FEE", "ipfs://fee", "FEE_SALT", 6000, feeProjectId);

        // Deploy test revnet.
        (revnetId,) = _deployRevnet("Revnet", "REV", "ipfs://rev", ERC20_SALT, 6000, 0);
    }

    /// @notice The invariant: buyback hook should only process the non-fee token count.
    /// This test FAILS before the fix (proving the bug) and PASSES after.
    function test_buybackHookReceivesOnlyNonFeeCount() external {
        // Fund the user and pay into the revnet.
        vm.deal(user, 10 ether);
        vm.prank(user);
        jbMultiTerminal().pay{value: 5 ether}({
            projectId: revnetId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 5 ether,
            beneficiary: user,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        uint256 fullCashOutCount = jbTokens().totalBalanceOf(user, revnetId) / 2;
        assertGt(fullCashOutCount, 0, "user should have tokens");

        // The non-fee count: what the buyback hook SHOULD process.
        uint256 feeCashOutCount = fullCashOutCount * revDeployer.FEE() / JBConstants.MAX_FEE;
        uint256 expectedNonFeeCount = fullCashOutCount - feeCashOutCount;

        // Perform the cash out.
        vm.prank(user);
        jbMultiTerminal()
            .cashOutTokensOf({
                holder: user,
                projectId: revnetId,
                cashOutCount: fullCashOutCount,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(user),
                metadata: ""
            });

        // THE INVARIANT: The buyback hook callback should receive nonFeeCashOutCount.
        // The real buyback hook remints `context.cashOutCount` tokens and sells them on the pool.
        // If it receives fullCashOutCount, it sells the fee portion too — the fee is bypassed.
        assertEq(
            mockBuyback.afterCashOutCount(),
            expectedNonFeeCount,
            "BUG: buyback hook received full count instead of non-fee count"
        );
    }

    function _deployRevnet(
        string memory name,
        string memory symbol,
        string memory projectUri,
        bytes32 salt,
        uint16 cashOutTaxRate,
        uint256 existingProjectId
    )
        internal
        returns (uint256 id, IJB721TiersHook hook)
    {
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
        stageConfigurations[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 2000,
            splits: splits,
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 90 days,
            issuanceCutPercent: JBConstants.MAX_WEIGHT_CUT_PERCENT / 2,
            cashOutTaxRate: cashOutTaxRate,
            extraMetadata: 0
        });

        return revDeployer.deployFor({
            revnetId: existingProjectId,
            configuration: REVConfig({
                description: REVDescription(name, symbol, projectUri, salt),
                baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
                splitOperator: multisig(),
                stageConfigurations: stageConfigurations
            }),
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked(symbol))
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }
}
