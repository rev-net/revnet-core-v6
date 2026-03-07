// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBPayoutTerminal} from "@bananapus/core-v6/src/interfaces/IJBPayoutTerminal.sol";
import {IREVLoans} from "../../src/interfaces/IREVLoans.sol";
import {REVLoanSource} from "../../src/structs/REVLoanSource.sol";

/// @notice A terminal that reverts on both pay() and addToBalanceOf().
/// @dev If the fee terminal breaks, cash-outs brick because
///      afterCashOutRecordedWith's fallback addToBalanceOf also reverts.
contract BrokenFeeTerminal is ERC165, IJBPayoutTerminal {
    bool public payReverts = true;
    bool public addToBalanceReverts = true;

    function setPayReverts(bool _reverts) external {
        payReverts = _reverts;
    }

    function setAddToBalanceReverts(bool _reverts) external {
        addToBalanceReverts = _reverts;
    }

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
        if (payReverts) revert("BrokenFeeTerminal: pay reverts");
        return 0;
    }

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
    {
        if (addToBalanceReverts) revert("BrokenFeeTerminal: addToBalance reverts");
    }

    function accountingContextForTokenOf(uint256, address) external pure override returns (JBAccountingContext memory) {
        return JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
    }

    function accountingContextsOf(uint256) external pure override returns (JBAccountingContext[] memory) {
        return new JBAccountingContext[](0);
    }

    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override {}

    function currentSurplusOf(
        uint256,
        JBAccountingContext[] memory,
        uint256,
        uint256
    )
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256) {
        return 0;
    }

    function sendPayoutsOf(uint256, address, uint256, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

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

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IJBPayoutTerminal).interfaceId
            || super.supportsInterface(interfaceId);
    }

    receive() external payable {}
}

/// @notice A terminal that attempts to addToBalance + borrow in a single tx.
/// @dev Flash loan surplus inflation via live surplus read.
contract SurplusInflator is ERC165, IJBPayoutTerminal {
    IREVLoans public loans;
    uint256 public revnetId;
    IJBPayoutTerminal public realTerminal;
    bool public shouldInflate;

    function configure(IREVLoans _loans, uint256 _revnetId, IJBPayoutTerminal _realTerminal) external {
        loans = _loans;
        revnetId = _revnetId;
        realTerminal = _realTerminal;
    }

    function setShouldInflate(bool _should) external {
        shouldInflate = _should;
    }

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
        if (shouldInflate) {
            shouldInflate = false;
            // Try to borrow at the inflated surplus
            REVLoanSource memory source = REVLoanSource({token: JBConstants.NATIVE_TOKEN, terminal: realTerminal});
            try loans.borrowFrom(revnetId, source, 0, 1e18, payable(address(this)), 25) {} catch {}
        }
        return 0;
    }

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

    function accountingContextForTokenOf(uint256, address) external pure override returns (JBAccountingContext memory) {
        return JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
    }

    function accountingContextsOf(uint256) external pure override returns (JBAccountingContext[] memory) {
        return new JBAccountingContext[](0);
    }

    function addAccountingContextsFor(uint256, JBAccountingContext[] calldata) external override {}

    function currentSurplusOf(
        uint256,
        JBAccountingContext[] memory,
        uint256,
        uint256
    )
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    function migrateBalanceOf(uint256, address, IJBTerminal) external pure override returns (uint256) {
        return 0;
    }

    function sendPayoutsOf(uint256, address, uint256, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

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

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IJBPayoutTerminal).interfaceId
            || super.supportsInterface(interfaceId);
    }

    receive() external payable {}
}
