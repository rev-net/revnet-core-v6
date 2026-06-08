// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/// @notice Functional-correctness proofs for the REVLoans loan-ID namespace encoding.
/// @dev `REVLoans` encodes each loan as `revnetId * _LOAN_ID_NAMESPACE_SIZE + loanNumber` (see
/// `_generateLoanId`) and recovers the revnet via `loanId / _LOAN_ID_NAMESPACE_SIZE` (see `revnetIdOfLoanWith`).
/// The contract enforces `loanNumber <= _MAX_LOAN_NUMBER` in `_nextLoanIdFor` so a loan number can never spill into
/// the next revnet's namespace. These checks prove the encode/decode is a faithful round-trip under that bound and
/// that distinct revnets never collide. The functions mirror the production constants exactly; both a symbolic
/// (`check_`) and a fuzz (`testFuzz_`) variant are provided per property.
contract REVLoanIdNamespace is Test {
    /// @notice The number of loan IDs reserved for each revnet (mirrors `REVLoans._LOAN_ID_NAMESPACE_SIZE`).
    uint256 internal constant _LOAN_ID_NAMESPACE_SIZE = 1_000_000_000_000_000_000;

    /// @notice The largest loan number that stays within a single revnet's ID namespace.
    uint256 internal constant _MAX_LOAN_NUMBER = _LOAN_ID_NAMESPACE_SIZE - 1;

    /// @notice Mirror of `REVLoans._generateLoanId`.
    function _generateLoanId(uint256 revnetId, uint256 loanNumber) internal pure returns (uint256) {
        return (revnetId * _LOAN_ID_NAMESPACE_SIZE) + loanNumber;
    }

    /// @notice Mirror of `REVLoans.revnetIdOfLoanWith`.
    function _revnetIdOfLoanWith(uint256 loanId) internal pure returns (uint256) {
        return loanId / _LOAN_ID_NAMESPACE_SIZE;
    }

    // --------------------------------------------------------------------- //
    // Property 1: revnet round-trip — decode(encode(revnetId, loanNumber)) == revnetId.
    // --------------------------------------------------------------------- //

    function _revnetRoundTrip(uint256 revnetId, uint256 loanNumber) internal pure {
        // The contract requires loanNumber in [1, _MAX_LOAN_NUMBER]; bound revnetId so the product cannot overflow.
        if (loanNumber == 0 || loanNumber > _MAX_LOAN_NUMBER) return;
        if (revnetId > type(uint256).max / _LOAN_ID_NAMESPACE_SIZE) return;
        if (revnetId * _LOAN_ID_NAMESPACE_SIZE > type(uint256).max - loanNumber) return;

        uint256 loanId = _generateLoanId({revnetId: revnetId, loanNumber: loanNumber});
        assert(_revnetIdOfLoanWith(loanId) == revnetId);
        // The loan number is fully recoverable as the remainder.
        assert(loanId % _LOAN_ID_NAMESPACE_SIZE == loanNumber);
    }

    /// @dev Symbolic: bound revnetId to a small symbolic range so the SMT product stays tractable.
    function check_revnetRoundTrip(uint64 revnetId, uint64 loanNumber) public pure {
        _revnetRoundTrip({revnetId: revnetId, loanNumber: loanNumber});
    }

    function testFuzz_revnetRoundTrip(uint256 revnetId, uint256 loanNumber) public pure {
        _revnetRoundTrip({revnetId: revnetId, loanNumber: loanNumber});
    }

    // --------------------------------------------------------------------- //
    // Property 2: no cross-revnet collision — different revnets occupy disjoint namespaces.
    // --------------------------------------------------------------------- //

    function _noCrossRevnetCollision(
        uint256 revnetA,
        uint256 revnetB,
        uint256 loanNumberA,
        uint256 loanNumberB
    )
        internal
        pure
    {
        if (revnetA == revnetB) return;
        if (loanNumberA == 0 || loanNumberA > _MAX_LOAN_NUMBER) return;
        if (loanNumberB == 0 || loanNumberB > _MAX_LOAN_NUMBER) return;
        if (revnetA > type(uint256).max / _LOAN_ID_NAMESPACE_SIZE) return;
        if (revnetB > type(uint256).max / _LOAN_ID_NAMESPACE_SIZE) return;
        if (revnetA * _LOAN_ID_NAMESPACE_SIZE > type(uint256).max - loanNumberA) return;
        if (revnetB * _LOAN_ID_NAMESPACE_SIZE > type(uint256).max - loanNumberB) return;

        uint256 idA = _generateLoanId({revnetId: revnetA, loanNumber: loanNumberA});
        uint256 idB = _generateLoanId({revnetId: revnetB, loanNumber: loanNumberB});
        assert(idA != idB);
    }

    function check_noCrossRevnetCollision(
        uint64 revnetA,
        uint64 revnetB,
        uint64 loanNumberA,
        uint64 loanNumberB
    )
        public
        pure
    {
        _noCrossRevnetCollision({
            revnetA: revnetA, revnetB: revnetB, loanNumberA: loanNumberA, loanNumberB: loanNumberB
        });
    }

    function testFuzz_noCrossRevnetCollision(
        uint256 revnetA,
        uint256 revnetB,
        uint256 loanNumberA,
        uint256 loanNumberB
    )
        public
        pure
    {
        _noCrossRevnetCollision({
            revnetA: revnetA, revnetB: revnetB, loanNumberA: loanNumberA, loanNumberB: loanNumberB
        });
    }

    // --------------------------------------------------------------------- //
    // Property 3: no intra-revnet collision — distinct loan numbers in the same revnet differ.
    // --------------------------------------------------------------------- //

    function _noIntraRevnetCollision(uint256 revnetId, uint256 loanNumberA, uint256 loanNumberB) internal pure {
        if (loanNumberA == loanNumberB) return;
        if (loanNumberA == 0 || loanNumberA > _MAX_LOAN_NUMBER) return;
        if (loanNumberB == 0 || loanNumberB > _MAX_LOAN_NUMBER) return;
        if (revnetId > type(uint256).max / _LOAN_ID_NAMESPACE_SIZE) return;
        if (revnetId * _LOAN_ID_NAMESPACE_SIZE > type(uint256).max - loanNumberA) return;
        if (revnetId * _LOAN_ID_NAMESPACE_SIZE > type(uint256).max - loanNumberB) return;

        assert(
            _generateLoanId({revnetId: revnetId, loanNumber: loanNumberA})
                != _generateLoanId({revnetId: revnetId, loanNumber: loanNumberB})
        );
    }

    function check_noIntraRevnetCollision(uint64 revnetId, uint64 loanNumberA, uint64 loanNumberB) public pure {
        _noIntraRevnetCollision({revnetId: revnetId, loanNumberA: loanNumberA, loanNumberB: loanNumberB});
    }

    function testFuzz_noIntraRevnetCollision(uint256 revnetId, uint256 loanNumberA, uint256 loanNumberB) public pure {
        _noIntraRevnetCollision({revnetId: revnetId, loanNumberA: loanNumberA, loanNumberB: loanNumberB});
    }
}
