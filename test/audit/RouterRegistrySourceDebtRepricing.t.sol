// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import /* {*} from */ "@bananapus/core-v6/test/helpers/TestBaseWorkflow.sol";
import /* {*} from */ "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
import /* {*} from */ "@bananapus/721-hook-v6/script/helpers/Hook721DeploymentLib.sol";
import /* {*} from */ "@bananapus/suckers-v6/script/helpers/SuckerDeploymentLib.sol";
import /* {*} from */ "@croptop/core-v6/script/helpers/CroptopDeploymentLib.sol";
import /* {*} from */ "@bananapus/router-terminal-v6/script/helpers/RouterTerminalDeploymentLib.sol";

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JBRouterTerminalRegistry} from "@bananapus/router-terminal-v6/src/JBRouterTerminalRegistry.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {JB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/JB721TiersHookDeployer.sol";
import {JB721TiersHook} from "@bananapus/721-hook-v6/src/JB721TiersHook.sol";
import {JB721TiersHookStore} from "@bananapus/721-hook-v6/src/JB721TiersHookStore.sol";
import {JB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/JB721CheckpointsDeployer.sol";
import {IJB721CheckpointsDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721CheckpointsDeployer.sol";
import {JBAddressRegistry} from "@bananapus/address-registry-v6/src/JBAddressRegistry.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";
import {CTPublisher} from "@croptop/core-v6/src/CTPublisher.sol";

import {REVDeployer} from "../../src/REVDeployer.sol";
import {REVLoans} from "../../src/REVLoans.sol";
import {REVLoan} from "../../src/structs/REVLoan.sol";
import {REVOwner} from "../../src/REVOwner.sol";
import {IREVLoans} from "../../src/interfaces/IREVLoans.sol";
import {REVConfig} from "../../src/structs/REVConfig.sol";
import {REVDescription} from "../../src/structs/REVDescription.sol";
import {REVStageConfig, REVAutoIssuance} from "../../src/structs/REVStageConfig.sol";
import {REVLoanSource} from "../../src/structs/REVLoanSource.sol";
import {REVSuckerDeploymentConfig} from "../../src/structs/REVSuckerDeploymentConfig.sol";
import {REVEmpty721Config} from "../helpers/REVEmpty721Config.sol";
import {MockBuybackDataHook} from "../mock/MockBuybackDataHook.sol";
import {MockSuckerRegistry} from "../mock/MockSuckerRegistry.sol";

contract MutableAccountingContextTerminal is ERC165, IJBPayoutTerminal {
    JBAccountingContext internal _context;

    constructor(JBAccountingContext memory context) {
        _context = context;
    }

    function accountingContextForTokenOf(uint256, address) external view override returns (JBAccountingContext memory) {
        return _context;
    }

    function accountingContextsOf(uint256) external view override returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] = _context;
    }

    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override {}

    function addToBalanceOf(
        uint256,
        address,
        uint256,
        bool,
        string calldata,
        bytes calldata
    )
        external
        payable
        override
    {}

    function currentSurplusOf(uint256, address[] calldata, uint256, uint256) external pure override returns (uint256) {}

    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256) {}

    function pay(
        uint256,
        address,
        uint256,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        override
        returns (uint256)
    {
        return 0;
    }

    function sendPayoutsOf(uint256, address, uint256, uint256, uint256) external pure override returns (uint256) {}

    function useAllowanceOf(
        uint256,
        address,
        uint256,
        uint256,
        uint256,
        address payable,
        address payable,
        string calldata
    )
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    function previewPayFor(
        uint256,
        address,
        uint256,
        address,
        bytes calldata
    )
        external
        pure
        override
        returns (JBRuleset memory ruleset, uint256, uint256, JBPayHookSpecification[] memory hookSpecifications)
    {
        hookSpecifications = new JBPayHookSpecification[](0);
        return (ruleset, 0, 0, hookSpecifications);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IJBPayoutTerminal).interfaceId
            || super.supportsInterface(interfaceId);
    }
}

contract CodexRouterRegistrySourceDebtRepricingTest is TestBaseWorkflow {
    bytes32 internal constant REV_DEPLOYER_SALT = "REVDeployer";

    address internal constant TRUSTED_FORWARDER = 0xB2b5841DBeF766d4b521221732F9B618fCf34A87;

    REVDeployer internal revDeployer;
    REVOwner internal revOwner;
    IREVLoans internal loans;
    JBRouterTerminalRegistry internal routerRegistry;
    JBSuckerRegistry internal suckerRegistry;
    JB721TiersHook internal exampleHook;
    IJB721TiersHookDeployer internal hookDeployer;
    IJB721TiersHookStore internal hookStore;
    IJBAddressRegistry internal addressRegistry;
    CTPublisher internal publisher;
    MockBuybackDataHook internal buybackHook;

    uint256 internal feeProjectId;
    uint256 internal revnetId;
    address internal user = makeAddr("user");

    function setUp() public override {
        super.setUp();

        feeProjectId = jbProjects().createFor(multisig());

        suckerRegistry = new JBSuckerRegistry(jbDirectory(), jbPermissions(), multisig(), address(0));
        hookStore = new JB721TiersHookStore();
        exampleHook = new JB721TiersHook(
            jbDirectory(),
            jbPermissions(),
            jbPrices(),
            jbRulesets(),
            hookStore,
            jbSplits(),
            IJB721CheckpointsDeployer(address(new JB721CheckpointsDeployer(hookStore))),
            multisig()
        );
        addressRegistry = new JBAddressRegistry();
        hookDeployer = new JB721TiersHookDeployer(exampleHook, hookStore, addressRegistry, multisig());
        publisher = new CTPublisher(jbDirectory(), jbPermissions(), feeProjectId, multisig());
        buybackHook = new MockBuybackDataHook();

        loans = new REVLoans({
            controller: jbController(),
            suckerRegistry: IJBSuckerRegistry(address(new MockSuckerRegistry())),
            revId: feeProjectId,
            owner: address(this),
            permit2: permit2(),
            trustedForwarder: TRUSTED_FORWARDER
        });

        revOwner = new REVOwner(
            IJBBuybackHookRegistry(address(buybackHook)),
            jbDirectory(),
            feeProjectId,
            suckerRegistry,
            address(loans),
            address(0)
        );

        revDeployer = new REVDeployer{salt: REV_DEPLOYER_SALT}(
            jbController(),
            suckerRegistry,
            feeProjectId,
            hookDeployer,
            publisher,
            IJBBuybackHookRegistry(address(buybackHook)),
            address(loans),
            TRUSTED_FORWARDER,
            address(revOwner)
        );
        revOwner.setDeployer(revDeployer);

        routerRegistry =
            new JBRouterTerminalRegistry(jbPermissions(), jbProjects(), permit2(), address(this), TRUSTED_FORWARDER);
        routerRegistry.setDefaultTerminal(jbMultiTerminal());

        vm.prank(multisig());
        jbProjects().approve(address(revDeployer), feeProjectId);
        _deployFeeRevnet();
        _deployRegistryBackedRevnet();

        vm.deal(user, 100 ether);
    }

    function test_registrySourceDebtCanBeRepricedByDefaultTerminalRetarget() public {
        vm.prank(user);
        uint256 tokenCount =
            jbMultiTerminal().pay{value: 20 ether}(revnetId, JBConstants.NATIVE_TOKEN, 20 ether, user, 0, "", "");
        assertGt(tokenCount, 1, "expected project tokens");

        uint256 firstCollateral = tokenCount / 2;
        _mockBurnPermission(user);

        REVLoanSource memory registrySource =
            REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: IJBPayoutTerminal(address(routerRegistry))});

        vm.prank(user);
        (uint256 firstLoanId, REVLoan memory firstLoan) =
            loans.borrowFrom(revnetId, registrySource, 0, firstCollateral, payable(user), 25, user);
        assertGt(firstLoanId, 0, "expected first loan");
        assertGt(firstLoan.amount, 0, "expected first borrow");

        uint256 remainingTokens = jbTokens().totalBalanceOf(user, revnetId);
        assertEq(remainingTokens, tokenCount - firstCollateral, "half the position should remain visible");

        uint256 borrowableBefore =
            loans.borrowableAmountFrom(revnetId, remainingTokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));
        assertGt(borrowableBefore, 0, "remaining tokens should still support a loan");

        MutableAccountingContextTerminal fakeTerminal = new MutableAccountingContextTerminal(
            JBAccountingContext({
                token: JBConstants.NATIVE_TOKEN, decimals: 6, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            })
        );
        routerRegistry.setDefaultTerminal(IJBTerminal(address(fakeTerminal)));

        uint256 borrowableAfter =
            loans.borrowableAmountFrom(revnetId, remainingTokens, 18, uint32(uint160(JBConstants.NATIVE_TOKEN)));

        assertGt(borrowableAfter, borrowableBefore, "retargeted registry source should inflate borrowable capacity");
        assertLt(
            loans.totalBorrowedFrom(revnetId, IJBPayoutTerminal(address(routerRegistry)), JBConstants.NATIVE_TOKEN),
            firstLoan.amount,
            "registry debt is later repriced through the fake 6-decimal context"
        );

        _mockBurnPermission(user);
        REVLoanSource memory terminalSource =
            REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: jbMultiTerminal()});

        vm.prank(user);
        (, REVLoan memory secondLoan) =
            loans.borrowFrom(revnetId, terminalSource, borrowableAfter, remainingTokens, payable(user), 25, user);

        assertEq(secondLoan.amount, borrowableAfter, "second loan uses the inflated capacity");
        assertGt(secondLoan.amount, borrowableBefore, "mutable registry source let the user borrow more than before");
    }

    function _deployFeeRevnet() internal {
        (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc) =
            _buildConfig("FeeProject", "FEE", "FEE_TOKEN", false);

        vm.prank(multisig());
        revDeployer.deployFor({
            revnetId: feeProjectId,
            configuration: cfg,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: sdc,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    function _deployRegistryBackedRevnet() internal {
        (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc) =
            _buildConfig("RegistryDebt", "RDEBT", "RDEBT_TOKEN", true);

        (revnetId,) = revDeployer.deployFor({
            revnetId: 0,
            configuration: cfg,
            terminalConfigurations: tc,
            suckerDeploymentConfiguration: sdc,
            tiered721HookConfiguration: REVEmpty721Config.empty721Config(uint32(uint160(JBConstants.NATIVE_TOKEN))),
            allowedPosts: REVEmpty721Config.emptyAllowedPosts()
        });
    }

    function _buildConfig(
        string memory name,
        string memory ticker,
        bytes32 salt,
        bool includeRegistry
    )
        internal
        view
        returns (REVConfig memory cfg, JBTerminalConfig[] memory tc, REVSuckerDeploymentConfig memory sdc)
    {
        JBAccountingContext[] memory acc = new JBAccountingContext[](1);
        acc[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        tc = new JBTerminalConfig[](includeRegistry ? 2 : 1);
        tc[0] = JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: acc});
        if (includeRegistry) {
            tc[1] = JBTerminalConfig({terminal: IJBTerminal(address(routerRegistry)), accountingContextsToAccept: acc});
        }

        REVStageConfig[] memory stages = new REVStageConfig[](1);
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0].beneficiary = payable(multisig());
        splits[0].percent = 10_000;

        stages[0] = REVStageConfig({
            startsAtOrAfter: uint40(block.timestamp),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 0,
            splits: splits,
            initialIssuance: uint112(1000e18),
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 5000,
            extraMetadata: 0
        });

        cfg = REVConfig({
            description: REVDescription(name, ticker, "ipfs://test", salt),
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            splitOperator: multisig(),
            stageConfigurations: stages
        });

        sdc = REVSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: keccak256(abi.encodePacked("ROUTER_DEBT"))
        });
    }

    function _mockBurnPermission(address holder) internal {
        mockExpect(
            address(jbPermissions()),
            abi.encodeCall(IJBPermissions.hasPermission, (address(loans), holder, revnetId, 11, true, true)),
            abi.encode(true)
        );
    }
}
