// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Protocol price floor used by BatchExecutor as the lower bound on swap output that the
///         executor cannot bypass. Implementations derive a conservative minimum from a trusted
///         on-chain price source (e.g. Chainlink) the executor does not control.
interface IPriceOracle {
    /// @notice Minimum acceptable `asset` output for `usdcIn` USDC (USDC base units), after a
    ///         conservative slippage haircut.
    /// @dev MUST revert if `asset` is unsupported or the price source is unsafe (stale, zero,
    ///      sequencer down, etc.) - never return 0 as a silent "no protection" fallback.
    /// @param asset  The target asset being purchased.
    /// @param usdcIn USDC actually being spent on the swap (USDC base units).
    /// @return minOut Minimum `asset` base units the swap must return.
    function quoteMinOut(address asset, uint256 usdcIn) external view returns (uint256 minOut);
}
