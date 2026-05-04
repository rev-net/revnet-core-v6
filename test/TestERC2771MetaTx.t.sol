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
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";
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
import {JB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/JB721CheckpointsDeployer.sol";
import {IJB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721CheckpointsDeployer.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {REVEmpty721Config} from "./helpers/REVEmpty721Config.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {ERC2771ForwarderMock, ForwardRequest} from "@bananapus/core-v6/test/mock/ERC2771ForwarderMock.sol";
import {REVOwner} from "../src/REVOwner.sol";
import {IREVDeployer} from "../src/interfaces/IREVDeployer.sol";
import {MockSuckerRegistry} from "./mock/MockSuckerRegistry.sol";
import {IREVHiddenTokens} from "../src/interfaces/IREVHiddenTokens.sol";

struct MetaTxProjectConfig {
    REVConfig configuration;
    JBTerminalConfig[] terminalConfigurations;
    REVSuckerDeploymentConfig suckerDeploymentConfiguration;
}

/// @title TestERC2771MetaTx
/// @notice Tests that REVLoans and REVDeployer correctly use ERC2771Context,
///         ensuring _msgSender() returns the actual user when called through a trusted forwarder,
///         and falls back to msg.sender when called through an untrusted one.
contract TestERC2771MetaTx is TestBaseWorkflow {
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
    REVLoans LOANS_CONTRACT;
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

    // The trusted forwarder mock deployed at a specific address.
    ERC2771ForwarderMock internal erc2771Forwarder;
    address internal constant FORWARDER_ADDRESS = address(123_456);

    // Meta-tx signer and relayer.
    uint256 internal signerPrivateKey;
    uint256 internal relayerPrivateKey;
    address internal signerAddr;
    address internal relayerAddr;

    function _getFeeProjectConfig() internal view returns (MetaTxProjectConfig memory) {
        string memory name = "Revnet";
        string memory symbol = "$REV";
        string memory projectUri = "ipfs://QmNRHT91HcDgMcenebYX7rJigt77cgNcosvuhX21wkF3tx";
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
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription(name, symbol, projectUri, ERC20_SALT),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations
        });

        return MetaTxProjectConfig({
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("REV"))
            })
        });
    }

    function _getRevnetConfig() internal view returns (MetaTxProjectConfig memory) {
        string memory name = "NANA";
        string memory symbol = "$NANA";
        string memory projectUri = "ipfs://QmNRHT91HcDgMcenebYX7rJigt77cgNxosvuhX21wkF3tx";
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
            // forge-lint: disable-next-line(named-struct-fields)
            description: REVDescription(name, symbol, projectUri, "NANA_TOKEN"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stageConfigurations
        });

        return MetaTxProjectConfig({
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("NANA"))
            })
        });
    }

    // =========================================================================
    // Helper: construct a ForwardRequestData from a ForwardRequest
    // =========================================================================

    function _forgeRequestData(
        uint256 value,
        uint256 nonce,
        uint48 deadline,
        bytes memory data,
        address target
    )
        internal
        view
        returns (ERC2771Forwarder.ForwardRequestData memory)
    {
        ForwardRequest memory request = ForwardRequest({
            from: signerAddr, to: target, value: value, gas: 3_000_000, nonce: nonce, deadline: deadline, data: data
        });

        bytes32 digest = erc2771Forwarder.structHash(request);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        return ERC2771Forwarder.ForwardRequestData({
            from: request.from,
            to: request.to,
            value: request.value,
            gas: request.gas,
            deadline: request.deadline,
            data: request.data,
            signature: signature
        });
    }

    function setUp() public override {
        super.setUp();

        signerPrivateKey = 0xA11CE;
        relayerPrivateKey = 0xB0B;
        signerAddr = vm.addr(signerPrivateKey);
        relayerAddr = vm.addr(relayerPrivateKey);

        // Deploy ERC2771ForwarderMock at the FORWARDER_ADDRESS using deployCodeTo.
        deployCodeTo("ERC2771ForwarderMock.sol", abi.encode("ERC2771Forwarder"), FORWARDER_ADDRESS);
        erc2771Forwarder = ERC2771ForwarderMock(FORWARDER_ADDRESS);

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
        TOKEN = new MockERC20("1/2 ETH", "1/2");

        MockPriceFeed priceFeed = new MockPriceFeed(1e21, 6);
        vm.prank(multisig());
        jbPrices()
            .addPriceFeedFor(0, uint32(uint160(address(TOKEN))), uint32(uint160(JBConstants.NATIVE_TOKEN)), priceFeed);

        // Deploy LOANS_CONTRACT with the forwarder as trusted forwarder.
        LOANS_CONTRACT = new REVLoans({
            controller: jbController(),
            suckerRegistry: IJBSuckerRegistry(address(new MockSuckerRegistry())),
            revId: FEE_PROJECT_ID,
            owner: address(this),
            permit2: permit2(),
            trustedForwarder: FORWARDER_ADDRESS
        });

        REV_OWNER = new REVOwner(
            IJBBuybackHookRegistry(address(MOCK_BUYBACK)),
            jbDirectory(),
            FEE_PROJECT_ID,
            SUCKER_REGISTRY,
            LOANS_CONTRACT,
            IREVHiddenTokens(address(0))
        );

        REV_DEPLOYER = new REVDeployer{salt: REV_DEPLOYER_SALT}(
            jbController(),
            SUCKER_REGISTRY,
            FEE_PROJECT_ID,
            HOOK_DEPLOYER,
            PUBLISHER,
            IJBBuybackHookRegistry(address(MOCK_BUYBACK)),
            LOANS_CONTRACT,
            FORWARDER_ADDRESS,
            address(REV_OWNER)
        );

        REV_OWNER.setDeployer(REV_DEPLOYER);

        // Approve the deployer to configure the project.
        vm.prank(address(multisig()));
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);

        // Deploy fee project.
        MetaTxProjectConfig memory feeProjectConfig = _getFeeProjectConfig();
        vm.prank(address(multisig()));
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeProjectConfig.configuration,
            terminalConfigurations: feeProjectConfig.terminalConfigurations,
            suckerDeploymentConfiguration: feeProjectConfig.suckerDeploymentConfiguration,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        // Deploy second revnet.
        MetaTxProjectConfig memory revnetConfig = _getRevnetConfig();
        (REVNET_ID,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: revnetConfig.configuration,
            terminalConfigurations: revnetConfig.terminalConfigurations,
            suckerDeploymentConfiguration: revnetConfig.suckerDeploymentConfiguration,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        // Fund the signer and relayer.
        vm.deal(signerAddr, 1000e18);
        vm.deal(relayerAddr, 1000e18);
    }

    // =========================================================================
    // Test: ERC2771 trusted forwarder is correctly configured
    // =========================================================================

    /// @notice Verifies that the trusted forwarder is set correctly on REVLoans.
    function test_erc2771_trustedForwarderIsSet() public view {
        assertTrue(LOANS_CONTRACT.isTrustedForwarder(FORWARDER_ADDRESS), "Forwarder should be trusted");
        assertFalse(LOANS_CONTRACT.isTrustedForwarder(address(0x999)), "Random address should not be trusted");
    }

    // =========================================================================
    // Test: borrow via trusted forwarder — loan owned by signer, not relayer
    // =========================================================================

    /// @notice When borrowFrom() is called through the trusted forwarder, the loan NFT
    ///         should be minted to the actual signer (from the appended calldata),
    ///         not the relayer who submitted the transaction.
    function test_erc2771_borrowViaForwarder() public {
        // First, signer pays into the revnet to get tokens.
        vm.prank(signerAddr);
        uint256 tokenCount =
            jbMultiTerminal().pay{value: 10e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, signerAddr, 0, "", "");
        assertTrue(tokenCount > 0, "Should receive tokens from payment");

        // Check borrowable amount.
        uint256 borrowable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokenCount, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        vm.assume(borrowable > 0);

        // Mock permission for loans contract to burn the signer's tokens.
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(
                IJBPermissions.hasPermission, (address(LOANS_CONTRACT), signerAddr, REVNET_ID, 11, true, true)
            ),
            abi.encode(true)
        );

        // Encode the borrowFrom call.
        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        bytes memory borrowData = abi.encodeWithSelector(
            IREVLoans.borrowFrom.selector,
            REVNET_ID,
            source,
            0, // minBorrowAmount
            tokenCount,
            payable(signerAddr),
            uint256(25), // MIN_PREPAID_FEE_PERCENT
            signerAddr // holder
        );

        // Build the forwarded request signed by the signer.
        ERC2771Forwarder.ForwardRequestData memory requestData = _forgeRequestData({
            value: 0, nonce: 0, deadline: uint48(block.timestamp + 1), data: borrowData, target: address(LOANS_CONTRACT)
        });

        // Relayer submits the meta-tx.
        vm.prank(relayerAddr);
        erc2771Forwarder.execute{value: 0}(requestData);

        // Verify the loan was created and is owned by the signer (not the relayer).
        uint256 loansBalance = LOANS_CONTRACT.balanceOf(signerAddr);
        assertTrue(loansBalance > 0, "Signer should own the loan NFT");

        uint256 relayerLoans = LOANS_CONTRACT.balanceOf(relayerAddr);
        assertEq(relayerLoans, 0, "Relayer should not own any loan NFTs");
    }

    // =========================================================================
    // Test: repay via trusted forwarder
    // =========================================================================

    /// @notice When repayLoan() is called through the trusted forwarder, the loan owner
    ///         check should use _msgSender() (the signer), not msg.sender (the forwarder).
    function test_erc2771_repayViaForwarder() public {
        // Signer pays to get tokens and creates a loan.
        vm.prank(signerAddr);
        uint256 tokenCount =
            jbMultiTerminal().pay{value: 10e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, signerAddr, 0, "", "");

        uint256 borrowable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokenCount, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        vm.assume(borrowable > 0);

        // Mock permission.
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(
                IJBPermissions.hasPermission, (address(LOANS_CONTRACT), signerAddr, REVNET_ID, 11, true, true)
            ),
            abi.encode(true)
        );

        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        vm.prank(signerAddr);
        (uint256 loanId,) =
            LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(signerAddr), 25, signerAddr);

        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);
        assertTrue(loan.amount > 0, "Loan should exist");

        // Calculate repay amount.
        uint256 sourceFee = LOANS_CONTRACT.determineSourceFeeAmount(loan, loan.amount);
        uint256 totalRepay = loan.amount + sourceFee;

        // Encode the repayLoan call.
        bytes memory repayData = abi.encodeWithSelector(
            IREVLoans.repayLoan.selector,
            loanId,
            totalRepay * 2, // maxRepayBorrowAmount
            loan.collateral,
            payable(signerAddr),
            JBSingleAllowance({sigDeadline: 0, amount: 0, expiration: 0, nonce: 0, signature: ""})
        );

        // Build the forwarded request signed by the signer.
        ERC2771Forwarder.ForwardRequestData memory requestData = _forgeRequestData({
            value: totalRepay * 2,
            nonce: 0,
            deadline: uint48(block.timestamp + 1),
            data: repayData,
            target: address(LOANS_CONTRACT)
        });

        // Relayer submits the meta-tx with ETH.
        vm.prank(relayerAddr);
        erc2771Forwarder.execute{value: totalRepay * 2}(requestData);

        // Verify loan was repaid: collateral should be zero.
        uint256 totalCollateral = LOANS_CONTRACT.totalCollateralOf(REVNET_ID);
        assertEq(totalCollateral, 0, "All collateral should be returned after repay via forwarder");
    }

    // =========================================================================
    // Test: untrusted forwarder uses msg.sender, not appended address
    // =========================================================================

    /// @notice When a call is forwarded through a forwarder that is NOT the trusted one,
    ///         OpenZeppelin's ERC2771Forwarder checks `isTrustedForwarder` on the target
    ///         and reverts with `ERC2771UntrustfulTarget`. This prevents identity spoofing
    ///         at the forwarder level itself.
    function test_erc2771_untrustedForwarder_usesMsgSender() public {
        // Deploy a different forwarder at a different address (NOT the trusted one).
        address untrustedForwarderAddr = address(789_012);
        deployCodeTo("ERC2771ForwarderMock.sol", abi.encode("UntrustedForwarder"), untrustedForwarderAddr);
        ERC2771ForwarderMock untrustedForwarder = ERC2771ForwarderMock(untrustedForwarderAddr);

        // Verify the untrusted forwarder is not trusted by the LOANS_CONTRACT.
        assertFalse(
            LOANS_CONTRACT.isTrustedForwarder(untrustedForwarderAddr), "Untrusted forwarder should not be trusted"
        );

        // Signer pays to get tokens.
        vm.prank(signerAddr);
        uint256 tokenCount =
            jbMultiTerminal().pay{value: 10e18}(REVNET_ID, JBConstants.NATIVE_TOKEN, 10e18, signerAddr, 0, "", "");

        uint256 borrowable =
            LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokenCount, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        vm.assume(borrowable > 0);

        // Encode the borrowFrom call.
        REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        bytes memory borrowData = abi.encodeWithSelector(
            IREVLoans.borrowFrom.selector, REVNET_ID, source, 0, tokenCount, payable(signerAddr), uint256(25)
        );

        // Build a forwarded request using the signer's key via the UNTRUSTED forwarder.
        ForwardRequest memory request = ForwardRequest({
            from: signerAddr,
            to: address(LOANS_CONTRACT),
            value: 0,
            gas: 3_000_000,
            nonce: 0,
            deadline: uint48(block.timestamp + 1),
            data: borrowData
        });

        bytes32 digest = untrustedForwarder.structHash(request);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        ERC2771Forwarder.ForwardRequestData memory requestData = ERC2771Forwarder.ForwardRequestData({
            from: request.from,
            to: request.to,
            value: request.value,
            gas: request.gas,
            deadline: request.deadline,
            data: request.data,
            signature: signature
        });

        // OpenZeppelin's ERC2771Forwarder.execute() checks isTrustedForwarder on the
        // target contract. Since the untrusted forwarder is not the trusted one,
        // it reverts with ERC2771UntrustfulTarget(target, forwarder).
        vm.prank(relayerAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC2771Forwarder.ERC2771UntrustfulTarget.selector, address(LOANS_CONTRACT), untrustedForwarderAddr
            )
        );
        untrustedForwarder.execute{value: 0}(requestData);

        // Verify no loan was created for the signer.
        uint256 signerLoansBalance = LOANS_CONTRACT.balanceOf(signerAddr);
        assertEq(signerLoansBalance, 0, "No loan should exist since untrusted forwarder was rejected");
    }

    // =========================================================================
    // Test: forwarder is correctly deployed and functional
    // =========================================================================

    /// @notice Sanity check that the forwarder mock deployed correctly.
    function test_erc2771_forwarderDeployed() public view {
        assertTrue(erc2771Forwarder.deployed(), "Forwarder should report as deployed");
    }
}
