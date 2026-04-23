// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBPayoutTerminal} from "@bananapus/core-v6/src/interfaces/IJBPayoutTerminal.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {REVLoanSource} from "../../src/structs/REVLoanSource.sol";
import {REVLoansFeeRecovery} from "../REVLoansFeeRecovery.t.sol";

contract StickyAllowanceFeeTerminal is ERC165, IJBPayoutTerminal {
    IERC20 public immutable token;
    address public immutable loans;
    address public thief;
    uint256 public stealAmount;

    constructor(IERC20 _token, address _loans) {
        token = _token;
        loans = _loans;
    }

    function configureSteal(address _thief, uint256 _stealAmount) external {
        thief = _thief;
        stealAmount = _stealAmount;
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
        uint256 amount = stealAmount;
        if (amount != 0) {
            stealAmount = 0;
            token.transferFrom(loans, thief, amount);
        }
        return 0;
    }

    function accountingContextForTokenOf(uint256, address) external view override returns (JBAccountingContext memory) {
        return JBAccountingContext({token: address(token), decimals: 6, currency: uint32(uint160(address(token)))});
    }

    function accountingContextsOf(uint256) external pure override returns (JBAccountingContext[] memory) {
        return new JBAccountingContext[](0);
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

    function currentSurplusOf(uint256, address[] calldata, uint256, uint256) external pure override returns (uint256) {
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
        returns (JBRuleset memory, uint256, uint256, JBPayHookSpecification[] memory)
    {
        JBRuleset memory ruleset;
        return (ruleset, 0, 0, new JBPayHookSpecification[](0));
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IJBPayoutTerminal).interfaceId
            || super.supportsInterface(interfaceId);
    }
}

contract TestFeeAllowanceLeak is REVLoansFeeRecovery {
    StickyAllowanceFeeTerminal internal stickyFeeTerminal;
    address internal attacker = makeAddr("attacker");

    function _stickyFeeTerminal() internal returns (StickyAllowanceFeeTerminal) {
        if (address(stickyFeeTerminal) == address(0)) {
            stickyFeeTerminal = new StickyAllowanceFeeTerminal(TOKEN, address(LOANS_CONTRACT));
        }
        return stickyFeeTerminal;
    }

    /// @notice Verifies that stale allowance is cleared — the original exploit no longer works.
    /// @dev Previously, a sticky fee terminal could accumulate reusable allowance across borrows.
    ///      After the fix (_afterTransferTo clears allowance on success), the allowance is zero.
    function test_feeTerminalCannotHarvestStaleAllowanceAfterFix() public {
        StickyAllowanceFeeTerminal terminal = _stickyFeeTerminal();

        vm.mockCall(
            address(jbDirectory()),
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector, FEE_PROJECT_ID, address(TOKEN)),
            abi.encode(address(terminal))
        );

        REVLoanSource memory source = REVLoanSource({token: address(TOKEN), terminal: jbMultiTerminal()});
        uint256 payAmount = 1_000_000;

        deal(address(TOKEN), USER, payAmount * 2);

        vm.startPrank(USER);
        TOKEN.approve(address(jbMultiTerminal()), payAmount * 2);
        uint256 firstTokenCount = jbMultiTerminal().pay(REVNET_ID, address(TOKEN), payAmount, USER, 0, "", "");
        vm.stopPrank();

        _mockLoanPermission(USER);
        vm.prank(USER);
        LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, firstTokenCount, payable(USER), 25, USER);

        // Allowance is now cleared after successful fee payment.
        uint256 allowanceAfterBorrow = TOKEN.allowance(address(LOANS_CONTRACT), address(stickyFeeTerminal));
        assertEq(allowanceAfterBorrow, 0, "no stale allowance after successful borrow");

        // The uncollected fee is still parked in REVLoans (terminal didn't pull it),
        // but there's no allowance for the terminal to steal it later.
        uint256 loansBalance = TOKEN.balanceOf(address(LOANS_CONTRACT));
        assertGt(loansBalance, 0, "uncollected fee is parked in REVLoans");

        // Second borrow — terminal tries to steal but can't because allowance is 0.
        vm.prank(USER);
        uint256 secondTokenCount = jbMultiTerminal().pay(REVNET_ID, address(TOKEN), payAmount, USER, 0, "", "");

        terminal.configureSteal(attacker, loansBalance);

        _mockLoanPermission(USER);
        vm.prank(USER);
        LOANS_CONTRACT.borrowFrom(REVNET_ID, source, 0, secondTokenCount, payable(USER), 25, USER);

        // The attacker gets nothing — the steal attempt fails silently (transferFrom reverts,
        // caught by _tryPayFee's try-catch).
        assertEq(TOKEN.balanceOf(attacker), 0, "attacker cannot drain stale allowance");

        // And the current borrow also leaves zero allowance.
        assertEq(
            TOKEN.allowance(address(LOANS_CONTRACT), address(terminal)),
            0,
            "no fresh stale allowance after second borrow"
        );
    }
}
