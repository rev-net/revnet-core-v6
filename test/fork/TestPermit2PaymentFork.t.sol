// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "./ForkTestBase.sol";
import {REVEmpty721Config} from "../helpers/REVEmpty721Config.sol";
import {MockERC20} from "@bananapus/core-v6/test/mock/MockERC20.sol";
import {MockPriceFeed} from "@bananapus/core-v6/test/mock/MockPriceFeed.sol";
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

/// @notice Fork tests for Permit2-based ERC-20 payments to a revnet terminal.
///
/// Verifies that JBMultiTerminal._acceptFundsFor() correctly processes Permit2 metadata,
/// including valid signatures, expired signatures, and replayed nonces.
///
/// Run with: FOUNDRY_PROFILE=fork forge test --match-contract TestPermit2PaymentFork -vvv
contract TestPermit2PaymentFork is ForkTestBase {
    using JBMetadataResolver for bytes;

    // Permit2 signing key.
    uint256 constant PRIV_KEY = 0xBEEF1234;
    address signer;

    MockERC20 testToken;
    uint256 revnetId;

    // Permit2 EIP-712 typehashes (copied from nana-core-v6 test patterns).
    bytes32 public constant _PERMIT_DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");

    bytes32 public constant _PERMIT_SINGLE_TYPEHASH = keccak256(
        "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    // Permit2 domain separator (fetched at runtime from the deployed Permit2 contract).
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 DOMAIN_SEPARATOR;

    function setUp() public override {
        super.setUp();

        signer = vm.addr(PRIV_KEY);
        vm.deal(signer, 10 ether);

        // Deploy fee project.
        _deployFeeProject(5000);

        // Deploy a mock ERC-20 for testing.
        testToken = new MockERC20("Test Token", "TEST");

        // Add a price feed: testToken → NATIVE_TOKEN so the buyback hook can quote.
        // 1 testToken (6 dec) = 0.0005 ETH (i.e. 1 ETH = 2000 testTokens).
        MockPriceFeed priceFeed = new MockPriceFeed(5e14, 18);
        vm.prank(multisig());
        jbPrices()
            .addPriceFeedFor(
                0, uint32(uint160(address(testToken))), uint32(uint160(JBConstants.NATIVE_TOKEN)), priceFeed
            );

        // Deploy a revnet that accepts both native token and the test ERC-20.
        revnetId = _deployRevnetWithERC20(5000);

        // Fetch the Permit2 domain separator from the on-chain Permit2 contract.
        DOMAIN_SEPARATOR = permit2().DOMAIN_SEPARATOR();

        // Mint tokens to the signer and approve Permit2 (NOT the terminal directly).
        testToken.mint(signer, 1000e6);
        vm.prank(signer);
        IERC20(address(testToken)).approve(address(permit2()), type(uint256).max);
    }

    /// @notice Deploy a revnet that accepts both native token and the test ERC-20.
    function _deployRevnetWithERC20(uint16 cashOutTaxRate) internal returns (uint256 id) {
        JBAccountingContext[] memory acc = new JBAccountingContext[](2);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        acc[1] = JBAccountingContext({
            token: address(testToken), decimals: 6, currency: uint32(uint160(address(testToken)))
        });

        JBTerminalConfig[] memory tc = new JBTerminalConfig[](1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});

        REVStageConfig[] memory stages = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;
        stages[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: INITIAL_ISSUANCE,
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: cashOutTaxRate,
            extraMetadata: 0
        });

        REVConfig memory cfg = REVConfig({
            description: REVDescription("Permit2 Test", "P2T", "ipfs://p2t", "PERMIT2_SALT"),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });

        REVSuckerDeploymentConfig memory sdc = REVSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("PERMIT2_TEST"))
        });

        (id,) = REV_DEPLOYER.deployFor({
            revnetId: 0,
            configuration: cfg,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: sdc,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    /// @notice Build Permit2 metadata for a payment.
    function _buildPermit2Metadata(
        uint160 amount,
        uint48 expiration,
        uint48 nonce,
        uint256 sigDeadline
    )
        internal
        view
        returns (bytes memory metadata)
    {
        // Build the permit struct for signing.
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: address(testToken), amount: amount, expiration: expiration, nonce: nonce
            }),
            spender: address(jbMultiTerminal()),
            sigDeadline: sigDeadline
        });

        // Sign it.
        bytes memory sig = _getPermitSignature(permitSingle, PRIV_KEY, DOMAIN_SEPARATOR);

        // Pack into JBSingleAllowance.
        JBSingleAllowance memory allowance = JBSingleAllowance({
            sigDeadline: sigDeadline, amount: amount, expiration: expiration, nonce: nonce, signature: sig
        });

        // Encode as metadata with the "permit2" key targeting the terminal, plus a zero "quote"
        // so the buyback hook skips the TWAP pool lookup (no pool exists for testToken).
        bytes4[] memory ids = new bytes4[](2);
        bytes[] memory datas = new bytes[](2);
        ids[0] = JBMetadataResolver.getId("permit2", address(jbMultiTerminal()));
        datas[0] = abi.encode(allowance);
        ids[1] = JBMetadataResolver.getId("quote", address(BUYBACK_HOOK));
        datas[1] = abi.encode(uint256(0), uint256(0));
        metadata = JBMetadataResolver.createMetadata(ids, datas);
    }

    /// @notice Pay a revnet with ERC-20 via Permit2 with zero direct terminal approval -- succeeds.
    function testFork_Permit2PaymentSucceeds() public {
        uint160 payAmount = 100e6; // 100 tokens (6 decimals)
        uint48 expiration = uint48(block.timestamp + 1 days);
        uint256 sigDeadline = block.timestamp + 1 days;
        uint48 nonce = 0;

        bytes memory metadata = _buildPermit2Metadata(payAmount, expiration, nonce, sigDeadline);

        // Verify the signer has NOT approved the terminal directly.
        assertEq(
            IERC20(address(testToken)).allowance(signer, address(jbMultiTerminal())),
            0,
            "signer should have zero direct terminal approval"
        );

        // Pay using Permit2.
        vm.prank(signer);
        uint256 tokensReceived = jbMultiTerminal()
            .pay({
                projectId: revnetId,
                token: address(testToken),
                amount: payAmount,
                beneficiary: signer,
                minReturnedTokens: 0,
                memo: "permit2 payment",
                metadata: metadata
            });

        // Verify payment succeeded.
        assertGt(tokensReceived, 0, "should receive project tokens from Permit2 payment");

        // Verify tokens were transferred from signer to terminal.
        assertEq(
            testToken.balanceOf(address(jbMultiTerminal())), payAmount, "terminal should hold the paid ERC-20 tokens"
        );

        // Verify signer's token balance decreased.
        assertEq(testToken.balanceOf(signer), 1000e6 - payAmount, "signer's token balance should decrease");
    }

    /// @notice Payment with an expired Permit2 signature deadline should revert.
    function testFork_Permit2ExpiredSignatureReverts() public {
        uint160 payAmount = 100e6;
        uint48 expiration = uint48(block.timestamp + 1 days);
        uint48 nonce = 0;

        // Set sigDeadline in the past.
        uint256 expiredDeadline = block.timestamp - 1;

        bytes memory metadata = _buildPermit2Metadata(payAmount, expiration, nonce, expiredDeadline);

        // The Permit2 contract should reject the expired signature.
        // The terminal catches permit failures in try-catch and falls back to transferFrom,
        // which will also fail due to zero approval. So we expect a generic revert.
        vm.prank(signer);
        vm.expectRevert();
        jbMultiTerminal()
            .pay({
                projectId: revnetId,
                token: address(testToken),
                amount: payAmount,
                beneficiary: signer,
                minReturnedTokens: 0,
                memo: "expired permit2",
                metadata: metadata
            });
    }

    /// @notice Replaying the same Permit2 nonce should revert on the second payment.
    function testFork_Permit2ReplayReverts() public {
        uint160 payAmount = 50e6;
        uint48 expiration = uint48(block.timestamp + 1 days);
        uint256 sigDeadline = block.timestamp + 1 days;
        uint48 nonce = 0;

        bytes memory metadata = _buildPermit2Metadata(payAmount, expiration, nonce, sigDeadline);

        // First payment succeeds.
        vm.prank(signer);
        jbMultiTerminal()
            .pay({
                projectId: revnetId,
                token: address(testToken),
                amount: payAmount,
                beneficiary: signer,
                minReturnedTokens: 0,
                memo: "first permit2 payment",
                metadata: metadata
            });

        // Second payment with the same nonce.
        // The permit call will fail (nonce already used), terminal catches it via try-catch,
        // then falls back to transferFrom which fails because there is no direct approval.
        vm.prank(signer);
        vm.expectRevert();
        jbMultiTerminal()
            .pay({
                projectId: revnetId,
                token: address(testToken),
                amount: payAmount,
                beneficiary: signer,
                minReturnedTokens: 0,
                memo: "replayed permit2 payment",
                metadata: metadata
            });
    }

    // ───────────────────────── Permit2 Signature Helpers
    // ─────────────────────────

    /// @notice Sign a PermitSingle struct and return the concatenated signature.
    function _getPermitSignature(
        IAllowanceTransfer.PermitSingle memory permitSingle,
        uint256 privateKey,
        bytes32 domainSeparator
    )
        internal
        pure
        returns (bytes memory sig)
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

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }
}
