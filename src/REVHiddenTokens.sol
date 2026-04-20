// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBPermissioned} from "@bananapus/core-v6/src/interfaces/IJBPermissioned.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

import {IREVDeployer} from "./interfaces/IREVDeployer.sol";
import {IREVHiddenTokens} from "./interfaces/IREVHiddenTokens.sol";

/// @notice Allows authorized operators to hide (burn) revnet tokens on behalf of holders, excluding them from
/// governance weight. Hidden tokens remain counted in totalSupply for cash-out/borrow valuations (via
/// `totalSupplyIncludingHiddenOf`) so hiding has NO economic benefit — it only reduces governance power.
/// Hidden tokens can be revealed (re-minted) at any time.
contract REVHiddenTokens is ERC2771Context, JBPermissioned, IREVHiddenTokens {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error REVHiddenTokens_AlreadyInitialized();
    error REVHiddenTokens_InsufficientHiddenBalance(uint256 hiddenBalance, uint256 requested);
    error REVHiddenTokens_InvalidBeneficiary(address beneficiary, address caller);
    error REVHiddenTokens_InvalidHolder(address holder, address caller);
    error REVHiddenTokens_Unauthorized(uint256 revnetId, address caller);

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The controller that manages revnets using this contract.
    IJBController public immutable override CONTROLLER;

    /// @notice The deployer that tracks each revnet's split operator.
    IREVDeployer public DEPLOYER;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The number of tokens a holder has hidden for a given revnet.
    /// @custom:param holder The address of the token holder.
    /// @custom:param revnetId The ID of the revnet.
    mapping(address holder => mapping(uint256 revnetId => uint256 count)) public override hiddenBalanceOf;

    /// @notice The total number of hidden tokens for a revnet.
    /// @custom:param revnetId The ID of the revnet.
    mapping(uint256 revnetId => uint256 count) public override totalHiddenOf;

    /// @notice The account allowed to bind the canonical deployer exactly once.
    address private immutable _DEPLOYER_BINDER;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param controller The controller that manages revnets.
    /// @param trustedForwarder The trusted forwarder for ERC-2771 meta-transactions.
    constructor(
        IJBController controller,
        address trustedForwarder
    )
        ERC2771Context(trustedForwarder)
        JBPermissioned(IJBPermissioned(address(controller)).PERMISSIONS())
    {
        CONTROLLER = controller;
        _DEPLOYER_BINDER = msg.sender;
    }

    //*********************************************************************//
    // ----------------------- public views ------------------------------ //
    //*********************************************************************//

    /// @notice The total token supply including hidden tokens for a revnet.
    /// @dev Use this for cash-out and borrow valuation calculations instead of raw totalSupply.
    /// Hidden tokens are added back so that hiding has no economic benefit — only governance effect.
    /// @param revnetId The ID of the revnet.
    /// @return supply The total supply including both circulating and hidden tokens.
    function totalSupplyIncludingHiddenOf(uint256 revnetId) public view override returns (uint256 supply) {
        supply = CONTROLLER.totalTokenSupplyWithReservedTokensOf(revnetId) + totalHiddenOf[revnetId];
    }

    /// @notice Bind the canonical deployer exactly once.
    /// @param deployer The revnet deployer.
    function setDeployer(IREVDeployer deployer) external {
        if (msg.sender != _DEPLOYER_BINDER) revert REVHiddenTokens_Unauthorized(0, msg.sender);
        if (address(DEPLOYER) != address(0)) revert REVHiddenTokens_AlreadyInitialized();

        DEPLOYER = deployer;
    }

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Hide tokens by burning them and tracking them for later reveal.
    /// @dev Only the revnet's split operator or an address the split operator has authorized can hide tokens.
    /// Callers can only hide their own tokens.
    /// @dev The holder must have granted BURN_TOKENS permission to this contract.
    /// @param revnetId The ID of the revnet whose tokens to hide.
    /// @param tokenCount The number of tokens to hide.
    /// @param holder The address whose tokens to hide.
    function hideTokensOf(uint256 revnetId, uint256 tokenCount, address holder) external override {
        address caller = _msgSender();
        if (holder != caller) revert REVHiddenTokens_InvalidHolder(holder, caller);

        _requirePermissionFrom({
            account: DEPLOYER.splitOperatorOf(revnetId),
            projectId: revnetId,
            permissionId: JBPermissionIds.HIDE_TOKENS
        });

        // Increment the holder's hidden balance.
        hiddenBalanceOf[holder][revnetId] += tokenCount;

        // Increment the revnet's total hidden count.
        totalHiddenOf[revnetId] += tokenCount;

        // Burn the tokens from the holder. The holder must have granted BURN_TOKENS permission.
        // slither-disable-next-line reentrancy-events
        CONTROLLER.burnTokensOf({holder: holder, projectId: revnetId, tokenCount: tokenCount, memo: ""});

        emit HideTokens({revnetId: revnetId, tokenCount: tokenCount, holder: holder, caller: _msgSender()});
    }

    /// @notice Reveal previously hidden tokens by re-minting them.
    /// @dev Only the revnet's split operator or an address the split operator has authorized can reveal tokens.
    /// Callers can only reveal their own hidden balance back to themselves.
    /// @param revnetId The ID of the revnet whose tokens to reveal.
    /// @param tokenCount The number of tokens to reveal.
    /// @param beneficiary The address that will receive the revealed tokens.
    /// @param holder The address whose hidden balance to decrement.
    function revealTokensOf(
        uint256 revnetId,
        uint256 tokenCount,
        address beneficiary,
        address holder
    )
        external
        override
    {
        address caller = _msgSender();
        if (holder != caller) revert REVHiddenTokens_InvalidHolder(holder, caller);
        if (beneficiary != caller) revert REVHiddenTokens_InvalidBeneficiary(beneficiary, caller);

        _requirePermissionFrom({
            account: DEPLOYER.splitOperatorOf(revnetId),
            projectId: revnetId,
            permissionId: JBPermissionIds.HIDE_TOKENS
        });

        uint256 hidden = hiddenBalanceOf[holder][revnetId];

        // Make sure the holder has enough hidden tokens.
        if (hidden < tokenCount) {
            revert REVHiddenTokens_InsufficientHiddenBalance({hiddenBalance: hidden, requested: tokenCount});
        }

        // Decrement the holder's hidden balance.
        hiddenBalanceOf[holder][revnetId] = hidden - tokenCount;

        // Decrement the revnet's total hidden count.
        totalHiddenOf[revnetId] -= tokenCount;

        // Mint the tokens to the beneficiary without applying the reserved percent.
        // slither-disable-next-line unused-return,reentrancy-events
        CONTROLLER.mintTokensOf({
            projectId: revnetId, tokenCount: tokenCount, beneficiary: beneficiary, memo: "", useReservedPercent: false
        });

        emit RevealTokens({
            revnetId: revnetId, tokenCount: tokenCount, beneficiary: beneficiary, holder: holder, caller: _msgSender()
        });
    }

    //*********************************************************************//
    // ------------------------ internal overrides ----------------------- //
    //*********************************************************************//

    /// @dev Resolve the `_msgSender` conflict between `ERC2771Context` and `Context` (from `JBPermissioned`).
    /// Prefer the ERC2771 version.
    function _msgSender() internal view override(ERC2771Context, Context) returns (address) {
        return ERC2771Context._msgSender();
    }

    /// @dev Resolve the `_msgData` conflict between `ERC2771Context` and `Context` (from `JBPermissioned`).
    /// Prefer the ERC2771 version.
    function _msgData() internal view override(ERC2771Context, Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @dev Resolve the `_contextSuffixLength` conflict between `ERC2771Context` and `Context`.
    function _contextSuffixLength() internal view override(ERC2771Context, Context) returns (uint256) {
        return ERC2771Context._contextSuffixLength();
    }
}
