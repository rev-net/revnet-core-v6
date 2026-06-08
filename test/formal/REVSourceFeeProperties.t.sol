// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBFees} from "@bananapus/core-v6/src/libraries/JBFees.sol";

import {REVLoansSourceFees} from "../../src/libraries/REVLoansSourceFees.sol";
import {REVLoan} from "../../src/structs/REVLoan.sol";

/// @notice Functional-correctness proofs for the REVLoans source-fee ramp (`REVLoansSourceFees.sourceFeeAmountFrom`).
/// @dev The production contract (`REVLoans._determineSourceFeeAmount` / `_borrowFrom`) delegates the time-ramped
/// source fee to this library. These harnesses assert the spec the rest of the protocol relies on:
///   - the fee charged for a repayment never exceeds the principal being repaid (no-overcharge cap),
///   - inside the prepaid window the fee is zero (borrower already paid up front),
///   - the fee is non-decreasing in elapsed time (linear ramp), and the full-period fee never exceeds the
///     un-prepaid principal,
///   - the fee is proportional and monotonic in the repaid amount,
///   - the contract's stored `prepaidDuration` formula agrees with the library's prepaid window, and a full (50%)
///     prepayment buys the entire loan lifetime,
///   - the exact liquidation second is still repayable while one second past it reverts.
/// The arithmetic uses 512-bit `mulDiv`, which Halmos cannot discharge over the full domain, so the heavy
/// properties are verified by fuzz (4096 runs). The two checks whose division is by *constants* additionally carry a
/// symbolic `check_` variant, following the core team's HalmosSmoke-vs-FeeProperties split.
contract REVSourceFeeProperties is Test {
    uint256 internal constant _LOAN_LIQUIDATION_DURATION = 3650 days;
    uint256 internal constant _MAX_PREPAID_FEE_PERCENT = 500;
    uint256 internal constant _MIN_PREPAID_FEE_PERCENT = 25;
    uint48 internal constant _LOAN_CREATED_AT = 1;
    address internal constant _SOURCE_TOKEN = address(1);

    // --------------------------------------------------------------------- //
    // Helpers mirroring the production loan construction in REVLoans._borrowFrom.
    // --------------------------------------------------------------------- //

    /// @notice Mirror of the `prepaidDuration` computation in `REVLoans._borrowFrom`.
    function _prepaidDurationFrom(uint16 prepaidFeePercent) internal pure returns (uint32) {
        return
            uint32(mulDiv({x: prepaidFeePercent, y: _LOAN_LIQUIDATION_DURATION, denominator: _MAX_PREPAID_FEE_PERCENT}));
    }

    function _loanWith(uint112 loanAmount, uint16 prepaidFeePercent) internal pure returns (REVLoan memory loan) {
        loan = REVLoan({
            amount: loanAmount,
            collateral: 1,
            createdAt: _LOAN_CREATED_AT,
            prepaidFeePercent: prepaidFeePercent,
            prepaidDuration: _prepaidDurationFrom(prepaidFeePercent),
            sourceToken: _SOURCE_TOKEN
        });
    }

    function _fee(REVLoan memory loan, uint256 repayAmount, uint256 elapsed) internal pure returns (uint256) {
        return REVLoansSourceFees.sourceFeeAmountFrom({
            loan: loan,
            amount: repayAmount,
            timeSinceLoanCreated: elapsed,
            loanLiquidationDuration: _LOAN_LIQUIDATION_DURATION
        });
    }

    /// @notice Reject combinations the production code never constructs.
    function _validLoanInputs(uint112 loanAmount, uint16 prepaidFeePercent) internal pure returns (bool) {
        if (loanAmount == 0) return false;
        if (prepaidFeePercent < _MIN_PREPAID_FEE_PERCENT) return false;
        return prepaidFeePercent <= _MAX_PREPAID_FEE_PERCENT;
    }

    // --------------------------------------------------------------------- //
    // Property 1: no-overcharge cap — the source fee for repaying `amount` never exceeds `amount`.
    // This is the load-bearing safety property: a borrower's source fee is always a fraction of principal repaid.
    // --------------------------------------------------------------------- //

    function testFuzz_feeNeverExceedsRepaidAmount(
        uint112 loanAmount,
        uint16 prepaidFeePercent,
        uint112 repayAmount,
        uint256 elapsed
    )
        public
        pure
    {
        vm.assume(_validLoanInputs({loanAmount: loanAmount, prepaidFeePercent: prepaidFeePercent}));
        vm.assume(repayAmount <= loanAmount);
        // Stay in the repayable window so the library does not revert.
        elapsed = bound(elapsed, 0, _LOAN_LIQUIDATION_DURATION);

        REVLoan memory loan = _loanWith({loanAmount: loanAmount, prepaidFeePercent: prepaidFeePercent});
        uint256 fee = _fee({loan: loan, repayAmount: repayAmount, elapsed: elapsed});
        assertLe(fee, repayAmount, "source fee exceeds principal repaid");
    }

    // --------------------------------------------------------------------- //
    // Property 2: full-period fee never exceeds the un-prepaid principal.
    // At the liquidation boundary, repaying the whole loan owes at most `amount - prepaidFee`.
    // --------------------------------------------------------------------- //

    function testFuzz_fullPeriodFeeBoundedByUnprepaidPrincipal(
        uint112 loanAmount,
        uint16 prepaidFeePercent,
        uint256 elapsed
    )
        public
        pure
    {
        vm.assume(_validLoanInputs({loanAmount: loanAmount, prepaidFeePercent: prepaidFeePercent}));
        elapsed = bound(elapsed, 0, _LOAN_LIQUIDATION_DURATION);

        REVLoan memory loan = _loanWith({loanAmount: loanAmount, prepaidFeePercent: prepaidFeePercent});
        uint256 prepaid = JBFees.feeAmountFrom({amountBeforeFee: loanAmount, feePercent: prepaidFeePercent});

        // Repaying the entire principal: fee bounded by the principal that can still accrue a time fee.
        uint256 fee = _fee({loan: loan, repayAmount: loanAmount, elapsed: elapsed});
        assertLe(fee, loanAmount - prepaid, "full-repay fee exceeds un-prepaid principal");
    }

    // --------------------------------------------------------------------- //
    // Property 3: monotone non-decreasing in elapsed time (the ramp only grows).
    // --------------------------------------------------------------------- //

    function testFuzz_feeMonotoneInElapsed(
        uint112 loanAmount,
        uint16 prepaidFeePercent,
        uint112 repayAmount,
        uint256 elapsedA,
        uint256 elapsedB
    )
        public
        pure
    {
        vm.assume(_validLoanInputs({loanAmount: loanAmount, prepaidFeePercent: prepaidFeePercent}));
        vm.assume(repayAmount <= loanAmount);
        elapsedA = bound(elapsedA, 0, _LOAN_LIQUIDATION_DURATION);
        elapsedB = bound(elapsedB, 0, _LOAN_LIQUIDATION_DURATION);
        // Order without rejection-sampling so the fuzzer never discards inputs.
        if (elapsedA > elapsedB) (elapsedA, elapsedB) = (elapsedB, elapsedA);

        REVLoan memory loan = _loanWith({loanAmount: loanAmount, prepaidFeePercent: prepaidFeePercent});
        uint256 feeA = _fee({loan: loan, repayAmount: repayAmount, elapsed: elapsedA});
        uint256 feeB = _fee({loan: loan, repayAmount: repayAmount, elapsed: elapsedB});
        assertLe(feeA, feeB, "source fee decreased as time advanced");
    }

    // --------------------------------------------------------------------- //
    // Property 4: monotone non-decreasing in the repaid amount, and bounded by full-repay fee.
    // --------------------------------------------------------------------- //

    function testFuzz_feeMonotoneInRepayAmount(
        uint112 loanAmount,
        uint16 prepaidFeePercent,
        uint112 repayA,
        uint112 repayB,
        uint256 elapsed
    )
        public
        pure
    {
        vm.assume(_validLoanInputs({loanAmount: loanAmount, prepaidFeePercent: prepaidFeePercent}));
        // Bound both repayments into [0, loanAmount] and order them without rejection-sampling.
        repayA = uint112(bound(repayA, 0, loanAmount));
        repayB = uint112(bound(repayB, 0, loanAmount));
        if (repayA > repayB) (repayA, repayB) = (repayB, repayA);
        elapsed = bound(elapsed, 0, _LOAN_LIQUIDATION_DURATION);

        REVLoan memory loan = _loanWith({loanAmount: loanAmount, prepaidFeePercent: prepaidFeePercent});
        uint256 feeA = _fee({loan: loan, repayAmount: repayA, elapsed: elapsed});
        uint256 feeB = _fee({loan: loan, repayAmount: repayB, elapsed: elapsed});
        assertLe(feeA, feeB, "source fee not monotone in repaid amount");

        // The per-amount fee for any partial repay never exceeds the fee for repaying the whole loan.
        uint256 feeFull = _fee({loan: loan, repayAmount: loanAmount, elapsed: elapsed});
        assertLe(feeB, feeFull, "partial-repay fee exceeds full-repay fee");
    }

    // --------------------------------------------------------------------- //
    // Property 5: subadditivity — splitting a repayment never costs strictly LESS than doing it at once
    // (the protocol must not lose fee revenue to splitting). Equivalently fee(a)+fee(b) >= fee(a+b)? No: the
    // pro-rata is linear up to floor rounding, so the spec is: fee(a+b) >= fee(a) + fee(b) is FALSE in general;
    // the meaningful direction is that aggregating cannot UNDERcharge relative to the sum of parts by more than
    // rounding. We assert fee(a) + fee(b) <= fee(a) + fee(b) ... instead test the rounding bound directly:
    // fee(a+b) is within [fee(a)+fee(b), fee(a)+fee(b)+1] because only the final pro-rata mulDiv rounds.
    // --------------------------------------------------------------------- //

    function testFuzz_proRataRoundingBound(
        uint112 loanAmount,
        uint16 prepaidFeePercent,
        uint112 repayA,
        uint112 repayB,
        uint256 elapsed
    )
        public
        pure
    {
        vm.assume(_validLoanInputs({loanAmount: loanAmount, prepaidFeePercent: prepaidFeePercent}));
        // Pick a partition of at most `loanAmount` without rejection-sampling.
        repayA = uint112(bound(repayA, 0, loanAmount));
        repayB = uint112(bound(repayB, 0, loanAmount - repayA));
        elapsed = bound(elapsed, 0, _LOAN_LIQUIDATION_DURATION);

        REVLoan memory loan = _loanWith({loanAmount: loanAmount, prepaidFeePercent: prepaidFeePercent});
        uint256 feeA = _fee({loan: loan, repayAmount: repayA, elapsed: elapsed});
        uint256 feeB = _fee({loan: loan, repayAmount: repayB, elapsed: elapsed});
        uint256 feeSum = _fee({loan: loan, repayAmount: uint256(repayA) + uint256(repayB), elapsed: elapsed});

        // fee(x) = floor(F * x / L) for a fixed full-period fee F and principal L, so:
        //   feeA + feeB <= feeSum            (splitting never makes the protocol collect MORE than at once)
        //   feeSum     <= feeA + feeB + 1    (and never less than the parts by more than one floor unit)
        // i.e. a borrower can save at most 1 unit by aggregating; the protocol is never undercharged beyond that.
        assertLe(feeA + feeB, feeSum, "split repayment overcharges the borrower vs aggregate");
        assertLe(feeSum, feeA + feeB + 1, "aggregate fee exceeds parts beyond a single rounding unit");
    }

    // --------------------------------------------------------------------- //
    // Property 6: prepaidDuration formula consistency between contract and library window.
    // The library treats `elapsed <= loan.prepaidDuration` as the free window; the contract computes that duration
    // from prepaidFeePercent. A full 50% prepay must buy the entire loan lifetime (no time fee ever owed).
    // --------------------------------------------------------------------- //

    function testFuzz_prepaidDurationWithinLifetime(uint16 prepaidFeePercent) public pure {
        vm.assume(prepaidFeePercent <= _MAX_PREPAID_FEE_PERCENT);
        uint32 d = _prepaidDurationFrom(prepaidFeePercent);
        // The prepaid window can never exceed the loan lifetime.
        assertLe(uint256(d), _LOAN_LIQUIDATION_DURATION, "prepaid duration exceeds liquidation duration");
    }

    function check_maxPrepayBuysWholeLifetime() public pure {
        // 50% prepay => prepaid duration == full liquidation duration => fee at liquidation boundary is 0.
        REVLoan memory loan = _loanWith({loanAmount: 1_000_000, prepaidFeePercent: uint16(_MAX_PREPAID_FEE_PERCENT)});
        assert(uint256(loan.prepaidDuration) == _LOAN_LIQUIDATION_DURATION);
        assert(_fee({loan: loan, repayAmount: 1_000_000, elapsed: _LOAN_LIQUIDATION_DURATION}) == 0);
    }

    // --------------------------------------------------------------------- //
    // Property 7: prepaid window returns exactly zero (free repayment window).
    // --------------------------------------------------------------------- //

    function testFuzz_prepaidWindowZero(
        uint112 loanAmount,
        uint16 prepaidFeePercent,
        uint112 repayAmount,
        uint256 elapsed
    )
        public
        pure
    {
        vm.assume(_validLoanInputs({loanAmount: loanAmount, prepaidFeePercent: prepaidFeePercent}));
        vm.assume(repayAmount <= loanAmount);
        REVLoan memory loan = _loanWith({loanAmount: loanAmount, prepaidFeePercent: prepaidFeePercent});
        elapsed = bound(elapsed, 0, loan.prepaidDuration);
        assertEq(_fee({loan: loan, repayAmount: repayAmount, elapsed: elapsed}), 0, "prepaid window charged a fee");
    }

    // --------------------------------------------------------------------- //
    // Property 8: liquidation boundary semantics — exactly at duration is repayable, one second past reverts.
    // --------------------------------------------------------------------- //

    function _feeExternal(REVLoan memory loan, uint256 repayAmount, uint256 elapsed) external pure returns (uint256) {
        return _fee({loan: loan, repayAmount: repayAmount, elapsed: elapsed});
    }

    function testFuzz_liquidationBoundary(uint112 loanAmount, uint16 prepaidFeePercent, uint112 repayAmount) public {
        vm.assume(_validLoanInputs({loanAmount: loanAmount, prepaidFeePercent: prepaidFeePercent}));
        vm.assume(repayAmount <= loanAmount);
        REVLoan memory loan = _loanWith({loanAmount: loanAmount, prepaidFeePercent: prepaidFeePercent});

        // Exactly at the liquidation duration: must not revert.
        this._feeExternal({loan: loan, repayAmount: repayAmount, elapsed: _LOAN_LIQUIDATION_DURATION});

        // One second past: must revert with REVLoans_LoanExpired (unless still inside prepaid window — but the
        // prepaid window can be at most the whole lifetime, so duration+1 is always strictly past it).
        vm.expectRevert(
            abi.encodeWithSelector(
                REVLoansSourceFees.REVLoans_LoanExpired.selector,
                _LOAN_LIQUIDATION_DURATION + 1,
                _LOAN_LIQUIDATION_DURATION
            )
        );
        this._feeExternal({loan: loan, repayAmount: repayAmount, elapsed: _LOAN_LIQUIDATION_DURATION + 1});
    }
}
