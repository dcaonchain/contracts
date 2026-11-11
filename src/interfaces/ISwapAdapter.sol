// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Swap interface implemented by each DEX adapter. SwapRouter exposes the same `swap`
///         signature, and BatchExecutor calls the router through it.
/// @dev Swaps a fixed input of USDC into `asset`, enforcing `minAmountOut` slippage protection.
///      The implementation pulls `amountIn` USDC from the caller, which must have approved it, and
///      transfers `amountOut` of `asset` to the caller before returning.
interface ISwapAdapter {
    /// @notice Swaps `amountIn` USDC into `asset`, reverting if output is below `minAmountOut`.
    /// @param asset Target asset to acquire.
    /// @param amountIn Amount of USDC to swap in.
    /// @param minAmountOut Minimum acceptable output; the swap reverts below this (slippage bound).
    /// @return amountOut Actual amount of `asset` received.
    function swap(address asset, uint256 amountIn, uint256 minAmountOut) external returns (uint256 amountOut);
}
