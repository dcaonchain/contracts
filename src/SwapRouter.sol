// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/ISwapAdapter.sol";

/// @notice Routes USDC-to-asset swaps from BatchExecutor to the adapter registered for each asset.
/// @dev BatchExecutor holds no routing knowledge; it only calls `swap` here. Adding a DEX means
///      deploying a new adapter and one `setAssetAdapter` call. Only BatchExecutor may call `swap`;
///      every setter is owner-only, and ownership moves by the two-step OpenZeppelin handover.
///      The router holds no funds between calls: each swap pulls exactly `amountIn` USDC, hands it to
///      the adapter, and forwards the adapter's output to BatchExecutor in the same call.
contract SwapRouter is Ownable2Step {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice `swap` was called by an address other than `batchExecutor`.
    error Unauthorized();
    error NoAdapterForAsset(address asset);
    error ZeroAmount();
    error ZeroAddress();
    /// @notice The adapter reverted the forwarded route-configuration call.
    error RouteConfigFailed();
    /// @notice The adapter does not expose a readable `usdc()` getter returning one address.
    error AdapterMissingUsdc();

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice The only address allowed to call `swap`.
    address public batchExecutor;
    /// @notice The swap adapter registered for each target asset; `address(0)` if none.
    mapping(address => ISwapAdapter) public adapters;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event AdapterSet(address indexed asset, address indexed adapter);
    /// @notice Emitted when the authorized BatchExecutor is set, including at construction.
    event BatchExecutorSet(address indexed batchExecutor);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address _batchExecutor, address _owner) Ownable(_owner) {
        if (_batchExecutor == address(0)) revert ZeroAddress();
        batchExecutor = _batchExecutor;
        emit BatchExecutorSet(_batchExecutor);
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    /// @notice Registers or replaces the adapter that swaps USDC into `asset`. Owner only.
    /// @dev The adapter must expose `usdc()` and must accept `swap` calls from this router, or every
    ///      swap for `asset` reverts. Reverts `ZeroAddress` if either argument is zero.
    function setAssetAdapter(address asset, address adapter) external onlyOwner {
        if (asset == address(0) || adapter == address(0)) revert ZeroAddress();
        adapters[asset] = ISwapAdapter(adapter);
        emit AdapterSet(asset, adapter);
    }

    /// @notice Sets the Uniswap V3 route for `asset` on `adapter`. Owner only.
    /// @dev Forwards to `UniswapV3Adapter.setRoute`, which accepts calls only from this router.
    ///      Reverts `RouteConfigFailed` if the adapter reverts; its revert data is discarded. A call to
    ///      an address with no code succeeds, so a wrong `adapter` address is not detected here.
    /// @param fee Fee tier of the pool that outputs `asset` (the only pool on a direct route).
    /// @param hopToken Intermediate token for a two-hop route, or `address(0)` for a direct route.
    /// @param hopFee Fee tier of the USDC-to-`hopToken` pool; ignored on a direct route.
    function configureUniswapRoute(address asset, address adapter, uint24 fee, address hopToken, uint24 hopFee)
        external onlyOwner
    {
        if (asset == address(0) || adapter == address(0)) revert ZeroAddress();
        (bool ok,) = adapter.call(
            abi.encodeWithSignature("setRoute(address,uint24,address,uint24)", asset, fee, hopToken, hopFee)
        );
        if (!ok) revert RouteConfigFailed();
    }

    /// @notice Sets the Aerodrome route for `asset` on `adapter`. Owner only.
    /// @dev Forwards to `AerodromeAdapter.setRoute`, with the same failure behavior as
    ///      `configureUniswapRoute`.
    /// @param stable True for an Aerodrome stable pool, false for a volatile pool.
    /// @param poolFactory Aerodrome pool factory that deployed the USDC/`asset` pool.
    function configureAerodromeRoute(address asset, address adapter, bool stable, address poolFactory)
        external onlyOwner
    {
        if (asset == address(0) || adapter == address(0)) revert ZeroAddress();
        (bool ok,) = adapter.call(
            abi.encodeWithSignature("setRoute(address,bool,address)", asset, stable, poolFactory)
        );
        if (!ok) revert RouteConfigFailed();
    }

    /// @notice Replaces the address allowed to call `swap`. Owner only.
    /// @dev The previous BatchExecutor loses swap access immediately. Reverts `ZeroAddress` if zero.
    function setBatchExecutor(address _batchExecutor) external onlyOwner {
        if (_batchExecutor == address(0)) revert ZeroAddress();
        batchExecutor = _batchExecutor;
        emit BatchExecutorSet(_batchExecutor);
    }

    // -------------------------------------------------------------------------
    // Swap
    // -------------------------------------------------------------------------

    /// @notice Swaps `amountIn` USDC from BatchExecutor into `asset` and returns the output to it.
    /// @dev Only `batchExecutor` may call. The caller must have approved this router for `amountIn`
    ///      USDC. Reverts `ZeroAmount`, `NoAdapterForAsset`, `AdapterMissingUsdc`, or whatever the
    ///      adapter reverts with, including a DEX revert when output is below `minAmountOut`.
    /// @param amountIn USDC to swap, in USDC base units.
    /// @param minAmountOut Minimum `asset` output, enforced by the adapter's DEX call.
    /// @return amountOut Amount of `asset` transferred to the caller, as reported by the adapter.
    function swap(address asset, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        if (msg.sender != batchExecutor) revert Unauthorized();
        if (amountIn == 0) revert ZeroAmount();

        ISwapAdapter adapter = adapters[asset];
        if (address(adapter) == address(0)) revert NoAdapterForAsset(asset);

        // The adapter pulls the full `amountIn`, so this allowance is consumed and returns to zero.
        IERC20 usdc = _usdcFromAdapter(adapter);
        usdc.safeTransferFrom(msg.sender, address(this), amountIn);
        usdc.forceApprove(address(adapter), amountIn);

        amountOut = adapter.swap(asset, amountIn, minAmountOut);

        // Forwards the reported amount, not a measured balance: the adapter transfers `amountOut` to
        // this router before returning, and the router holds no other funds to cover a shortfall.
        IERC20(asset).safeTransfer(msg.sender, amountOut);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @dev Reads the input token from the adapter itself, so the router stores no USDC address and
    ///      cannot disagree with an adapter about it. Uses a low-level staticcall because
    ///      `ISwapAdapter` does not declare `usdc()`. Reverts `AdapterMissingUsdc` if the call fails
    ///      or does not return exactly one word.
    function _usdcFromAdapter(ISwapAdapter adapter) internal view returns (IERC20) {
        (bool ok, bytes memory data) = address(adapter).staticcall(abi.encodeWithSignature("usdc()"));
        if (!ok || data.length != 32) revert AdapterMissingUsdc();
        return IERC20(abi.decode(data, (address)));
    }
}
