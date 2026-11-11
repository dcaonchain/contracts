// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// `YIELD_WITHDRAWAL_TOLERANCE` is the maximum shortfall, in base-token units, that a conforming
// yield adapter may leave against an amount it was handed or asked for: below the requested
// withdrawal amount on the way out, and below the deposited amount in the position it reports on
// the way in. Despite "withdrawal" in its name, it is the venue's single rounding tolerance and
// bounds deposits as well as withdrawals. `MAX_YIELD_WITHDRAWAL_TOLERANCE` is the ceiling it must
// not exceed, which DCAFactory checks at construction.
//
// Solidity interfaces cannot declare constants, so both live at file level and are imported by both
// sides of the postcondition: the adapter enforces the tolerance, and UserStrategyAccount
// independently checks the outcome on both paths.
//
// Two units are the smallest tolerance compatible with Base aUSDC (aToken revision 5). That revision
// mints floor(amount * RAY / liquidityIndex) scaled units and reports
// floor(scaled * liquidityIndex / RAY). For an integer amount A and index I, the composition credits
// at least A - ceil(I / RAY): the first floor loses less than one scaled unit, worth I / RAY base
// units, and the second floor loses less than one more base unit. While I <= 2 * RAY, the integer
// shortfall is therefore at most two. The Base aUSDC index is well below 2 * RAY; the approved venue
// and this bound must be reviewed again before it approaches that value.
//
// Both are compile-time constants, so this is a fixed compatibility requirement: a venue that needs
// a larger tolerance is incompatible with this factory.
//
// Ten base units is the policy ceiling. It is deliberately much wider than the proven two-unit Base
// bound, but still too small to weaken any economically meaningful execution. It can only be raised
// in source, by redeploying a mutually compatible set of contracts.
uint256 constant MAX_YIELD_WITHDRAWAL_TOLERANCE = 10;

// The tolerance is economically negligible and correctly accounted for, but it is not guaranteed
// recoverable. If the entire receipt-token balance is already `amount - 2`, the adapter withdraws
// all of it and nothing remains to sweep at close. Treat it as a realized rounding loss, not
// deferred dust.
uint256 constant YIELD_WITHDRAWAL_TOLERANCE = 2;

/// @notice Yield venue interface implemented by per-strategy adapter clones.
/// @dev One adapter instance per UserStrategyAccount; all calls are restricted to the owning account.
///
///      Postconditions every venue implementation must satisfy:
///      - Position isolation: an instance's position is reachable only through that instance, and
///        `withdraw`/`withdrawAll` can never touch another strategy's position.
///      - Denomination: every amount in and out is denominated in the factory's single base token.
///        A factory's approved implementation set is homogeneous in base token, which is what keeps
///        venue selection invisible to the batch layer.
///      - Authorization: `deposit` pulls only from the bound account; `withdraw`/`withdrawAll` send
///        only to it.
///      - Bounded deposit: `deposit(amount)` moves exactly `amount` of the base token out of the
///        bound account AND raises the position it reports for that account by at least
///        `amount - YIELD_WITHDRAWAL_TOLERANCE`, or reverts. Both halves are required: pulling
///        without crediting is indistinguishable from theft, and crediting without pulling leaves
///        base tokens in the account that `withdraw()` cannot reach.
///      - Bounded shortfall: `withdraw(amount)` returns `received >= amount - YIELD_WITHDRAWAL_TOLERANCE`
///        or reverts. Rounding may consume the tolerance; insufficient venue liquidity must revert
///        rather than silently return less.
///      - Faithful withdrawal transfer: `withdraw` and `withdrawAll` must transfer to the bound
///        account at least as many base tokens as they return; a venue may never report more than it
///        actually moves. `withdrawAll` returns the full position it holds and is bounded below the
///        same way. `UserStrategyAccount` credits the base-token delta it measures across the call,
///        not the reported figure, so an over-report cannot inflate the account's book; the rule is
///        stated here so a venue author is told it rather than left to infer it.
interface IYieldAdapter {
    /// @notice Deposits `amount` of the base token into the yield venue.
    /// @dev Caller must have approved the adapter for `amount` beforehand.
    ///
    ///      Postcondition (the "bounded deposit" rule above): this call must consume the whole
    ///      `amount` from the caller and leave the position it reports for the caller at least
    ///      `amount - YIELD_WITHDRAWAL_TOLERANCE` higher, or revert. An implementation that pulls
    ///      nothing, pulls part, or pulls in full and credits nothing satisfies neither half.
    ///
    ///      `UserStrategyAccount.deposit` measures both halves itself, from its own base-token
    ///      balance and from `balanceOf`, rather than trusting this implementation to have checked
    ///      - the same shape `authorisedPull` uses on the withdrawal side. Enforcing it here is
    ///      still required: it names the failure at the venue, where a venue author can act on it.
    ///
    ///      Reverting is the only conforming failure mode. There is no partial-deposit outcome to
    ///      report, because the account has no way to represent one.
    /// @param amount Amount of base token to deposit.
    function deposit(uint256 amount) external;

    /// @notice Withdraws `amount` of the base token back to the calling account.
    /// @dev Reverts if the venue returns less than `amount - YIELD_WITHDRAWAL_TOLERANCE`. Must
    ///      transfer at least `received` to the account (faithful-transfer rule above): the account
    ///      credits the base-token delta it measures, not this return value.
    /// @param amount Amount of base token to withdraw.
    /// @return received Actual amount of base token returned to the account.
    function withdraw(uint256 amount) external returns (uint256 received);

    /// @notice Withdraws the full position (principal + accrued yield) back to the calling account.
    /// @dev Must transfer at least `received` to the account (faithful-transfer rule above): the
    ///      account credits the base-token delta it measures, not this return value.
    /// @return received Total amount of base token returned to the account.
    function withdrawAll() external returns (uint256 received);

    /// @notice Returns the current position value (principal + accrued yield) for `account`.
    /// @dev Two obligations beyond "report a number", because `UserStrategyAccount.isDueAndFunded`
    ///      and the off-chain keeper decide whether to execute a strategy from this value alone.
    ///
    ///      **The value must be what the bound position can actually supply**, in both directions.
    ///      It must include every base-token unit that position can supply, and exclude any it
    ///      cannot, venue liquidity permitting. Both halves are needed: the exclusion half alone is
    ///      satisfied by a constant zero. Under-reporting is the dangerous half: an adapter that
    ///      reports conservatively, omits a component of a multi-part position, or answers for the
    ///      wrong position is silently excluded from every batch forever, with no revert and no event
    ///      anywhere. Over-reporting is bounded rather than caught. If the real position cannot cover
    ///      the inflated draw, the venue withdrawal reverts or comes back short, and the account
    ///      skips that execution with `YieldFailure` or pauses. If it can, the execution goes
    ///      through, and `UserStrategyAccount._quoteYieldFee` caps the yield fee charged on the
    ///      phantom yield at one execution's worth per execution.
    ///
    ///      **It must answer for the position `withdraw` would draw on**, which for a per-strategy
    ///      clone is the clone's own position. The `account` parameter is redundant under the clone
    ///      model, where each instance serves one account: `AaveV3YieldAdapter` ignores it. An
    ///      implementation that honors it must still return the same value the bound account's
    ///      `withdraw` would source from.
    ///
    ///      Neither obligation is checkable on-chain in general, so both are reviewed before
    ///      governance approves an implementation. One partial check exists: the bounded-deposit rule
    ///      above, enforced by both the adapter and the account, gives this function a checked floor
    ///      at deposit time - under-reporting by more than the tolerance reverts the deposit instead
    ///      of silently excluding the strategy from every batch. Nothing checks it thereafter.
    ///
    ///      What this interface cannot express at all is *withdrawability*: this is an ownership
    ///      figure, so a venue holding the position but lacking free liquidity reports funded and
    ///      reverts the withdrawal. That strategy is selected for a batch, its pull fails, and it is
    ///      skipped for that execution with a `YieldFailure` event while the rest of the batch
    ///      proceeds.
    /// @param account Account whose position is queried.
    /// @return Position value denominated in the base token.
    function balanceOf(address account) external view returns (uint256);
}

/// @notice The clone lifecycle DCAFactory drives on an approved yield-adapter implementation.
/// @dev An approved implementation is cloned per strategy (EIP-1167) and bound to that strategy's
///      account exactly once. Market addresses are implementation immutables shared by every clone;
///      only `account` lives in clone storage. An uninitialized clone must fail closed.
interface IYieldAdapterImplementation is IYieldAdapter {
    /// @notice Binds a freshly cloned adapter to the account that may operate it. Callable once.
    /// @param strategyAccount The UserStrategyAccount this clone serves.
    function initialize(address strategyAccount) external;

    /// @notice The account this instance is bound to, or `address(0)` on an uninitialized clone.
    function account() external view returns (address);

    /// @notice The base token this venue accepts and returns. Must equal the factory's base token.
    function baseToken() external view returns (address);
}
