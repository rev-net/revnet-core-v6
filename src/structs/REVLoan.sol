// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {REVLoanSource} from "./REVLoanSource.sol";

/// @notice An active loan against a revnet. The borrower locked collateral tokens (which were burned) and received
/// funds from the revnet's terminal. The loan can be repaid within the prepaid duration at no extra cost; after that,
/// repayment cost increases linearly until liquidation at 10 years.
/// @custom:member amount The amount borrowed (includes fees taken at creation).
/// @custom:member collateral The number of revnet tokens burned as collateral.
/// @custom:member createdAt The timestamp when the loan was created.
/// @custom:member prepaidFeePercent The percentage of fees prepaid at creation (determines prepaid duration).
/// @custom:member prepaidDuration The duration (seconds) during which repayment costs nothing beyond the original
/// amount. @custom:member source The terminal and token from which funds were drawn.
struct REVLoan {
    uint112 amount;
    uint112 collateral;
    uint48 createdAt;
    uint16 prepaidFeePercent;
    uint32 prepaidDuration;
    REVLoanSource source;
}
