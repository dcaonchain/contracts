// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../interfaces/IYieldAdapter.sol";
import "../../interfaces/IAaveV3Pool.sol";

/// @notice Deposits and withdraws the base token via Aave V3 on behalf of one UserStrategyAccount.
/// @dev Deployed once per chain as an immutable implementation and cloned per strategy by
///      DCAFactory (EIP-1167). Market addresses are implementation immutables that every clone shares
///      through delegatecall; only the bound `account` lives in clone storage. All external addresses
///      are injected at deploy time - no hardcoded chain addresses.
///
///      Position isolation is structural: each clone is its own address, so its aToken balance is
///      its own position and no clone can reach another's.
contract AaveV3YieldAdapter is IYieldAdapterImplementation, Initializable {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice The caller is not the bound `account` (always the case on an uninitialized clone).
    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    /// @notice Aave returned more than `YIELD_WITHDRAWAL_TOLERANCE` below the requested amount.
    error WithdrawalShortfall(uint256 requested, uint256 received);
    /// @notice Aave credited more than `YIELD_WITHDRAWAL_TOLERANCE` below the deposited amount.
    error DepositShortfall(uint256 deposited, uint256 credited);

    // -------------------------------------------------------------------------
    // Implementation immutables - chain-wide market configuration, shared by all clones
    // -------------------------------------------------------------------------

    IAaveV3Pool public immutable aavePool;
    /// @inheritdoc IYieldAdapterImplementation
    address public immutable baseToken;
    /// @notice The aToken Aave mints against `baseToken` for this market.
    address public immutable receiptToken;

    // -------------------------------------------------------------------------
    // Clone storage
    // -------------------------------------------------------------------------

    /// @inheritdoc IYieldAdapterImplementation
    address public account;

    // -------------------------------------------------------------------------
    // Constructor / initializer
    // -------------------------------------------------------------------------

    /// @dev Locks the implementation itself so only clones can be bound to an account.
    ///      Reverts `ZeroAddress` if any argument is zero.
    /// @param _baseToken The token supplied to and withdrawn from Aave; must equal the factory's base
    ///        token.
    constructor(address _aavePool, address _baseToken, address _receiptToken) {
        if (_aavePool == address(0) || _baseToken == address(0) || _receiptToken == address(0)) {
            revert ZeroAddress();
        }
        aavePool     = IAaveV3Pool(_aavePool);
        baseToken    = _baseToken;
        receiptToken = _receiptToken;
        _disableInitializers();
    }

    /// @notice Binds this clone to `_account`. Called by DCAFactory in the same transaction as the clone.
    /// @dev Callable once per clone, and never on the implementation. Reverts `ZeroAddress` if
    ///      `_account` is zero. An uninitialized clone has `account == address(0)`, which no caller
    ///      can match, so every operation on it reverts `Unauthorized` - it fails closed.
    /// @param _account The UserStrategyAccount this clone serves.
    function initialize(address _account) external initializer {
        if (_account == address(0)) revert ZeroAddress();
        account = _account;
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyAccount() {
        if (msg.sender != account) revert Unauthorized();
        _;
    }

    // -------------------------------------------------------------------------
    // IYieldAdapter
    // -------------------------------------------------------------------------

    /// @notice Deposits `amount` of the base token into Aave V3. Only the bound account may call, and
    ///         it must have approved this clone for `amount` first.
    /// @dev Enforces the interface's bounded-deposit postcondition. `safeTransferFrom` already makes
    ///      the pull half unconditional here - it moves exactly `amount` or reverts - so what is left
    ///      to check is that Aave actually credited a position against it. Reverts `ZeroAmount` or
    ///      `DepositShortfall`.
    ///
    ///      The bound is `credited >= amount - YIELD_WITHDRAWAL_TOLERANCE`, not equality. Base aUSDC
    ///      (aToken revision 5) floors both the scaled mint and the reported balance. Their
    ///      composition can credit two base units less than `amount` while its liquidity index is
    ///      between one and two RAY; `IYieldAdapter.sol` documents the algebra and the index ceiling.
    ///      Only the low side is the venue's obligation, so only that side is bounded here.
    ///
    ///      Measured as a delta across the supply rather than as an absolute balance, because a
    ///      clone's position is not empty on a second deposit and accrued interest makes even the
    ///      first one drift. `UserStrategyAccount.deposit` measures the same delta from its own
    ///      reading of `balanceOf`, so the guarantee does not rest on this check alone.
    // Static analysis flags reentrancy because `positionBefore` is read before `supply` and
    // `credited` is used in a condition after it, so a reentrant callee could make the pre-read
    // stale. It is not exploitable: `aavePool` is an immutable Aave V3 Pool injected at deploy,
    // `supply` makes no callback into this adapter, and this function is `onlyAccount` behind the
    // account's `nonReentrant` deposit. A stale `positionBefore` could only overstate `credited` and
    // weaken this check, never move funds, and the account checks the same bound afterwards.
    // slither-disable-next-line reentrancy-balance,reentrancy-benign,reentrancy-events
    function deposit(uint256 amount) external onlyAccount {
        if (amount == 0) revert ZeroAmount();
        uint256 positionBefore = IERC20(receiptToken).balanceOf(address(this));
        IERC20(baseToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(baseToken).forceApprove(address(aavePool), amount);
        aavePool.supply(baseToken, amount, address(this), 0);
        uint256 positionAfter = IERC20(receiptToken).balanceOf(address(this));
        // Clamped rather than a bare subtraction: a venue whose reported position DROPS across its
        // own deposit must report zero credit and revert, not panic on an underflow.
        uint256 credited = positionAfter > positionBefore ? positionAfter - positionBefore : 0;
        if (credited + YIELD_WITHDRAWAL_TOLERANCE < amount) revert DepositShortfall(amount, credited);
    }

    /// @notice Withdraws `amount` of the base token from Aave V3 to the bound account. Only that
    ///         account may call.
    /// @dev Reverts `ZeroAmount`, or `WithdrawalShortfall` when Aave returns more than
    ///      `YIELD_WITHDRAWAL_TOLERANCE` below `amount`. Aave V3 can report the aToken balance below
    ///      the supplied amount after its two floor operations, and it reverts a request above the
    ///      balance. Requesting `min(amount, aTokenBalance)` keeps a tolerated rounding shortfall from
    ///      reverting inside Aave, and the tolerance check on the result still rejects a real one.
    /// @return received Base-token amount Aave reports it sent to the account.
    // Not exploitable reentrancy: the callee is the immutable Aave V3 Pool, the caller is the
    // account behind `onlyAccount` and its own `nonReentrant`, and the result is Aave's return value,
    // not a re-read balance.
    // slither-disable-next-line reentrancy-balance
    function withdraw(uint256 amount) external onlyAccount returns (uint256 received) {
        if (amount == 0) revert ZeroAmount();
        uint256 aBalance = IERC20(receiptToken).balanceOf(address(this));
        uint256 toWithdraw = aBalance < amount ? aBalance : amount;
        received = aavePool.withdraw(baseToken, toWithdraw, msg.sender);
        if (received + YIELD_WITHDRAWAL_TOLERANCE < amount) revert WithdrawalShortfall(amount, received);
    }

    /// @notice Withdraws the full position from Aave V3 to the bound account. Only that account may
    ///         call.
    /// @dev `type(uint256).max` is Aave V3's sentinel for the caller's whole aToken balance. An empty
    ///      position returns 0 without calling Aave, which reverts a zero-amount withdrawal.
    /// @return received Base-token amount Aave reports it sent to the account.
    // `balance == 0` is an exact-zero guard, not a balance-equality check.
    // slither-disable-next-line incorrect-equality
    function withdrawAll() external onlyAccount returns (uint256 received) {
        uint256 balance = IERC20(receiptToken).balanceOf(address(this));
        if (balance == 0) return 0;
        received = aavePool.withdraw(baseToken, type(uint256).max, msg.sender);
    }

    /// @notice Returns this clone's aToken balance (principal plus accrued yield), in base-token units.
    /// @dev The address argument is ignored: a clone serves exactly one account and reports its own
    ///      position, which is the position `withdraw` draws on.
    function balanceOf(address) external view returns (uint256) {
        return IERC20(receiptToken).balanceOf(address(this));
    }
}
