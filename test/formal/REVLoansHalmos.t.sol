// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {mulDiv} from "@prb/math/src/Common.sol";

import {REVLoansSourceFees} from "../../src/libraries/REVLoansSourceFees.sol";
import {REVLoan} from "../../src/structs/REVLoan.sol";

/// @notice Halmos proofs for REVLoans source-fee timing and proportionality.
/// @dev The production contract delegates `_determineSourceFeeAmount` to `REVLoansSourceFees`, so these checks keep
/// the solver focused on the exact arithmetic path without loading the full ERC-721 loan contract.
contract REVLoansHalmos {
    /// @notice The duration after which an unrepaid REV loan expires.
    uint256 internal constant _LOAN_LIQUIDATION_DURATION = 3650 days;

    /// @notice The maximum fee percent that can be prepaid when borrowing.
    uint256 internal constant _MAX_PREPAID_FEE_PERCENT = 500;

    /// @notice The minimum fee percent that must be prepaid when borrowing.
    uint256 internal constant _MIN_PREPAID_FEE_PERCENT = 25;

    /// @notice Arbitrary nonzero creation timestamp; source-fee math receives elapsed time directly.
    uint48 internal constant _LOAN_CREATED_AT = 1;

    /// @notice Arbitrary nonzero source token; source-fee math only reads timing and amount fields.
    address internal constant _SOURCE_TOKEN = address(1);

    /// @notice Proves source-fee lookups reject loans older than the liquidation duration.
    /// @param loanAmount The original borrowed amount.
    /// @param prepaidFeePercent The production prepaid fee percent.
    /// @param repayAmount The principal amount being repaid.
    /// @param overtime Extra seconds after the first expired second.
    function check_liquidatedLoansRejectSourceFee(
        uint96 loanAmount,
        uint16 prepaidFeePercent,
        uint96 repayAmount,
        uint32 overtime
    )
        public
        view
    {
        if (!_validLoanInputs({loanAmount: loanAmount, prepaidFeePercent: prepaidFeePercent})) return;
        if (repayAmount > loanAmount) return;

        REVLoan memory loan = _loanWith({loanAmount: loanAmount, prepaidFeePercent: prepaidFeePercent});

        // Reaching the first second after liquidation must fail before any fee denominator is evaluated.
        try this.sourceFeeAmountFrom({
            loan: loan, repayAmount: repayAmount, elapsed: _LOAN_LIQUIDATION_DURATION + 1 + overtime
        }) returns (
            uint256
        ) {
            assert(false);
        } catch {}
    }

    /// @notice Proves max-prepaid loans never hit the zero-denominator ramp branch.
    /// @param loanAmount The original borrowed amount.
    /// @param repayAmount The principal amount being repaid.
    /// @param elapsed A loan age at or before the liquidation boundary.
    function check_maxPrepaidNeverDividesByZero(uint96 loanAmount, uint96 repayAmount, uint32 elapsed) public pure {
        if (loanAmount == 0) return;
        if (repayAmount > loanAmount) return;
        if (elapsed > _LOAN_LIQUIDATION_DURATION) return;

        REVLoan memory loan = _loanWith({loanAmount: loanAmount, prepaidFeePercent: uint16(_MAX_PREPAID_FEE_PERCENT)});

        assert(loan.prepaidDuration == _LOAN_LIQUIDATION_DURATION);
        assert(_sourceFeeAmountFrom({loan: loan, repayAmount: repayAmount, elapsed: elapsed}) == 0);
    }

    /// @notice Proves repayments inside the prepaid window do not owe an additional source fee.
    /// @param loanAmount The original borrowed amount.
    /// @param prepaidFeePercent The production prepaid fee percent.
    /// @param repayAmount The principal amount being repaid.
    /// @param elapsed A loan age that may fall inside the prepaid window.
    function check_prepaidWindowReturnsZero(
        uint96 loanAmount,
        uint16 prepaidFeePercent,
        uint96 repayAmount,
        uint32 elapsed
    )
        public
        pure
    {
        if (!_validLoanInputs({loanAmount: loanAmount, prepaidFeePercent: prepaidFeePercent})) return;
        if (repayAmount > loanAmount) return;

        REVLoan memory loan = _loanWith({loanAmount: loanAmount, prepaidFeePercent: prepaidFeePercent});
        if (elapsed > loan.prepaidDuration) return;

        assert(_sourceFeeAmountFrom({loan: loan, repayAmount: repayAmount, elapsed: elapsed}) == 0);
    }

    /// @notice Checks representative active-ramp fee values for min, mid, and max prepayment.
    function check_sourceFeeRampBoundaryTable() public pure {
        REVLoan memory minPrepayLoan =
            _loanWith({loanAmount: 1000, prepaidFeePercent: uint16(_MIN_PREPAID_FEE_PERCENT)});
        REVLoan memory midPrepayLoan = _loanWith({loanAmount: 1000, prepaidFeePercent: 250});
        REVLoan memory maxPrepayLoan =
            _loanWith({loanAmount: 1000, prepaidFeePercent: uint16(_MAX_PREPAID_FEE_PERCENT)});

        // Min prepayment leaves 975 units to ramp from 0 to full fee after the prepaid window.
        assert(
            _sourceFeeAmountFrom({loan: minPrepayLoan, repayAmount: 1000, elapsed: minPrepayLoan.prepaidDuration}) == 0
        );
        assert(_sourceFeeAmountFrom({loan: minPrepayLoan, repayAmount: 1000, elapsed: 165_564_000}) == 487);
        assert(
            _sourceFeeAmountFrom({loan: minPrepayLoan, repayAmount: 1000, elapsed: _LOAN_LIQUIDATION_DURATION}) == 975
        );

        // 25% prepayment leaves 750 units to ramp over the remaining half of the loan lifetime.
        assert(
            _sourceFeeAmountFrom({loan: midPrepayLoan, repayAmount: 1000, elapsed: midPrepayLoan.prepaidDuration}) == 0
        );
        assert(_sourceFeeAmountFrom({loan: midPrepayLoan, repayAmount: 1000, elapsed: 236_520_000}) == 375);
        assert(
            _sourceFeeAmountFrom({loan: midPrepayLoan, repayAmount: 1000, elapsed: _LOAN_LIQUIDATION_DURATION}) == 750
        );

        // Max prepayment covers the whole loan lifetime, so the exact liquidation boundary still owes no source fee.
        assert(_sourceFeeAmountFrom({loan: maxPrepayLoan, repayAmount: 1000, elapsed: _LOAN_LIQUIDATION_DURATION}) == 0);
    }

    /// @notice External wrapper used by `try/catch` checks for expected expiry reverts.
    /// @param loan The loan to determine the source fee for.
    /// @param repayAmount The principal amount being repaid.
    /// @param elapsed The elapsed time since loan creation.
    /// @return sourceFeeAmount The source fee amount for the repayment.
    function sourceFeeAmountFrom(
        REVLoan memory loan,
        uint256 repayAmount,
        uint256 elapsed
    )
        external
        pure
        returns (uint256 sourceFeeAmount)
    {
        return _sourceFeeAmountFrom({loan: loan, repayAmount: repayAmount, elapsed: elapsed});
    }

    /// @notice Builds a production-shaped loan using the same prepaid-duration formula as `_borrowFrom`.
    function _loanWith(uint96 loanAmount, uint16 prepaidFeePercent) internal pure returns (REVLoan memory loan) {
        loan = REVLoan({
            amount: uint112(loanAmount),
            collateral: 1,
            createdAt: _LOAN_CREATED_AT,
            prepaidFeePercent: prepaidFeePercent,
            prepaidDuration: _prepaidDurationFrom(prepaidFeePercent),
            sourceToken: _SOURCE_TOKEN
        });
    }

    /// @notice Converts a prepaid fee percent into the duration stored on a production loan.
    function _prepaidDurationFrom(uint16 prepaidFeePercent) internal pure returns (uint32) {
        return
            uint32(mulDiv({x: prepaidFeePercent, y: _LOAN_LIQUIDATION_DURATION, denominator: _MAX_PREPAID_FEE_PERCENT}));
    }

    /// @notice Evaluates the production source-fee library at a chosen loan age.
    function _sourceFeeAmountFrom(
        REVLoan memory loan,
        uint256 repayAmount,
        uint256 elapsed
    )
        internal
        pure
        returns (uint256)
    {
        return REVLoansSourceFees.sourceFeeAmountFrom({
            loan: loan,
            amount: repayAmount,
            timeSinceLoanCreated: elapsed,
            loanLiquidationDuration: _LOAN_LIQUIDATION_DURATION
        });
    }

    /// @notice Whether inputs match the production constraints enforced when creating loans.
    function _validLoanInputs(uint96 loanAmount, uint16 prepaidFeePercent) internal pure returns (bool) {
        if (loanAmount == 0) return false;
        if (prepaidFeePercent < _MIN_PREPAID_FEE_PERCENT) return false;
        return prepaidFeePercent <= _MAX_PREPAID_FEE_PERCENT;
    }
}
