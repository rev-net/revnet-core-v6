// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPayoutTerminal} from "@bananapus/core-v6/src/interfaces/IJBPayoutTerminal.sol";
import {IJBPermissioned} from "@bananapus/core-v6/src/interfaces/IJBPermissioned.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokenUriResolver} from "@bananapus/core-v6/src/interfaces/IJBTokenUriResolver.sol";
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBFees} from "@bananapus/core-v6/src/libraries/JBFees.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBSurplus} from "@bananapus/core-v6/src/libraries/JBSurplus.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {IREVLoans} from "./interfaces/IREVLoans.sol";
import {IREVOwner} from "./interfaces/IREVOwner.sol";
import {REVLoan} from "./structs/REVLoan.sol";
import {REVLoanSource} from "./structs/REVLoanSource.sol";

/// @notice A contract for borrowing from revnets.
/// @dev Tokens used as collateral are burned, and reminted when the loan is paid off. This keeps the revnet's token
/// structure orderly.
/// @dev The borrowable amount is the same as the cash out amount.
/// @dev An upfront fee is taken when a loan is created. 2.5% is charged by the underlying protocol, 2.5% is charged
/// by the
/// revnet issuing the loan, and a variable amount charged by the revnet that receives the fees. This variable amount is
/// chosen by the borrower, the more paid upfront, the longer the prepaid duration. The loan can be repaid anytime
/// within the prepaid duration without additional fees.
/// After the prepaid duration, the loan will increasingly cost more to pay off. After 10 years, the loan collateral
/// cannot be
/// recouped.
/// @dev The loaned amounts include the fees taken, meaning the amount paid back is the amount borrowed plus the fees.
contract REVLoans is ERC721, ERC2771Context, JBPermissioned, Ownable, IREVLoans {
    // A library that parses the packed ruleset metadata into a friendlier format.
    using JBRulesetMetadataResolver for JBRuleset;

    // A library that adds default safety checks to ERC20 functionality.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error REVLoans_CashOutDelayNotFinished(uint256 cashOutDelay, uint256 blockTimestamp);
    error REVLoans_CollateralExceedsLoan(uint256 collateralToReturn, uint256 loanCollateral);
    error REVLoans_InvalidPrepaidFeePercent(uint256 prepaidFeePercent, uint256 min, uint256 max);
    error REVLoans_InvalidTerminal(address terminal, uint256 revnetId);
    error REVLoans_LoanExpired(uint256 timeSinceLoanCreated, uint256 loanLiquidationDuration);
    error REVLoans_LoanIdOverflow();
    error REVLoans_NewBorrowAmountGreaterThanLoanAmount(uint256 newBorrowAmount, uint256 loanAmount);
    error REVLoans_NoMsgValueAllowed();
    error REVLoans_NotEnoughCollateral();
    error REVLoans_NothingToRepay();
    error REVLoans_OverMaxRepayBorrowAmount(uint256 maxRepayBorrowAmount, uint256 repayBorrowAmount);
    error REVLoans_OverflowAlert(uint256 value, uint256 limit);
    error REVLoans_PermitAllowanceNotEnough(uint256 allowanceAmount, uint256 requiredAmount);
    error REVLoans_ReallocatingMoreCollateralThanBorrowedAmountAllows(uint256 newBorrowAmount, uint256 loanAmount);
    error REVLoans_SourceMismatch();
    error REVLoans_UnderMinBorrowAmount(uint256 minBorrowAmount, uint256 borrowAmount);
    error REVLoans_ZeroBorrowAmount();
    error REVLoans_ZeroCollateralLoanIsInvalid();

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @dev After the prepaid duration, the loan will cost more to pay off. After 10 years, the loan
    /// collateral cannot be recouped. This means paying 50% of the loan amount upfront will pay for having access to
    /// the remaining 50% for 10 years,
    /// whereas paying 0% of the loan upfront will cost 100% of the loan amount to be paid off after 10 years. After 10
    /// years with repayment, both loans cost 100% and are liquidated.
    uint256 public constant override LOAN_LIQUIDATION_DURATION = 3650 days;

    /// @dev The maximum amount of a loan that can be prepaid at the time of borrowing, in terms of JBConstants.MAX_FEE.
    uint256 public constant override MAX_PREPAID_FEE_PERCENT = 500;

    /// @dev A fee of 1% is charged by the $REV revnet.
    uint256 public constant override REV_PREPAID_FEE_PERCENT = 10; // 1%

    /// @dev A fee of 2.5% is charged by the loan's source upfront.
    uint256 public constant override MIN_PREPAID_FEE_PERCENT = 25; // 2.5%

    //*********************************************************************//
    // ------------------------ private constants ------------------------ //
    //*********************************************************************//

    /// @notice Just a kind reminder to our readers.
    /// @dev Used in loan token ID generation.
    uint256 private constant _ONE_TRILLION = 1_000_000_000_000;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The permit2 utility.
    IPermit2 public immutable override PERMIT2;

    /// @notice The controller of revnets that use this loans contract.
    IJBController public immutable override CONTROLLER;

    /// @notice The directory of terminals and controllers for revnets.
    IJBDirectory public immutable override DIRECTORY;

    /// @notice A contract that stores prices for each revnet.
    IJBPrices public immutable override PRICES;

    /// @notice The ID of the REV revnet that will receive the fees.
    uint256 public immutable override REV_ID;

    /// @notice The sucker registry used to discover peer chain suckers for cross-chain awareness.
    IJBSuckerRegistry public immutable override SUCKER_REGISTRY;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice An indication if a revnet currently has outstanding loans from the specified terminal in the specified
    /// token.
    /// @custom:param revnetId The ID of the revnet issuing the loan.
    /// @custom:param terminal The terminal that the loan is issued from.
    /// @custom:param token The token being loaned.
    mapping(uint256 revnetId => mapping(IJBPayoutTerminal terminal => mapping(address token => bool)))
        public
        override isLoanSourceOf;

    /// @notice The cumulative number of loans ever created for a revnet, used as a loan ID sequence counter.
    /// @dev This counter only increments (on borrow, repay-with-new-loan, and reallocation) and never decrements.
    /// It does NOT represent the number of currently active loans. Repaid and liquidated loans leave permanent gaps
    /// in the ID sequence. Integrators should not use this to count active loans.
    /// @custom:param revnetId The ID of the revnet to get the cumulative loan count from.
    mapping(uint256 revnetId => uint256) public override totalLoansBorrowedFor;

    /// @notice The contract resolving each project ID to its ERC721 URI.
    IJBTokenUriResolver public override tokenUriResolver;

    /// @notice The total amount loaned out by a revnet from a specified terminal in a specified token.
    /// @custom:param revnetId The ID of the revnet issuing the loan.
    /// @custom:param terminal The terminal that the loan is issued from.
    /// @custom:param token The token being loaned.
    mapping(uint256 revnetId => mapping(IJBPayoutTerminal terminal => mapping(address token => uint256)))
        public
        override totalBorrowedFrom;

    /// @notice The total amount of collateral supporting a revnet's loans.
    /// @custom:param revnetId The ID of the revnet issuing the loan.
    mapping(uint256 revnetId => uint256) public override totalCollateralOf;

    //*********************************************************************//
    // --------------------- internal stored properties ------------------ //
    //*********************************************************************//

    /// @notice The sources of each revnet's loan.
    /// @dev This array grows monotonically -- entries are appended when a new (terminal, token) pair is first used for
    /// borrowing, but are never removed. The `isLoanSourceOf` mapping tracks whether a source has been registered.
    /// Since the number of distinct (terminal, token) pairs per revnet is practically bounded (typically < 10),
    /// the gas cost of iterating this array in `loanSourcesOf` remains manageable.
    /// @custom:member revnetId The ID of the revnet issuing the loan.
    mapping(uint256 revnetId => REVLoanSource[]) internal _loanSourcesOf;

    /// @notice The loans.
    /// @custom:member The ID of the loan.
    mapping(uint256 loanId => REVLoan) internal _loanOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param controller The controller that manages revnets using this loans contract.
    /// @param suckerRegistry The registry used to discover peer chain suckers for cross-chain supply/surplus awareness.
    /// @param revId The ID of the REV revnet that will receive the fees.
    /// @param owner The owner of the contract that can set the URI resolver.
    /// @param permit2 A permit2 utility.
    /// @param trustedForwarder A trusted forwarder of transactions to this contract.
    constructor(
        IJBController controller,
        IJBSuckerRegistry suckerRegistry,
        uint256 revId,
        address owner,
        IPermit2 permit2,
        address trustedForwarder
    )
        ERC721("REV Loans", "$REVLOAN")
        ERC2771Context(trustedForwarder)
        JBPermissioned(IJBPermissioned(address(controller)).PERMISSIONS())
        Ownable(owner)
    {
        CONTROLLER = controller;
        DIRECTORY = controller.DIRECTORY();
        PRICES = controller.PRICES();
        REV_ID = revId;
        PERMIT2 = permit2;
        SUCKER_REGISTRY = suckerRegistry;
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice The amount that can be borrowed from a revnet.
    /// @param revnetId The ID of the revnet to check for borrowable assets from.
    /// @param collateralCount The amount of collateral used to secure the loan.
    /// @param decimals The decimals the resulting fixed point value will include.
    /// @param currency The currency that the resulting amount should be in terms of.
    /// @return borrowableAmount The amount that can be borrowed from the revnet.
    function borrowableAmountFrom(
        uint256 revnetId,
        uint256 collateralCount,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        returns (uint256)
    {
        // Cache the current ruleset once — used by both _cashOutDelayOf and _borrowableAmountFrom.
        JBRuleset memory currentRuleset = _currentRulesetOf(revnetId);

        // If the cash out delay hasn't passed yet, no amount is borrowable.
        if (_cashOutDelayOf({revnetId: revnetId, currentRuleset: currentRuleset}) > block.timestamp) return 0;

        return _borrowableAmountFrom({
            revnetId: revnetId,
            collateralCount: collateralCount,
            decimals: decimals,
            currency: currency,
            terminals: _terminalsOf(revnetId),
            currentStage: currentRuleset
        });
    }

    /// @notice Get a loan.
    /// @custom:member The ID of the loan.
    function loanOf(uint256 loanId) external view override returns (REVLoan memory) {
        return _loanOf[loanId];
    }

    /// @notice The sources of each revnet's loan.
    /// @dev This array only grows -- sources are never removed. The number of distinct sources is practically bounded
    /// by the number of unique (terminal, token) pairs used for borrowing, which is typically small.
    /// @custom:member revnetId The ID of the revnet issuing the loan.
    function loanSourcesOf(uint256 revnetId) external view override returns (REVLoanSource[] memory) {
        return _loanSourcesOf[revnetId];
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Determines the source fee amount for a loan being paid off a certain amount.
    /// @param loan The loan having its source fee amount determined.
    /// @param amount The amount being paid off.
    /// @return sourceFeeAmount The source fee amount for the loan.
    function determineSourceFeeAmount(REVLoan memory loan, uint256 amount) public view returns (uint256) {
        return _determineSourceFeeAmount({loan: loan, amount: amount});
    }

    /// @notice The revnet ID for the loan with the provided loan ID.
    /// @param loanId The loan ID of the loan to get the revnet ID of.
    /// @return The ID of the revnet.
    function revnetIdOfLoanWith(uint256 loanId) public pure override returns (uint256) {
        return loanId / _ONE_TRILLION;
    }

    /// @notice Returns the URI where the ERC-721 standard JSON of a loan is hosted.
    /// @param loanId The ID of the loan to get a URI of.
    /// @return The token URI to use for the provided `loanId`.
    function tokenURI(uint256 loanId) public view override returns (string memory) {
        // Keep a reference to the resolver.
        IJBTokenUriResolver resolver = tokenUriResolver;

        // If there's no resolver, there's no URI.
        if (resolver == IJBTokenUriResolver(address(0))) return "";

        // Return the resolved URI.
        return resolver.getUri(loanId);
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice Checks this contract's balance of a specific token.
    /// @param token The address of the token to get this contract's balance of.
    /// @return This contract's balance.
    function _balanceOf(address token) internal view returns (uint256) {
        // If the `token` is native, get the native token balance.
        return token == JBConstants.NATIVE_TOKEN ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    /// @dev This function reads live surplus from the revnet's terminals. A potential concern is flash loan
    /// manipulation: an attacker could temporarily inflate surplus via `addToBalanceOf` or `pay`, borrow at the
    /// inflated rate, then repay the flash loan. However, this attack is economically irrational:
    ///
    /// - `addToBalanceOf` permanently donates funds to the project (no recovery mechanism). The attacker's extra
    ///   borrowable amount equals `donation * (collateralCount / totalSupply)`, which is always less than the
    ///   donation since `collateralCount < totalSupply`. The attacker loses more than they gain.
    /// - `pay` increases both surplus AND totalSupply (via newly minted tokens), so the net effect on the
    ///   borrowable-amount-per-token ratio is neutral — the increased surplus is offset by supply dilution.
    /// - With non-zero `cashOutTaxRate`, the bonding curve is concave, making the attack even less profitable.
    /// - Refinancing during inflated surplus (`reallocateCollateralFromLoan`) does not help either: the freed
    ///   collateral can only borrow a fraction of the donated amount, keeping the attack net-negative.
    ///
    /// In summary, any attempt to inflate surplus to increase borrowing power costs the attacker more than it yields,
    /// because the bonding curve ensures no individual can extract more than their proportional share of surplus.
    /// @dev The amount that can be borrowed from a revnet given a certain amount of collateral.
    /// @dev The system intentionally allows up to 100% LTV (loan-to-value) by design. The borrowable amount equals
    /// what the collateral tokens would receive if cashed out, computed via the bonding curve formula in
    /// `JBCashOuts.cashOutFrom`. The `cashOutTaxRate` configured for the current stage serves as an implicit margin
    /// buffer: a non-zero tax rate reduces the cash-out value below the pro-rata share of surplus, creating an
    /// effective collateralization margin. For example, a 20% `cashOutTaxRate` means borrowers can only extract ~80%
    /// of their pro-rata surplus, providing a ~20% buffer against collateral depreciation before liquidation.
    /// A `cashOutTaxRate` of 0 means the full pro-rata amount is borrowable (true 100% LTV with no margin).
    /// @param revnetId The ID of the revnet to check for borrowable assets from.
    /// @param collateralCount The amount of collateral that the loan will be collateralized with.
    /// @param decimals The decimals the resulting fixed point value will include.
    /// @param currency The currency that the resulting amount should be in terms of.
    /// @param terminals The terminals that the funds are being borrowed from.
    /// @param currentStage The pre-fetched current ruleset.
    /// @return borrowableAmount The amount that can be borrowed from the revnet.
    function _borrowableAmountFrom(
        uint256 revnetId,
        uint256 collateralCount,
        uint256 decimals,
        uint256 currency,
        IJBTerminal[] memory terminals,
        JBRuleset memory currentStage
    )
        internal
        view
        returns (uint256)
    {
        // Get the surplus of all the revnet's terminals in terms of the native currency.
        uint256 totalSurplus = JBSurplus.currentSurplusOf({
            projectId: revnetId, terminals: terminals, tokens: new address[](0), decimals: decimals, currency: currency
        });

        // Get the total amount the revnet currently has loaned out, in terms of the native currency with 18
        // decimals.
        uint256 totalBorrowed = _totalBorrowedFrom({revnetId: revnetId, decimals: decimals, currency: currency});

        // Get the total amount of tokens in circulation.
        uint256 totalSupply = CONTROLLER.totalTokenSupplyWithReservedTokensOf(revnetId);

        // Get a refeerence to the collateral being used to secure loans.
        uint256 totalCollateral = totalCollateralOf[revnetId];

        // The local supply includes both circulating tokens and tokens locked as loan collateral.
        uint256 localSupply = totalSupply + totalCollateral;

        // The local surplus includes both the treasury surplus and the outstanding borrowed amounts.
        uint256 localSurplus = totalSurplus + totalBorrowed;

        // Proportional — uses the CURRENT stage's cashOutTaxRate.
        // NOTE: When a revnet transitions between stages with different cashOutTaxRate values, the borrowable amount
        // for the same collateral changes. A lower cashOutTaxRate in a later stage means more borrowable value per
        // collateral. This is by design: loan value tracks the current bonding curve parameters, just as cash-out
        // value does. Borrowers benefit from decreasing tax rates and are constrained by increasing ones.
        // Add cross-chain remote values for proportional reclaim.
        uint256 omnichainSurplus = localSurplus
            + SUCKER_REGISTRY.remoteSurplusOf({projectId: revnetId, decimals: decimals, currency: currency});
        uint256 omnichainSupply = localSupply + SUCKER_REGISTRY.remoteTotalSupplyOf(revnetId);
        uint256 reclaimable = JBCashOuts.cashOutFrom({
            surplus: omnichainSurplus,
            cashOutCount: collateralCount,
            totalSupply: omnichainSupply,
            cashOutTaxRate: currentStage.cashOutTaxRate()
        });
        // Cap at local surplus — can't borrow more than what this chain's terminals actually hold.
        return reclaimable > localSurplus ? localSurplus : reclaimable;
    }

    /// @notice The amount of the loan that should be borrowed for the given collateral amount.
    /// @param loan The loan having its borrow amount determined.
    /// @param revnetId The ID of the revnet to check for borrowable assets from.
    /// @param collateralCount The amount of collateral that the loan will be collateralized with.
    /// @param currentRuleset The pre-fetched current ruleset.
    /// @return borrowAmount The amount of the loan that should be borrowed.
    function _borrowAmountFrom(
        REVLoan storage loan,
        uint256 revnetId,
        uint256 collateralCount,
        JBRuleset memory currentRuleset
    )
        internal
        view
        returns (uint256)
    {
        // If there's no collateral, there's no loan.
        if (collateralCount == 0) return 0;

        // Get a reference to the accounting context for the source.
        JBAccountingContext memory accountingContext =
            loan.source.terminal.accountingContextForTokenOf({projectId: revnetId, token: loan.source.token});

        // Keep a reference to the revnet's terminals.
        IJBTerminal[] memory terminals = _terminalsOf(revnetId);

        return _borrowableAmountFrom({
            revnetId: revnetId,
            collateralCount: collateralCount,
            decimals: accountingContext.decimals,
            currency: accountingContext.currency,
            terminals: terminals,
            currentStage: currentRuleset
        });
    }

    /// @notice Returns the cash out delay timestamp using a pre-fetched ruleset.
    /// @param revnetId The ID of the revnet.
    /// @param currentRuleset The pre-fetched current ruleset.
    /// @return The cash out delay timestamp. Returns 0 if no data hook is set or no delay exists.
    function _cashOutDelayOf(uint256 revnetId, JBRuleset memory currentRuleset) internal view returns (uint256) {
        // Extract the data hook address from the ruleset's packed metadata.
        address dataHook = currentRuleset.dataHook();

        // If there's no data hook, this isn't a revnet — no cash out delay applies.
        if (dataHook == address(0)) return 0;

        // Read the cash out delay from the REVOwner contract (the data hook).
        return IREVOwner(dataHook).cashOutDelayOf(revnetId);
    }

    /// @dev `ERC-2771` specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view override(ERC2771Context, Context) returns (uint256) {
        return super._contextSuffixLength();
    }

    /// @notice Returns the current ruleset for a revnet. Consolidates ABI encode/decode to a single site.
    /// @param revnetId The ID of the revnet.
    /// @return currentRuleset The current ruleset.
    function _currentRulesetOf(uint256 revnetId) internal view returns (JBRuleset memory currentRuleset) {
        // slither-disable-next-line unused-return
        (currentRuleset,) = CONTROLLER.currentRulesetOf(revnetId);
    }

    /// @notice Determines the source fee amount for a loan being paid off a certain amount.
    /// @param loan The loan having its source fee amount determined.
    /// @param amount The amount being paid off.
    /// @return The source fee amount for the loan.
    function _determineSourceFeeAmount(REVLoan memory loan, uint256 amount) internal view returns (uint256) {
        // Keep a reference to the time since the loan was created.
        uint256 timeSinceLoanCreated = block.timestamp - loan.createdAt;

        // If the loan period has passed the prepaid time frame, take a fee.
        if (timeSinceLoanCreated <= loan.prepaidDuration) return 0;

        // If the loan period has passed the liquidation time frame, do not allow loan management.
        // Uses `>` (not `>=`) so the exact boundary second is still repayable — the liquidation path
        // uses `<=`, and matching `>=` here would create a 1-second window where neither path is available.
        if (timeSinceLoanCreated > LOAN_LIQUIDATION_DURATION) {
            revert REVLoans_LoanExpired(timeSinceLoanCreated, LOAN_LIQUIDATION_DURATION);
        }

        // Get a reference to the amount prepaid for the full loan.
        uint256 prepaid = JBFees.feeAmountFrom({amountBeforeFee: loan.amount, feePercent: loan.prepaidFeePercent});

        uint256 fullSourceFeeAmount = JBFees.feeAmountFrom({
            amountBeforeFee: loan.amount - prepaid,
            feePercent: mulDiv({
                x: timeSinceLoanCreated - loan.prepaidDuration,
                y: JBConstants.MAX_FEE,
                denominator: LOAN_LIQUIDATION_DURATION - loan.prepaidDuration
            })
        });

        // Calculate the source fee amount for the amount being paid off.
        return mulDiv({x: fullSourceFeeAmount, y: amount, denominator: loan.amount});
    }

    /// @notice Generate a ID for a loan given a revnet ID and a loan number within that revnet.
    /// @dev The multiplication and addition can theoretically overflow a uint256 if revnetId or loanNumber are
    /// astronomically large. In practice this is infeasible — it would require 2^256 loans or project IDs, far
    /// beyond any realistic usage. No overflow check is needed.
    /// @param revnetId The ID of the revnet to generate a loan ID for.
    /// @param loanNumber The loan number of the loan within the revnet.
    /// @return The token ID of the 721.
    function _generateLoanId(uint256 revnetId, uint256 loanNumber) internal pure returns (uint256) {
        return (revnetId * _ONE_TRILLION) + loanNumber;
    }

    /// @notice The calldata. Preferred to use over `msg.data`.
    /// @return calldata The `msg.data` of this call.
    function _msgData() internal view override(ERC2771Context, Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @notice The message's sender. Preferred to use over `msg.sender`.
    /// @return sender The address which sent this call.
    function _msgSender() internal view override(ERC2771Context, Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }

    /// @notice Returns the terminals for a revnet. Consolidates ABI encode/decode to a single site.
    /// @param revnetId The ID of the revnet.
    /// @return The terminals registered for the revnet.
    function _terminalsOf(uint256 revnetId) internal view returns (IJBTerminal[] memory) {
        return DIRECTORY.terminalsOf(revnetId);
    }

    /// @notice The total borrowed amount from a revnet, aggregated across all loan sources.
    /// @dev Each source's `totalBorrowedFrom` is stored in the source token's native decimals (e.g. 6 for USDC,
    /// 18 for ETH). Before aggregation, each amount is normalized to the target `decimals` to prevent mixed-decimal
    /// arithmetic errors. For cross-currency sources, the normalized amount is then converted via the price feed.
    /// @dev Inverse price feeds may truncate to zero at low decimal counts (e.g. a feed returning 1e21 at 6 decimals
    /// inverts to mulDiv(1e6, 1e6, 1e21) = 0). Sources with a zero price are skipped to prevent division-by-zero.
    /// @param revnetId The ID of the revnet to check for borrowed assets from.
    /// @param decimals The decimals the resulting fixed point value will include.
    /// @param currency The currency the resulting value will be in terms of.
    /// @return borrowedAmount The total amount borrowed.
    function _totalBorrowedFrom(
        uint256 revnetId,
        uint256 decimals,
        uint256 currency
    )
        internal
        view
        returns (uint256 borrowedAmount)
    {
        // Keep a reference to all sources being used to loaned out from this revnet.
        // Use storage ref to avoid bulk-copying the entire array to memory.
        REVLoanSource[] storage sources = _loanSourcesOf[revnetId];

        // Iterate over all sources being used to loaned out.
        for (uint256 i; i < sources.length; i++) {
            // Get a reference to the token being iterated on.
            REVLoanSource storage source = sources[i];

            // Get a reference to the amount of tokens loaned out.
            uint256 tokensLoaned = totalBorrowedFrom[revnetId][source.terminal][source.token];

            // Skip if no tokens are loaned from this source. Checked before the external call below to avoid
            // reverting on stale sources whose terminals may no longer support this token.
            if (tokensLoaned == 0) continue;

            // Get a reference to the accounting context for the source.
            // slither-disable-next-line calls-loop
            JBAccountingContext memory accountingContext =
                source.terminal.accountingContextForTokenOf({projectId: revnetId, token: source.token});

            // Normalize the token amount from the source's decimals to the target decimals.
            uint256 normalizedTokens;
            if (accountingContext.decimals > decimals) {
                normalizedTokens = tokensLoaned / (10 ** (accountingContext.decimals - decimals));
            } else if (accountingContext.decimals < decimals) {
                normalizedTokens = tokensLoaned * (10 ** (decimals - accountingContext.decimals));
            } else {
                normalizedTokens = tokensLoaned;
            }

            // If the currency matches, add the normalized amount directly.
            if (accountingContext.currency == currency) {
                borrowedAmount += normalizedTokens;
            } else {
                // Otherwise, convert via the price feed.
                // slither-disable-next-line calls-loop
                uint256 pricePerUnit = PRICES.pricePerUnitOf({
                    projectId: revnetId,
                    pricingCurrency: accountingContext.currency,
                    unitCurrency: currency,
                    decimals: decimals
                });

                // If the price feed returns zero, skip this source to avoid a division-by-zero panic
                // that would DoS all loan operations. This intentionally understates total debt for
                // the affected source — an acceptable tradeoff vs. blocking every borrow/repay.
                if (pricePerUnit == 0) continue;

                borrowedAmount += mulDiv({x: normalizedTokens, y: 10 ** decimals, denominator: pricePerUnit});
            }
        }
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Open a loan by borrowing from a revnet.
    /// @dev The caller must first grant BURN_TOKENS permission to this contract via JBPermissions.setPermissionsFor().
    /// This is required because collateral posting burns the caller's tokens through the controller.
    /// @dev Collateral tokens are permanently burned when the loan is created. They are re-minted to the borrower
    /// only upon repayment. If the loan expires (after LOAN_LIQUIDATION_DURATION), the collateral is permanently
    /// lost and cannot be recovered.
    /// @dev A delegated operator (with OPEN_LOAN permission) can set `beneficiary` to any address, directing borrowed
    /// funds away from the holder. Holders should only grant OPEN_LOAN to fully trusted operators.
    /// @param revnetId The ID of the revnet being borrowed from.
    /// @param source The source of the loan being borrowed.
    /// @param minBorrowAmount The minimum amount being borrowed, denominated in the token of the source's accounting
    /// context.
    /// @param collateralCount The amount of tokens to use as collateral for the loan.
    /// @param beneficiary The address that'll receive the borrowed funds and the tokens resulting from fee payments.
    /// @param prepaidFeePercent The fee percent that will be charged upfront from the revnet being borrowed from.
    /// Prepaying a fee is cheaper than paying later.
    /// @return loanId The ID of the loan created from borrowing.
    /// @return loan The loan created from borrowing.
    function borrowFrom(
        uint256 revnetId,
        REVLoanSource calldata source,
        uint256 minBorrowAmount,
        uint256 collateralCount,
        address payable beneficiary,
        uint256 prepaidFeePercent,
        address holder
    )
        public
        override
        returns (uint256 loanId, REVLoan memory)
    {
        // Only the holder or a permissioned operator can open a loan on the holder's behalf.
        // Note: the operator controls `beneficiary`, so they can direct borrowed funds to any address.
        _requirePermissionFrom({account: holder, projectId: revnetId, permissionId: JBPermissionIds.OPEN_LOAN});

        // A loan needs to have collateral.
        if (collateralCount == 0) revert REVLoans_ZeroCollateralLoanIsInvalid();

        // Make sure the source terminal is registered in the directory for this revnet.
        if (!DIRECTORY.isTerminalOf({projectId: revnetId, terminal: IJBTerminal(address(source.terminal))})) {
            revert REVLoans_InvalidTerminal(address(source.terminal), revnetId);
        }

        // Make sure the prepaid fee percent is between `MIN_PREPAID_FEE_PERCENT` and `MAX_PREPAID_FEE_PERCENT`. Meaning
        // an 16 year loan can be paid upfront with a
        // payment of 50% of the borrowed assets, the cheapest possible rate.
        if (prepaidFeePercent < MIN_PREPAID_FEE_PERCENT || prepaidFeePercent > MAX_PREPAID_FEE_PERCENT) {
            revert REVLoans_InvalidPrepaidFeePercent(
                prepaidFeePercent, MIN_PREPAID_FEE_PERCENT, MAX_PREPAID_FEE_PERCENT
            );
        }

        // Cache the current ruleset once — used by both _cashOutDelayOf and _borrowAmountFrom.
        JBRuleset memory currentRuleset = _currentRulesetOf(revnetId);

        // Enforce the cash out delay.
        {
            uint256 cashOutDelay = _cashOutDelayOf({revnetId: revnetId, currentRuleset: currentRuleset});
            if (cashOutDelay > block.timestamp) {
                revert REVLoans_CashOutDelayNotFinished(cashOutDelay, block.timestamp);
            }
        }

        // Prevent the loan number from exceeding the ID namespace for this revnet.
        if (totalLoansBorrowedFor[revnetId] >= _ONE_TRILLION) revert REVLoans_LoanIdOverflow();

        // Get a reference to the loan ID.
        loanId = _generateLoanId({revnetId: revnetId, loanNumber: ++totalLoansBorrowedFor[revnetId]});

        // Get a reference to the loan being created.
        REVLoan storage loan = _loanOf[loanId];

        // Set the loan's values.
        loan.source = source;
        loan.createdAt = uint48(block.timestamp);
        // forge-lint: disable-next-line(unsafe-typecast)
        loan.prepaidFeePercent = uint16(prepaidFeePercent);
        loan.prepaidDuration =
            uint32(mulDiv({x: prepaidFeePercent, y: LOAN_LIQUIDATION_DURATION, denominator: MAX_PREPAID_FEE_PERCENT}));

        // Get the amount of the loan, using the cached ruleset.
        uint256 borrowAmount = _borrowAmountFrom({
            loan: loan, revnetId: revnetId, collateralCount: collateralCount, currentRuleset: currentRuleset
        });

        // Revert if the bonding curve returns zero to prevent creating zero-amount loans.
        if (borrowAmount == 0) revert REVLoans_ZeroBorrowAmount();

        // Make sure the minimum borrow amount is met.
        if (borrowAmount < minBorrowAmount) revert REVLoans_UnderMinBorrowAmount(minBorrowAmount, borrowAmount);

        // Get the amount of additional fee to take for the revnet issuing the loan.
        // Fee rounding may leave a few wei of dust — economically insignificant relative to gas costs.
        uint256 sourceFeeAmount = JBFees.feeAmountFrom({amountBeforeFee: borrowAmount, feePercent: prepaidFeePercent});

        // Borrow the amount.
        _adjust({
            loan: loan,
            revnetId: revnetId,
            newBorrowAmount: borrowAmount,
            newCollateralCount: collateralCount,
            sourceFeeAmount: sourceFeeAmount,
            beneficiary: beneficiary,
            holder: holder
        });

        // Mint the loan NFT to the holder.
        _mint({to: holder, tokenId: loanId});

        emit Borrow({
            loanId: loanId,
            revnetId: revnetId,
            loan: loan,
            source: source,
            borrowAmount: borrowAmount,
            collateralCount: collateralCount,
            sourceFeeAmount: sourceFeeAmount,
            beneficiary: beneficiary,
            caller: _msgSender()
        });

        return (loanId, loan);
    }

    /// @notice Liquidates loans that have exceeded the 10-year liquidation duration.
    /// @dev Liquidation permanently destroys the collateral backing expired loans. Since collateral tokens were burned
    /// at deposit time (not held in escrow), there is nothing to return upon liquidation -- the collateral count is
    /// simply removed from tracking. The borrower retains whatever funds they received from the loan, but the
    /// collateral tokens that were burned to secure the loan are permanently lost.
    /// @dev This is an intentional design choice to keep the protocol simple and to incentivize timely repayment or
    /// refinancing. Borrowers have the full LOAN_LIQUIDATION_DURATION (10 years) to repay their loan and recover
    /// their collateral via re-minting.
    /// @dev Since some loans may be reallocated or paid off, loans within startingLoanId and startingLoanId + count
    /// may be skipped, so choose these parameters carefully to avoid extra gas usage.
    /// @param revnetId The ID of the revnet to liquidate loans from.
    /// @param startingLoanId The ID of the loan to start iterating from.
    /// @param count The amount of loans iterate over since the last liquidated loan.
    function liquidateExpiredLoansFrom(uint256 revnetId, uint256 startingLoanId, uint256 count) external override {
        // Prevent cross-revnet accounting corruption: loan numbers must stay within the revnet's ID namespace.
        if (startingLoanId + count > _ONE_TRILLION) revert REVLoans_LoanIdOverflow();

        // Cache the sender to avoid repeated ERC2771 context reads inside the loop.
        address sender = _msgSender();

        // Iterate over the desired number of loans to check for liquidation.
        for (uint256 i; i < count; i++) {
            // Get a reference to the next loan ID.
            uint256 loanId = _generateLoanId({revnetId: revnetId, loanNumber: startingLoanId + i});

            // Check createdAt via storage ref first to avoid loading the full struct for empty slots.
            // slither-disable-next-line incorrect-equality
            if (_loanOf[loanId].createdAt == 0) continue;

            // Get a reference to the loan being iterated on.
            REVLoan memory loan = _loanOf[loanId];

            // Keep a reference to the loan's owner.
            address owner = _ownerOf(loanId);

            // If the loan is already burned, or if it hasn't passed its liquidation duration, continue.
            if (owner == address(0) || (block.timestamp <= loan.createdAt + LOAN_LIQUIDATION_DURATION)) continue;

            // Burn the loan.
            _burn(loanId);

            // Clear stale loan data for gas refund.
            delete _loanOf[loanId];

            if (loan.collateral > 0) {
                // The collateral was burned at deposit time -- there is nothing to return. This bookkeeping
                // removal means the collateral tokens are permanently lost.
                // Decrement the total amount of collateral tokens supporting loans from this revnet.
                totalCollateralOf[revnetId] -= loan.collateral;
            }

            if (loan.amount > 0) {
                // Decrement the amount loaned.
                totalBorrowedFrom[revnetId][loan.source.terminal][loan.source.token] -= loan.amount;
            }

            emit Liquidate({loanId: loanId, revnetId: revnetId, loan: loan, caller: sender});
        }
    }

    /// @notice Refinances a loan by transferring extra collateral from an existing loan to a new loan.
    /// @dev Useful if a loan's collateral has gone up in value since the loan was created.
    /// @dev Refinancing a loan will burn the original and create two new loans.
    /// @dev This function is intentionally not payable — it only moves existing collateral between loans and does
    /// not accept new funds. Any ETH sent with the call will be rejected by the EVM.
    /// @dev A delegated operator (with REALLOCATE_LOAN permission) can set `beneficiary` to any address, directing
    /// borrowed funds from the new loan away from the loan owner. Grant this permission only to trusted operators.
    /// @param loanId The ID of the loan to reallocate collateral from.
    /// @param collateralCountToTransfer The amount of collateral to transfer from the original loan.
    /// @param source The source of the loan to create.
    /// @param minBorrowAmount The minimum amount being borrowed, denominated in the token of the source's accounting
    /// context.
    /// @param collateralCountToAdd The amount of collateral to add to the loan.
    /// @param beneficiary The address that'll receive the borrowed funds and the tokens resulting from fee payments.
    /// @param prepaidFeePercent The fee percent that will be charged upfront from the revnet being borrowed from.
    /// @return reallocatedLoanId The ID of the loan being reallocated.
    /// @return newLoanId The ID of the new loan.
    /// @return reallocatedLoan The loan being reallocated.
    /// @return newLoan The new loan created from reallocating collateral.
    function reallocateCollateralFromLoan(
        uint256 loanId,
        uint256 collateralCountToTransfer,
        REVLoanSource calldata source,
        uint256 minBorrowAmount,
        uint256 collateralCountToAdd,
        address payable beneficiary,
        uint256 prepaidFeePercent
    )
        external
        override
        returns (uint256 reallocatedLoanId, uint256 newLoanId, REVLoan memory reallocatedLoan, REVLoan memory newLoan)
    {
        // Keep a reference to the revnet ID of the loan being reallocated.
        uint256 revnetId = revnetIdOfLoanWith(loanId);

        // Only the loan owner or a permissioned operator can reallocate.
        // Note: the operator controls `beneficiary`, so they can direct new loan proceeds to any address.
        address loanOwner = _ownerOf(loanId);
        _requirePermissionFrom({account: loanOwner, projectId: revnetId, permissionId: JBPermissionIds.REALLOCATE_LOAN});

        // Make sure the loan hasn't expired.
        if (block.timestamp - _loanOf[loanId].createdAt > LOAN_LIQUIDATION_DURATION) {
            revert REVLoans_LoanExpired(block.timestamp - _loanOf[loanId].createdAt, LOAN_LIQUIDATION_DURATION);
        }

        // Make sure the new loan's source matches the existing loan's source to prevent cross-source value extraction.
        {
            REVLoanSource storage existingSource = _loanOf[loanId].source;
            if (source.token != existingSource.token || source.terminal != existingSource.terminal) {
                revert REVLoans_SourceMismatch();
            }
        }

        // Note: this function is not payable, so the EVM prevents sending ETH at the call level.

        // Refinance the loan.
        (reallocatedLoanId, reallocatedLoan) = _reallocateCollateralFromLoan({
            loanId: loanId, revnetId: revnetId, collateralCountToRemove: collateralCountToTransfer, loanOwner: loanOwner
        });

        // Make a new loan with the leftover collateral from reallocating.
        // The loan owner is the holder for the new loan (their tokens are used as collateral).
        (newLoanId, newLoan) = borrowFrom({
            revnetId: revnetId,
            source: source,
            minBorrowAmount: minBorrowAmount,
            collateralCount: collateralCountToTransfer + collateralCountToAdd,
            beneficiary: beneficiary,
            prepaidFeePercent: prepaidFeePercent,
            holder: loanOwner
        });
    }

    /// @notice Allows the owner of a loan to pay it back or receive returned collateral no longer necessary to support
    /// the loan.
    /// @dev A delegated operator (with REPAY_LOAN permission) can set `beneficiary` to any address, directing returned
    /// collateral tokens away from the loan owner. Grant this permission only to trusted operators.
    /// @param loanId The ID of the loan being adjusted.
    /// @param maxRepayBorrowAmount The maximum amount being paid off, denominated in the token of the source's
    /// accounting context.
    /// @param collateralCountToReturn The amount of collateral being returned from the loan.
    /// @param beneficiary The address receiving the returned collateral and any tokens resulting from paying fees.
    /// @param allowance An allowance to faciliate permit2 interactions.
    /// @return paidOffLoanId The ID of the loan after it's been paid off.
    /// @return paidOffloan The loan after it's been paid off.
    function repayLoan(
        uint256 loanId,
        uint256 maxRepayBorrowAmount,
        uint256 collateralCountToReturn,
        address payable beneficiary,
        JBSingleAllowance calldata allowance
    )
        external
        payable
        override
        returns (uint256 paidOffLoanId, REVLoan memory paidOffloan)
    {
        // Cache the sender to avoid repeated ERC2771 context reads.
        address sender = _msgSender();

        // Only the loan owner or a permissioned operator can repay.
        // Note: the operator controls `beneficiary`, so they can direct returned collateral to any address.
        address loanOwner = _ownerOf(loanId);
        _requirePermissionFrom({
            account: loanOwner, projectId: revnetIdOfLoanWith(loanId), permissionId: JBPermissionIds.REPAY_LOAN
        });

        // Keep a reference to the fee being iterated on.
        REVLoan storage loan = _loanOf[loanId];

        if (collateralCountToReturn > loan.collateral) {
            revert REVLoans_CollateralExceedsLoan(collateralCountToReturn, loan.collateral);
        }

        // Get a reference to the revnet ID of the loan being repaid.
        uint256 revnetId = revnetIdOfLoanWith(loanId);

        // Cache the current ruleset once for borrow amount calculation.
        JBRuleset memory currentRuleset = _currentRulesetOf(revnetId);

        // Scope to limit newBorrowAmount's stack lifetime.
        uint256 repayBorrowAmount;
        {
            // Get the new borrow amount.
            uint256 newBorrowAmount = _borrowAmountFrom({
                loan: loan,
                revnetId: revnetId,
                collateralCount: loan.collateral - collateralCountToReturn,
                currentRuleset: currentRuleset
            });

            // If the remaining collateral yields zero borrow amount, treat as full repay.
            if (newBorrowAmount == 0) {
                collateralCountToReturn = loan.collateral;
            }

            // Make sure the new borrow amount is less than the loan's amount.
            if (newBorrowAmount > loan.amount) {
                revert REVLoans_NewBorrowAmountGreaterThanLoanAmount(newBorrowAmount, loan.amount);
            }

            // Get the amount of the loan being repaid.
            repayBorrowAmount = loan.amount - newBorrowAmount;
        }

        // Revert if this repayment would do nothing — no borrow amount repaid and no collateral returned.
        // Without this check, a zero-amount repayment would burn the old loan NFT and mint a new one,
        // incrementing totalLoansBorrowedFor without limit.
        if (repayBorrowAmount == 0 && collateralCountToReturn == 0) revert REVLoans_NothingToRepay();

        // Keep a reference to the fee that'll be taken.
        uint256 sourceFeeAmount = _determineSourceFeeAmount({loan: loan, amount: repayBorrowAmount});

        // Add the fee to the repay amount.
        repayBorrowAmount += sourceFeeAmount;

        // Accept the funds that'll be used to pay off loans.
        maxRepayBorrowAmount =
            _acceptFundsFor({token: loan.source.token, amount: maxRepayBorrowAmount, allowance: allowance});

        // Make sure the minimum borrow amount is met.
        if (repayBorrowAmount > maxRepayBorrowAmount) {
            revert REVLoans_OverMaxRepayBorrowAmount(maxRepayBorrowAmount, repayBorrowAmount);
        }

        // Cache the source token before _repayLoan deletes the loan storage.
        address sourceToken = loan.source.token;

        (paidOffLoanId, paidOffloan) = _repayLoan({
            loanId: loanId,
            loan: loan,
            revnetId: revnetId,
            repayBorrowAmount: repayBorrowAmount,
            sourceFeeAmount: sourceFeeAmount,
            collateralCountToReturn: collateralCountToReturn,
            beneficiary: beneficiary,
            loanOwner: loanOwner
        });

        // If the max repay amount is greater than the repay amount, return the difference back to the payer.
        if (maxRepayBorrowAmount > repayBorrowAmount) {
            _transferFrom({
                from: address(this),
                to: payable(sender),
                token: sourceToken,
                amount: maxRepayBorrowAmount - repayBorrowAmount
            });
        }
    }

    /// @notice Sets the address of the resolver used to retrieve the tokenURI of loans.
    /// @param resolver The address of the new resolver.
    function setTokenUriResolver(IJBTokenUriResolver resolver) external override onlyOwner {
        // Store the new resolver.
        tokenUriResolver = resolver;

        emit SetTokenUriResolver({resolver: resolver, caller: _msgSender()});
    }

    //*********************************************************************//
    // --------------------- internal transactions ----------------------- //
    //*********************************************************************//

    /// @notice Accepts an incoming token.
    /// @param token The token being accepted.
    /// @param amount The number of tokens being accepted.
    /// @param allowance The permit2 context.
    /// @return amount The number of tokens which have been accepted.
    function _acceptFundsFor(
        address token,
        uint256 amount,
        JBSingleAllowance calldata allowance
    )
        internal
        returns (uint256)
    {
        // If the token is the native token, override `amount` with `msg.value`.
        if (token == JBConstants.NATIVE_TOKEN) return msg.value;

        // If the token is not native, revert if there is a non-zero `msg.value`.
        if (msg.value != 0) revert REVLoans_NoMsgValueAllowed();

        // Check if the metadata contains permit data.
        if (allowance.amount != 0) {
            // Make sure the permit allowance is enough for this payment. If not we revert early.
            if (allowance.amount < amount) {
                revert REVLoans_PermitAllowanceNotEnough(allowance.amount, amount);
            }

            // Keep a reference to the permit rules.
            IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
                details: IAllowanceTransfer.PermitDetails({
                    token: token, amount: allowance.amount, expiration: allowance.expiration, nonce: allowance.nonce
                }),
                spender: address(this),
                sigDeadline: allowance.sigDeadline
            });

            // Set the allowance to `spend` tokens for the user.
            try PERMIT2.permit({owner: _msgSender(), permitSingle: permitSingle, signature: allowance.signature}) {}
                catch (bytes memory) {}
        }

        // Get a reference to the balance before receiving tokens.
        uint256 balanceBefore = _balanceOf(token);

        // Transfer tokens to this terminal from the msg sender.
        _transferFrom({from: _msgSender(), to: payable(address(this)), token: token, amount: amount});

        // The amount should reflect the change in balance.
        return _balanceOf(token) - balanceBefore;
    }

    /// @notice Adds collateral to a loan by burning the collateral tokens permanently.
    /// @dev The collateral tokens are burned via the controller, not held in escrow. They are only re-minted if the
    /// loan is repaid. If the loan expires and is liquidated, the burned collateral is permanently lost.
    /// @param revnetId The ID of the revnet the loan is being added in.
    /// @param amount The new amount of collateral being added to the loan.
    function _addCollateralTo(uint256 revnetId, uint256 amount, address holder) internal {
        // Increment the total amount of collateral tokens.
        totalCollateralOf[revnetId] += amount;

        // Permanently burn the tokens that are tracked as collateral. These are only re-minted upon repayment.
        CONTROLLER.burnTokensOf({holder: holder, projectId: revnetId, tokenCount: amount, memo: ""});
    }

    /// @notice Add a new amount to the loan that is greater than the previous amount.
    /// @param loan The loan being added to.
    /// @param revnetId The ID of the revnet the loan is being added in.
    /// @param addedBorrowAmount The amount being added to the loan, denominated in the token of the source's
    /// accounting context.
    /// @param sourceFeeAmount The amount of the fee being taken from the revnet acting as the source of the loan.
    /// @param beneficiary The address receiving the returned collateral and any tokens resulting from paying fees.
    function _addTo(
        REVLoan memory loan,
        uint256 revnetId,
        uint256 addedBorrowAmount,
        uint256 sourceFeeAmount,
        address payable beneficiary
    )
        internal
    {
        // Register the source if this is the first time its being used for this revnet.
        // Note: Sources are only appended, never removed. Gas accumulation from iteration is bounded
        // because the number of distinct (terminal, token) pairs per revnet is practically small (~5-20).
        if (!isLoanSourceOf[revnetId][loan.source.terminal][loan.source.token]) {
            isLoanSourceOf[revnetId][loan.source.terminal][loan.source.token] = true;
            _loanSourcesOf[revnetId].push(REVLoanSource({token: loan.source.token, terminal: loan.source.terminal}));
        }

        // Increment the amount of the token borrowed from the revnet from the terminal.
        totalBorrowedFrom[revnetId][loan.source.terminal][loan.source.token] += addedBorrowAmount;

        uint256 netAmountPaidOut;
        {
            // Get a reference to the accounting context for the source.
            JBAccountingContext memory accountingContext =
                loan.source.terminal.accountingContextForTokenOf({projectId: revnetId, token: loan.source.token});

            // Pull the amount to be loaned out of the revnet. This will incure the protocol fee.
            // slither-disable-next-line unused-return
            netAmountPaidOut = loan.source.terminal
                .useAllowanceOf({
                    projectId: revnetId,
                    token: loan.source.token,
                    amount: addedBorrowAmount,
                    currency: accountingContext.currency,
                    minTokensPaidOut: 0,
                    beneficiary: payable(address(this)),
                    feeBeneficiary: beneficiary,
                    memo: ""
                });
        }

        // Keep a reference to the fee terminal.
        IJBTerminal feeTerminal = DIRECTORY.primaryTerminalOf({projectId: REV_ID, token: loan.source.token});

        // Get the amount of additional fee to take for REV.
        uint256 revFeeAmount = address(feeTerminal) == address(0)
            ? 0
            : JBFees.feeAmountFrom({amountBeforeFee: addedBorrowAmount, feePercent: REV_PREPAID_FEE_PERCENT});

        // Try to pay the REV fee. If it fails, revFeeAmount is zeroed so the borrower receives it instead.
        if (revFeeAmount > 0) {
            if (!_tryPayFee({
                    terminal: feeTerminal,
                    projectId: REV_ID,
                    token: loan.source.token,
                    amount: revFeeAmount,
                    beneficiary: beneficiary,
                    metadataProjectId: revnetId
                })) {
                revFeeAmount = 0;
            }
        }

        // Transfer the remaining balance to the borrower.
        // Note: In extreme fee configurations the subtraction could theoretically underflow, but the
        // protocol fee (2.5%) and source fee (capped at prepaidFeePercent) are both small fractions of
        // the borrowed amount, so `netAmountPaidOut` will always exceed their sum in practice.
        _transferFrom({
            from: address(this),
            to: beneficiary,
            token: loan.source.token,
            amount: netAmountPaidOut - revFeeAmount - sourceFeeAmount
        });
    }

    /// @notice Allows the owner of a loan to pay it back, add more, or receive returned collateral no longer necessary
    /// to support the loan.
    /// @dev CEI ordering note: `totalCollateralOf` is not incremented until `_addCollateralTo` executes,
    /// which happens after the external calls in `_addTo` (useAllowanceOf, fee payment, transfer). A reentrant
    /// `borrowFrom` during those calls would see a lower `totalCollateralOf`, potentially passing collateral
    /// checks that should fail. Practically infeasible — requires an adversarial pay hook on the revnet's own
    /// terminal that calls back into `borrowFrom`, which is not a realistic deployment configuration.
    /// @param loan The loan being adjusted.
    /// @param revnetId The ID of the revnet the loan is being adjusted in.
    /// @param newBorrowAmount The new amount of the loan, denominated in the token of the source's accounting
    /// context.
    /// @param newCollateralCount The new amount of collateral backing the loan.
    /// @param sourceFeeAmount The amount of the fee being taken from the revnet acting as the source of the loan.
    /// @param beneficiary The address receiving the returned collateral and any tokens resulting from paying fees.
    /// @param holder The address whose tokens are used as collateral (burned).
    function _adjust(
        REVLoan storage loan,
        uint256 revnetId,
        uint256 newBorrowAmount,
        uint256 newCollateralCount,
        uint256 sourceFeeAmount,
        address payable beneficiary,
        address holder
    )
        internal
    {
        // Cache frequently-read storage fields to avoid repeated SLOAD.
        address sourceToken = loan.source.token;
        IJBPayoutTerminal sourceTerminal = loan.source.terminal;

        // Snapshot deltas from current state before writing.
        uint256 addedBorrowAmount = newBorrowAmount > loan.amount ? newBorrowAmount - loan.amount : 0;
        uint256 repaidBorrowAmount = loan.amount > newBorrowAmount ? loan.amount - newBorrowAmount : 0;
        uint256 addedCollateralCount = newCollateralCount > loan.collateral ? newCollateralCount - loan.collateral : 0;
        uint256 returnedCollateralCount =
            loan.collateral > newCollateralCount ? loan.collateral - newCollateralCount : 0;

        // EFFECTS: Write loan state before any external calls (CEI pattern).
        // Any reentrant call will see the updated loan values, reverting on overflow.
        if (newBorrowAmount > type(uint112).max) revert REVLoans_OverflowAlert(newBorrowAmount, type(uint112).max);
        if (newCollateralCount > type(uint112).max) {
            revert REVLoans_OverflowAlert(newCollateralCount, type(uint112).max);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        loan.amount = uint112(newBorrowAmount);
        // forge-lint: disable-next-line(unsafe-typecast)
        loan.collateral = uint112(newCollateralCount);

        // INTERACTIONS: Execute external calls with pre-computed deltas.

        // Add to the loan if needed...
        if (addedBorrowAmount > 0) {
            _addTo({
                loan: loan,
                revnetId: revnetId,
                addedBorrowAmount: addedBorrowAmount,
                sourceFeeAmount: sourceFeeAmount,
                beneficiary: beneficiary
            });
            // ... or pay off the loan if needed.
        } else if (repaidBorrowAmount > 0) {
            _removeFrom({loan: loan, revnetId: revnetId, repaidBorrowAmount: repaidBorrowAmount});
        }

        // Add collateral if needed...
        if (addedCollateralCount > 0) {
            _addCollateralTo({revnetId: revnetId, amount: addedCollateralCount, holder: holder});
            // ... or return collateral if needed.
        } else if (returnedCollateralCount > 0) {
            _returnCollateralFrom({
                revnetId: revnetId, collateralCount: returnedCollateralCount, beneficiary: beneficiary
            });
        }

        // Try to pay the source fee. If it fails, transfer the amount to the beneficiary instead.
        if (sourceFeeAmount > 0) {
            if (!_tryPayFee({
                    terminal: IJBTerminal(address(sourceTerminal)),
                    projectId: revnetId,
                    token: sourceToken,
                    amount: sourceFeeAmount,
                    beneficiary: beneficiary,
                    metadataProjectId: REV_ID
                })) {
                _transferFrom({from: address(this), to: beneficiary, token: sourceToken, amount: sourceFeeAmount});
            }
        }
    }

    /// @notice Logic to be triggered before transferring tokens from this contract.
    /// @param to The address the transfer is going to.
    /// @param token The token being transferred.
    /// @param amount The number of tokens being transferred, as a fixed point number with the same number of decimals
    /// as the token specifies.
    /// @return payValue The value to attach to the transaction being sent.
    function _beforeTransferTo(address to, address token, uint256 amount) internal returns (uint256) {
        // If the token is the native token, no allowance needed.
        if (token == JBConstants.NATIVE_TOKEN) return amount;
        IERC20(token).safeIncreaseAllowance({spender: to, value: amount});
        return 0;
    }

    /// @notice Clears any token allowance granted by `_beforeTransferTo`.
    /// @param to The address that was granted the allowance.
    /// @param token The token whose allowance should be cleared.
    function _afterTransferTo(address to, address token) internal {
        if (token == JBConstants.NATIVE_TOKEN) return;
        IERC20(token).forceApprove({spender: to, value: 0});
    }

    /// @notice Reallocates collateral from a loan by making a new loan based on the original, with reduced collateral.
    /// @param loanId The ID of the loan to reallocate collateral from.
    /// @param revnetId The ID of the revnet the loan is from.
    /// @param collateralCountToRemove The amount of collateral to remove from the loan.
    /// @return reallocatedLoanId The ID of the loan.
    /// @return reallocatedLoan The reallocated loan.
    function _reallocateCollateralFromLoan(
        uint256 loanId,
        uint256 revnetId,
        uint256 collateralCountToRemove,
        address loanOwner
    )
        internal
        returns (uint256 reallocatedLoanId, REVLoan storage reallocatedLoan)
    {
        // Burn the original loan.
        _burn(loanId);

        // Keep a reference to loan having its collateral reduced.
        REVLoan storage loan = _loanOf[loanId];

        // Make sure there is enough collateral to transfer.
        if (collateralCountToRemove > loan.collateral) revert REVLoans_NotEnoughCollateral();

        // Keep a reference to the new collateral amount.
        uint256 newCollateralCount = loan.collateral - collateralCountToRemove;

        // Cache the current ruleset for borrow amount calculation.
        JBRuleset memory currentRuleset = _currentRulesetOf(revnetId);

        // Keep a reference to the new borrow amount.
        uint256 borrowAmount = _borrowAmountFrom({
            loan: loan, revnetId: revnetId, collateralCount: newCollateralCount, currentRuleset: currentRuleset
        });

        // Make sure the borrow amount is not less than the original loan's amount.
        if (borrowAmount < loan.amount) {
            revert REVLoans_ReallocatingMoreCollateralThanBorrowedAmountAllows(borrowAmount, loan.amount);
        }

        // Prevent the loan number from exceeding the ID namespace for this revnet.
        if (totalLoansBorrowedFor[revnetId] >= _ONE_TRILLION) revert REVLoans_LoanIdOverflow();

        // Get a reference to the replacement loan ID.
        reallocatedLoanId = _generateLoanId({revnetId: revnetId, loanNumber: ++totalLoansBorrowedFor[revnetId]});

        // Get a reference to the loan being created.
        reallocatedLoan = _loanOf[reallocatedLoanId];

        // Set the reallocated loan's values the same as the original loan.
        reallocatedLoan.amount = loan.amount;
        reallocatedLoan.collateral = loan.collateral;
        reallocatedLoan.createdAt = loan.createdAt;
        reallocatedLoan.prepaidFeePercent = loan.prepaidFeePercent;
        reallocatedLoan.prepaidDuration = loan.prepaidDuration;
        reallocatedLoan.source = loan.source;

        // Reduce the collateral of the reallocated loan.
        _adjust({
            loan: reallocatedLoan,
            revnetId: revnetId,
            newBorrowAmount: reallocatedLoan.amount, // Don't change the borrow amount.
            newCollateralCount: newCollateralCount,
            sourceFeeAmount: 0,
            beneficiary: payable(loanOwner), // Return collateral to the loan owner, who will have the returned
            // collateral tokens debited from their balance for the new loan.
            holder: loanOwner // Only used if collateral is added (not the case here — collateral is being returned).
        });

        // Mint the replacement loan to the loan owner.
        _mint({to: loanOwner, tokenId: reallocatedLoanId});

        // Clear stale loan data for gas refund.
        delete _loanOf[loanId];

        emit ReallocateCollateral({
            loanId: loanId,
            revnetId: revnetId,
            reallocatedLoanId: reallocatedLoanId,
            reallocatedLoan: reallocatedLoan,
            removedCollateralCount: collateralCountToRemove,
            caller: _msgSender()
        });
    }

    /// @notice Pays off a loan.
    /// @param loan The loan being paid off.
    /// @param revnetId The ID of the revnet the loan is being paid off in.
    /// @param repaidBorrowAmount The amount being paid off, denominated in the token of the source's accounting
    /// context.
    function _removeFrom(REVLoan memory loan, uint256 revnetId, uint256 repaidBorrowAmount) internal {
        // Decrement the total amount of a token being loaned out by the revnet from its terminal.
        totalBorrowedFrom[revnetId][loan.source.terminal][loan.source.token] -= repaidBorrowAmount;

        // Increase the allowance for the beneficiary.
        uint256 payValue = _beforeTransferTo({
            to: address(loan.source.terminal), token: loan.source.token, amount: repaidBorrowAmount
        });

        // Add the loaned amount back to the revnet.
        // slither-disable-next-line arbitrary-send-eth
        loan.source.terminal.addToBalanceOf{value: payValue}({
            projectId: revnetId,
            token: loan.source.token,
            amount: repaidBorrowAmount,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: bytes(abi.encodePacked(REV_ID))
        });

        _afterTransferTo({to: address(loan.source.terminal), token: loan.source.token});
    }

    /// @notice Pays down a loan.
    /// @param loanId The ID of the loan being paid down.
    /// @param loan The loan being paid down.
    /// @param repayBorrowAmount The amount being paid down from the loan, denominated in the token of the source's
    /// accounting context.
    /// @param sourceFeeAmount The amount of the fee being taken from the revnet acting as the source of the loan.
    /// @param collateralCountToReturn The amount of collateral being returned that the loan no longer requires.
    /// @param beneficiary The address receiving the returned collateral and any tokens resulting from paying fees.
    /// @param loanOwner The owner of the loan NFT (receives replacement loan if partial repay).
    // slither-disable-next-line reentrancy-eth,reentrancy-events
    function _repayLoan(
        uint256 loanId,
        REVLoan storage loan,
        uint256 revnetId,
        uint256 repayBorrowAmount,
        uint256 sourceFeeAmount,
        uint256 collateralCountToReturn,
        address payable beneficiary,
        address loanOwner
    )
        internal
        returns (uint256, REVLoan memory)
    {
        // Burn the original loan.
        _burn(loanId);

        // If the loan will carry no more amount or collateral, store its changes directly.
        // slither-disable-next-line incorrect-equality
        if (collateralCountToReturn == loan.collateral) {
            // Snapshot the loan to memory BEFORE _adjust zeroes the storage pointer.
            REVLoan memory loanSnapshot = loan;

            // Borrow in.
            _adjust({
                loan: loan,
                revnetId: revnetId,
                newBorrowAmount: 0,
                newCollateralCount: 0,
                sourceFeeAmount: sourceFeeAmount,
                beneficiary: beneficiary,
                holder: _msgSender() // Only used if collateral is added (not the case here — collateral is returned).
            });

            // Snapshot the zeroed loan for the return value (reflects post-repay state).
            REVLoan memory paidOffSnapshot = loan;

            emit RepayLoan({
                loanId: loanId,
                revnetId: revnetId,
                paidOffLoanId: loanId,
                loan: loanSnapshot,
                paidOffLoan: paidOffSnapshot,
                repayBorrowAmount: repayBorrowAmount,
                sourceFeeAmount: sourceFeeAmount,
                collateralCountToReturn: collateralCountToReturn,
                beneficiary: beneficiary,
                caller: _msgSender()
            });

            // Clear stale loan data for gas refund.
            delete _loanOf[loanId];

            return (loanId, paidOffSnapshot);
        } else {
            // Make a new loan with the remaining amount and collateral.
            // Prevent the loan number from exceeding the ID namespace for this revnet.
            if (totalLoansBorrowedFor[revnetId] >= _ONE_TRILLION) revert REVLoans_LoanIdOverflow();

            // Get a reference to the replacement loan ID.
            uint256 paidOffLoanId = _generateLoanId({revnetId: revnetId, loanNumber: ++totalLoansBorrowedFor[revnetId]});

            // Get a reference to the loan being paid off.
            REVLoan storage paidOffLoan = _loanOf[paidOffLoanId];

            // Copy the original loan's values. amount and collateral are written here so _adjust
            // can compute correct deltas, then _adjust overwrites them with the final values.
            paidOffLoan.amount = loan.amount;
            paidOffLoan.collateral = loan.collateral;
            paidOffLoan.createdAt = loan.createdAt;
            paidOffLoan.prepaidFeePercent = loan.prepaidFeePercent;
            paidOffLoan.prepaidDuration = loan.prepaidDuration;
            paidOffLoan.source = loan.source;

            // Mint the replacement loan to the loan owner FIRST so it exists before _adjust writes data.
            _mint({to: loanOwner, tokenId: paidOffLoanId});

            // Then adjust the loan data.
            _adjust({
                loan: paidOffLoan,
                revnetId: revnetId,
                newBorrowAmount: paidOffLoan.amount - (repayBorrowAmount - sourceFeeAmount),
                newCollateralCount: paidOffLoan.collateral - collateralCountToReturn,
                sourceFeeAmount: sourceFeeAmount,
                beneficiary: beneficiary,
                holder: _msgSender() // Only used if collateral is added (not the case here — collateral is returned).
            });

            emit RepayLoan({
                loanId: loanId,
                revnetId: revnetId,
                paidOffLoanId: paidOffLoanId,
                loan: loan,
                paidOffLoan: paidOffLoan,
                repayBorrowAmount: repayBorrowAmount,
                sourceFeeAmount: sourceFeeAmount,
                collateralCountToReturn: collateralCountToReturn,
                beneficiary: beneficiary,
                caller: _msgSender()
            });

            // Clear stale loan data for gas refund.
            delete _loanOf[loanId];

            return (paidOffLoanId, paidOffLoan);
        }
    }

    /// @notice Returns collateral from a loan.
    /// @param revnetId The ID of the revnet the loan is being returned in.
    /// @param collateralCount The amount of collateral being returned from the loan.
    /// @param beneficiary The address receiving the returned collateral.
    function _returnCollateralFrom(uint256 revnetId, uint256 collateralCount, address payable beneficiary) internal {
        // Decrement the total amount of collateral tokens.
        totalCollateralOf[revnetId] -= collateralCount;

        // Mint the collateral tokens back to the loan payer.
        // slither-disable-next-line unused-return,calls-loop
        CONTROLLER.mintTokensOf({
            projectId: revnetId,
            tokenCount: collateralCount,
            beneficiary: beneficiary,
            memo: "",
            useReservedPercent: false
        });
    }

    /// @notice Transfers tokens.
    /// @param from The address to transfer tokens from.
    /// @param to The address to transfer tokens to.
    /// @param token The address of the token being transfered.
    /// @param amount The amount of tokens to transfer, as a fixed point number with the same number of decimals as the
    /// token.
    function _transferFrom(address from, address payable to, address token, uint256 amount) internal virtual {
        if (from == address(this)) {
            // If the token is native token, assume the `sendValue` standard.
            if (token == JBConstants.NATIVE_TOKEN) return Address.sendValue({recipient: to, amount: amount});

            // If the transfer is from this contract, use `safeTransfer`.
            return IERC20(token).safeTransfer({to: to, value: amount});
        }

        // If there's sufficient approval, transfer normally.
        if (IERC20(token).allowance({owner: address(from), spender: address(this)}) >= amount) {
            return IERC20(token).safeTransferFrom({from: from, to: to, value: amount});
        }

        // Make sure the amount being paid is less than the maximum permit2 allowance.
        if (amount > type(uint160).max) revert REVLoans_OverflowAlert(amount, type(uint160).max);

        // Otherwise, attempt to use the `permit2` method.
        // forge-lint: disable-next-line(unsafe-typecast)
        PERMIT2.transferFrom({from: from, to: to, amount: uint160(amount), token: token});
    }

    /// @notice Attempts to pay a fee to a terminal. On failure, cleans up the ERC-20 allowance and returns false.
    /// @param terminal The terminal to pay the fee to.
    /// @param projectId The project receiving the fee.
    /// @param token The token being used to pay the fee.
    /// @param amount The fee amount.
    /// @param beneficiary The address to credit for the fee payment.
    /// @param metadataProjectId The project ID encoded in the payment metadata.
    /// @return success Whether the fee was successfully paid.
    function _tryPayFee(
        IJBTerminal terminal,
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256 metadataProjectId
    )
        internal
        returns (bool success)
    {
        uint256 payValue = _beforeTransferTo({to: address(terminal), token: token, amount: amount});

        // slither-disable-next-line arbitrary-send-eth,unused-return
        try terminal.pay{value: payValue}({
            projectId: projectId,
            token: token,
            amount: amount,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: bytes(abi.encodePacked(metadataProjectId))
        }) {
            success = true;
            _afterTransferTo({to: address(terminal), token: token});
        } catch (bytes memory) {
            if (token != JBConstants.NATIVE_TOKEN) {
                IERC20(token).safeDecreaseAllowance({spender: address(terminal), requestedDecrease: amount});
            }
        }
    }

    fallback() external payable {}
    receive() external payable {}
}
