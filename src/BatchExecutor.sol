// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/ISwapAdapter.sol";
import "./interfaces/IPriceOracle.sol";
import "./DCAFactory.sol";
import "./libraries/BoundedTransfer.sol";

/// @notice Economic core of the protocol. Pulls USDC from every due UserStrategyAccount in a batch,
///         takes the execution fee in USDC, executes one pooled swap, then distributes the whole
///         purchased amount pro-rata to the accounts that paid.
/// @dev The executor address is a plain setter, so any automation provider can drive batches.
///      Pause blocks new batches only: held-output claims, fee flushes and rescues stay available,
///      and so does `withdraw()` on every account.
contract BatchExecutor is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error Unauthorized();
    error ZeroAddress();
    error ArrayLengthMismatch();
    error EmptyAccounts();
    error NonceUsed(uint256 nonce);
    error AssetNotWhitelisted(address asset);
    /// @notice No balance of the token exceeds what `rescueTokens` must leave behind.
    error NothingToRescue();
    error TargetAssetMismatch(address account, address expected);
    /// @notice `minAmountOut` was zero, which would disable the executor's slippage bound entirely.
    error ZeroMinAmountOut();
    error OracleNotConfigured();
    error OracleReturnedZero(address asset, uint256 usdcIn);
    error OutputBelowEffectiveMinimum(uint256 amountOut, uint256 effectiveMinOut);
    error NotGuardian();
    error NothingToFlush();
    error NothingToClaim();

    /// @notice Gas forwarded to the output token's `transfer` of one account's share. Matches
    ///         `UserStrategyAccount.OUTPUT_TRANSFER_GAS`, sized from measurements on Base: WETH
    ///         uses about 30k, cbBTC about 45k.
    uint256 public constant SHARE_TRANSFER_GAS = 100_000;
    /// @notice Gas kept back from that call to record a held share: two fresh storage slots and an
    ///         event.
    uint256 public constant SHARE_HOLD_GAS = 60_000;

    /// @notice Factory whose clones are the only accounts a batch will pull from. Also supplies the
    ///         fee rate and the treasury address.
    DCAFactory public immutable factory;
    /// @notice The base token users deposit and batches swap from.
    IERC20 public immutable usdc;
    /// @notice Router every batch swap goes through. Owner-set.
    ISwapAdapter public swapRouter;
    /// @notice The only address that may call `executeBatch`. Provider-agnostic: an EOA keeper, a
    ///         Gelato or Chainlink Automation forwarder, or any other contract. Guardian-set.
    address public executor;

    /// @notice Holds the two powers that must not wait out the timelock: the emergency stop, and
    ///         rotating the executor key.
    /// @dev `owner` is intended to be a TimelockController, so every fund-routing setter is
    ///      delayed. The guardian is delegated exactly the actions where a delay would be harmful:
    ///        - `pause`/`unpause`, because a delayed emergency stop is worse than none;
    ///        - `setExecutor`, because the keeper key is the most likely thing to leak.
    ///      Neither can move funds or change routing, so the guardian is strictly weaker than the
    ///      owner despite acting instantly. It may also call `flushFees`, which can only pay the
    ///      current treasury. Rotating the guardian itself is owner-gated, and therefore delayed.
    ///
    ///      The same multisig may hold the guardian role and control the timelock. The security comes
    ///      from the timelock delay being unskippable, not from the two roles being different parties.
    address public guardian;

    /// @notice Batch nonces already used. A nonce is spent even by a batch that ends up empty.
    mapping(uint256 => bool) public usedNonces;
    /// @notice Assets a batch may buy. Owner-set.
    mapping(address => bool) public whitelistedAssets;

    /// @notice Independent, executor-proof price floor. Quoted on the USDC actually swapped, so
    ///         skipped or fake accounts cannot dilute it, and it bounds swap output even when the
    ///         executor supplies `minAmountOut == 1`. BatchExecutor depends only on the
    ///         IPriceOracle interface; the concrete oracle is set by the owner. A batch cannot
    ///         execute without one configured.
    IPriceOracle public priceOracle;

    /// @notice Execution and yield fees retained because the treasury could not be paid at
    ///         execution time.
    /// @dev The fee is a bare USDC transfer to `factory.treasury()` inside every batch. A treasury
    ///      the base token refuses to pay - a USDC-blacklisted Safe is the realistic case, since
    ///      Circle's FiatToken reverts a transfer to a blacklisted recipient - would otherwise revert
    ///      every batch protocol-wide, because the closing balance assert would fail on the fee left
    ///      in the contract. Instead the fee is retained and counted here, and `flushFees()` pays it
    ///      out once the treasury is payable again. This is treasury income held in escrow, never
    ///      user funds: distribution has already completed when the fee is paid.
    uint256 public accruedFees;

    /// @notice Output bought for `account` that the output token refused to transfer to it, held
    ///         here until the account's owner claims it with `claimHeldOutput`.
    ///         Keyed account => asset => amount.
    /// @dev The realistic cause is the token's issuer freezing the strategy clone, which cbBTC's
    ///      blacklister can do. A bare transfer would then revert every batch containing that
    ///      account, so one frozen user would stop every other user in the batch. Unlike
    ///      `accruedFees` this is user funds in escrow. `rescueTokens` reaches neither.
    mapping(address => mapping(address => uint256)) public heldOutput;
    /// @notice Sum of `heldOutput` over all accounts, per asset. What `rescueTokens` leaves behind.
    mapping(address => uint256) public totalHeldOutput;

    /// @dev Result of pulling USDC from a batch's accounts. Bundling these into a
    ///      single memory struct keeps executeBatch's live-variable count within the
    ///      EVM's 16-slot stack limit, so the contract compiles without via_ir.
    struct PullResult {
        address[] accounts;     // accounts that contributed (first `count` entries are used)
        uint256[] amounts;      // USDC actually pulled from each (parallel to accounts)
        uint256 count;          // number of contributing accounts
        uint256 actualTotal;    // sum of amounts actually pulled
        uint256 submittedTotal; // sum of EVERY submitted amount, contributing or not (slippage base)
        uint256 yieldFeeTotal;  // yield fees the accounts sent alongside their contributions
    }

    /// @notice A batch swapped and distributed.
    /// @param totalIn USDC pulled from the accounts, GROSS. The execution fee is taken
    ///        from this in USDC before the swap, so the amount actually swapped is
    ///        `totalIn - (totalIn * executionFeeBps / 10000)`, not `totalIn`. Stated as the exact
    ///        subtraction the code performs: the tempting `totalIn * (10000 - executionFeeBps) / 10000`
    ///        can differ by one base unit, because each form floors a different division. An implied
    ///        price derived from `totalOut / totalIn` is therefore wrong by the fee. The gross
    ///        figure is kept because it is what the accounts paid, which is what an off-chain
    ///        keeper reconciles against each account's `Executed` events.
    /// @param totalOut Target-asset units received, all of which go to the accounts: delivered, or
    ///        held for an account the token refused (`OutputHeld`).
    /// @param accountCount Number of accounts that contributed and received a share.
    event BatchExecuted(address indexed asset, uint256 totalIn, uint256 totalOut, uint256 accountCount, uint256 indexed nonce);
    /// @notice A batch ran but no account contributed, so nothing was swapped. The nonce is spent.
    event BatchEmpty(address indexed asset, uint256 indexed nonce);
    /// @notice `account` was left out of a batch: not a factory clone, not active, or its pull
    ///         reverted.
    event AccountSkipped(address indexed account);
    event ExecutorSet(address indexed executor);
    event SwapRouterSet(address indexed swapRouter);
    event AssetWhitelisted(address indexed asset, bool whitelisted);
    event GuardianSet(address indexed guardian);
    event PriceOracleSet(address indexed priceOracle);
    /// @notice `amount` of `token` not reserved for users or the treasury was sent to `to`.
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    /// @notice A batch's fees could not be paid to the treasury and were retained.
    event FeeAccrued(address indexed treasury, uint256 amount);
    /// @notice Retained fees were paid out to the treasury by `flushFees`.
    event FeesFlushed(address indexed treasury, uint256 amount);
    /// @notice The token refused to transfer `account`'s share, so it is held here.
    event OutputHeld(address indexed account, address indexed asset, uint256 amount);
    /// @notice The owner of `account` claimed its held output to `to`.
    event HeldOutputClaimed(address indexed account, address indexed asset, address indexed to, uint256 amount);

    /// @dev Reverts `ZeroAddress` if any address but `_owner` is zero; a zero `_owner` reverts in
    ///      OpenZeppelin's `Ownable`.
    /// @param _factory DCAFactory whose clones this executor serves.
    /// @param _owner Owner, intended to be a TimelockController.
    constructor(
        address _factory,
        address _usdc,
        address _swapRouter,
        address _executor,
        address _owner,
        address _guardian
    ) Ownable(_owner) {
        if (_factory == address(0) || _usdc == address(0) || _swapRouter == address(0) || _executor == address(0))
            revert ZeroAddress();
        // Set in the constructor so there is never a block in which the emergency stop has no
        // holder. A zero guardian would leave pause() unreachable until the owner calls
        // setGuardian, which waits out the full timelock delay.
        if (_guardian == address(0)) revert ZeroAddress();
        factory    = DCAFactory(_factory);
        usdc       = IERC20(_usdc);
        swapRouter = ISwapAdapter(_swapRouter);
        executor   = _executor;
        guardian   = _guardian;
        emit GuardianSet(_guardian);
    }

    /// @notice Executes a DCA batch: pull USDC from accounts, take the execution fee, swap, and
    ///         distribute the purchased asset pro-rata.
    /// @dev Executor only, and only while not paused. Accounts that are not active factory clones,
    ///      or whose pull reverts, are skipped with `AccountSkipped`; a batch with no contributor
    ///      emits `BatchEmpty` and still spends its nonce. Reverts the whole batch if any submitted
    ///      account that is an active factory clone buys a different asset (checked before its
    ///      pull), if no oracle is set or it quotes zero, or if the swap returns less than the
    ///      effective minimum.
    /// @param accounts   Ordered list of UserStrategyAccount addresses in this batch.
    /// @param amounts    USDC amount to pull from each account (must equal account.amountPerExecution).
    /// @param targetAsset The asset being purchased.
    /// @param minAmountOut Executor-supplied slippage bound on the swap output. Advisory and
    ///        stricter-only: enforced as max(adjusted minAmountOut, oracle floor), so it can
    ///        tighten but never weaken protection - a minAmountOut of 1 cannot accept dust.
    /// @param nonce      Unique batch identifier. Each nonce can be used once, which prevents replay.
    /// @return amountOut Target-asset units the swap returned, 0 for an empty batch.
    // Static-analysis suppressions:
    // - incorrect-equality: the strict equalities are exact-count guards and the balance-delta
    //   assertions, which must be exact. A >= would let a batch under-distribute in silence.
    // - reentrancy-balance: openingUsdc/openingAsset are read before the account pulls and the
    //   swap, then compared after, which is the flagged shape. Nothing attacker-controlled runs in
    //   between: executeBatch is nonReentrant, pulls only reach factory-created clones of the one
    //   fixed UserStrategyAccount implementation (gated by factory.isDeployedByFactory), and the swap only
    //   reaches the owner-configured SwapRouter. A donation from any outside address lands in a
    //   different transaction, so it is either already inside the snapshot or arrives after the
    //   check. Reading the balances after the pulls instead would leave the swap outside the
    //   measured window, and the swap must be inside it.
    // slither-disable-next-line incorrect-equality,reentrancy-balance
    function executeBatch(
        address[] calldata accounts,
        uint256[] calldata amounts,
        address targetAsset,
        uint256 minAmountOut,
        uint256 nonce
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        // Step 1: structural checks.
        if (msg.sender != executor) revert Unauthorized();
        if (usedNonces[nonce]) revert NonceUsed(nonce);
        if (accounts.length != amounts.length) revert ArrayLengthMismatch();
        if (accounts.length == 0) revert EmptyAccounts();
        if (!whitelistedAssets[targetAsset]) revert AssetNotWhitelisted(targetAsset);
        // Slippage protection must never be fully disabled by the executor.
        if (minAmountOut == 0) revert ZeroMinAmountOut();

        // Spent immediately, so a nonce is consumed even if the batch ends up empty.
        usedNonces[nonce] = true;

        // Snapshot balances BEFORE any funds move. An ERC-20 recipient cannot refuse a direct
        // transfer, so anyone can donate dust to this contract at any time. The property worth
        // enforcing is that a batch leaves no NEW balance behind - not that the contract holds
        // nothing, which a third party could falsify for one USDC base unit and halt execution.
        uint256 openingUsdc  = usdc.balanceOf(address(this));
        uint256 openingAsset = IERC20(targetAsset).balanceOf(address(this));

        // Step 2: per-account pulls. No caller-supplied total is accepted. The totals execution
        // needs are accumulated during the pulls: actualTotal determines the fee and, net of it,
        // the amount swapped; that swapAmount sizes the swap and the oracle floor; submittedTotal
        // is the denominator that scales the executor bound. A submitted total could only ever be
        // checked against those, never used, so it is not part of the ABI.
        PullResult memory r = _pullFromAccounts(accounts, amounts, targetAsset, nonce);

        if (r.count == 0) {
            // A yield fee without a contribution is not a case to handle, it is a broken account.
            // Settlement gives the contribution priority, so a factory clone that owes a fee has
            // necessarily contributed, and an empty batch therefore carries no fee.
            //
            // Fail closed rather than collect. Collecting would mask the violated invariant AND
            // charge the owner for an execution that bought nothing - the one outcome worse than
            // reverting a batch that was going to distribute nothing anyway.
            assert(r.yieldFeeTotal == 0);
            assert(usdc.balanceOf(address(this)) == openingUsdc);
            assert(IERC20(targetAsset).balanceOf(address(this)) == openingAsset);
            emit BatchEmpty(targetAsset, nonce);
            return 0;
        }

        // Step 3: take the execution fee in USDC, before the swap. The fee is a share of what users
        // actually paid in, not of what the swap returned, so it is denominated in USDC and never
        // exposed to slippage. Rounds down, in the users' favor. Everything downstream sizes
        // itself on `swapAmount`: what is not swapped cannot be bought, quoted against, or
        // distributed. `actualTotal` is contributions only, so the execution fee is charged on
        // what users paid for asset and never on the yield fee that travelled in the same transfers.
        uint256 totalFee = r.actualTotal * factory.executionFeeBps() / 10000;
        uint256 swapAmount = r.actualTotal - totalFee;

        // Step 4: compute the effective slippage bound. The executor's minAmountOut is ADVISORY
        // and stricter-only: the executor can tighten slippage but never weaken it. The
        // non-bypassable lower bound is the oracle floor, derived from the USDC actually being
        // swapped (so skipped or fake accounts cannot dilute it) by a protocol-configured price
        // oracle the executor does not control. No oracle means no batch.
        if (address(priceOracle) == address(0)) revert OracleNotConfigured();

        // Scale the executor's bound by what it actually quoted against, which is every SUBMITTED
        // amount, contributing or not. Dividing by the contributing subset instead would apply a
        // bound quoted for the whole batch unchanged to a smaller swap, so one dropped account
        // would revert the batch for everyone else in it.
        //
        // This denominator lets an executor shrink its own bound by padding the array with entries
        // it knows will contribute nothing. That costs nothing worth blocking: `swapAmount <
        // submittedTotal` always, so an executor wanting no bound of its own can pass
        // `minAmountOut = 1` and this expression floors to zero in one step, no padding required.
        //
        // That truncation is deliberately reachable. Rejecting it would only force a rogue executor
        // to pass one unit more, so it is not a control; what actually bounds a compromised
        // executor is `oracleMinOut` below, which it cannot influence. The executor's own term is
        // a self-imposed tightening and nothing else.
        //
        // `swapAmount` in the numerator, not `actualTotal`: the executor quotes minAmountOut for the
        // gross amounts it submitted, and this scaling is what nets the fee out of that quote, so
        // the executor never has to account for the fee itself.
        uint256 adjustedExecutorMinOut = minAmountOut * swapAmount / r.submittedTotal;
        uint256 oracleMinOut = priceOracle.quoteMinOut(targetAsset, swapAmount);
        // Defense in depth: IPriceOracle forbids a zero quote, but a faulty or non-compliant
        // oracle could still return 0, which would collapse effectiveMinOut to the executor's own
        // (bypassable) term and make the post-swap floor vacuous. Reject it at the consumer too, so
        // the floor cannot be disabled whatever oracle is configured.
        if (oracleMinOut == 0) revert OracleReturnedZero(targetAsset, swapAmount);
        uint256 effectiveMinOut = adjustedExecutorMinOut > oracleMinOut ? adjustedExecutorMinOut : oracleMinOut;

        // Step 5: swap.
        usdc.forceApprove(address(swapRouter), swapAmount);
        amountOut = ISwapRouter(address(swapRouter)).swap(targetAsset, swapAmount, effectiveMinOut);
        // Defense-in-depth: the swap stack is expected to enforce effectiveMinOut, so re-verify
        // that complete bound here in case a misconfigured/buggy router or adapter ignores the
        // minimum it was given (swapRouter is a trust boundary). oracleMinOut remains the
        // non-bypassable protocol floor; effectiveMinOut is it plus any executor tightening,
        // and is never lower, so failing closed on it cannot accept a worse trade.
        if (amountOut < effectiveMinOut) revert OutputBelowEffectiveMinimum(amountOut, effectiveMinOut);

        // Step 6: distribute the whole output, remainder to the last account. No fee term: the fee
        // was already taken in USDC, so every unit bought belongs to the accounts that paid for it.
        uint256 outputHeld = _distributeOutput(targetAsset, amountOut, r);

        // Step 7: pay the treasury. In USDC, and after the swap rather than before it, so a
        // reverting swap cannot leave the fee already banked. Ordering only, not accounting: the
        // amount was fixed in step 3. If the treasury cannot receive USDC, the fee is retained
        // (tracked in accruedFees) and returned as feeRetained rather than reverting the whole
        // batch, so one unpayable treasury cannot halt DCA for every user. Distribution already
        // completed, so no user is affected.
        //
        // Yield fees ride the same path. They are treasury income exactly as the execution fee is,
        // so one transfer pays both and one `accruedFees` entry retains both when the treasury
        // cannot be paid. Summing cannot overflow: both terms were accumulated from USDC actually
        // transferred into this contract during this batch, so their total is at most this
        // contract's balance, which the closing assert below pins.
        uint256 treasuryDue = totalFee + r.yieldFeeTotal;
        uint256 feeRetained = 0;
        if (treasuryDue > 0) {
            feeRetained = _collectFee(treasuryDue);
        }

        // Invariant: a batch leaves no new USDC behind beyond a fee it could not pay, and no new
        // asset beyond shares it could not deliver. Compared against the opening snapshot rather
        // than zero, so a donated balance is passed through untouched instead of reverting every
        // batch. feeRetained and outputHeld are 0 on the normal path, so the asserts are exact
        // whenever everything is payable. Unsolicited balances stay recoverable via rescueTokens,
        // retained fees via flushFees, and held output via claimHeldOutput.
        assert(IERC20(targetAsset).balanceOf(address(this)) == openingAsset + outputHeld);
        assert(usdc.balanceOf(address(this)) == openingUsdc + feeRetained);

        emit BatchExecuted(targetAsset, r.actualTotal, amountOut, r.count, nonce);
    }

    /// @dev Step 2 of `executeBatch`, split out to keep it within stack limits. Pulls USDC from
    ///      each account, skipping any that is not an active factory clone or whose pull reverts.
    ///      Reverts the whole batch with `TargetAssetMismatch` if an active factory clone buys
    ///      another asset; that check runs before the clone's pull.
    function _pullFromAccounts(
        address[] calldata accounts,
        uint256[] calldata amounts,
        address targetAsset,
        uint256 nonce
    ) internal returns (PullResult memory r) {
        r.accounts = new address[](accounts.length);
        r.amounts  = new uint256[](accounts.length);

        for (uint256 i = 0; i < accounts.length; i++) {
            // Accumulated for EVERY entry, before any decision about it. This is what the executor
            // quoted against, so it is the only base that scales its bound correctly when part of
            // the batch does not contribute.
            r.submittedTotal += amounts[i];

            // Defense-in-depth, two separate questions:
            //   - provenance: is this address a clone this factory deployed. Guards the calls
            //     below, which hit a fixed implementation only because of this check.
            //   - active membership: is it in the batch registry right now. A paused, auto-paused,
            //     never-funded or withdrawn account is not, so a stale batch cannot reach it.
            // The account-level checks stay authoritative; this only stops the call being made.
            if (!factory.isDeployedByFactory(accounts[i]) || !factory.isActiveStrategy(accounts[i])) {
                emit AccountSkipped(accounts[i]);
                continue;
            }
            // Bind every pulled account to the batch asset. A strategy may only be included in a
            // batch buying its own targetAsset - revert the whole batch on mismatch so a
            // compromised executor cannot reallocate a user into another asset.
            if (ITargetAsset(accounts[i]).targetAsset() != targetAsset) {
                revert TargetAssetMismatch(accounts[i], targetAsset);
            }
            // An account transfers its contribution and its yield fee in one transfer and
            // reports them separately. Only `got` is a contribution. `yieldFee` is treasury income
            // that merely travelled with it, so it must stay out of `actualTotal` - which sizes the
            // swap, the oracle floor and every pro-rata share. Folding it in would buy asset with
            // treasury money and hand it to whichever accounts happened to carry the most yield.
            try IAuthorisedPull(accounts[i]).authorisedPull(amounts[i], nonce)
                returns (uint256 got, uint256 yieldFee)
            {
                if (got > 0) {
                    r.accounts[r.count] = accounts[i];
                    r.amounts[r.count]  = got;
                    r.count++;
                    r.actualTotal   += got;
                }
                // Accumulated outside the `got > 0` guard on purpose: the two are independent, and
                // an account that settles a fee while contributing nothing must still have that fee
                // accounted for, or it would be stranded here and trip the closing assert.
                r.yieldFeeTotal += yieldFee;
            } catch {
                emit AccountSkipped(accounts[i]);
            }
        }
    }

    /// @dev Step 6 of `executeBatch`. Distributes the whole swap output pro-rata to the USDC each
    ///      account contributed. Each share rounds down and the last account absorbs the
    ///      remainder, so the shares sum to exactly `distributable` and no dust is left in the
    ///      executor. Returns the total held for accounts the token refused, which the caller
    ///      folds into the closing balance assert so it stays exact.
    // Static-analysis suppression, reentrancy-no-eth: a refused share is recorded after an
    // EARLIER iteration's `receiveOutput`. That call reaches only a factory clone of the fixed
    // UserStrategyAccount implementation (provenance checked in step 2), and executeBatch, the
    // only caller, is nonReentrant. The flagged cross-function readers are `claimHeldOutput`
    // (nonReentrant) and `rescueTokens` (owner-only), neither of which an account can reach.
    // slither-disable-next-line reentrancy-no-eth
    function _distributeOutput(
        address targetAsset,
        uint256 distributable,
        PullResult memory r
    ) internal returns (uint256 held) {
        uint256 distributed = 0;
        for (uint256 i = 0; i < r.count; i++) {
            uint256 share;
            if (i == r.count - 1) {
                share = distributable - distributed;
            } else {
                share = distributable * r.amounts[i] / r.actualTotal;
                distributed += share;
            }
            // Transfer the share to the account, then notify it so it forwards the asset to the
            // strategy owner. A transfer the token refuses holds the share here instead of
            // reverting every other account's purchase with it. The account is not notified: it
            // never received the share, and the owner claims it from this contract.
            if (BoundedTransfer.tryTransfer(targetAsset, r.accounts[i], share, SHARE_TRANSFER_GAS, SHARE_HOLD_GAS)) {
                IReceiveOutput(r.accounts[i]).receiveOutput(targetAsset, share);
            } else {
                heldOutput[r.accounts[i]][targetAsset] += share;
                totalHeldOutput[targetAsset] += share;
                held += share;
                emit OutputHeld(r.accounts[i], targetAsset, share);
            }
        }
    }

    /// @notice Pay out output held for `account` because the token refused to transfer it there.
    /// @dev Only the account's owner may claim, and to an address they name: the account itself is
    ///      the address the token refused, so paying it again would usually fail again. Available
    ///      while paused, like every other exit. A record exists only for an account a batch
    ///      already accepted as a factory clone, so its `owner()` is the strategy owner. Reverts
    ///      `NothingToClaim` when nothing is held, and reverts, restoring the record, if the token
    ///      refuses `to`. State is cleared before the transfer.
    /// @param to Recipient of the held amount. Reverts `ZeroAddress` if zero.
    function claimHeldOutput(address account, address asset, address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = heldOutput[account][asset];
        if (amount == 0) revert NothingToClaim();
        if (msg.sender != IStrategyOwner(account).owner()) revert Unauthorized();
        heldOutput[account][asset] = 0;
        totalHeldOutput[asset] -= amount;
        emit HeldOutputClaimed(account, asset, to, amount);
        IERC20(asset).safeTransfer(to, amount);
    }

    /// @dev Pay the batch's fees to the current treasury in one transfer, or retain them if the
    ///      treasury cannot receive USDC. The whole fee is treasury income with no per-account
    ///      split, so no per-account remainder can strand fee dust. The transfer is routed through
    ///      the external `payFee` so its failure is catchable: a library `safeTransfer` reverts and
    ///      cannot be wrapped in try/catch inline. On failure the fee is added to `accruedFees`
    ///      (recoverable later with `flushFees`) instead of reverting the batch. Returns the amount
    ///      retained this batch - 0 when the treasury was paid - which the caller folds into the
    ///      closing balance assert so it stays exact.
    // The external call here is `this.payFee`, a self-call whose only effect is a USDC transfer to
    // the treasury; it cannot re-enter, both because its sole caller executeBatch is nonReentrant and
    // because payFee is callable only by this contract. The `accruedFees` write and FeeAccrued emit
    // in the catch are therefore not a reentrancy hazard; the flagged shape is the try/catch alone.
    // slither-disable-next-line reentrancy-events,reentrancy-benign,reentrancy-no-eth
    function _collectFee(uint256 totalFee) internal returns (uint256 retained) {
        address treasury = factory.treasury();
        try this.payFee(treasury, totalFee) {
            return 0;
        } catch {
            accruedFees += totalFee;
            emit FeeAccrued(treasury, totalFee);
            return totalFee;
        }
    }

    /// @notice Fee transfer, external only so `_collectFee` can wrap it in try/catch; a
    ///         library `safeTransfer` cannot be caught inline. Callable solely by this contract, so
    ///         it is not an independent way to move USDC out of the executor.
    function payFee(address to, uint256 amount) external {
        if (msg.sender != address(this)) revert Unauthorized();
        usdc.safeTransfer(to, amount);
    }

    /// @notice Pay out fees retained because the treasury could not be paid at execution time.
    /// @dev Guardian-gated and instant, like the other operational recoveries: it cannot misdirect
    ///      funds because it always pays the current `factory.treasury()`, and it moves treasury
    ///      income, not user funds. Reverts (restoring `accruedFees`, since the zeroing is rolled
    ///      back with it) if the treasury still cannot receive USDC, so a premature flush is a
    ///      harmless no-op rather than a way to lose the retained fees. Reverts `NothingToFlush`
    ///      when nothing is retained.
    function flushFees() external onlyGuardian nonReentrant {
        uint256 amount = accruedFees;
        if (amount == 0) revert NothingToFlush();
        address treasury = factory.treasury();
        accruedFees = 0;
        usdc.safeTransfer(treasury, amount);
        emit FeesFlushed(treasury, amount);
    }

    /// @dev Admin is two-tier. The owner is intended to be a TimelockController, so anything that
    ///      could redirect funds - the router, the oracle, the asset allowlist, rescueTokens - is
    ///      delayed and publicly queued before it can land. `onlyGuardian` is instant and deliberately
    ///      limited to the actions a delay would break: pausing, and rotating the executor, plus
    ///      the `flushFees` recovery, which can only pay the treasury. Reverts `NotGuardian`.
    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    /// @notice Switch automation provider by updating the executor address.
    /// @dev Guardian-gated and instant: the keeper key is the most likely credential to leak, and a
    ///      multi-day rotation window is not a usable incident response. Safe to leave instant
    ///      because a rogue executor alone cannot drain - the oracle floor and the closing balance
    ///      assert both rest on owner-controlled config that stays timelocked. Reverts
    ///      `ZeroAddress` for a zero address.
    function setExecutor(address _executor) external onlyGuardian {
        if (_executor == address(0)) revert ZeroAddress();
        executor = _executor;
        emit ExecutorSet(_executor);
    }

    /// @notice Update the SwapRouter the executor routes swaps through.
    function setSwapRouter(address _swapRouter) external onlyOwner {
        if (_swapRouter == address(0)) revert ZeroAddress();
        swapRouter = ISwapAdapter(_swapRouter);
        emit SwapRouterSet(_swapRouter);
    }

    /// @notice Add or remove an asset from the batch-execution allowlist.
    /// @dev Only whitelist an asset that also has oracle coverage configured in `priceOracle`;
    ///      otherwise the oracle's quote reverts and so does executeBatch, so an unprotected asset
    ///      cannot trade.
    function setWhitelistedAsset(address asset, bool whitelisted) external onlyOwner {
        whitelistedAssets[asset] = whitelisted;
        emit AssetWhitelisted(asset, whitelisted);
    }

    /// @notice Rotate the guardian. Owner-gated, so it inherits the timelock delay.
    /// @dev Deliberately NOT guardian-gated: a compromised guardian must not be able to entrench
    ///      itself by handing the role onward, and it must not be able to lock the owner out.
    function setGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert ZeroAddress();
        guardian = newGuardian;
        emit GuardianSet(newGuardian);
    }

    /// @notice Set the price oracle providing the non-bypassable per-asset output floor.
    ///         Required before any batch can execute. Any IPriceOracle implementation works, so
    ///         changing the price source needs no other change here.
    function setPriceOracle(address _priceOracle) external onlyOwner {
        if (_priceOracle == address(0)) revert ZeroAddress();
        priceOracle = IPriceOracle(_priceOracle);
        emit PriceOracleSet(_priceOracle);
    }

    /// @notice Rescue tokens sent directly to this contract outside of executeBatch.
    /// @dev Sends the whole unreserved balance of `token` to `to`. Never takes held output: that
    ///      belongs to strategy owners and leaves only through `claimHeldOutput`. Never takes
    ///      retained fees either: for USDC it also leaves `accruedFees`, which only `flushFees`
    ///      pays out, so the counter stays backed. Reverts `NothingToRescue` when no balance is
    ///      above what it leaves.
    function rescueTokens(address token, address to) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 reserved = totalHeldOutput[token];
        if (token == address(usdc)) reserved += accruedFees;
        if (balance <= reserved) revert NothingToRescue();
        uint256 bal = balance - reserved;
        IERC20(token).safeTransfer(to, bal);
        emit TokensRescued(token, to, bal);
    }

    /// @notice Pause batch execution. Does not affect user withdrawals.
    /// @dev Guardian-gated and instant: a delayed emergency stop is worse than no role split at
    ///      all. Pausing blocks new batches only - `withdraw()` on every account stays available,
    ///      which is what makes "pause, then let users leave" a real escape hatch.
    function pause() external onlyGuardian { _pause(); }
    /// @notice Resume batch execution after a pause.
    function unpause() external onlyGuardian { _unpause(); }
}

interface IAuthorisedPull {
    /// @notice Transfers the account's contribution and any yield fee it owes to the caller.
    /// @param amount USDC the batch asks this account to contribute.
    /// @return pulled   The account's contribution, at most `amount` and short by at most the venue
    ///                  rounding tolerance. This is the only part that is swapped and distributed.
    /// @return yieldFee Yield fee the account settled in the same transfer. Treasury income;
    ///                  never part of `actualTotal`, the swap, the oracle floor or pro-rata.
    function authorisedPull(uint256 amount, uint256 nonce)
        external
        returns (uint256 pulled, uint256 yieldFee);
}

interface ITargetAsset {
    function targetAsset() external view returns (address);
}

interface IStrategyOwner {
    function owner() external view returns (address);
}

/// @notice Tells a UserStrategyAccount it has received its share, so it forwards it to its owner.
interface IReceiveOutput {
    function receiveOutput(address asset, uint256 amount) external;
}

interface ISwapRouter {
    function swap(address asset, uint256 amountIn, uint256 minAmountOut) external returns (uint256);
}
