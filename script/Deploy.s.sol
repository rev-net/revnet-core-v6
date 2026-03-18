// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// forge-lint: disable-next-line(unaliased-plain-import)
import "@bananapus/721-hook-v6/script/helpers/Hook721DeploymentLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@bananapus/buyback-hook-v6/script/helpers/BuybackDeploymentLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@bananapus/suckers-v6/script/helpers/SuckerDeploymentLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@bananapus/router-terminal-v6/script/helpers/RouterTerminalDeploymentLib.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "@croptop/core-v6/script/helpers/CroptopDeploymentLib.sol";

import {Sphinx} from "@sphinx-labs/contracts/contracts/foundry/SphinxPlugin.sol";
import {Script} from "forge-std/Script.sol";

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBTokenMapping} from "@bananapus/suckers-v6/src/structs/JBTokenMapping.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";

import {REVDeployer} from "./../src/REVDeployer.sol";
import {REVAutoIssuance} from "../src/structs/REVAutoIssuance.sol";
import {REVConfig} from "../src/structs/REVConfig.sol";
import {REVDescription} from "../src/structs/REVDescription.sol";
import {REVStageConfig} from "../src/structs/REVStageConfig.sol";
import {REVSuckerDeploymentConfig} from "../src/structs/REVSuckerDeploymentConfig.sol";
import {REVLoans} from "./../src/REVLoans.sol";
import {REVDeploy721TiersHookConfig} from "../src/structs/REVDeploy721TiersHookConfig.sol";
import {REVCroptopAllowedPost} from "../src/structs/REVCroptopAllowedPost.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {JB721InitTiersConfig} from "@bananapus/721-hook-v6/src/structs/JB721InitTiersConfig.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {REVBaseline721HookConfig} from "../src/structs/REVBaseline721HookConfig.sol";
import {REV721TiersHookFlags} from "../src/structs/REV721TiersHookFlags.sol";

struct FeeProjectConfig {
    REVConfig configuration;
    JBTerminalConfig[] terminalConfigurations;
    REVSuckerDeploymentConfig suckerDeploymentConfiguration;
    REVDeploy721TiersHookConfig tiered721HookConfiguration;
    REVCroptopAllowedPost[] allowedPosts;
}

contract DeployScript is Script, Sphinx {
    /// @notice tracks the deployment of the buyback hook.
    BuybackDeployment buybackHook;
    /// @notice tracks the deployment of the core contracts for the chain we are deploying to.
    CoreDeployment core;
    /// @notice tracks the deployment of the croptop contracts for the chain we are deploying to.
    CroptopDeployment croptop;
    /// @notice tracks the deployment of the 721 hook contracts for the chain we are deploying to.
    Hook721Deployment hook;
    /// @notice tracks the deployment of the sucker contracts for the chain we are deploying to.
    SuckerDeployment suckers;
    /// @notice tracks the deployment of the router terminal.
    RouterTerminalDeployment routerTerminal;

    // forge-lint: disable-next-line(mixed-case-variable)
    uint32 PREMINT_CHAIN_ID = 1;
    // forge-lint: disable-next-line(mixed-case-variable)
    string NAME = "Revnet";
    // forge-lint: disable-next-line(mixed-case-variable)
    string SYMBOL = "REV";
    // forge-lint: disable-next-line(mixed-case-variable)
    string PROJECT_URI = "ipfs://QmcCBD5fM927LjkLDSJWtNEU9FohcbiPSfqtGRHXFHzJ4W";
    // forge-lint: disable-next-line(mixed-case-variable)
    uint32 NATIVE_CURRENCY = uint32(uint160(JBConstants.NATIVE_TOKEN));
    // forge-lint: disable-next-line(mixed-case-variable)
    uint32 ETH_CURRENCY = JBCurrencyIds.ETH;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint8 DECIMALS = 18;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256 DECIMAL_MULTIPLIER = 10 ** DECIMALS;
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 ERC20_SALT = "_REV_ERC20_SALT_V6_";
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 SUCKER_SALT = "_REV_SUCKER_SALT_V6_";
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 DEPLOYER_SALT = "_REV_DEPLOYER_SALT_V6_";
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 REVLOANS_SALT = "_REV_LOANS_SALT_V6_";
    // forge-lint: disable-next-line(mixed-case-variable)
    address LOANS_OWNER;
    // forge-lint: disable-next-line(mixed-case-variable)
    address OPERATOR;
    // forge-lint: disable-next-line(mixed-case-variable)
    address TRUSTED_FORWARDER;
    // forge-lint: disable-next-line(mixed-case-variable)
    IPermit2 PERMIT2;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint48 REV_START_TIME = 1_740_089_444;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint104 REV_MAINNET_AUTO_ISSUANCE_ = 1_050_482_341_387_116_262_330_122;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint104 REV_BASE_AUTO_ISSUANCE_ = 38_544_322_230_437_559_731_228;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint104 REV_OP_AUTO_ISSUANCE_ = 32_069_388_242_375_817_844;
    // forge-lint: disable-next-line(mixed-case-variable)
    uint104 REV_ARB_AUTO_ISSUANCE_ = 3_479_431_776_906_850_000_000;

    function configureSphinx() public override {
        // TODO: Update to contain revnet devs.
        sphinxConfig.projectName = "revnet-core-v6";
        sphinxConfig.mainnets = ["ethereum", "optimism", "base", "arbitrum"];
        sphinxConfig.testnets = ["ethereum_sepolia", "optimism_sepolia", "base_sepolia", "arbitrum_sepolia"];
    }

    function run() public {
        // Get the operator address.
        OPERATOR = safeAddress();
        // Get the loans owner address.
        LOANS_OWNER = safeAddress();

        // Get the deployment addresses for the nana CORE for this chain.
        // We want to do this outside of the `sphinx` modifier.
        core = CoreDeploymentLib.getDeployment(
            vm.envOr({
                name: "NANA_CORE_DEPLOYMENT_PATH", defaultValue: string("node_modules/@bananapus/core-v6/deployments/")
            })
        );
        // Get the deployment addresses for the suckers contracts for this chain.
        suckers = SuckerDeploymentLib.getDeployment(
            vm.envOr({
                name: "NANA_SUCKERS_DEPLOYMENT_PATH",
                defaultValue: string("node_modules/@bananapus/suckers-v6/deployments/")
            })
        );
        // Get the deployment addresses for the 721 hook contracts for this chain.
        croptop = CroptopDeploymentLib.getDeployment(
            vm.envOr({
                name: "CROPTOP_CORE_DEPLOYMENT_PATH", defaultValue: string("node_modules/@croptop/core-v6/deployments/")
            })
        );
        // Get the deployment addresses for the 721 hook contracts for this chain.
        hook = Hook721DeploymentLib.getDeployment(
            vm.envOr({
                name: "NANA_721_DEPLOYMENT_PATH",
                defaultValue: string("node_modules/@bananapus/721-hook-v6/deployments/")
            })
        );
        // Get the deployment addresses for the router terminal contracts for this chain.
        routerTerminal = RouterTerminalDeploymentLib.getDeployment(
            vm.envOr({
                name: "NANA_ROUTER_TERMINAL_DEPLOYMENT_PATH",
                defaultValue: string("node_modules/@bananapus/router-terminal-v6/deployments/")
            })
        );
        // Get the deployment addresses for the 721 hook contracts for this chain.
        buybackHook = BuybackDeploymentLib.getDeployment(
            vm.envOr({
                name: "NANA_BUYBACK_HOOK_DEPLOYMENT_PATH",
                defaultValue: string("node_modules/@bananapus/buyback-hook-v6/deployments/")
            })
        );

        // We use the same trusted forwarder and permit2 as the core deployment.
        TRUSTED_FORWARDER = core.controller.trustedForwarder();
        PERMIT2 = core.terminal.PERMIT2();

        // Perform the deployment transactions.
        deploy();
    }

    function getFeeProjectConfig() internal view returns (FeeProjectConfig memory) {
        // The tokens that the project accepts and stores.
        JBAccountingContext[] memory accountingContextsToAccept = new JBAccountingContext[](1);

        // Accept the chain's native currency through the multi terminal.
        accountingContextsToAccept[0] =
            JBAccountingContext({token: JBConstants.NATIVE_TOKEN, decimals: DECIMALS, currency: NATIVE_CURRENCY});

        // The terminals that the project will accept funds through.
        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](2);
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: core.terminal, accountingContextsToAccept: accountingContextsToAccept});
        terminalConfigurations[1] = JBTerminalConfig({
            terminal: IJBTerminal(address(routerTerminal.registry)),
            accountingContextsToAccept: new JBAccountingContext[](0)
        });

        // The project's revnet stage configurations.
        REVStageConfig[] memory stageConfigurations = new REVStageConfig[](3);

        // Create a split group that assigns all of the splits to the operator.
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            preferAddToBalance: false,
            percent: JBConstants.SPLITS_TOTAL_PERCENT,
            projectId: 0,
            beneficiary: payable(OPERATOR),
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });

        {
            REVAutoIssuance[] memory issuanceConfs = new REVAutoIssuance[](4);
            issuanceConfs[0] = REVAutoIssuance({chainId: 1, count: REV_MAINNET_AUTO_ISSUANCE_, beneficiary: OPERATOR});
            issuanceConfs[1] = REVAutoIssuance({chainId: 8453, count: REV_BASE_AUTO_ISSUANCE_, beneficiary: OPERATOR});
            issuanceConfs[2] = REVAutoIssuance({chainId: 10, count: REV_OP_AUTO_ISSUANCE_, beneficiary: OPERATOR});
            issuanceConfs[3] = REVAutoIssuance({chainId: 42_161, count: REV_ARB_AUTO_ISSUANCE_, beneficiary: OPERATOR});

            stageConfigurations[0] = REVStageConfig({
                startsAtOrAfter: REV_START_TIME,
                autoIssuances: issuanceConfs,
                splitPercent: 3800, // 38%
                splits: splits,
                // forge-lint: disable-next-line(unsafe-typecast)
                initialIssuance: uint112(10_000 * DECIMAL_MULTIPLIER),
                issuanceCutFrequency: 90 days,
                issuanceCutPercent: 380_000_000, // 38%
                cashOutTaxRate: 1000, // 0.1
                extraMetadata: 4 // Allow adding suckers.
            });
        }

        {
            REVAutoIssuance[] memory issuanceConfs = new REVAutoIssuance[](1);
            issuanceConfs[0] = REVAutoIssuance({
                // forge-lint: disable-next-line(unsafe-typecast)
                chainId: PREMINT_CHAIN_ID,
                // forge-lint: disable-next-line(unsafe-typecast)
                count: uint104(1_550_000 * DECIMAL_MULTIPLIER),
                beneficiary: OPERATOR
            });

            stageConfigurations[1] = REVStageConfig({
                startsAtOrAfter: uint40(stageConfigurations[0].startsAtOrAfter + 720 days),
                autoIssuances: issuanceConfs,
                splitPercent: 3800, // 38%
                splits: splits,
                initialIssuance: 1, // inherit from previous cycle.
                issuanceCutFrequency: 30 days,
                issuanceCutPercent: 70_000_000, // 7%
                cashOutTaxRate: 1000, // 0.1
                extraMetadata: 4 // Allow adding suckers.
            });
        }

        stageConfigurations[2] = REVStageConfig({
            startsAtOrAfter: uint40(stageConfigurations[1].startsAtOrAfter + 3600 days),
            autoIssuances: new REVAutoIssuance[](0),
            splitPercent: 3800, // 38%
            splits: splits,
            initialIssuance: 0, // no more issaunce.
            issuanceCutFrequency: 0,
            issuanceCutPercent: 0,
            cashOutTaxRate: 1000, // 0.1
            extraMetadata: 4 // Allow adding suckers.
        });

        // The project's revnet configuration
        REVConfig memory revnetConfiguration = REVConfig({
            description: REVDescription({name: NAME, ticker: SYMBOL, uri: PROJECT_URI, salt: ERC20_SALT}),
            baseCurrency: ETH_CURRENCY,
            splitOperator: OPERATOR,
            stageConfigurations: stageConfigurations
        });

        // Organize the instructions for how this project will connect to other chains.
        JBTokenMapping[] memory tokenMappings = new JBTokenMapping[](1);
        tokenMappings[0] = JBTokenMapping({
            localToken: JBConstants.NATIVE_TOKEN,
            minGas: 200_000,
            remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
        });

        REVSuckerDeploymentConfig memory suckerDeploymentConfiguration;

        {
            JBSuckerDeployerConfig[] memory suckerDeployerConfigurations;
            if (block.chainid == 1 || block.chainid == 11_155_111) {
                suckerDeployerConfigurations = new JBSuckerDeployerConfig[](3);
                // OP
                suckerDeployerConfigurations[0] =
                    JBSuckerDeployerConfig({deployer: suckers.optimismDeployer, mappings: tokenMappings});

                suckerDeployerConfigurations[1] =
                    JBSuckerDeployerConfig({deployer: suckers.baseDeployer, mappings: tokenMappings});

                suckerDeployerConfigurations[2] =
                    JBSuckerDeployerConfig({deployer: suckers.arbitrumDeployer, mappings: tokenMappings});
            } else {
                suckerDeployerConfigurations = new JBSuckerDeployerConfig[](1);
                // L2 -> Mainnet
                suckerDeployerConfigurations[0] = JBSuckerDeployerConfig({
                    deployer: address(suckers.optimismDeployer) != address(0)
                        ? suckers.optimismDeployer
                        : address(suckers.baseDeployer) != address(0) ? suckers.baseDeployer : suckers.arbitrumDeployer,
                    mappings: tokenMappings
                });

                if (address(suckerDeployerConfigurations[0].deployer) == address(0)) {
                    revert("L2 > L1 Sucker is not configured");
                }
            }
            // Specify all sucker deployments.
            suckerDeploymentConfiguration =
                REVSuckerDeploymentConfig({deployerConfigurations: suckerDeployerConfigurations, salt: SUCKER_SALT});
        }

        return FeeProjectConfig({
            configuration: revnetConfiguration,
            terminalConfigurations: terminalConfigurations,
            suckerDeploymentConfiguration: suckerDeploymentConfiguration,
            tiered721HookConfiguration: REVDeploy721TiersHookConfig({
                baseline721HookConfiguration: REVBaseline721HookConfig({
                    name: "",
                    symbol: "",
                    baseUri: "",
                    tokenUriResolver: IJB721TokenUriResolver(address(0)),
                    contractUri: "",
                    tiersConfig: JB721InitTiersConfig({
                        tiers: new JB721TierConfig[](0), currency: ETH_CURRENCY, decimals: 18
                    }),
                    reserveBeneficiary: address(0),
                    flags: REV721TiersHookFlags({
                        noNewTiersWithReserves: false,
                        noNewTiersWithVotes: false,
                        noNewTiersWithOwnerMinting: false,
                        preventOverspending: false
                    })
                }),
                salt: bytes32(0),
                preventSplitOperatorAdjustingTiers: false,
                preventSplitOperatorUpdatingMetadata: false,
                preventSplitOperatorMinting: false,
                preventSplitOperatorIncreasingDiscountPercent: false
            }),
            allowedPosts: new REVCroptopAllowedPost[](0)
        });
    }

    function deploy() public sphinx {
        // TODO figure out how to reference project ID if the contracts are already deployed.
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 FEE_PROJECT_ID = core.projects.createFor(safeAddress());

        // Deploy REVLoans first — it only depends on the controller.
        (address _revloansAddr, bool _revloansIsDeployed) = _isDeployed({
            salt: REVLOANS_SALT,
            creationCode: type(REVLoans).creationCode,
            arguments: abi.encode(
                core.controller, core.projects, FEE_PROJECT_ID, LOANS_OWNER, PERMIT2, TRUSTED_FORWARDER
            )
        });
        REVLoans revloans = _revloansIsDeployed
            ? REVLoans(payable(_revloansAddr))
            : new REVLoans{salt: REVLOANS_SALT}({
                controller: core.controller,
                projects: core.projects,
                revId: FEE_PROJECT_ID,
                owner: LOANS_OWNER,
                permit2: PERMIT2,
                trustedForwarder: TRUSTED_FORWARDER
            });

        // Deploy REVDeployer with the REVLoans and buyback hook addresses.
        (address _deployerAddr, bool _deployerIsDeployed) = _isDeployed({
            salt: DEPLOYER_SALT,
            creationCode: type(REVDeployer).creationCode,
            arguments: abi.encode(
                core.controller,
                suckers.registry,
                FEE_PROJECT_ID,
                hook.hook_deployer,
                croptop.publisher,
                IJBBuybackHookRegistry(address(buybackHook.registry)),
                address(revloans),
                TRUSTED_FORWARDER
            )
        });
        REVDeployer _basicDeployer = _deployerIsDeployed
            ? REVDeployer(payable(_deployerAddr))
            : new REVDeployer{salt: DEPLOYER_SALT}({
                controller: core.controller,
                suckerRegistry: suckers.registry,
                feeRevnetId: FEE_PROJECT_ID,
                hookDeployer: hook.hook_deployer,
                publisher: croptop.publisher,
                buybackHook: IJBBuybackHookRegistry(address(buybackHook.registry)),
                loans: address(revloans),
                trustedForwarder: TRUSTED_FORWARDER
            });

        // Approve the basic deployer to configure the project.
        core.projects.approve({to: address(_basicDeployer), tokenId: FEE_PROJECT_ID});

        // Build the config.
        FeeProjectConfig memory feeProjectConfig = getFeeProjectConfig();

        // Configure the project.
        _basicDeployer.deployFor({
            revnetId: FEE_PROJECT_ID,
            configuration: feeProjectConfig.configuration,
            terminalConfigurations: feeProjectConfig.terminalConfigurations,
            suckerDeploymentConfiguration: feeProjectConfig.suckerDeploymentConfiguration,
            tiered721HookConfiguration: feeProjectConfig.tiered721HookConfiguration,
            allowedPosts: feeProjectConfig.allowedPosts
        });
    }

    function _isDeployed(
        bytes32 salt,
        bytes memory creationCode,
        bytes memory arguments
    )
        internal
        view
        returns (address deployedTo, bool isDeployed)
    {
        // Note: This uses the Arachnid deterministic-deployment-proxy address, which differs from
        // the Sphinx deployer used at runtime. As a result, the predicted address won't match and
        // _isDeployed will always return false when deploying via Sphinx. This is benign — it just
        // means contracts are always freshly deployed rather than skipped.
        address _deployedTo = vm.computeCreate2Address({
            salt: salt,
            initCodeHash: keccak256(abi.encodePacked(creationCode, arguments)),
            // Arachnid/deterministic-deployment-proxy address.
            deployer: address(0x4e59b44847b379578588920cA78FbF26c0B4956C)
        });

        // Return if code is already present at this address.
        return (_deployedTo, address(_deployedTo).code.length != 0);
    }
}
