// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {CTPublisher} from "@croptop/core-v6/src/CTPublisher.sol";
import {REVConfig} from "../structs/REVConfig.sol";
import {REVCroptopAllowedPost} from "../structs/REVCroptopAllowedPost.sol";
import {REVDeploy721TiersHookConfig} from "../structs/REVDeploy721TiersHookConfig.sol";
import {REVSuckerDeploymentConfig} from "../structs/REVSuckerDeploymentConfig.sol";

/// @notice Deploys and manages revnets -- Juicebox projects with pre-configured tokenomics.
interface IREVDeployer {
    /// @notice Emitted when tokens are auto-issued for a beneficiary during a stage.
    /// @param revnetId The ID of the revnet.
    /// @param stageId The ID of the stage.
    /// @param beneficiary The address receiving the auto-issued tokens.
    /// @param count The number of tokens auto-issued.
    /// @param caller The address that triggered the auto-issuance.
    event AutoIssue(
        uint256 indexed revnetId, uint256 indexed stageId, address indexed beneficiary, uint256 count, address caller
    );

    /// @notice Emitted when held tokens are burned from the deployer contract.
    /// @param revnetId The ID of the revnet whose tokens were burned.
    /// @param count The number of tokens burned.
    /// @param caller The address that triggered the burn.
    event BurnHeldTokens(uint256 indexed revnetId, uint256 count, address caller);

    /// @notice Emitted when a new revnet is deployed.
    /// @param revnetId The ID of the deployed revnet.
    /// @param configuration The revnet's configuration.
    /// @param terminalConfigurations The terminals configured for the revnet.
    /// @param suckerDeploymentConfiguration The sucker deployment configuration.
    /// @param rulesetConfigurations The rulesets configured for the revnet.
    /// @param encodedConfigurationHash The hash of the encoded configuration.
    /// @param caller The address that deployed the revnet.
    event DeployRevnet(
        uint256 indexed revnetId,
        REVConfig configuration,
        JBTerminalConfig[] terminalConfigurations,
        REVSuckerDeploymentConfig suckerDeploymentConfiguration,
        JBRulesetConfig[] rulesetConfigurations,
        bytes32 encodedConfigurationHash,
        address caller
    );

    /// @notice Emitted when suckers are deployed for a revnet.
    /// @param revnetId The ID of the revnet.
    /// @param encodedConfigurationHash The hash of the encoded configuration.
    /// @param suckerDeploymentConfiguration The sucker deployment configuration.
    /// @param caller The address that deployed the suckers.
    event DeploySuckers(
        uint256 indexed revnetId,
        bytes32 encodedConfigurationHash,
        REVSuckerDeploymentConfig suckerDeploymentConfiguration,
        address caller
    );

    /// @notice Emitted when the split operator of a revnet is replaced.
    /// @param revnetId The ID of the revnet.
    /// @param newSplitOperator The address of the new split operator.
    /// @param caller The address that replaced the split operator.
    event ReplaceSplitOperator(uint256 indexed revnetId, address indexed newSplitOperator, address caller);

    /// @notice Emitted when the cash out delay is set for a revnet.
    /// @param revnetId The ID of the revnet.
    /// @param cashOutDelay The cash out delay in seconds.
    /// @param caller The address that set the delay.
    event SetCashOutDelay(uint256 indexed revnetId, uint256 cashOutDelay, address caller);

    /// @notice Emitted when an auto-issuance amount is stored for a beneficiary during a stage.
    /// @param revnetId The ID of the revnet.
    /// @param stageId The ID of the stage.
    /// @param beneficiary The address the tokens will be issued to.
    /// @param count The number of tokens stored for auto-issuance.
    /// @param caller The address that stored the amount.
    event StoreAutoIssuanceAmount(
        uint256 indexed revnetId, uint256 indexed stageId, address indexed beneficiary, uint256 count, address caller
    );

    /// @notice The number of revnet tokens that can be auto-minted for a beneficiary during a stage.
    /// @param revnetId The ID of the revnet.
    /// @param stageId The ID of the stage.
    /// @param beneficiary The beneficiary of the auto-mint.
    /// @return The number of tokens available to auto-issue.
    function amountToAutoIssue(uint256 revnetId, uint256 stageId, address beneficiary) external view returns (uint256);

    /// @notice The buyback hook used as a data hook to route payments through buyback pools.
    /// @return The buyback hook contract.
    function BUYBACK_HOOK() external view returns (IJBBuybackHookRegistry);

    /// @notice The number of seconds until a revnet's participants can cash out after deploying to a new network.
    /// @return The cash out delay in seconds.
    function CASH_OUT_DELAY() external view returns (uint256);

    /// @notice The timestamp when cash outs become available for a revnet's participants.
    /// @param revnetId The ID of the revnet.
    /// @return The cash out delay timestamp.
    function cashOutDelayOf(uint256 revnetId) external view returns (uint256);

    /// @notice The controller used to create and manage Juicebox projects for revnets.
    /// @return The controller contract.
    function CONTROLLER() external view returns (IJBController);

    /// @notice The default Uniswap pool fee tier for auto-configured buyback pools.
    /// @return The fee tier (10_000 = 1%).
    function DEFAULT_BUYBACK_POOL_FEE() external view returns (uint24);

    /// @notice The default TWAP window for auto-configured buyback pools.
    /// @return The TWAP window in seconds.
    function DEFAULT_BUYBACK_TWAP_WINDOW() external view returns (uint32);

    /// @notice The directory of terminals and controllers for Juicebox projects.
    /// @return The directory contract.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice The cash out fee as a fraction out of `JBConstants.MAX_FEE`.
    /// @return The fee value.
    function FEE() external view returns (uint256);

    /// @notice The Juicebox project ID of the revnet that receives cash out fees.
    /// @return The fee revnet ID.
    function FEE_REVNET_ID() external view returns (uint256);

    /// @notice The hashed encoded configuration of each revnet.
    /// @param revnetId The ID of the revnet.
    /// @return The hashed encoded configuration.
    function hashedEncodedConfigurationOf(uint256 revnetId) external view returns (bytes32);

    /// @notice The deployer used to create tiered ERC-721 hooks for revnets.
    /// @return The hook deployer contract.
    function HOOK_DEPLOYER() external view returns (IJB721TiersHookDeployer);

    /// @notice Whether an address is a revnet's split operator.
    /// @param revnetId The ID of the revnet.
    /// @param addr The address to check.
    /// @return A flag indicating whether the address is the revnet's split operator.
    function isSplitOperatorOf(uint256 revnetId, address addr) external view returns (bool);

    /// @notice The loan contract used by all revnets.
    /// @return The loans contract address.
    function LOANS() external view returns (address);

    /// @notice The contract that stores Juicebox project access permissions.
    /// @return The permissions contract.
    function PERMISSIONS() external view returns (IJBPermissions);

    /// @notice The contract that mints ERC-721s representing project ownership.
    /// @return The projects contract.
    function PROJECTS() external view returns (IJBProjects);

    /// @notice The croptop publisher revnets can use to publish ERC-721 posts to their tiered ERC-721 hooks.
    /// @return The publisher contract.
    function PUBLISHER() external view returns (CTPublisher);

    /// @notice The registry that deploys and tracks suckers for revnets.
    /// @return The sucker registry contract.
    function SUCKER_REGISTRY() external view returns (IJBSuckerRegistry);

    /// @notice Each revnet's tiered ERC-721 hook.
    /// @param revnetId The ID of the revnet.
    /// @return The tiered ERC-721 hook.
    function tiered721HookOf(uint256 revnetId) external view returns (IJB721TiersHook);

    /// @notice Auto-mint a revnet's tokens from a stage for a beneficiary.
    /// @param revnetId The ID of the revnet to auto-mint tokens from.
    /// @param stageId The ID of the stage auto-mint tokens are available from.
    /// @param beneficiary The address to auto-mint tokens to.
    function autoIssueFor(uint256 revnetId, uint256 stageId, address beneficiary) external;

    /// @notice Burn any of a revnet's tokens held by this contract.
    /// @param revnetId The ID of the revnet whose tokens should be burned.
    function burnHeldTokensOf(uint256 revnetId) external;

    /// @notice Deploy a revnet with a tiered ERC-721 hook and optional croptop posting support.
    /// @dev Every revnet gets a 721 hook — pass an empty config if no tiers are needed initially.
    /// @param revnetId The ID of the Juicebox project to initialize. Send 0 to deploy a new revnet.
    /// @param configuration Core revnet configuration.
    /// @param terminalConfigurations The terminals to set up for the revnet.
    /// @param suckerDeploymentConfiguration The suckers to set up for cross-chain token transfers.
    /// @param tiered721HookConfiguration How to set up the tiered ERC-721 hook for the revnet.
    /// @param allowedPosts Restrictions on which croptop posts are allowed on the revnet's ERC-721 tiers.
    /// @return The ID of the newly created or initialized revnet.
    /// @return hook The tiered ERC-721 hook that was deployed for the revnet.
    function deployFor(
        uint256 revnetId,
        REVConfig memory configuration,
        JBTerminalConfig[] memory terminalConfigurations,
        REVSuckerDeploymentConfig memory suckerDeploymentConfiguration,
        REVDeploy721TiersHookConfig memory tiered721HookConfiguration,
        REVCroptopAllowedPost[] memory allowedPosts
    )
        external
        returns (uint256, IJB721TiersHook hook);

    /// @notice Deploy new suckers for an existing revnet.
    /// @param revnetId The ID of the revnet to deploy suckers for.
    /// @param suckerDeploymentConfiguration The suckers to set up for the revnet.
    /// @return suckers The addresses of the deployed suckers.
    function deploySuckersFor(
        uint256 revnetId,
        REVSuckerDeploymentConfig calldata suckerDeploymentConfiguration
    )
        external
        returns (address[] memory suckers);

    /// @notice Change a revnet's split operator. Only the current split operator can call this.
    /// @param revnetId The ID of the revnet.
    /// @param newSplitOperator The new split operator's address.
    function setSplitOperatorOf(uint256 revnetId, address newSplitOperator) external;
}
