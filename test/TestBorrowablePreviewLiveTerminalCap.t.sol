// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
import "@bananapus/721-hook-v6/script/helpers/Hook721DeploymentLib.sol";
import "@bananapus/suckers-v6/script/helpers/SuckerDeploymentLib.sol";
import "@croptop/core-v6/script/helpers/CroptopDeploymentLib.sol";
import "@bananapus/router-terminal-v6/script/helpers/RouterTerminalDeploymentLib.sol";
import "@croptop/core-v6/src/CTPublisher.sol";
import "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import "@bananapus/721-hook-v6/src/JB721CheckpointsDeployer.sol";
import {IJB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721CheckpointsDeployer.sol";
import "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import "@bananapus/core-v6/src/libraries/JBConstants.sol";
import "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import "@bananapus/core-v6/src/structs/JBSplit.sol";
import "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";

import {MockBuybackDataHook} from "./mock/MockBuybackDataHook.sol";
import {REVEmpty721Config} from "./helpers/REVEmpty721Config.sol";
import {REVDeployer} from "../src/REVDeployer.sol";
import {REVLoans} from "../src/REVLoans.sol";
import {REVOwner} from "../src/REVOwner.sol";
import {IREVLoans} from "../src/interfaces/IREVLoans.sol";
import {IREVDeployer} from "../src/interfaces/IREVDeployer.sol";
import {REVConfig} from "../src/structs/REVConfig.sol";
import {REVDescription} from "../src/structs/REVDescription.sol";
import {REVStageConfig} from "../src/structs/REVStageConfig.sol";
import {REVAutoIssuance} from "../src/structs/REVStageConfig.sol";
import {REVLoan} from "../src/structs/REVLoan.sol";
import {REVSuckerDeploymentConfig} from "../src/structs/REVSuckerDeploymentConfig.sol";
import {MockEmptyTerminal} from "./mock/MockEmptyTerminal.sol";

/// @notice A sucker registry stand-in whose cross-chain readings can be tuned. Used to give the borrowable-amount
/// preview a large remote surplus relative to remote supply, so that the bonding-curve quote exceeds the local
/// surplus and the local surplus cap becomes the binding constraint.
contract TunableSuckerRegistry {
    uint256 public remoteSurplus;
    uint256 public remoteSupply;

    function set(uint256 newRemoteSurplus, uint256 newRemoteSupply) external {
        remoteSurplus = newRemoteSurplus;
        remoteSupply = newRemoteSupply;
    }

    function isSuckerOf(uint256, address) external pure returns (bool) {
        return false;
    }

    function remoteTotalSupplyOf(uint256) external view returns (uint256) {
        return remoteSupply;
    }

    function remoteSurplusOf(uint256, uint256, uint256) external view returns (uint256) {
        return remoteSurplus;
    }
}

/// @notice The borrowable-amount preview must never quote more than the canonical terminal can actually disburse in
/// the current state. A borrow draws funds from the live terminal balance, so once a prior borrow has drawn the
/// terminal down, the preview must shrink to match -- otherwise it would quote an amount that the terminal cannot
/// deliver, making the borrow revert even though the economic limit would allow it.
contract TestBorrowablePreviewLiveTerminalCap is TestBaseWorkflow {
    bytes32 internal constant REV_DEPLOYER_SALT = "REVDeployer";
    address internal constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    address internal ALICE = makeAddr("alice");
    address internal BOB = makeAddr("bob");

    REVDeployer internal REV_DEPLOYER;
    REVOwner internal REV_OWNER;
    REVLoans internal LOANS;
    JB721TiersHook internal EXAMPLE_HOOK;
    IJB721TiersHookDeployer internal HOOK_DEPLOYER;
    IJB721TiersHookStore internal HOOK_STORE;
    IJBAddressRegistry internal ADDRESS_REGISTRY;
    IJBSuckerRegistry internal SUCKER_REGISTRY;
    CTPublisher internal PUBLISHER;
    MockBuybackDataHook internal MOCK_BUYBACK;
    TunableSuckerRegistry internal LOANS_SUCKER_REGISTRY;

    uint256 internal FEE_PROJECT_ID;
    uint256 internal REVNET_ID;
    uint32 internal NATIVE_CURRENCY = uint32(uint160(JBConstants.NATIVE_TOKEN));

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

        // The loans contract reads cross-chain surplus/supply through this tunable stand-in.
        LOANS_SUCKER_REGISTRY = new TunableSuckerRegistry();
        LOANS = new REVLoans({
            controller: jbController(),
            terminal: jbMultiTerminal(),
            suckerRegistry: IJBSuckerRegistry(address(LOANS_SUCKER_REGISTRY)),
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
            LOANS,
            address(this)
        );
        REV_DEPLOYER = new REVDeployer{salt: REV_DEPLOYER_SALT}(
            jbController(),
            jbMultiTerminal(),
            IJBTerminal(address(new MockEmptyTerminal())),
            SUCKER_REGISTRY,
            FEE_PROJECT_ID,
            HOOK_DEPLOYER,
            PUBLISHER,
            IJBBuybackHookRegistry(address(MOCK_BUYBACK)),
            LOANS,
            TRUSTED_FORWARDER,
            address(REV_OWNER)
        );
        REV_OWNER.setDeployer(IREVDeployer(REV_DEPLOYER));

        vm.prank(multisig());
        jbProjects().approve(address(REV_DEPLOYER), FEE_PROJECT_ID);

        _deployRevnet(FEE_PROJECT_ID, "Fee Revnet", "FEE", bytes32("FEE_TOKEN"), keccak256("FEE"));
        REVNET_ID = _deployRevnet(0, "Cap", "CAP", bytes32("CAP_TOKEN"), keccak256("CAP_TOKEN"));

        vm.deal(ALICE, 1000 ether);
        vm.deal(BOB, 1000 ether);
    }

    /// @notice After a borrow draws the terminal down, the preview must not quote more than the live terminal can
    /// disburse, and borrowing exactly the freshly-quoted amount must succeed.
    function test_borrowablePreviewDoesNotExceedLiveTerminalBalance() public {
        // Two holders each pay the same amount, so each ends up holding half of the local supply and the local
        // surplus is the sum of both payments.
        vm.prank(ALICE);
        uint256 aliceTokens = jbMultiTerminal().pay{value: 10 ether}({
            projectId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            beneficiary: ALICE,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        vm.prank(BOB);
        uint256 bobTokens = jbMultiTerminal().pay{value: 10 ether}({
            projectId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            beneficiary: BOB,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });

        // Local terminal now holds 20 ether of surplus.
        assertEq(_liveTerminalBalance(), 20 ether, "setup: terminal should hold both payments");

        // Give the preview a large remote surplus with zero remote supply. This makes the global bonding-curve quote
        // for either holder's collateral exceed the local surplus, so the local surplus cap is the binding
        // constraint for the quote.
        LOANS_SUCKER_REGISTRY.set({newRemoteSurplus: 100 ether, newRemoteSupply: 0});

        // Cache the max prepaid fee percent before pranking -- reading it is an external call that would otherwise
        // consume the prank before the borrow.
        uint256 maxPrepaidFeePercent = LOANS.MAX_PREPAID_FEE_PERCENT();

        // Alice opens a small loan, drawing the terminal balance down. She borrows against a quarter of her
        // collateral so that the terminal is only partially drained and a positive balance remains.
        uint256 aliceCollateral = aliceTokens / 4;
        _grantBurnPermission(ALICE);
        vm.prank(ALICE);
        (, REVLoan memory aliceLoan) = LOANS.borrowFrom({
            revnetId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            minBorrowAmount: 0,
            collateralCount: aliceCollateral,
            beneficiary: payable(ALICE),
            prepaidFeePercent: maxPrepaidFeePercent,
            holder: ALICE
        });
        assertGt(aliceLoan.amount, 0, "setup: alice's borrow should draw a positive amount");

        // The live terminal balance is now strictly less than 20 ether.
        uint256 liveBalance = _liveTerminalBalance();
        assertLt(liveBalance, 20 ether, "setup: alice's borrow should have drawn the terminal down");
        assertGt(liveBalance, 0, "setup: a positive balance should remain");

        // Quote Bob's borrowable amount against his full collateral.
        uint256 bobQuote = LOANS.borrowableAmountFrom({
            revnetId: REVNET_ID, collateralCount: bobTokens, decimals: 18, currency: NATIVE_CURRENCY
        });

        // The preview must not promise more than the terminal can actually disburse right now.
        assertLe(bobQuote, liveBalance, "preview must not exceed the live terminal balance");

        // Borrowing exactly the freshly-quoted amount must succeed.
        _grantBurnPermission(BOB);
        vm.prank(BOB);
        (, REVLoan memory bobLoan) = LOANS.borrowFrom({
            revnetId: REVNET_ID,
            token: JBConstants.NATIVE_TOKEN,
            minBorrowAmount: bobQuote,
            collateralCount: bobTokens,
            beneficiary: payable(BOB),
            prepaidFeePercent: maxPrepaidFeePercent,
            holder: BOB
        });
        assertEq(bobLoan.amount, bobQuote, "the executed borrow should match the quoted amount");
    }

    function _liveTerminalBalance() internal view returns (uint256) {
        return jbTerminalStore().balanceOf(address(jbMultiTerminal()), REVNET_ID, JBConstants.NATIVE_TOKEN);
    }

    function _grantBurnPermission(address holder) internal {
        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = JBPermissionIds.BURN_TOKENS;
        vm.prank(holder);
        jbPermissions()
            .setPermissionsFor({
            account: holder,
            permissionsData: JBPermissionsData({
            operator: address(LOANS),
            // forge-lint: disable-next-line(unsafe-typecast)
            projectId: uint56(REVNET_ID),
            permissionIds: permissionIds
        })
        });
    }

    function _deployRevnet(
        uint256 revnetId,
        string memory name,
        string memory symbol,
        bytes32 salt,
        bytes32 suckerSalt
    )
        internal
        returns (uint256)
    {
        JBAccountingContext[] memory tc = new JBAccountingContext[](1);
        tc[0] = JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: NATIVE_CURRENCY});

        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        REVStageConfig[] memory stages = new REVStageConfig[](1);
        stages[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            // A zero cash-out tax rate keeps the bonding-curve quote proportional, making the local surplus cap the
            // sole constraint on the preview.
            cashOutTaxRate: 0,
            extraMetadata: 0
        });

        REVConfig memory config = REVConfig({
            description: REVDescription(name, symbol, "", salt),
            baseCurrency: NATIVE_CURRENCY,
            operator: multisig(),
            // Aggregate cross-chain state so the tunable remote surplus feeds into the preview.
            scopeCashOutsToLocalBalances: false,
            stageConfigurations: stages
        });

        vm.prank(multisig());
        (uint256 deployedId,) = REV_DEPLOYER.deployFor({
            revnetId: revnetId,
            configuration: config,
            accountingContextsToAccept: tc,
            suckerDeploymentConfiguration: REVSuckerDeploymentConfig({
                deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: suckerSalt
            }),
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(NATIVE_CURRENCY),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
        return deployedId;
    }
}
