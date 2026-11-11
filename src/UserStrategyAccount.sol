// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/IYieldAdapter.sol";
import "./libraries/BoundedTransfer.sol";
import "./DCAFactory.sol";

/// @notice Holds one user's DCA strategy: the owner's USDC, an optional yield position, and the
///         schedule on which BatchExecutor may draw one fixed contribution to buy `targetAsset`.
///         Deployed by DCAFactory as an EIP-1167 minimal proxy clone.
/// @dev All strategy parameters are set once in `initialize()` and never change. Ownership is a
///      plain stored address rather than Ownable, so the clone needs no constructor and works
///      with Initializable. The owner can always withdraw, whether or not the strategy is paused.
contract UserStrategyAccount is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error Unauthorized();
    error NotPaused();
    error AlreadyPaused();
    /// @notice `pause()` was called before the first deposit activated the strategy.
    error NotActivated();
    error ZeroAmount();
    /// @notice The first deposit is below `amountPerExecution` times the tier's minimum execution
    ///         count.
    error BelowMinimumDeposit(uint256 amount, uint256 minimum);
    /// @notice The executor requested an amount other than `amountPerExecution`.
    error WrongAmount(uint256 provided, uint256 expected);
    /// @notice The executor pulled before `nextExecutionTime`.
    error TooEarly(uint256 now_, uint256 nextExecution);
    error NonceUsed(uint256 nonce);
    /// @notice The strategy was closed by `withdraw()` and cannot take deposits or resume.
    error StrategyClosed();
    /// @notice The yield adapter did not take exactly `amount` USDC on deposit.
    error YieldDepositNotPulled(uint256 amount, uint256 moved);
    /// @notice The yield position grew by less than `amount` minus the withdrawal tolerance.
    error YieldDepositShortfall(uint256 amount, uint256 credited);
    /// @notice Reading the yield position reverted, hit an address with no code, or returned
    ///         anything other than one word.
    error VenueUnreadable();
    error WrongOutputAsset(address asset);
    /// @notice `withdrawPending` was called for USDC, which only `withdraw()` pays out.
    error PrincipalNotRecoverable();

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Why a strategy is paused: it could not fund an execution, or its owner paused it.
    enum PauseReason { InsufficientBalance, ManualPause }

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 private constant SECONDS_PER_DAY    = 86400;
    uint256 private constant SECONDS_PER_WEEK   = 7 * SECONDS_PER_DAY;
    uint256 private constant SECONDS_PER_BIWEEK = 14 * SECONDS_PER_DAY;
    // Monday 5 January 1970 00:00 UTC, the first Monday after the Unix epoch. Weekly and
    // bi-weekly windows are aligned to it.
    uint256 private constant REF_MONDAY = 4 * SECONDS_PER_DAY;
    uint256 private constant _BPS = 10_000;

    /// @notice Gas forwarded to the output token's `transfer` in `receiveOutput`.
    ///         Measured on Base: WETH about 30k, cbBTC about 45k.
    uint256 public constant OUTPUT_TRANSFER_GAS = 100_000;
    /// @notice Gas `receiveOutput` keeps back from the token call to record a pending fallback.
    uint256 public constant OUTPUT_FALLBACK_GAS = 50_000;

    // -------------------------------------------------------------------------
    // Strategy parameters - set once in initialize(), never changed
    // -------------------------------------------------------------------------

    /// @notice The strategy owner: the only address that can deposit, pause, resume and withdraw,
    ///         and the recipient of every purchase.
    address public owner;
    /// @notice The asset this strategy buys. Never USDC.
    address public targetAsset;
    /// @notice USDC drawn per execution, in USDC base units.
    uint256 public amountPerExecution;
    DCAFactory.Tier public tier;
    /// @notice Whether deposited USDC is held in the yield venue rather than idle in this account.
    bool public yieldEnabled;
    /// @notice The yield adapter this account supplies to. Used only when `yieldEnabled` is true.
    IYieldAdapter public yieldAdapter;
    /// @notice The only address allowed to pull contributions and deliver purchased output.
    address public batchExecutor;
    /// @notice The factory that created this account. Source of fee rates, the treasury and the
    ///         active-strategy registry.
    DCAFactory public factory;
    IERC20 public usdc;

    // -------------------------------------------------------------------------
    // Mutable state
    // -------------------------------------------------------------------------

    /// @notice USDC held idle in this account and tracked by its accounting, in base units.
    ///         Excludes the yield position and any tokens sent here directly.
    uint256 public balance;
    /// @notice Principal book: USDC deposited and not yet spent on purchases, in base units.
    ///         Yield is whatever the account can reach above this figure.
    uint256 public depositedAmount;
    /// @notice Earliest timestamp at which the next pull is allowed. Zero until the first deposit.
    uint256 public nextExecutionTime;

    /// @notice True while the strategy does not execute. Pausing also tries to remove it from the
    ///         active registry; a failed removal is swallowed, so a paused strategy can remain
    ///         registered, and `authorisedPull` still skips it on this flag.
    bool public paused;
    /// @notice Why the strategy was last paused. Meaningful only while `paused` is true.
    PauseReason public pauseReason;
    // Set by the first deposit. Cleared only when `withdraw()` deregisters successfully.
    bool private _registered;
    /// @notice True after `withdraw()`. Terminal: a closed strategy cannot take deposits, resume
    ///         or execute.
    bool public closed;

    mapping(uint256 => bool) public usedNonces;
    /// @notice Output, by asset, that `receiveOutput` could not deliver to the owner. A non-zero
    ///         entry lets the owner claim it with `withdrawPending`.
    mapping(address => uint256) public pendingWithdrawals;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice The owner deposited `amount` USDC. `account` is this contract.
    event Deposited(address indexed account, uint256 amount);
    /// @notice The strategy closed and paid `amount` USDC to the owner, net of any yield fee.
    event Withdrawn(address indexed account, uint256 amount);
    /// @notice The strategy paused. Its removal from the active registry was attempted, and a
    ///         failed removal does not stop the pause.
    event Paused(address indexed account, PauseReason reason);
    /// @notice The strategy resumed and rejoined the active registry.
    event Resumed(address indexed account);
    /// @notice One contribution of `amount` USDC was sent to BatchExecutor under batch `nonce`.
    event Executed(address indexed account, uint256 amount, uint256 nonce);
    /// @notice The yield venue refused to release `amount` from a position that covers it. The
    ///         execution was skipped; `nextExecutionTime` does not advance, so the strategy stays
    ///         due and can be retried in a later batch.
    event YieldFailure(address indexed account, address indexed adapter, uint256 amount, uint256 timestamp);
    event OutputReceived(address indexed asset, uint256 amount, address indexed recipient);
    /// @notice Delivery to the owner failed, and `amount` was recorded in `pendingWithdrawals`.
    event OutputPending(address indexed asset, uint256 amount, address indexed owner);
    event PendingWithdrawn(address indexed asset, uint256 amount);
    /// @notice Yield realized by this transition and the fee charged on it.
    /// @param realizedYield The yield actually spent or paid out here - `min(untaxed, drawn)` on the
    ///        executor path, the whole settled residual at `withdraw()`. NOT the untaxed pool: when
    ///        more yield has accrued than one execution can consume, only the consumed part is
    ///        reported, because only that part was charged.
    /// @param fee The fee charged, in USDC base units.
    event YieldFeeCharged(address indexed account, uint256 realizedYield, uint256 fee);

    /// @dev Disables initializers on the implementation contract so only clones can be
    ///      initialized. Each clone has its own storage and is initialized by DCAFactory.
    constructor() {
        _disableInitializers();
    }

    /// @notice One-time setup of all strategy parameters. Called by DCAFactory on a new clone.
    /// @dev Replaces the constructor for the minimal-proxy pattern and can run exactly once. No
    ///      parameter changes afterwards. `_owner` is the address that called
    ///      `DCAFactory.createStrategy`, not a value that caller supplies. The factory initializes
    ///      the clone in the same transaction that creates it and marks it as a strategy only after
    ///      this succeeds, so an independently deployed clone is not a recognized strategy.
    ///      `nextExecutionTime` stays zero until the first deposit.
    /// @param _amountPerExecution USDC per execution, in base units.
    /// @param _tier `DCAFactory.Tier` as its integer value.
    /// @param _factory The creating DCAFactory, which also supplies the USDC address.
    function initialize(
        address _owner,
        address _targetAsset,
        uint256 _amountPerExecution,
        uint8   _tier,
        bool    _yieldEnabled,
        address _yieldAdapter,
        address _batchExecutor,
        address _factory
    ) external initializer {
        owner              = _owner;
        targetAsset        = _targetAsset;
        amountPerExecution = _amountPerExecution;
        tier               = DCAFactory.Tier(_tier);
        yieldEnabled       = _yieldEnabled;
        yieldAdapter       = IYieldAdapter(_yieldAdapter);
        batchExecutor      = _batchExecutor;
        factory            = DCAFactory(_factory);
        usdc               = IERC20(DCAFactory(_factory).usdc());
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyBatchExecutor() {
        if (msg.sender != batchExecutor) revert Unauthorized();
        _;
    }

    /// @notice Deposits USDC into the strategy. The first deposit activates it: it must cover the
    ///         tier's minimum number of executions, it sets the first execution window, and it
    ///         registers the strategy with the factory. A deposit never resumes a paused strategy;
    ///         only `resume()` does.
    /// @dev Owner-only. Only the owner can withdraw, so a deposit into someone else's strategy
    ///      would hand that USDC over irreversibly; rejecting it removes the mistake at no cost.
    ///      Reverts `StrategyClosed` after `withdraw()`, `ZeroAmount` for zero, `BelowMinimumDeposit`
    ///      for an undersized first deposit, and `YieldDepositNotPulled` or `YieldDepositShortfall`
    ///      when the yield venue does not take and credit the deposit in full.
    /// @param amount USDC to deposit, in base units. Pulled from the caller, who must first approve
    ///        this account for it.
    // Reentrancy is blocked by nonReentrant. The one cross-function read is `pause()` reading
    // `_registered`, and it is not reachable: a reentrant caller during `yieldAdapter.deposit` is
    // the ADAPTER, and `pause()` is onlyOwner, so it reverts Unauthorized before reading anything.
    // Even granting owner-controlled reentry, both cases are benign: on first activation
    // `_registered` is false, so `pause()` reverts NotActivated, and on a top-up it is already true,
    // so pausing is the ordinary owner action it looks like. `_registered = true` must therefore
    // STAY after the adapter call: written early, it would let a reentrant `pause()` succeed on an
    // account not yet in the registry, and this deposit would then register it while paused.
    // slither-disable-next-line reentrancy-no-eth
    function deposit(uint256 amount) external onlyOwner nonReentrant {
        // `withdraw()` is terminal: a closed strategy can never be reactivated or re-registered.
        if (closed) revert StrategyClosed();
        if (amount == 0) revert ZeroAmount();

        if (!_registered) {
            uint256 minimum = amountPerExecution * factory.minExecutions(tier);
            if (amount < minimum) revert BelowMinimumDeposit(amount, minimum);
        }

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        depositedAmount += amount;

        if (yieldEnabled) {
            // Read both sides BEFORE handing over, so what follows is a measurement of this call
            // rather than a reading of absolute state. `usdcBefore` is taken after the transferFrom
            // above, so it already includes `amount`; the position is generally non-zero here,
            // because a strategy can be topped up and interest accrues between deposits.
            uint256 usdcBefore = usdc.balanceOf(address(this));
            uint256 positionBefore = yieldAdapter.balanceOf(address(this));

            usdc.forceApprove(address(yieldAdapter), amount);
            yieldAdapter.deposit(amount);

            _assertDepositLanded(amount, usdcBefore, positionBefore);
        } else {
            balance += amount;
        }

        if (!_registered) {
            _registered = true;
            nextExecutionTime = _nextAnchor(block.timestamp);
            factory.registerStrategy(address(this));
        }

        emit Deposited(address(this), amount);
    }

    /// @dev Checks the yield adapter's deposit against this account's OWN readings, rather than
    ///      trusting the adapter to have checked it. The withdrawal paths work the same way: they
    ///      credit the base-token delta this account observes across the venue call, not the
    ///      number the adapter returns.
    ///
    ///      Two halves, because either alone admits a way to lose the deposit:
    ///
    ///      - **Pull.** A yield-enabled deposit does NOT credit `balance`, so USDC the adapter fails
    ///        to take is tracked by neither `balance` nor the position, and `withdraw()` - which
    ///        pays out `balance` plus `withdrawAll()` - cannot reach it. `withdrawPending` is not a
    ///        second route either: it never pays out USDC. So an unpulled unit would be stranded
    ///        permanently, and this check makes that impossible rather than merely unlikely.
    ///      - **Credit.** Pulling in full while reporting no position is the same loss with an extra
    ///        step, and it would also leave the strategy invisible to `_canFundOneExecution`
    ///        forever, with no revert and no event.
    ///
    ///      The pull half is exact, not toleranced. `forceApprove` set the allowance to exactly
    ///      `amount` immediately before the call, so `moved` can never exceed it, and an ERC-20
    ///      transfer of the base token does not round. Requiring equality therefore also settles the
    ///      residual allowance without a second SSTORE to zero it: on success the whole allowance
    ///      was spent, and on failure the revert unwinds the approval with everything else.
    ///      A fee-on-transfer base token would break that equality, but it would already have broken
    ///      `depositedAmount` at the transferFrom in `deposit`, and the factory's base token is fixed
    ///      at deployment.
    ///
    ///      The credit half is a lower bound, because Aave V3 can report a position up to
    ///      `YIELD_WITHDRAWAL_TOLERANCE` below the amount supplied, through rounding. An exact rule
    ///      would reject a correctly behaving Aave V3 adapter.
    ///
    ///      Reverting is right here and would be wrong in `authorisedPull`. This is the owner's own
    ///      transaction: nothing has been committed that a revert cannot unwind, the owner learns
    ///      immediately, and no funds move. `authorisedPull` pauses instead: BatchExecutor catches a
    ///      reverting pull and only skips the account, which would then stay registered and due and
    ///      fail again in every later batch.
    function _assertDepositLanded(uint256 amount, uint256 usdcBefore, uint256 positionBefore) internal view {
        uint256 usdcAfter = usdc.balanceOf(address(this));
        // Clamped so an adapter that PUSHES base tokens back into this account reports zero moved
        // and hits the named revert, rather than panicking on an underflow.
        uint256 moved = usdcBefore > usdcAfter ? usdcBefore - usdcAfter : 0;
        if (moved != amount) revert YieldDepositNotPulled(amount, moved);

        uint256 positionAfter = yieldAdapter.balanceOf(address(this));
        uint256 credited = positionAfter > positionBefore ? positionAfter - positionBefore : 0;
        if (credited + YIELD_WITHDRAWAL_TOLERANCE < amount) revert YieldDepositShortfall(amount, credited);
    }

    // -------------------------------------------------------------------------
    // Yield-fee quote - the single source both authorisedPull and the funded
    // predicate read, so the decision and the prediction cannot drift
    // -------------------------------------------------------------------------

    /// @dev Saturating add. `venue` is an untrusted adapter report, and a well-formed
    ///      `type(uint256).max` would otherwise revert this path on overflow before the fee cap in
    ///      `_quoteYieldFee` can bound anything. Protects THIS addition only: `amountPerExecution`
    ///      is bounded at creation (DCAFactory.MAX_AMOUNT_PER_EXECUTION), which is what makes the
    ///      rest of the fee arithmetic total.
    function _satAdd(uint256 x, uint256 y) private pure returns (uint256 z) {
        unchecked { z = x + y; if (z < x) z = type(uint256).max; }
    }

    /// @dev Untaxed yield: everything the account can reach above its principal book.
    ///
    ///      Scope is `balance + venue`, deliberately the same scope as `depositedAmount`, which is a
    ///      book over ALL base tokens this account holds rather than over the venue position alone.
    ///      Narrowing it to the venue would misread idle base tokens as yield.
    ///
    ///      It must NOT read `usdc.balanceOf(address(this))`: anyone can transfer base tokens
    ///      straight to an account, and counting that as yield would let a third party grief the
    ///      owner into a fee on a gift. `balance` is the tracked field, which only a measured
    ///      inflow moves.
    function _untaxedYield(uint256 venue) internal view returns (uint256) {
        uint256 reachable = _satAdd(balance, venue);
        return reachable > depositedAmount ? reachable - depositedAmount : 0;
    }

    /// @dev Fee on the yield ONE execution of `amount` would realize, grossed up.
    ///
    ///      The fee is drawn from the venue ON TOP of `amount`, so the yield actually leaving is
    ///      `amount + fee`, not `amount`. Solving `fee = b * (amount + fee)` gives
    ///      `fee = amount * b / (10000 - b)`, which is the cap: at `b = 1500` it is 17.65% of
    ///      `amount`, i.e. exactly 15% of what left. Below the cap the whole untaxed pool is
    ///      realized and the plain `untaxed * b / 10000` applies.
    ///
    ///      That cap is also the blast radius of a lying venue. `IYieldAdapter.balanceOf` cannot be
    ///      verified on chain, and this bound is what keeps an over-report from charging more than
    ///      one execution's worth however large the lie.
    ///
    ///      `mulDiv` rather than `*` then `/`: it carries the intermediate in 512 bits, so neither
    ///      product can overflow whatever the adapter reported. `MAX_YIELD_FEE_BPS` is 3000, so the
    ///      `_BPS - b` denominator is at least 7000 and never zero.
    function _quoteYieldFee(uint256 untaxed, uint256 amount) internal view returns (uint256) {
        // `untaxed` first: it is a local, and the common path has no yield to charge. Reading the
        // rate before it would spend an external call on every no-yield execution.
        //
        // Slither flags this as a dangerous strict equality. It is not one: the detector is about
        // comparing a BALANCE against an exact value, where a donation makes the equality
        // unreachable. `untaxed` is a local computed two lines earlier in the caller, and this is a
        // guard that skips work when there is none to do.
        // slither-disable-next-line incorrect-equality
        if (untaxed == 0) return 0;
        uint256 b = factory.yieldFeeBps();
        if (b == 0) return 0;
        uint256 cap = amount.mulDiv(b, _BPS - b);
        // `untaxed >= amount + cap`, written without the addition. Equivalent for every uint256:
        // where `amount + cap` would overflow, the original is false for any `untaxed`, and so is
        // this. `amount` is bounded at creation, so the addition is in fact safe - the form is kept
        // because `untaxed` is adapter-derived and the comparison should not depend on that bound.
        if (untaxed >= amount && untaxed - amount >= cap) return cap;
        return untaxed.mulDiv(b, _BPS);
    }

    // -------------------------------------------------------------------------
    // Execution - called by BatchExecutor
    // -------------------------------------------------------------------------

    /// @notice Sends one contribution of `amountPerExecution` USDC, plus the yield fee it realizes,
    ///         to BatchExecutor in a single transfer, and advances `nextExecutionTime`. Only
    ///         BatchExecutor may call it.
    /// @dev Returns (0, 0) and moves nothing when the strategy is paused or closed. Returns (0, 0)
    ///      and pauses the strategy when its funding source cannot cover the complete draw, the
    ///      contribution plus any yield fee. Returns (0, 0) and pauses, keeping what arrived in
    ///      `balance`, when the venue's withdrawal succeeds but delivers more than
    ///      `YIELD_WITHDRAWAL_TOLERANCE` less than the draw. Returns (0, 0) without pausing,
    ///      emitting `YieldFailure`, when the yield position covers the draw but the venue's
    ///      withdrawal reverts. Reverts `TooEarly` before `nextExecutionTime`, `WrongAmount` unless
    ///      `amount` equals `amountPerExecution`, `NonceUsed` on a nonce this account already
    ///      served, and `VenueUnreadable` when the yield position cannot be read, which
    ///      BatchExecutor records as a skipped account.
    ///
    ///      `pulled` can be up to `YIELD_WITHDRAWAL_TOLERANCE` below `amount` when the funding
    ///      source is short by no more than that. A venue shortfall is taken from the fee before it
    ///      reaches the contribution.
    /// @param amount Requested contribution; must equal `amountPerExecution`.
    /// @param nonce Batch nonce, recorded so this account serves each nonce at most once.
    /// @return pulled USDC contribution sent, in base units. Only this sizes the account's share.
    /// @return yieldFee USDC yield fee sent in the same transfer, in base units.
    // Reentrancy is blocked by nonReentrant, which every entry point that moves tokens or changes
    // `balance` or `depositedAmount` carries.
    // slither-disable-next-line reentrancy-no-eth
    function authorisedPull(uint256 amount, uint256 nonce)
        external
        onlyBatchExecutor
        nonReentrant
        returns (uint256 pulled, uint256 yieldFee)
    {
        // Stopped accounts are excluded from batches by `DCAFactory.getDueAccounts` and by
        // BatchExecutor's registry check, but may still be submitted in edge cases (a batch built
        // before a pause or withdrawal lands after it). Return 0 = skip, leaving this account's own
        // `usedNonces[nonce]` slot unwritten and moving no tokens.
        //
        // That is the ACCOUNT-local replay slot, not the batch nonce. BatchExecutor.executeBatch
        // marks the batch nonce used before it pulls from anyone, so the batch nonce is consumed
        // either way - including when every entry is skipped and the call emits BatchEmpty.
        // Skipping here means this account wrote no state, not that the batch nonce can be reused.
        //
        // `closed` is checked explicitly rather than relying on withdraw() having zeroed `balance`,
        // which would route a closed strategy through the insufficient-balance path, pausing and
        // emitting. A closed strategy is terminal and is simply skipped.
        if (paused || closed) return (0, 0);

        if (block.timestamp < nextExecutionTime) revert TooEarly(block.timestamp, nextExecutionTime);
        if (amount != amountPerExecution) revert WrongAmount(amount, amountPerExecution);
        if (usedNonces[nonce]) revert NonceUsed(nonce);

        usedNonces[nonce] = true;

        // Both survive the venue call: `untaxed` is the pool the fee was quoted against and is what
        // the principal transition below is measured relative to, and `quoted` is the ceiling the
        // settled fee may not exceed.
        //
        // Written `= 0` explicitly, though Solidity zeroes them either way. The yield-disabled path
        // never enters the block below and settles against both, so the zero is behavior that
        // path relies on - no fee and the whole contribution counted as principal - not an unused
        // initial value.
        uint256 untaxed = 0;
        uint256 quoted = 0;

        // With yield enabled, withdraw the draw from the venue and credit the base-token amount this
        // account actually OBSERVES arriving, measured as the delta of its own `usdc.balanceOf`, not
        // the number the adapter reports. The report cannot be verified, and an over-reporting venue
        // would otherwise credit `balance` with USDC that never arrived. A conforming adapter may fall
        // up to YIELD_WITHDRAWAL_TOLERANCE short on rounding.
        if (yieldEnabled) {
            // The draw is `amount + fee`, so the yield funding this execution is charged as it
            // leaves rather than at close, where it would already have been spent on purchases.
            uint256 venue = _readVenueStrict();
            uint256 draw;
            (draw, untaxed, quoted) = _executionDraw(venue);

            // A position that cannot cover the complete draw is a finished strategy, not a
            // venue incident, and it pauses here exactly as an empty yield-off account does below.
            // Classified before the venue call, so no guaranteed-failing withdrawal is made and every
            // revert the catch below still sees comes from a position that reported enough.
            if (!_covers(venue, draw)) {
                _autoPause();
                return (0, 0);
            }

            uint256 usdcBefore = usdc.balanceOf(address(this));
            // The adapter's return is deliberately ignored: the credited amount is the measured
            // base-token delta below, not the venue's self-report.
            // slither-disable-next-line unused-return
            try yieldAdapter.withdraw(draw) returns (uint256) {
                // Measured delta, not the adapter's return. Clamped so a venue that pushes nothing (or
                // pulls) reports zero moved and hits the shortfall path rather than underflowing.
                uint256 usdcAfter = usdc.balanceOf(address(this));
                uint256 received = usdcAfter > usdcBefore ? usdcAfter - usdcBefore : 0;
                // Credit first: the delta has already landed here, so it must be accounted for even
                // when the shortfall turns out to be material.
                balance += received;
                // Validate the measured delta rather than only the resulting balance. Any idle balance
                // sitting in this account is excluded by the before/after subtraction, so it can no
                // longer absorb - and hide - an adapter shortfall larger than the tolerance. A
                // conforming adapter reverts before returning short, so reaching this is an
                // adapter-conformance failure. Pause instead of reverting: a revert would unwind
                // the withdrawal, BatchExecutor would skip the account, and the account would stay
                // registered and due and fail the same way in every later batch. Pausing stops it
                // once and keeps what arrived in `balance`, withdrawable by the owner.
                //
                // Shortfall form rather than `received + TOLERANCE < draw`: `received` is bounded
                // only by the base token's real supply, not by anything this contract enforces, and
                // this is the same comparison `_canFundOneExecution` writes.
                uint256 requiredDraw =
                    draw > YIELD_WITHDRAWAL_TOLERANCE ? draw - YIELD_WITHDRAWAL_TOLERANCE : 0;
                if (received < requiredDraw) {
                    _autoPause();
                    return (0, 0);
                }
            } catch {
                // The position covered the draw, so this is the venue refusing: paused, frozen or
                // short of liquidity. The contract cannot tell a temporary refusal from a permanent
                // one, so it skips and stays due for a later batch rather than pausing and making
                // every owner resume after one venue outage. `nextExecutionTime` does not advance
                // and this account's nonce slot stays used.
                emit YieldFailure(address(this), address(yieldAdapter), draw, block.timestamp);
                return (0, 0);
            }
        }

        // Insufficient balance: pause and leave the registry. A rounding shortfall within the
        // tolerance must NOT pause - it would otherwise stall the strategy on every routine venue
        // withdrawal.
        //
        // Equivalent to `_covers(balance, amount)` here: the two differ only when
        // `amountPerExecution <= YIELD_WITHDRAWAL_TOLERANCE`, which DCAFactory's floor on
        // `minAmountPerExecution` excludes.
        uint256 requiredContribution =
            amount > YIELD_WITHDRAWAL_TOLERANCE ? amount - YIELD_WITHDRAWAL_TOLERANCE : 0;
        if (balance < requiredContribution) {
            _autoPause();
            return (0, 0);
        }

        // Settle from what ACTUALLY arrived, never from the planned draw. The contribution has
        // priority, so a tolerated venue shortfall is borne by the fee first and only reaches the
        // purchase once the fee is exhausted - which is why `pulled` is not always `amount`.
        //
        // A pre-existing idle `balance` participates here even though it does not establish venue
        // fundability: once the venue has answered, settlement draws on everything tracked.
        pulled   = balance < amount ? balance : amount;
        balance -= pulled;
        yieldFee = balance < quoted ? balance : quoted;
        balance -= yieldFee;

        // `drawn`, not `amount + quoted`. Decrementing the book by the PLANNED draw while only the
        // measured amount arrived would push `depositedAmount` too far down, inflating every future
        // `_untaxedYield` and systematically over-charging the owner.
        uint256 drawn         = pulled + yieldFee;
        uint256 realizedYield = drawn < untaxed ? drawn : untaxed;
        uint256 principalPart = drawn > untaxed ? drawn - untaxed : 0;
        depositedAmount = depositedAmount > principalPart ? depositedAmount - principalPart : 0;

        nextExecutionTime = _nextAnchor(block.timestamp);

        // One transfer for both. BatchExecutor keeps them apart: only `pulled` sizes the swap, the
        // oracle floor and the pro-rata shares.
        usdc.safeTransfer(batchExecutor, drawn);
        emit Executed(address(this), pulled, nonce);
        if (yieldFee > 0) emit YieldFeeCharged(address(this), realizedYield, yieldFee);
    }

    // -------------------------------------------------------------------------
    // Output delivery - called by BatchExecutor after the swap
    // -------------------------------------------------------------------------

    /// @notice Receives this account's share of a batch's purchased asset and forwards it to the
    ///         owner. Only BatchExecutor may call it. Falls back to `pendingWithdrawals` if the
    ///         delivery reverts, returns false, or returns a non-standard value, so a single failed
    ///         delivery cannot revert the whole batch. Reverts with
    ///         `BoundedTransfer.InsufficientOutputGas` when the caller leaves too little gas to give
    ///         the token its full `OUTPUT_TRANSFER_GAS` allowance and still record a fallback.
    /// @dev `BoundedTransfer` bounds both the token's gas and the returndata copied, because a
    ///      revert here would revert the whole batch. A malformed return is a failed delivery;
    ///      `withdrawPending` then pays the account's real balance, so recording a pending amount
    ///      for a token that did move its own way is harmless.
    ///
    ///      Reverts `WrongOutputAsset` for any asset other than `targetAsset`, whichever executor is
    ///      bound. `DCAFactory.setBatchExecutor` accepts any address for future clones, so the
    ///      account must not rely on its executor to name the right asset: a pending record over
    ///      USDC would let `withdrawPending` pay out tracked principal.
    /// @param asset The purchased token; must equal `targetAsset`.
    /// @param amount Output in the token's base units, already transferred to this account. Zero is
    ///        a no-op.
    function receiveOutput(address asset, uint256 amount)
        external
        onlyBatchExecutor
        nonReentrant
    {
        if (asset != targetAsset) revert WrongOutputAsset(asset);
        if (amount == 0) return;

        address recipient = owner;
        if (BoundedTransfer.tryTransfer(asset, recipient, amount, OUTPUT_TRANSFER_GAS, OUTPUT_FALLBACK_GAS)) {
            emit OutputReceived(asset, amount, recipient);
            return;
        }

        pendingWithdrawals[asset] += amount;
        emit OutputPending(asset, amount, owner);
    }

    /// @notice Recovers output tokens that a failed direct delivery left in this account. Owner
    ///         only. Reverts `PrincipalNotRecoverable` for USDC, and does nothing when no delivery
    ///         of `asset` has failed.
    /// @dev Gated on a non-zero `pendingWithdrawals[asset]` record, then transfers the account's
    ///      ACTUAL current balance rather than the recorded amount.
    ///
    ///      The record can exceed the real balance: a fee-on-transfer or downward-rebasing output
    ///      asset, or an executor that transfers and reports different amounts, all make them
    ///      diverge. Transferring the recorded amount would revert and strand tokens the account
    ///      really holds, with no other way out.
    ///
    ///      The record is an authorization gate and a frontend signal, never a separately funded
    ///      liability. It must not be reduced to a bare `balanceOf` sweep: this account holds live
    ///      USDC, and an ungated sweep would move it without decrementing `balance` or
    ///      `depositedAmount`, corrupting accounting and bypassing the terminal `withdraw()` path.
    ///
    ///      Transferring the full balance (not `min(recorded, balance)`) is safe because only
    ///      `receiveOutput` can create a record and it accepts only `targetAsset`, whichever executor
    ///      is bound. So a recorded asset is this strategy's single output asset, and any balance of
    ///      it belongs to the owner.
    ///
    ///      That argument needs the output asset never to be USDC, or a record over USDC would pay
    ///      out tracked principal alongside the output. `DCAFactory.createStrategy` rejects
    ///      `targetAsset == usdc`, and this function also refuses USDC itself with
    ///      `PrincipalNotRecoverable`, so the guarantee does not rest on the factory alone.
    function withdrawPending(address asset) external onlyOwner nonReentrant {
        if (asset == address(usdc)) revert PrincipalNotRecoverable();
        if (pendingWithdrawals[asset] == 0) return;

        uint256 amount = IERC20(asset).balanceOf(address(this));

        // Clear before the external call. A reverting safeTransfer reverts the whole
        // transaction and restores the record, so recovery stays retriable.
        pendingWithdrawals[asset] = 0;

        // Skip a pointless zero-value transfer; no security property rests on this equality.
        // The detector fires because `amount` is balance-derived, and a third party can move it
        // off zero by donating. Doing so only makes the claim send that donation to the owner,
        // which is the intended semantics: recovery pays out the account's real balance.
        // slither-disable-next-line incorrect-equality
        if (amount == 0) return;

        IERC20(asset).safeTransfer(owner, amount);
        emit PendingWithdrawn(asset, amount);
    }

    /// @notice Withdraws everything and closes the strategy permanently. Owner only, and available
    ///         whether or not the strategy is paused. With yield enabled, redeems the whole yield
    ///         position and sends the treasury the yield fee on any yield not yet charged; the
    ///         owner receives the rest. Undelivered output is not included: it stays claimable
    ///         through `withdrawPending`.
    /// @dev Also removes the strategy from the factory's registry. A failed removal does not block
    ///      the exit; `_registered` then stays set, recording that the removal is still owed.
    // Reentrancy is blocked by nonReentrant, which every entry point that moves tokens or changes
    // `balance` or `depositedAmount` carries.
    // slither-disable-next-line reentrancy-no-eth
    function withdraw() external onlyOwner nonReentrant {
        uint256 total = balance;

        if (yieldEnabled) {
            // Use the base-token delta this account observes across the call, not the adapter's
            // reported figure. An over-reporting venue would otherwise inflate `total` past what
            // actually landed, so the payout transfer below would revert and permanently brick the
            // only USDC exit. Measuring the delta keeps `total` equal to real holdings, so it pays out.
            uint256 usdcBefore = usdc.balanceOf(address(this));
            // The adapter's return is deliberately ignored: `received` below is the measured
            // base-token delta, not the venue's self-report.
            // slither-disable-next-line unused-return
            yieldAdapter.withdrawAll();
            uint256 usdcAfter = usdc.balanceOf(address(this));
            uint256 received = usdcAfter > usdcBefore ? usdcAfter - usdcBefore : 0;

            // `total + received`, not `received` alone. The fee base is everything the account can
            // reach against its book, and idle `balance` is inside that book. Reading only the venue
            // return would understate it whenever an adapter-conformance failure left base tokens
            // sitting here. No guard is needed on the addition: `total == balance <= usdcBefore`,
            // because the tracked field only ever moves on a measured inflow, so the sum is at most
            // `usdcAfter`.
            uint256 reachable = total + received;

            // The terminal realization: whatever is left above the book is charged once, here. On a
            // strategy that executed, most of it was already charged as it was spent, so this is
            // the residual rather than the whole lifetime yield.
            uint256 realizedYield = reachable > depositedAmount ? reachable - depositedAmount : 0;
            uint256 fee = realizedYield.mulDiv(factory.yieldFeeBps(), _BPS);

            // `fee <= realizedYield <= reachable` by construction, so the subtraction below cannot
            // underflow and the fee is always payable.
            if (fee > 0) {
                usdc.safeTransfer(factory.treasury(), fee);
                emit YieldFeeCharged(address(this), realizedYield, fee);
            }
            total = reachable - fee;
        }

        depositedAmount = 0;
        balance = 0;

        // Terminal: no later deposit or resume can re-register this (possibly paused) strategy
        // into the active registry.
        closed = true;

        // Remove from registry (whether paused or active)
        if (_registered) {
            // Clear `_registered` only when the removal actually lands. The failure is swallowed so
            // it cannot block the exit, and it can be forced - an owner can starve the call of gas
            // (EIP-150). Clearing the flag anyway would destroy the only record that deregistration
            // is still owed, leaving a closed entry in the registry that a later `pause()` could no
            // longer retry.
            try factory.removeStrategy(address(this)) {
                _registered = false;
            } catch {}
        }

        if (total > 0) {
            usdc.safeTransfer(owner, total);
        }

        emit Withdrawn(address(this), total);
    }

    // -------------------------------------------------------------------------
    // Pause / Resume
    // -------------------------------------------------------------------------

    /// @notice Manually pauses the strategy and removes it from the active registry. Owner only;
    ///         funds stay withdrawable. Reverts `NotActivated` before the first deposit and
    ///         `AlreadyPaused` when already paused.
    /// @dev Requires activation. A strategy that never took a deposit was never in the registry,
    ///      so there is nothing for `pause()` to remove - but letting it reach `paused` would let
    ///      `resume()` register an account the first deposit never activated, and `withdraw()` then
    ///      skip `removeStrategy` because `_registered` is still false, stranding a closed strategy
    ///      in the registry with no automatic or third-party removal path.
    ///
    ///      This one guard is what makes registry membership imply `_registered`: `deposit()` sets
    ///      the flag before registering, and `resume()` requires `paused`, which requires the flag
    ///      (`_autoPause` keeps the same rule). That implication is what makes `withdraw()`'s
    ///      `if (_registered)` deregistration correct by construction rather than by accident.
    function pause() external onlyOwner {
        if (!_registered) revert NotActivated();
        if (paused) revert AlreadyPaused();
        _manualPause();
    }

    /// @notice Resumes a paused strategy and re-registers it. Owner only. The next execution
    ///         window is the first anchor after now, not the one missed while paused. Reverts
    ///         `StrategyClosed` after `withdraw()` and `NotPaused` unless paused. Does not check
    ///         funding: an underfunded strategy is paused again when a due pull or
    ///         `reconcileFunding` finds it cannot fund its next draw.
    function resume() external onlyOwner {
        // `withdraw()` is terminal: a closed strategy can never re-enter the active registry,
        // including through resume() after a pause-then-withdraw sequence.
        if (closed) revert StrategyClosed();
        if (!paused) revert NotPaused();
        paused = false;
        nextExecutionTime = _nextAnchor(block.timestamp);
        factory.registerStrategy(address(this));
        emit Resumed(address(this));
    }

    /// @notice Pauses a due strategy that cannot fund its complete next execution.
    /// @dev A keeper that selects through `isDueAndFunded` never submits an underfunded strategy, so
    ///      it never reaches the insufficient-balance pause in `authorisedPull` and would otherwise
    ///      stay registered and due forever. This is that same transition without an execution: no
    ///      tokens move, no nonce is consumed and `nextExecutionTime` is left alone.
    ///
    ///      Callable by the owner or by the CURRENT executor of this account's BatchExecutor, read
    ///      live so an executor rotation takes effect here at once. Not permissionless: a strategy is
    ///      due before the keeper's scheduled run, and venue accrual in between can carry a strategy
    ///      at the boundary back over it. A third party could also pause it just ahead of the
    ///      owner's top-up. The executor gains nothing it lacked: submitting the account to a batch
    ///      reaches the same pause.
    ///
    ///      Returns false and emits nothing when there is no transition to make: never registered,
    ///      already paused, closed, not yet due, or funded. Reverts `Unauthorized` for any other
    ///      caller and `VenueUnreadable` when a yield venue cannot be read, so an incident is never
    ///      taken for depletion.
    /// @return pausedNow True when this call paused the strategy.
    function reconcileFunding() external nonReentrant returns (bool pausedNow) {
        if (msg.sender != owner && msg.sender != IExecutorRole(batchExecutor).executor()) {
            revert Unauthorized();
        }
        if (!_registered || paused || closed || block.timestamp < nextExecutionTime) return false;
        if (_coversNextExecution()) return false;
        _autoPause();
        return true;
    }

    // -------------------------------------------------------------------------
    // Due views - read by the DCAFactory registry queries
    // -------------------------------------------------------------------------

    /// @notice Returns true if this strategy is active, matches `_tier`, and is due at `windowStart`.
    /// @dev Read by DCAFactory.getDueAccounts to build batches off-chain.
    ///      Deliberately says nothing about funding - it is the raw timing view, so monitoring can
    ///      still see a strategy that stays due but unfunded.
    ///
    ///      `closed` IS checked, unlike funding. `withdraw()` sets `closed` without setting
    ///      `paused`, so the timing half alone answers `true` forever on a terminated strategy. The
    ///      normal lifecycle hides that: `withdraw()` also deregisters, and the intended caller
    ///      reaches this through the registry. But that deregistration is a `try/catch` whose
    ///      failure is deliberately swallowed, so a closed account CAN remain registered - and then
    ///      `getDueAccounts` reports it as due and monitoring alarms on a strategy that terminated
    ///      normally. Execution is not at risk either way: `authorisedPull` checks `closed` itself,
    ///      and that is the security boundary. This is consistency and defense in depth.
    function isDue(uint8 _tier, uint256 windowStart) external view returns (bool) {
        return !paused
            && !closed
            && DCAFactory.Tier(_tier) == tier
            && windowStart >= nextExecutionTime;
    }

    /// @notice `isDue`, narrowed to strategies that can currently fund their complete next draw -
    ///         the contribution plus any yield fee - within the withdrawal tolerance. NOT "one full
    ///         `amountPerExecution`": at `amountPerExecution - YIELD_WITHDRAWAL_TOLERANCE` this is
    ///         true and the pull goes through short, so a rounding shortfall does not stall the
    ///         strategy. Answers false, rather than reverting, when the yield venue cannot be read.
    /// @dev Read by DCAFactory.getDueFundedAccounts. The funding half lives here rather than in the
    ///      factory because `authorisedPull` lives here: the predicate has to mirror the decision
    ///      that function actually makes, and splitting the two across contracts is how they drift.
    ///
    ///      Only the funding half is added on top of `isDue`: both views reject `closed`.
    ///
    ///      This is an off-chain convenience, NOT a security boundary. Funding can change between
    ///      this call and the batch, so the executor must revalidate and BatchExecutor must stay
    ///      tolerant of a pull that returns zero.
    function isDueAndFunded(uint8 _tier, uint256 windowStart) external view returns (bool) {
        if (paused || closed) return false;
        if (DCAFactory.Tier(_tier) != tier) return false;
        if (windowStart < nextExecutionTime) return false;
        return _canFundOneExecution();
    }

    /// @dev The fail-soft twin of `_coversNextExecution`: the same source, draw and threshold, but an
    ///      unreadable venue answers false instead of reverting.
    ///
    ///      The two funding sources are NOT the same. With yield off, the pull draws on idle
    ///      `balance`. With yield on, it asks the venue for the WHOLE draw and idle USDC cannot top up
    ///      a short answer, so summing idle and venue balances would report fundable strategies that
    ///      cannot execute.
    ///
    ///      Fail-soft because a reverting, code-less or malformed adapter must not revert the caller's
    ///      whole page. It cannot bound an adapter that burns all the gas it is given; which adapters
    ///      the factory approves is the control there. A false here is NOT evidence of underfunding:
    ///      the paths that pause read the venue strictly instead.
    function _canFundOneExecution() internal view returns (bool) {
        if (!yieldEnabled) return _covers(balance, amountPerExecution);
        (bool ok, uint256 venue) = _tryReadVenue();
        if (!ok) return false;
        (uint256 draw,,) = _executionDraw(venue);
        return _covers(venue, draw);
    }

    /// @dev Whether the funding source covers the complete next draw. Reverts `VenueUnreadable` when a
    ///      yield venue cannot be read, so no caller that pauses on `false` can mistake an incident for
    ///      depletion.
    function _coversNextExecution() internal view returns (bool) {
        if (!yieldEnabled) return _covers(balance, amountPerExecution);
        uint256 venue = _readVenueStrict();
        (uint256 draw,,) = _executionDraw(venue);
        return _covers(venue, draw);
    }

    /// @dev The one funding threshold: `available` covers `requested` within the withdrawal
    ///      tolerance. NOT "the full `requested`": at `requested - YIELD_WITHDRAWAL_TOLERANCE` this
    ///      is true and the pull goes through short, so routine venue rounding does not stall a
    ///      strategy.
    ///
    ///      Stated as a shortfall rather than `available + TOLERANCE >= requested`, because
    ///      `available` may be an untrusted adapter report and type(uint256).max would overflow the
    ///      addition. The two forms agree everywhere the addition does not overflow.
    ///
    ///      `available > 0` matters only at or below the tolerance, where the clamp makes the
    ///      requirement zero. Without it an empty strategy would count as funded. That is not a
    ///      harmless over-report: the yield-off pull gate in `authorisedPull` clears in that
    ///      configuration, transfers `min(balance, amount) == 0` and ADVANCES the execution window,
    ///      so the funded view would hand the keeper a strategy whose only effect is to lose its
    ///      owner a window in silence. That zero-pull advance needs
    ///      `amountPerExecution <= YIELD_WITHDRAWAL_TOLERANCE`, which DCAFactory makes unreachable:
    ///      `createStrategy` requires at least `minAmountPerExecution`, and
    ///      `setMinAmountPerExecution` cannot set it below `YIELD_WITHDRAWAL_TOLERANCE + 1`. Above
    ///      the tolerance, `available >= requested - TOLERANCE` already implies `available > 0`, so
    ///      the guard keeps the function correct on its own rather than relying on that floor.
    function _covers(uint256 available, uint256 requested) internal pure returns (bool) {
        uint256 required =
            requested > YIELD_WITHDRAWAL_TOLERANCE ? requested - YIELD_WITHDRAWAL_TOLERANCE : 0;
        return available > 0 && available >= required;
    }

    /// @dev The complete draw one execution asks the venue for: the contribution plus the yield fee it
    ///      realizes. Also returns the two quote inputs `authorisedPull` settles against. The
    ///      single source for the pull, the funded view and reconciliation, so the decision and its
    ///      predictions cannot drift.
    function _executionDraw(uint256 venue)
        internal
        view
        returns (uint256 draw, uint256 untaxed, uint256 quoted)
    {
        untaxed = _untaxedYield(venue);
        quoted  = _quoteYieldFee(untaxed, amountPerExecution);
        draw    = amountPerExecution + quoted;
    }

    /// @dev Reads the venue position without letting the adapter revert the caller. `ok` is false for
    ///      a revert, missing code or anything but exactly one word of returndata.
    function _tryReadVenue() internal view returns (bool ok, uint256 venue) {
        bytes memory data;
        (ok, data) = address(yieldAdapter).staticcall(
            abi.encodeWithSelector(IYieldAdapter.balanceOf.selector, address(this))
        );
        if (!ok || data.length != 32) return (false, 0);
        venue = abi.decode(data, (uint256));
    }

    /// @dev `_tryReadVenue`, reverting `VenueUnreadable` where it would answer false. Built on the same
    ///      low-level read so the strict and fail-soft paths accept exactly the same answers.
    function _readVenueStrict() internal view returns (uint256 venue) {
        bool ok;
        (ok, venue) = _tryReadVenue();
        if (!ok) revert VenueUnreadable();
    }

    // -------------------------------------------------------------------------
    // Internal: pause helpers
    // -------------------------------------------------------------------------

    /// @dev Pauses with `InsufficientBalance` and removes the strategy from the registry. A failed
    ///      removal is swallowed, so the executor path never reverts on it.
    function _autoPause() internal {
        // Never move a never-activated account to `paused`. A never-registered account was never in
        // the registry, so there is nothing to remove - but letting it reach `paused == true` would
        // be a second route into the state `pause()` refuses: `resume()` then registers an account
        // the first deposit never activated, and `withdraw()` skips deregistration because
        // `_registered` is still false, stranding a closed strategy in the registry with no
        // automatic, third-party, or governance removal path.
        //
        // Skip rather than revert. This is the executor path: BatchExecutor isolates each pull in
        // try/catch, but an executor that does not would have its whole batch reverted by one
        // entry. Skipping makes `authorisedPull` return 0 (an ordinary skip) under ANY executor, so
        // the guarantee is the account's own and does not rest on BatchExecutor's registry filter
        // or its try/catch; `DCAFactory.setBatchExecutor` can repoint future accounts elsewhere. A
        // genuinely underfunded account is always `_registered`, so the ordinary auto-pause is
        // unaffected.
        if (!_registered) return;
        paused = true;
        pauseReason = PauseReason.InsufficientBalance;
        try factory.removeStrategy(address(this)) {} catch {}
        emit Paused(address(this), PauseReason.InsufficientBalance);
    }

    function _manualPause() internal {
        paused = true;
        pauseReason = PauseReason.ManualPause;
        try factory.removeStrategy(address(this)) {} catch {}
        emit Paused(address(this), PauseReason.ManualPause);
    }

    // -------------------------------------------------------------------------
    // Internal: execution window anchoring
    // -------------------------------------------------------------------------

    /// @dev Returns the first execution anchor strictly after `ts` for this strategy's tier, in UTC:
    ///      the next midnight (Daily), the next Monday-aligned 7- or 14-day boundary counted from
    ///      `REF_MONDAY` (Weekly, BiWeekly), or 00:00 on the first day of the next month (Monthly).
    ///      Every strategy of a tier shares the same anchors, so due strategies batch together.
    function _nextAnchor(uint256 ts) internal view returns (uint256) {
        DCAFactory.Tier t = tier;
        if (t == DCAFactory.Tier.Daily) {
            return _ceilToDay(ts);
        } else if (t == DCAFactory.Tier.Weekly) {
            return _ceilToPeriod(ts, SECONDS_PER_WEEK, REF_MONDAY);
        } else if (t == DCAFactory.Tier.BiWeekly) {
            return _ceilToPeriod(ts, SECONDS_PER_BIWEEK, REF_MONDAY);
        } else {
            return _nextMonthStart(ts);
        }
    }

    // Calendar arithmetic, not randomness: `%` and `== 0` here are exact date arithmetic.
    // slither-disable-next-line weak-prng,incorrect-equality
    function _ceilToDay(uint256 ts) internal pure returns (uint256) {
        uint256 remainder = ts % SECONDS_PER_DAY;
        return remainder == 0 ? ts + SECONDS_PER_DAY : ts - remainder + SECONDS_PER_DAY;
    }

    // Calendar arithmetic, not randomness: `%` here is exact period arithmetic.
    // slither-disable-next-line weak-prng
    function _ceilToPeriod(uint256 ts, uint256 period, uint256 refEpoch) internal pure returns (uint256) {
        if (ts < refEpoch) return refEpoch;
        uint256 elapsed = ts - refEpoch;
        uint256 remainder = elapsed % period;
        // Always advance to the NEXT period boundary (never return current timestamp)
        return ts - remainder + period;
    }

    /// @dev Returns 00:00 UTC on the first day of the calendar month after the one containing `ts`.
    ///      Converts days to a proleptic Gregorian date and back with Howard Hinnant's
    ///      `civil_from_days` / `days_from_civil` algorithms.
    // Gregorian calendar arithmetic, not randomness or financial math: `%`, `/`, `*` and `==` here
    // are exact integer date operations, and the divide-before-multiply order is the algorithm's.
    // slither-disable-next-line weak-prng,divide-before-multiply,incorrect-equality
    function _nextMonthStart(uint256 ts) internal pure returns (uint256) {
        // Days since the epoch to year and month.
        uint256 z = ts / SECONDS_PER_DAY + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 m = mp < 10 ? mp + 3 : mp - 9;
        if (m <= 2) y++;

        // Advance to next month
        if (m == 12) { m = 1; y++; }
        else { m++; }

        // Year, month and day 1 back to days since the epoch.
        if (m <= 2) { y--; }
        uint256 mp2 = m > 2 ? m - 3 : m + 9;
        uint256 yoe2 = y % 400;
        uint256 era2 = y / 400;
        uint256 doy2 = (153 * mp2 + 2) / 5;
        uint256 doe2 = yoe2 * 365 + yoe2 / 4 - yoe2 / 100 + doy2;
        uint256 days2 = era2 * 146097 + doe2 - 719468;
        return days2 * SECONDS_PER_DAY;
    }
}

/// @dev The one BatchExecutor read `reconcileFunding` needs, declared here so the account does not
///      depend on the executor's source.
interface IExecutorRole {
    function executor() external view returns (address);
}
