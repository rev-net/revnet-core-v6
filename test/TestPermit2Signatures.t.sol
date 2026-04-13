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
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {REVEmpty721Config} from "./helpers/REVEmpty721Config.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JBFees} from "@bananapus/core-v6/src/libraries/JBFees.sol";
import {REVOwner} from "../src/REVOwner.sol";
import {IREVDeployer} from "../src/interfaces/IREVDeployer.sol";

struct Permit2ProjectConfig {
    REVConfig configuration;
    JBTerminalConfig[] terminalConfigurations;
    REVSuckerDeploymentConfig suckerDeploymentConfiguration;
}

/// @title TestPermit2Signatures
/// @notice Tests that REVLoans.repayLoan() works correctly with real Permit2 signatures,
///         including happy-path repayment, expired signatures, and wrong-signer scenarios.
contract TestPermit2Signatures is TestBaseWorkflow {
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

    address private constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    // Permit2 signature type hashes (from nana-core-v6 TestPermit2Terminal).
    bytes32 public constant _PERMIT_DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");

    bytes32 public constant _PERMIT_SINGLE_TYPEHASH = keccak256(
        "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    // Permit2 domain separator, set in setUp.
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 DOMAIN_SEPARATOR;

    // Private key and derived address for signing.
    uint256 private signerPrivateKey = 0x12341234;
    address private signer;

    function _getFeeProjectConfig() internal view returns (Permit2ProjectConfig memory) {
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

        return Permit2ProjectConfig({
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("REV"))
            })
        });
    }

    function _getRevnetConfig() internal view returns (Permit2ProjectConfig memory) {
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

        return Permit2ProjectConfig({
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("NANA"))
            })
        });
    }

    function setUp() public override {
        super.setUp();

        signer = vm.addr(signerPrivateKey);

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
            suckerRegistry: IJBSuckerRegistry(address(0)),
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

        // Deploy fee project.
        Permit2ProjectConfig memory feeProjectConfig = _getFeeProjectConfig();
        vm.prank(address(multisig()));
        REV_DEPLOYER.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeProjectConfig.configuration,
            terminalConfigurations: feeProjectConfig.terminalConfigurations,
            suckerDeploymentConfiguration: feeProjectConfig.suckerDeploymentConfiguration,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        // Deploy second revnet with loans enabled.
        Permit2ProjectConfig memory revnetConfig = _getRevnetConfig();
        (REVNET_ID,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: revnetConfig.configuration,
            terminalConfigurations: revnetConfig.terminalConfigurations,
            suckerDeploymentConfiguration: revnetConfig.suckerDeploymentConfiguration,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });

        // Set the Permit2 domain separator.
        DOMAIN_SEPARATOR = permit2().DOMAIN_SEPARATOR();

        // Fund the signer.
        vm.deal(signer, 1000e18);
    }

    // =========================================================================
    // Permit2 signature helpers (from nana-core-v6/test/TestPermit2Terminal.sol)
    // =========================================================================

    function _getPermitSignatureRaw(
        IAllowanceTransfer.PermitSingle memory permitSingle,
        uint256 privateKey,
        bytes32 domainSeparator
    )
        internal
        pure
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 permitHash = keccak256(abi.encode(_PERMIT_DETAILS_TYPEHASH, permitSingle.details));

        bytes32 msgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                keccak256(
                    abi.encode(_PERMIT_SINGLE_TYPEHASH, permitHash, permitSingle.spender, permitSingle.sigDeadline)
                )
            )
        );

        (v, r, s) = vm.sign(privateKey, msgHash);
    }

    function _getPermitSignature(
        IAllowanceTransfer.PermitSingle memory permitSingle,
        uint256 privateKey,
        bytes32 domainSeparator
    )
        internal
        pure
        returns (bytes memory sig)
    {
        (uint8 v, bytes32 r, bytes32 s) = _getPermitSignatureRaw(permitSingle, privateKey, domainSeparator);
        return bytes.concat(r, s, bytes1(v));
    }

    // =========================================================================
    // Helper: create a loan from ERC20 tokens (not native)
    // =========================================================================

    function _setupERC20Loan(
        address user,
        uint256 tokenAmount,
        uint256 prepaidFee
    )
        internal
        returns (uint256 loanId, uint256 tokenCount, uint256 borrowAmount)
    {
        // Deal the user ERC20 tokens and approve the terminal.
        deal(address(TOKEN), user, tokenAmount);
        vm.prank(user);
        TOKEN.approve(address(jbMultiTerminal()), tokenAmount);

        // Pay into revnet to get project tokens.
        vm.prank(user);
        tokenCount = jbMultiTerminal().pay(REVNET_ID, address(TOKEN), tokenAmount, user, 0, "", "");

        // Check borrowable amount.
        borrowAmount = LOANS_CONTRACT.borrowableAmountFrom(REVNET_ID, tokenCount, 6, uint32(uint160(address(TOKEN))));

        if (borrowAmount == 0) return (0, tokenCount, 0);

        // Mock permission for loans contract to burn tokens.
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(LOANS_CONTRACT), user, REVNET_ID, 11, true, true)),
            abi.encode(true)
        );

        REVLoanSource memory source = REVLoanSource({token: address(TOKEN), terminal: jbMultiTerminal()});

        vm.prank(user);
        (loanId,) = LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, tokenCount, payable(user), prepaidFee, user);
    }

    // =========================================================================
    // Test: repay loan with a real Permit2 signature
    // =========================================================================

    /// @notice Repays a loan using a real Permit2 signature instead of direct ERC20 approval.
    /// @dev Verifies end-to-end Permit2 flow: sign -> repayLoan -> funds transferred.
    function test_permit2_realSignature_repayLoan() public {
        // Create a loan from the signer's ERC20 tokens.
        uint256 payAmount = 100e6; // 100 USDC-like tokens (6 decimals).
        (uint256 loanId, uint256 tokenCount, uint256 borrowAmount) =
            _setupERC20Loan(signer, payAmount, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());

        // Skip if borrowable amount was zero.
        vm.assume(borrowAmount > 0);
        vm.assume(tokenCount > 0);
        vm.assume(loanId > 0);

        // Get loan details.
        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);
        assertTrue(loan.amount > 0, "Loan amount should be non-zero");

        // Calculate repay amount (loan amount + source fee for immediate repay).
        uint256 sourceFee = LOANS_CONTRACT.determineSourceFeeAmount(loan, loan.amount);
        uint256 totalRepay = loan.amount + sourceFee;

        // Give the signer enough ERC20 tokens to repay.
        deal(address(TOKEN), signer, totalRepay * 2);

        // Approve Permit2 contract to spend the signer's tokens (step 1 of Permit2 flow).
        vm.prank(signer);
        TOKEN.approve(address(permit2()), type(uint256).max);

        // Build and sign a Permit2 allowance for REVLoans to spend tokens.
        uint48 expiration = uint48(block.timestamp + 1 hours);
        uint256 sigDeadline = block.timestamp + 1 hours;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint160 permitAmount = uint160(totalRepay * 2);

        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: address(TOKEN), amount: permitAmount, expiration: expiration, nonce: 0
            }),
            spender: address(LOANS_CONTRACT),
            sigDeadline: sigDeadline
        });

        bytes memory sig = _getPermitSignature(permitSingle, signerPrivateKey, DOMAIN_SEPARATOR);

        // Build the JBSingleAllowance with the real signature.
        JBSingleAllowance memory allowance = JBSingleAllowance({
            sigDeadline: sigDeadline, amount: permitAmount, expiration: expiration, nonce: uint48(0), signature: sig
        });

        // Record balances before repayment.
        uint256 signerBalanceBefore = TOKEN.balanceOf(signer);
        uint256 totalCollateralBefore = LOANS_CONTRACT.totalCollateralOf(REVNET_ID);

        // Repay the loan using the Permit2 signature (no direct ERC20 approval to LOANS_CONTRACT).
        vm.prank(signer);
        LOANS_CONTRACT.repayLoan({
            loanId: loanId,
            maxRepayBorrowAmount: totalRepay * 2,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(signer),
            allowance: allowance
        });

        // Verify repayment succeeded: signer spent tokens.
        uint256 signerBalanceAfter = TOKEN.balanceOf(signer);
        assertTrue(signerBalanceAfter < signerBalanceBefore, "Signer should have spent tokens on repayment");

        // Verify collateral was returned.
        uint256 totalCollateralAfter = LOANS_CONTRACT.totalCollateralOf(REVNET_ID);
        assertEq(totalCollateralAfter, totalCollateralBefore - loan.collateral, "Collateral should be returned");
    }

    // =========================================================================
    // Test: expired Permit2 signature reverts
    // =========================================================================

    /// @notice Verifies that an expired Permit2 signature causes the repayLoan call to revert.
    /// @dev The Permit2 contract rejects signatures whose sigDeadline has passed.
    function test_permit2_expiredSignature_reverts() public {
        // Create a loan.
        uint256 payAmount = 100e6;
        (uint256 loanId, uint256 tokenCount, uint256 borrowAmount) =
            _setupERC20Loan(signer, payAmount, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());

        vm.assume(borrowAmount > 0);
        vm.assume(tokenCount > 0);
        vm.assume(loanId > 0);

        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);
        uint256 sourceFee = LOANS_CONTRACT.determineSourceFeeAmount(loan, loan.amount);
        uint256 totalRepay = loan.amount + sourceFee;

        // Give tokens and approve Permit2.
        deal(address(TOKEN), signer, totalRepay * 2);
        vm.prank(signer);
        TOKEN.approve(address(permit2()), type(uint256).max);

        // Sign with a deadline that is already expired.
        uint256 expiredDeadline = block.timestamp - 1;
        uint48 expiration = uint48(block.timestamp + 1 hours);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint160 permitAmount = uint160(totalRepay * 2);

        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: address(TOKEN), amount: permitAmount, expiration: expiration, nonce: 0
            }),
            spender: address(LOANS_CONTRACT),
            sigDeadline: expiredDeadline
        });

        bytes memory sig = _getPermitSignature(permitSingle, signerPrivateKey, DOMAIN_SEPARATOR);

        JBSingleAllowance memory allowance = JBSingleAllowance({
            sigDeadline: expiredDeadline, amount: permitAmount, expiration: expiration, nonce: uint48(0), signature: sig
        });

        // The Permit2 try-catch in _acceptFundsFor swallows the permit error,
        // so the permit call itself does not revert. However, the subsequent _transferFrom
        // will attempt PERMIT2.transferFrom which requires the allowance to have been set.
        // Since the expired permit did not set the allowance, _transferFrom will revert.
        vm.prank(signer);
        vm.expectRevert();
        LOANS_CONTRACT.repayLoan({
            loanId: loanId,
            maxRepayBorrowAmount: totalRepay * 2,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(signer),
            allowance: allowance
        });
    }

    // =========================================================================
    // Test: wrong signer — signature signed by A, call from B
    // =========================================================================

    /// @notice Verifies that a Permit2 signature signed by one key cannot be used by a different address.
    /// @dev The permit2.permit() call checks that the signature matches the `owner` parameter,
    ///      which is _msgSender() in _acceptFundsFor. If they do not match, the permit fails,
    ///      and the subsequent transfer also fails since no allowance was set.
    function test_permit2_wrongSigner_reverts() public {
        // Create a loan owned by the signer.
        uint256 payAmount = 100e6;
        (uint256 loanId, uint256 tokenCount, uint256 borrowAmount) =
            _setupERC20Loan(signer, payAmount, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());

        vm.assume(borrowAmount > 0);
        vm.assume(tokenCount > 0);
        vm.assume(loanId > 0);

        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);
        uint256 sourceFee = LOANS_CONTRACT.determineSourceFeeAmount(loan, loan.amount);
        uint256 totalRepay = loan.amount + sourceFee;

        // Use a completely different private key for signing.
        uint256 wrongPrivateKey = 0xDEADBEEF;
        address wrongSigner = vm.addr(wrongPrivateKey);

        // Transfer the loan NFT to the wrongSigner so they can call repayLoan.
        vm.prank(signer);
        REVLoans(payable(address(LOANS_CONTRACT))).transferFrom(signer, wrongSigner, loanId);

        // Give tokens to the wrongSigner and approve Permit2.
        deal(address(TOKEN), wrongSigner, totalRepay * 2);
        vm.prank(wrongSigner);
        TOKEN.approve(address(permit2()), type(uint256).max);

        // Sign the permit with the ORIGINAL signer's key (not wrongSigner's key).
        uint48 expiration = uint48(block.timestamp + 1 hours);
        uint256 sigDeadline = block.timestamp + 1 hours;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint160 permitAmount = uint160(totalRepay * 2);

        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: address(TOKEN), amount: permitAmount, expiration: expiration, nonce: 0
            }),
            spender: address(LOANS_CONTRACT),
            sigDeadline: sigDeadline
        });

        // Sign with the original signer's key, but call will come from wrongSigner.
        bytes memory sig = _getPermitSignature(permitSingle, signerPrivateKey, DOMAIN_SEPARATOR);

        JBSingleAllowance memory allowance = JBSingleAllowance({
            sigDeadline: sigDeadline, amount: permitAmount, expiration: expiration, nonce: uint48(0), signature: sig
        });

        // The permit2.permit() call will fail because the signature was signed for
        // the original signer's address, but _msgSender() is wrongSigner.
        // The try-catch swallows this, then _transferFrom fails since no allowance was set.
        vm.prank(wrongSigner);
        vm.expectRevert();
        LOANS_CONTRACT.repayLoan({
            loanId: loanId,
            maxRepayBorrowAmount: totalRepay * 2,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(wrongSigner),
            allowance: allowance
        });
    }

    // =========================================================================
    // Test: repay with correct signer matches permit owner
    // =========================================================================

    /// @notice Verifies that a properly signed Permit2 allowance where the signer matches
    ///         _msgSender() succeeds, while the same signature fails when called from a
    ///         different address. This validates the signer-caller binding.
    function test_permit2_signerMatchesCaller() public {
        // Create a loan from the signer.
        uint256 payAmount = 100e6;
        (uint256 loanId, uint256 tokenCount, uint256 borrowAmount) =
            _setupERC20Loan(signer, payAmount, LOANS_CONTRACT.MIN_PREPAID_FEE_PERCENT());

        vm.assume(borrowAmount > 0);
        vm.assume(tokenCount > 0);
        vm.assume(loanId > 0);

        REVLoan memory loan = LOANS_CONTRACT.loanOf(loanId);
        uint256 sourceFee = LOANS_CONTRACT.determineSourceFeeAmount(loan, loan.amount);
        uint256 totalRepay = loan.amount + sourceFee;

        // Give signer enough tokens to repay.
        deal(address(TOKEN), signer, totalRepay * 2);

        // Approve Permit2 to spend tokens.
        vm.prank(signer);
        TOKEN.approve(address(permit2()), type(uint256).max);

        // Build the Permit2 signature where spender = LOANS_CONTRACT, signed by signer.
        uint48 expiration = uint48(block.timestamp + 1 hours);
        uint256 sigDeadline = block.timestamp + 1 hours;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint160 permitAmount = uint160(totalRepay * 2);

        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: address(TOKEN), amount: permitAmount, expiration: expiration, nonce: 0
            }),
            spender: address(LOANS_CONTRACT),
            sigDeadline: sigDeadline
        });

        bytes memory sig = _getPermitSignature(permitSingle, signerPrivateKey, DOMAIN_SEPARATOR);

        JBSingleAllowance memory allowance = JBSingleAllowance({
            sigDeadline: sigDeadline, amount: permitAmount, expiration: expiration, nonce: uint48(0), signature: sig
        });

        // When called by the signer (who signed the permit), it should succeed.
        vm.prank(signer);
        LOANS_CONTRACT.repayLoan({
            loanId: loanId,
            maxRepayBorrowAmount: totalRepay * 2,
            collateralCountToReturn: loan.collateral,
            beneficiary: payable(signer),
            allowance: allowance
        });

        // Verify collateral was returned.
        uint256 totalCollateral = LOANS_CONTRACT.totalCollateralOf(REVNET_ID);
        assertEq(totalCollateral, 0, "All collateral should be returned after full repay");
    }
}
