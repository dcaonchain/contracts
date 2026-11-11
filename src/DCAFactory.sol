// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "./interfaces/IYieldAdapter.sol";

/// @notice Deploys UserStrategyAccount minimal proxies (EIP-1167), permanently records which
///         accounts it deployed, maintains the separate registry of active strategies, and stores
///         protocol-wide configuration: fee rates, approved yield-adapter implementations and
///         creation minimums.
/// @dev Pausing blocks new strategy creation only. Withdrawal from an existing account is never
///      paused. `owner` is intended to be a TimelockController, so every owner-gated setter below is
///      delayed and publicly queued, while `guardian` holds only the instant pause and unpause.
contract DCAFactory is Ownable2Step, Pausable, ReentrancyGuard {

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ZeroAddress();
    error AdapterNotApproved(address implementation);
    error AdapterHasNoCode(address implementation);
    error StrategyImplementationHasNoCode(address implementation);
    /// @notice The strategy implementation's codehash differs from the one pinned at construction.
    error StrategyImplementationCodehashMismatch(address implementation, bytes32 pinned, bytes32 actual);
    /// @notice The yield-adapter implementation's codehash differs from the one pinned at approval.
    error AdapterCodehashMismatch(address implementation, bytes32 approved, bytes32 actual);
    /// @notice The yield adapter, or its implementation, reports a base token other than USDC.
    error AdapterBaseTokenMismatch(address adapter, address baseToken);
    /// @notice A new adapter clone reports a bound account other than the strategy just created.
    error AdapterAccountMismatch(address adapter, address expected, address actual);
    error FeeTooHigh(uint256 provided, uint256 max);
    /// @notice The compiled-in yield withdrawal tolerance exceeds its ceiling. Checked at
    ///         construction, so an inconsistent build cannot be deployed.
    error YieldWithdrawalToleranceTooHigh(uint256 provided, uint256 max);
    error AmountTooLow(uint256 provided, uint256 min);
    error AmountTooHigh(uint256 provided, uint256 max);
    /// @notice A strategy cannot buy USDC, the input asset.
    error TargetAssetIsUsdc();
    /// @notice BatchExecutor does not list the target asset, so the strategy could never execute.
    error TargetAssetNotWhitelisted(address asset);
    /// @notice The caller is not a factory-deployed account acting for itself.
    error NotAStrategy();
    /// @notice The new strategy account's `initialize` call reverted.
    error InitFailed();
    error NotGuardian();
    error ZeroLimit();

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Execution cadence of a strategy.
    enum Tier { Daily, Weekly, BiWeekly, Monthly }

    /// @notice Strategy configuration passed to `createStrategy`. Fixed for the account's lifetime.
    /// @dev There is no owner field: the owner is always the `createStrategy` caller. There is no
    ///      destination field: purchased assets are delivered to the owner. There is no referrer
    ///      field: the protocol pays no referral share and stores no publicly resolvable
    ///      attribution. Attribution travels separately as the blinded `referralCommitment` argument
    ///      to `createStrategy`, which this contract emits and does not otherwise interpret. There is
    ///      no separate yield flag: yield is enabled exactly when `yieldAdapterImplementation` is
    ///      non-zero, so a contradictory pair cannot be submitted.
    struct StrategyParams {
        /// @dev Asset bought on each execution. Must be listed by BatchExecutor and must not be USDC.
        address targetAsset;
        /// @dev USDC base units (6 decimals) spent per execution.
        uint256 amountPerExecution;
        Tier tier;
        /// @dev address(0) disables yield. A non-zero value must be an approved implementation and
        ///      is the exact venue bytecode the caller signed for. There is deliberately no
        ///      "address(0) means the current default" rule, which would let an admin substitute the
        ///      venue between signing and execution.
        address yieldAdapterImplementation;
    }

    // -------------------------------------------------------------------------
    // Fee constants (hard caps enforced on setters)
    // -------------------------------------------------------------------------

    uint256 public constant MAX_EXECUTION_FEE_BPS = 100;   // 1%
    uint256 public constant MAX_YIELD_FEE_BPS     = 3000;  // 30%

    // Floors the owner setters cannot go below, so no later owner call can make a creation
    // minimum vacuous. An amount per execution must exceed the amount a yield venue may fall short
    // on withdrawal, so every pull moves value.
    uint256 private constant MIN_AMOUNT_PER_EXECUTION = YIELD_WITHDRAWAL_TOLERANCE + 1;
    uint256 private constant MIN_EXECUTIONS_PER_TIER = 1;

    /// @notice Upper bound on `amountPerExecution`, enforced at creation and on the minimum setter.
    /// @dev An arithmetic-safety bound rather than an economic one, and deliberately not
    ///      configurable. It is what keeps per-execution fee arithmetic over `amountPerExecution`
    ///      provably free of overflow without a runtime guard at every site: a fee derived as
    ///      `amount * bps / (10000 - bps)` is strictly below `amount`, so the fee, the venue draw
    ///      `amount + fee`, and every intermediate stay below `2**129` while this bound holds and
    ///      `yieldFeeBps <= MAX_YIELD_FEE_BPS`.
    ///
    ///      Making it governable would add storage, a setter, an event and another timelocked way to
    ///      invalidate that proof, in exchange for flexibility nothing needs: the bound is roughly
    ///      3.4e38 base units against a USDC total supply near 1e16, so no reachable strategy can
    ///      touch it.
    uint256 public constant MAX_AMOUNT_PER_EXECUTION = type(uint128).max;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice UserStrategyAccount implementation that every account is cloned from.
    address public immutable strategyImplementation;
    /// @notice `strategyImplementation`'s codehash at construction, revalidated before every clone.
    /// @dev Guards against code loss and metamorphic replacement for FUTURE accounts only. Existing
    ///      clones delegate to whatever code is at the address, so source review of the
    ///      implementation remains the control that it has no destructive path.
    bytes32 public immutable strategyImplementationCodehash;
    /// @notice USDC on this chain: the deposit currency and the base token of every yield adapter.
    address public immutable usdc;
    /// @notice BatchExecutor that new strategies are bound to at creation.
    address public batchExecutor;
    /// @notice Receives execution and yield fees. Separate from `owner`.
    address public treasury;

    /// @notice Minimum `amountPerExecution` accepted by `createStrategy`, in USDC base units
    ///         (6 decimals).
    uint256 public minAmountPerExecution = 5_000_000; // 5 USDC default

    /// @notice Execution fee rate in basis points, read by BatchExecutor on every batch.
    uint256 public executionFeeBps  = 15;   // 0.15%
    /// @notice Share of realized yield taken as the yield fee, in basis points.
    uint256 public yieldFeeBps      = 1500; // 15%

    /// @notice Minimum number of executions the first deposit must fund, per tier. An account's
    ///         first deposit must be at least `amountPerExecution * minExecutions[tier]`.
    mapping(Tier => uint256) public minExecutions;

    /// @notice Codehash recorded when each yield-adapter implementation was approved. Zero means
    ///         not approved.
    /// @dev Storing the codehash rather than a boolean guarantees the implementation bytecode a
    ///      clone delegates to is the bytecode reviewed at approval, and catches a metamorphic
    ///      redeploy at the same address. Clone bytecode itself is the fixed EIP-1167 stub, so it is
    ///      the delegate target that matters. It does NOT detect a proxy upgrade behind stable proxy
    ///      bytecode, and does NOT protect existing clones if implementation code later changes -
    ///      source review and deployment verification remain the real control.
    mapping(address => bytes32) public approvedYieldAdapterCodehash;

    /// @notice Holds the instant emergency stop while `owner` is a timelock.
    /// @dev Can pause and unpause creation, and nothing else. Every economic and routing setter
    ///      stays owner-gated and therefore delayed. Rotating the guardian is owner-gated too.
    address public guardian;

    // Strategy provenance and the active registry are two independent concepts, deliberately not
    // one flag:
    //   - provenance (`isDeployedByFactory`) answers "did THIS factory deploy this address". Set
    //     once at creation and never cleared, because resume() has to be able to re-register a
    //     paused account, and a closed account must stay recognizable.
    //   - active membership (`isActiveStrategy`) answers "is this account in the batch registry
    //     right now". Derived from `_strategyIndex` rather than stored as a second boolean, so the
    //     fact is not copied. Index and array are still two structures: their correspondence comes
    //     from the swap-with-last-and-pop in `_removeFromRegistry`, not from the derivation alone.
    // Membership implies provenance (registerStrategy requires it); the converse does not hold, so a
    // caller that wants "safe to call AND expected in this batch" must check both.
    address[] private _activeStrategies;
    mapping(address => uint256) private _strategyIndex; // strategy => 1-based index in _activeStrategies
    /// @notice True for every account this factory deployed. Set at creation and never cleared,
    ///         including after the account is paused or closed.
    mapping(address => bool) public isDeployedByFactory;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @dev Carries both the venue implementation and the per-strategy clone so indexers can label
    ///      a strategy's venue without a follow-up call. Both are address(0) when yield is disabled.
    /// @param referralCommitment Opaque, emitted for off-chain attribution and never used on chain.
    ///        See the NatSpec on `createStrategy` for what it is and what it is not.
    event StrategyCreated(
        address indexed account,
        address indexed owner,
        address indexed targetAsset,
        uint256 amountPerExecution,
        Tier tier,
        address yieldAdapterImplementation,
        address yieldAdapter,
        bytes32 referralCommitment
    );
    /// @notice Emitted on every successful `registerStrategy`, including a call for an account that
    ///         is already active.
    event StrategyRegistered(address indexed account);
    /// @notice Emitted on every successful `removeStrategy`, including a call for an account that
    ///         is already inactive.
    event StrategyRemoved(address indexed account);
    /// @notice Emitted on each `setBatchExecutor` call. Not emitted for the constructor value.
    event BatchExecutorSet(address indexed batchExecutor);
    /// @notice Emitted on each `setTreasury` call. Not emitted for the constructor value.
    event TreasurySet(address indexed treasury);
    /// @notice Emitted on each approval or revocation. `codehash` is the pinned value, or zero on
    ///         revocation.
    event YieldAdapterImplementationSet(address indexed implementation, bool approved, bytes32 codehash);
    /// @notice Emitted on each `setFees` call with the new rates, in basis points.
    event FeesUpdated(uint256 executionFeeBps, uint256 yieldFeeBps);
    /// @notice Emitted on each `setMinExecutions` call. Not emitted for the constructor defaults.
    event MinExecutionsSet(Tier indexed tier, uint256 minExecs);
    /// @notice Emitted on each `setMinAmountPerExecution` call, with the amount in USDC base units.
    event MinAmountPerExecutionSet(uint256 amount);
    /// @notice Emitted at construction and on each change of `guardian`.
    event GuardianSet(address indexed guardian);

    /// @notice Thrown when `createStrategy` is given a zero `referralCommitment`.
    /// @dev Does not and cannot enforce randomness: any other constant passes. It catches an
    ///      integration that never filled the field, and makes the "every creation carries a word"
    ///      convention enforced rather than merely documented.
    error ZeroReferralCommitment();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Wires the factory and sets default minimum executions per tier (Daily 10, Weekly 8,
    ///         BiWeekly 6, Monthly 3).
    /// @dev Reverts `ZeroAddress` if any address argument is zero, `StrategyImplementationHasNoCode`
    ///      if `_strategyImplementation` has no code, and `YieldWithdrawalToleranceTooHigh` if the
    ///      compiled-in tolerance constants are inconsistent.
    ///      `_batchExecutor` is not checked for code, so a placeholder may be passed and replaced
    ///      later with `setBatchExecutor`; `createStrategy` reverts until it is.
    /// @param _strategyImplementation UserStrategyAccount implementation to clone. Immutable.
    /// @param _owner                  Owner of every setter, intended to be a timelock.
    constructor(
        address _strategyImplementation,
        address _batchExecutor,
        address _usdc,
        address _owner,
        address _treasury,
        address _guardian
    )
        Ownable(_owner)
    {
        if (YIELD_WITHDRAWAL_TOLERANCE > MAX_YIELD_WITHDRAWAL_TOLERANCE) {
            revert YieldWithdrawalToleranceTooHigh(
                YIELD_WITHDRAWAL_TOLERANCE, MAX_YIELD_WITHDRAWAL_TOLERANCE
            );
        }
        if (_strategyImplementation == address(0) || _batchExecutor == address(0) || _usdc == address(0) || _treasury == address(0)) revert ZeroAddress();
        // The strategy implementation is immutable and is the delegate target of every account this
        // factory ever clones. A non-zero but codeless address (an EOA, or a not-yet-deployed
        // address) passes the check above, `Clones.clone` still deploys the EIP-1167 stub, and
        // `initialize` on that clone returns success with empty data because a call into a codeless
        // delegate target succeeds - so `createStrategy`'s `InitFailed` guard never fires and a
        // permanently dead account is registered. Reject it here, where the mistake is still fixable,
        // matching the code-length check an adapter implementation gets at approval.
        if (_strategyImplementation.code.length == 0) revert StrategyImplementationHasNoCode(_strategyImplementation);
        // Required, not optional: a zero guardian leaves the factory with no reachable emergency
        // stop, and restoring one would have to wait out the full timelock delay.
        if (_guardian == address(0)) revert ZeroAddress();
        guardian = _guardian;
        emit GuardianSet(_guardian);
        strategyImplementation = _strategyImplementation;
        strategyImplementationCodehash = _strategyImplementation.codehash;
        batchExecutor = _batchExecutor;
        usdc = _usdc;
        treasury = _treasury;

        minExecutions[Tier.Daily]     = 10;
        minExecutions[Tier.Weekly]    = 8;
        minExecutions[Tier.BiWeekly]  = 6;
        minExecutions[Tier.Monthly]   = 3;
    }

    // -------------------------------------------------------------------------
    // Roles
    // -------------------------------------------------------------------------

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    // -------------------------------------------------------------------------
    // Strategy creation
    // -------------------------------------------------------------------------

    /// @notice Deploys a minimal proxy UserStrategyAccount owned by the caller and records its
    ///         factory provenance. It does NOT enter the active registry here.
    /// @dev Creation grants `isDeployedByFactory` only. Active membership is granted by the
    ///      account's first `deposit`, which calls `registerStrategy`. A created but unfunded
    ///      account is therefore authentic and inactive at the same time, and BatchExecutor skips
    ///      it.
    ///
    ///      Reverts `TargetAssetNotWhitelisted` unless `batchExecutor.whitelistedAssets(targetAsset)`,
    ///      and reverts without data if `batchExecutor` has no code, as a deployment placeholder
    ///      does before `setBatchExecutor` wires the real executor. Also reverts while paused, on a
    ///      zero commitment, on a zero or USDC target, on an amount outside
    ///      [`minAmountPerExecution`, `MAX_AMOUNT_PER_EXECUTION`], on an unapproved or altered
    ///      yield adapter, and on an altered strategy implementation.
    ///
    ///      Pausing blocks new strategy creation only. Existing strategies are unaffected.
    ///      The owner is taken from `msg.sender` and is never caller-supplied calldata, so a
    ///      compromised frontend cannot hand the created strategy to a third party. For a Safe or
    ///      other smart account, `msg.sender` is the calling account and therefore the owner.
    ///
    ///      Reentrancy-guarded because it runs implementation-selected init code: the adapter
    ///      clone's `initialize` delegatecalls approved-but-third-party bytecode.
    /// @param referralCommitment Opaque 32 bytes, emitted in `StrategyCreated` and used for nothing
    ///        else. Beyond rejecting zero, this contract does not persist, hash or forward it: it
    ///        reaches no storage slot, no other protocol contract, and no branch other than that
    ///        rejection. It is public, in calldata and in the log beside the owner, so its privacy
    ///        rests on the secret salt described below rather than on obscurity. It is a second
    ///        argument rather than a `StrategyParams` field because it is creation metadata, not
    ///        strategy configuration, and keeping it out of the struct stops a reader treating it
    ///        as one.
    ///
    ///        The intended client convention: for a referred creation, a hash commitment to the
    ///        referral that includes a fresh 32-byte secret salt; for an unreferred one, an
    ///        independently random non-zero word, so the two are indistinguishable from chain
    ///        data. None of that is or can be checked here. The zero rejection below catches an
    ///        integration that never filled the field; it cannot detect a constant, and an
    ///        integration that passes one narrows the anonymity set for every other user of the
    ///        protocol.
    /// @return account The new UserStrategyAccount, owned by `msg.sender`.
    function createStrategy(StrategyParams calldata params, bytes32 referralCommitment)
        external
        whenNotPaused
        nonReentrant
        returns (address account)
    {
        if (referralCommitment == bytes32(0)) revert ZeroReferralCommitment();
        if (params.targetAsset == address(0)) revert ZeroAddress();
        // USDC is the input asset, never an output. Allowing it would give a strategy a pending
        // record over the same token as its tracked principal, and pending recovery pays out the
        // account's whole balance of the recorded asset. Enforced here so that property rests on a
        // check rather than on the asset allowlist staying sane.
        if (params.targetAsset == usdc) revert TargetAssetIsUsdc();
        // Only the executor pulls a strategy, and it refuses an unlisted asset, so an unlisted
        // strategy would be funded and due forever without ever executing. Read from the executor
        // new accounts are bound to, so the two agree at creation. A later de-listing is not
        // covered.
        if (!IAssetAllowlist(batchExecutor).whitelistedAssets(params.targetAsset)) {
            revert TargetAssetNotWhitelisted(params.targetAsset);
        }
        if (params.amountPerExecution < minAmountPerExecution)
            revert AmountTooLow(params.amountPerExecution, minAmountPerExecution);
        if (params.amountPerExecution > MAX_AMOUNT_PER_EXECUTION)
            revert AmountTooHigh(params.amountPerExecution, MAX_AMOUNT_PER_EXECUTION);

        // Yield is opt-in by naming a venue: address(0) disables it, non-zero selects the exact
        // approved implementation to clone. Re-check approval here, not only at approval time, so
        // a revoked or mutated implementation cannot be cloned.
        address implementation = params.yieldAdapterImplementation;
        bool yieldEnabled = implementation != address(0);
        if (yieldEnabled) {
            bytes32 approvedCodehash = approvedYieldAdapterCodehash[implementation];
            if (approvedCodehash == bytes32(0)) revert AdapterNotApproved(implementation);
            // Reachable, and checked before the codehash pin on purpose: an approved implementation
            // can lose its code afterwards. Pre-EIP-6780 chains allow a plain SELFDESTRUCT, and even
            // post-6780 an owner multicall could deploy, approve and destroy in one transaction.
            // EXTCODEHASH is then keccak256("") for a surviving empty account or 0 for a deleted one,
            // so the pin would also reject it, but reporting "no code" is the accurate diagnosis.
            if (implementation.code.length == 0) revert AdapterHasNoCode(implementation);
            bytes32 actualCodehash = implementation.codehash;
            if (actualCodehash != approvedCodehash) {
                revert AdapterCodehashMismatch(implementation, approvedCodehash, actualCodehash);
            }
            address implBase = IYieldAdapterImplementation(implementation).baseToken();
            if (implBase != usdc) revert AdapterBaseTokenMismatch(implementation, implBase);
        }

        // The constructor check alone is not enough: the implementation can lose its code later (a
        // pre-EIP-6780 SELFDESTRUCT, or a same-transaction create/accept/destroy under Cancun), and
        // `Clones.clone` would then register a dead account whose `initialize` returns success with
        // empty data. Code length first for the accurate diagnosis, then the pin, which also catches
        // a metamorphic redeploy at the same address.
        if (strategyImplementation.code.length == 0) revert StrategyImplementationHasNoCode(strategyImplementation);
        bytes32 actualStrategyCodehash = strategyImplementation.codehash;
        if (actualStrategyCodehash != strategyImplementationCodehash) {
            revert StrategyImplementationCodehashMismatch(
                strategyImplementation, strategyImplementationCodehash, actualStrategyCodehash
            );
        }
        account = Clones.clone(strategyImplementation);

        // Clone and bind the adapter now that the account address is known. Both happen inside this
        // transaction, so a clone is never observable in its uninitialized state.
        address adapterToUse = address(0);
        if (yieldEnabled) {
            adapterToUse = Clones.clone(implementation);
            IYieldAdapterImplementation(adapterToUse).initialize(account);
            // Lineage: catches an implementation whose initializer binds the clone to the wrong
            // account, or fails to bind it at all. That is all it catches.
            //
            // It does NOT establish that the clone is reachable only by this strategy. It verifies
            // what `account()` chooses to report, and a hostile implementation can report the right
            // account while also exposing an unrestricted withdrawal path, or SELFDESTRUCT the clone
            // from inside `initialize` (the clone is created in this transaction, so EIP-6780 permits
            // its deletion) and still pass every check here. Exclusivity comes from the approval
            // review in setApprovedYieldAdapterImplementation, not from this assertion.
            address boundAccount = IYieldAdapterImplementation(adapterToUse).account();
            if (boundAccount != account) revert AdapterAccountMismatch(adapterToUse, account, boundAccount);
            address cloneBase = IYieldAdapterImplementation(adapterToUse).baseToken();
            if (cloneBase != usdc) revert AdapterBaseTokenMismatch(adapterToUse, cloneBase);
        }

        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,uint256,uint8,bool,address,address,address)",
            msg.sender,
            params.targetAsset,
            params.amountPerExecution,
            uint8(params.tier),
            yieldEnabled,
            adapterToUse,
            batchExecutor,
            address(this)
        );
        (bool ok,) = account.call(initData);
        if (!ok) revert InitFailed();

        isDeployedByFactory[account] = true;
        emit StrategyCreated(
            account,
            msg.sender,
            params.targetAsset,
            params.amountPerExecution,
            params.tier,
            implementation,
            adapterToUse,
            referralCommitment
        );
    }

    // -------------------------------------------------------------------------
    // Registry - each UserStrategyAccount calls these for itself only
    // -------------------------------------------------------------------------

    /// @notice Adds an account to the active registry. Called by UserStrategyAccount on first
    ///         deposit and on resume.
    /// @dev Reverts `NotAStrategy` unless `msg.sender == account` and this factory deployed it.
    ///      Provenance is required but never granted here: an account this factory did not deploy
    ///      can never enter the registry, and one it did deploy stays eligible to re-enter after a
    ///      pause. Idempotent - a second call for an already-active account is a no-op that still
    ///      emits, which callers rely on (resume after auto-pause).
    function registerStrategy(address account) external {
        if (!isDeployedByFactory[account] || msg.sender != account) revert NotAStrategy();
        _addToRegistry(account);
        emit StrategyRegistered(account);
    }

    /// @notice Removes an account from the active registry. Called by UserStrategyAccount on
    ///         pause, auto-pause and withdraw.
    /// @dev Reverts `NotAStrategy` unless `msg.sender == account` and this factory deployed it.
    ///      Requires provenance as well as self-call, so an unknown contract cannot emit a
    ///      misleading no-op StrategyRemoved for itself and pollute the indexed registry history.
    ///      Idempotent. Does NOT clear provenance: resume() depends on it surviving the removal.
    function removeStrategy(address account) external {
        if (!isDeployedByFactory[account] || msg.sender != account) revert NotAStrategy();
        _removeFromRegistry(account);
        emit StrategyRemoved(account);
    }

    // -------------------------------------------------------------------------
    // Registry queries
    // -------------------------------------------------------------------------

    /// @notice True while `account` sits in the active registry. False before its first deposit,
    ///         while paused or auto-paused, and after withdrawal.
    /// @dev Reads the 1-based `_strategyIndex` rather than a second boolean, so membership is not
    ///      stored twice. Agreement with `_activeStrategies` rests on `_removeFromRegistry` keeping
    ///      index and array in step.
    ///
    ///      This is NOT an authenticity check - pair it with `isDeployedByFactory`.
    function isActiveStrategy(address account) external view returns (bool) {
        return _strategyIndex[account] != 0;
    }

    /// @notice Returns all active strategies due for execution in the given tier and window,
    ///         funded or not.
    /// @dev Read off-chain by the keeper and by monitoring. Scans the whole registry in one call,
    ///      so its cost grows with total protocol size; `getDueFundedAccounts` is the bounded,
    ///      paged alternative. An account whose `isDue` call reverts or returns other than 32 bytes
    ///      is left out; a 32-byte answer that is not a valid bool reverts the whole query.
    /// @return due Due strategies, in registry order.
    function getDueAccounts(Tier tier, uint256 windowStart) external view returns (address[] memory due) {
        uint256 count = _activeStrategies.length;
        address[] memory temp = new address[](count);
        uint256 found = 0;

        for (uint256 i = 0; i < count; i++) {
            address acct = _activeStrategies[i];
            // Each account answers for itself, so the factory stores no tier or schedule state.
            (bool ok, bytes memory data) = acct.staticcall(
                abi.encodeWithSignature("isDue(uint8,uint256)", uint8(tier), windowStart)
            );
            if (ok && data.length == 32 && abi.decode(data, (bool))) {
                temp[found++] = acct;
            }
        }

        due = new address[](found);
        for (uint256 i = 0; i < found; i++) due[i] = temp[i];
    }

    /// @notice One bounded page of active strategies that are due in `tier` at `windowStart` AND
    ///         currently able to fund their complete next draw - the contribution plus any yield
    ///         fee - within the yield withdrawal tolerance (`UserStrategyAccount.isDueAndFunded`).
    /// @param tier        Tier to select.
    /// @param windowStart Start of the execution window being built.
    /// @param cursor      Registry index to resume from. Start at 0.
    /// @param limit       Maximum registry entries to INSPECT, not to return. A page that inspects
    ///                    `limit` candidates and finds none funded correctly returns an empty array
    ///                    and a non-zero `nextCursor`.
    /// @return accounts   Due and funded strategies found in this page, registry order preserved.
    /// @return nextCursor Index to pass as the next `cursor`, or 0 when the registry end was reached.
    ///                    A caller pages until it sees 0.
    /// @dev Companion to `getDueAccounts`, not a replacement for it. The raw query stays the
    ///      monitoring surface: a strategy that is persistently due but unfunded must remain visible
    ///      somewhere, and it is deliberately invisible here.
    ///
    ///      Bounded because `getDueAccounts` is not: it allocates and scans the whole registry in one
    ///      call, so it degrades with total protocol size rather than with page size, and can
    ///      eventually exceed an RPC call's gas limit. This selector lets a keeper trade page size
    ///      against call cost.
    ///
    ///      Pagination is over registry INDICES, so a page is only free of duplicates and omissions
    ///      while the registry is stable. Registration and removal are a swap-with-last-and-pop, so
    ///      a concurrent removal can move an unvisited entry behind the cursor and cost it one
    ///      window.
    ///
    ///      **A caller paging a FUTURE `windowStart` must deduplicate across pages.** Removal only
    ///      swaps the last entry DOWN, so an EXISTING entry's index rises only on
    ///      remove-then-re-register, which is `resume` after a manual or automatic pause - and that
    ///      re-anchors `nextExecutionTime` to the next boundary EXACTLY. A caller paging the open
    ///      window therefore never sees the re-added entry twice, but a caller that passes that same
    ///      boundary as `windowStart` does. (A first deposit also appends at the tail, but it adds an
    ///      entry that no earlier page can have returned, so it is not a duplicate path.)
    ///
    ///      Documented rather than enforced, and not because it is cheap to enforce. It is not
    ///      enforceable here at all: by the time the entry reappears at the tail its earlier
    ///      occurrence is gone from the array, and this view holds no memory of what a previous call
    ///      returned. Closing it would take caller-supplied seen-state, registry snapshot or version
    ///      semantics, or rejecting `windowStart > block.timestamp` - and the last would take away
    ///      the legitimate pre-building this function is useful for.
    ///
    ///      **No duplicate can buy twice**, which is the property that matters, and it holds because
    ///      a second successful pull is unreachable rather than because any one rejection always
    ///      fires. Once an active, due, correctly formed occurrence reaches funding resolution, the
    ///      three outcomes are: it pulled, and advanced `nextExecutionTime`, so a later occurrence
    ///      before the next anchor reverts `TooEarly`; it auto-paused, so a later occurrence is
    ///      skipped on BatchExecutor's membership check, or returns zero on the `paused` guard if the
    ///      deregistration itself reverted and was swallowed; or it hit a yield failure, consuming
    ///      the account's own nonce slot without advancing the anchor, so a later occurrence reverts
    ///      `NonceUsed`.
    ///
    ///      That list is not the whole space and is not meant to be. `authorisedPull` has earlier
    ///      exits - paused, closed, too early, wrong amount, nonce already used - that reject BOTH
    ///      occurrences without either pulling, and a reverting token transfer rolls the nonce and
    ///      the anchor back with the rest of the call. A batch that bought nothing may then be
    ///      retried under a fresh nonce, which is a retry and not a second buy. The cost of a
    ///      duplicate is a keeper that quoted for USDC that never arrives.
    ///
    ///      A candidate whose read reverts or answers malformed is skipped rather than reverting the
    ///      page. Every registry member is a clone of this factory's single `strategyImplementation`,
    ///      so a malformed answer is not expected. The tolerance keeps one unqueryable candidate from
    ///      making the selector unusable protocol-wide.
    ///
    ///      That isolation is over the ANSWER, not over gas, and the distinction matters. Each
    ///      candidate is given essentially all remaining gas, and so is the adapter read nested
    ///      inside it, so a strategy or adapter that loops or returns a huge buffer takes the page
    ///      down with it rather than being skipped. No gas stipend is imposed here: any constant
    ///      would be a guess that a legitimate adapter or a repricing hard fork could invalidate,
    ///      and it would silently convert "this venue is expensive to read" into "this user never
    ///      executes". The controls are adapter approval review and the fact that this is an
    ///      off-chain view; the caller's own lever is a smaller `limit`, which bounds how many
    ///      candidates one failed page costs.
    function getDueFundedAccounts(Tier tier, uint256 windowStart, uint256 cursor, uint256 limit)
        external
        view
        returns (address[] memory accounts, uint256 nextCursor)
    {
        // A zero limit would return an empty page and no cursor progress, which reads exactly like
        // "nothing left to do" and spins a paging caller forever. Reject it as the caller bug it is.
        if (limit == 0) revert ZeroLimit();

        uint256 total = _activeStrategies.length;
        if (cursor >= total) return (new address[](0), 0);

        // No overflow: the branch is taken only when `limit` is below the remaining span.
        uint256 end = limit < total - cursor ? cursor + limit : total;

        accounts = _scanDueFunded(tier, windowStart, cursor, end);

        // 0 is the end-of-registry sentinel. Unambiguous because a page that stopped short always
        // ended past index 0, so a non-final page can never report 0.
        nextCursor = end == total ? 0 : end;
    }

    /// @dev Scans `_activeStrategies[from..to)`. Split out of `getDueFundedAccounts` purely so that
    ///      function's live-variable count stays inside the EVM's 16-slot stack limit, which is what
    ///      lets this contract compile without via_ir.
    function _scanDueFunded(Tier tier, uint256 windowStart, uint256 from, uint256 to)
        internal
        view
        returns (address[] memory funded)
    {
        address[] memory temp = new address[](to - from);
        uint256 found = 0;

        for (uint256 i = from; i < to; i++) {
            address acct = _activeStrategies[i];
            (bool ok, bytes memory data) = acct.staticcall(
                abi.encodeWithSignature("isDueAndFunded(uint8,uint256)", uint8(tier), windowStart)
            );
            // Decoded as uint256 rather than bool on purpose: `abi.decode(_, (bool))` reverts on a
            // word that is neither 0 nor 1, which would hand one malformed candidate the power to
            // revert the whole page. Only an exact 1 is accepted, so a dirty word is skipped like
            // any other malformed answer rather than reverting OR being read as true.
            if (ok && data.length == 32 && abi.decode(data, (uint256)) == 1) {
                temp[found++] = acct;
            }
        }

        funded = new address[](found);
        for (uint256 i = 0; i < found; i++) funded[i] = temp[i];
    }

    /// @notice Number of strategies currently in the active registry.
    function activeStrategyCount() external view returns (uint256) {
        return _activeStrategies.length;
    }

    /// @notice Full list of strategies currently in the active registry.
    function getActiveStrategies() external view returns (address[] memory) {
        return _activeStrategies;
    }

    // -------------------------------------------------------------------------
    // Admin setters
    // -------------------------------------------------------------------------

    /// @notice Update the BatchExecutor address recorded for new strategies.
    /// @dev **Affects new strategies only.** Every existing `UserStrategyAccount` is permanently
    ///      pinned to the BatchExecutor it was given at `initialize`: there is no setter for it on
    ///      the account, and accounts are non-upgradeable clones. So this cannot redirect an
    ///      existing user's funds: from each account's point of view its executor is already
    ///      immutable.
    ///
    ///      Owner-gated and therefore timelocked, because it does determine where *future*
    ///      strategies send their USDC. Reverts `ZeroAddress` on a zero address.
    function setBatchExecutor(address _batchExecutor) external onlyOwner {
        if (_batchExecutor == address(0)) revert ZeroAddress();
        batchExecutor = _batchExecutor;
        emit BatchExecutorSet(_batchExecutor);
    }

    /// @notice Update the treasury that receives execution and yield fees. Owner only.
    /// @dev Reverts `ZeroAddress` on a zero address.
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }

    /// @notice Approve or revoke a yield-adapter implementation that new strategies may clone.
    ///         Owner only.
    /// @dev One call per chain per venue. Market addresses live in the implementation's own
    ///      immutables, so there is no second, divergable factory-side source of venue config: a
    ///      market or address change is a new reviewed implementation, not a setter.
    ///
    ///      Every approved implementation must operate on this factory's single base currency.
    ///      Accounting (`depositedAmount`, yield fee, pro-rata) and the batch pull are denominated in
    ///      that one currency, which is what keeps venue selection invisible to the batch layer -
    ///      `authorisedPull` pulls one currency uniformly, with no per-venue batching.
    ///
    ///      Approval is the real security control, so governance must independently verify the
    ///      implementation is:
    ///        - source-verified, immutable, CREATE-deployed, non-proxy;
    ///        - free of delegatecall to a mutable slot;
    ///        - free of any reachable SELFDESTRUCT. Clone code runs in the clone's context, so a
    ///          SELFDESTRUCT anywhere in the implementation can destroy a clone from inside
    ///          `initialize`, and EIP-6780 permits that for a clone created in the same transaction;
    ///        - free of any withdrawal path not gated on the bound account.
    ///      None of these are checkable on-chain, and the creation-time assertions in createStrategy
    ///      do not substitute for them. There is no robust general on-chain proxy check either; the
    ///      codehash pin below only guarantees that the implementation a clone delegates to equals
    ///      the one reviewed here. The clone's own bytecode is the fixed EIP-1167 stub.
    ///
    ///      Revoking blocks new selection only. Existing clones keep working, by design: their funds
    ///      must stay withdrawable.
    ///
    ///      Reverts `ZeroAddress` on a zero address. Approval also reverts `AdapterHasNoCode` on a
    ///      codeless address and `AdapterBaseTokenMismatch` unless `baseToken()` is `usdc`.
    /// @param approved True to approve and pin the implementation's current codehash, false to
    ///        revoke.
    function setApprovedYieldAdapterImplementation(address implementation, bool approved) external onlyOwner {
        if (implementation == address(0)) revert ZeroAddress();

        bytes32 codehash = bytes32(0);
        if (approved) {
            if (implementation.code.length == 0) revert AdapterHasNoCode(implementation);
            address implBase = IYieldAdapterImplementation(implementation).baseToken();
            if (implBase != usdc) revert AdapterBaseTokenMismatch(implementation, implBase);
            codehash = implementation.codehash;
            approvedYieldAdapterCodehash[implementation] = codehash;
        } else {
            delete approvedYieldAdapterCodehash[implementation];
        }

        emit YieldAdapterImplementationSet(implementation, approved, codehash);
    }

    /// @notice Update fee parameters. Owner only. Reverts `FeeTooHigh` if either value exceeds its
    ///         hard cap. Both rates are in basis points.
    function setFees(uint256 _executionFeeBps, uint256 _yieldFeeBps)
        external onlyOwner
    {
        if (_executionFeeBps > MAX_EXECUTION_FEE_BPS)   revert FeeTooHigh(_executionFeeBps, MAX_EXECUTION_FEE_BPS);
        if (_yieldFeeBps > MAX_YIELD_FEE_BPS)           revert FeeTooHigh(_yieldFeeBps, MAX_YIELD_FEE_BPS);
        executionFeeBps  = _executionFeeBps;
        yieldFeeBps      = _yieldFeeBps;
        emit FeesUpdated(_executionFeeBps, _yieldFeeBps);
    }

    /// @notice Set the minimum number of executions a first deposit must fund in `tier`, which sets
    ///         that tier's minimum first deposit. Owner only.
    /// @dev Reverts `AmountTooLow` below one: a zero minimum would make the first-deposit check
    ///      `amountPerExecution * minExecutions[tier]` accept any amount.
    function setMinExecutions(Tier tier, uint256 minExecs) external onlyOwner {
        if (minExecs < MIN_EXECUTIONS_PER_TIER) {
            revert AmountTooLow(minExecs, MIN_EXECUTIONS_PER_TIER);
        }
        minExecutions[tier] = minExecs;
        emit MinExecutionsSet(tier, minExecs);
    }

    /// @notice Set the minimum USDC amount per execution enforced at strategy creation. Owner only.
    ///         Existing strategies are unaffected.
    /// @dev Must exceed the venue withdrawal tolerance so a zero-value pull cannot consume a
    ///      strategy's execution window, and must not exceed
    ///      `MAX_AMOUNT_PER_EXECUTION`: a minimum above the maximum leaves `createStrategy` with no
    ///      satisfiable amount, bricking creation protocol-wide until a second timelocked call
    ///      undoes it. Same shape as the minima guard above - a setter must not be able to make a
    ///      creation-time range vacuous. Reverts `AmountTooLow` or `AmountTooHigh` outside that
    ///      range.
    /// @param amount New minimum, in USDC base units.
    function setMinAmountPerExecution(uint256 amount) external onlyOwner {
        if (amount < MIN_AMOUNT_PER_EXECUTION) {
            revert AmountTooLow(amount, MIN_AMOUNT_PER_EXECUTION);
        }
        if (amount > MAX_AMOUNT_PER_EXECUTION) {
            revert AmountTooHigh(amount, MAX_AMOUNT_PER_EXECUTION);
        }
        minAmountPerExecution = amount;
        emit MinAmountPerExecutionSet(amount);
    }

    /// @notice Rotate the guardian. Owner-gated, so it inherits the timelock delay.
    /// @dev Not guardian-gated on purpose: a compromised guardian must not be able to pass the role
    ///      on, nor lock the owner out of reclaiming it. Reverts `ZeroAddress` on a zero address.
    function setGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert ZeroAddress();
        guardian = newGuardian;
        emit GuardianSet(newGuardian);
    }

    /// @notice Pause blocks createStrategy only. Withdraw is always available.
    /// @dev Guardian-gated and instant. Factory-level pause has to be as fast as the
    ///      executor-level one: the point of separating the guardian from the timelocked owner is
    ///      that stopping the system never waits.
    function pause() external onlyGuardian { _pause(); }
    /// @notice Re-enables createStrategy. Guardian-gated and instant.
    function unpause() external onlyGuardian { _unpause(); }

    // -------------------------------------------------------------------------
    // Internal registry helpers - O(1) swap-with-last-and-pop
    // -------------------------------------------------------------------------

    function _addToRegistry(address account) internal {
        if (_strategyIndex[account] != 0) return; // already registered (index 0 reserved = not present)
        _activeStrategies.push(account);
        _strategyIndex[account] = _activeStrategies.length; // 1-based index
    }

    function _removeFromRegistry(address account) internal {
        uint256 idx = _strategyIndex[account];
        if (idx == 0) return; // not in registry

        uint256 lastIdx = _activeStrategies.length;
        if (idx != lastIdx) {
            address last = _activeStrategies[lastIdx - 1];
            _activeStrategies[idx - 1] = last;
            _strategyIndex[last] = idx;
        }
        _activeStrategies.pop();
        delete _strategyIndex[account];
    }

}

/// @dev The one BatchExecutor read `createStrategy` needs. Declared here rather than importing
///      BatchExecutor, which already imports this file.
interface IAssetAllowlist {
    function whitelistedAssets(address asset) external view returns (bool);
}
