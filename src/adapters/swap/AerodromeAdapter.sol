// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../interfaces/ISwapAdapter.sol";
import "../../interfaces/IAerodromeRouter.sol";

/// @notice Swaps USDC into a target asset through Aerodrome, on behalf of SwapRouter only.
/// @dev An alternative venue for assets whose Uniswap V3 liquidity is insufficient. Each route is a
///      single USDC/asset pool. Routes are set per asset through SwapRouter, whose owner configures
///      them. The adapter holds no funds between calls: it pulls exactly `amountIn`, swaps all of it,
///      and sends the whole output back to SwapRouter in the same call.
contract AerodromeAdapter is ISwapAdapter {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice The caller is not `swapRouter`.
    error Unauthorized();
    /// @notice No route is set for `asset` (its `factory` is zero).
    error AssetNotConfigured(address asset);
    error ZeroAmount();
    error ZeroOutput();

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    struct RouteConfig {
        // True for a stable pool, false for a volatile pool.
        bool stable;
        // Aerodrome pool factory that deployed the pool; address(0) = not configured.
        address factory;
    }

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice The Aerodrome router this adapter trades through.
    IAerodromeRouter public immutable router;
    IERC20 public immutable usdc;
    /// @notice The SwapRouter contract; the only address allowed to call `setRoute` and `swap`.
    address public immutable swapRouter;

    mapping(address => RouteConfig) public routes;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event RouteSet(address indexed asset, bool stable, address factory);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @dev Arguments are not checked for zero; a zero address leaves the adapter unusable.
    constructor(address _router, address _usdc, address _swapRouter) {
        router = IAerodromeRouter(_router);
        usdc = IERC20(_usdc);
        swapRouter = _swapRouter;
    }

    // -------------------------------------------------------------------------
    // Configuration
    // -------------------------------------------------------------------------

    /// @notice Sets or replaces the route for `asset`. Callable only by `swapRouter`, which exposes it
    ///         to its owner as `configureAerodromeRoute`.
    /// @dev Values are not validated. Setting `factory` to zero disables swaps into `asset`.
    function setRoute(address asset, bool stable, address factory) external {
        if (msg.sender != swapRouter) revert Unauthorized();
        routes[asset] = RouteConfig(stable, factory);
        emit RouteSet(asset, stable, factory);
    }

    // -------------------------------------------------------------------------
    // ISwapAdapter
    // -------------------------------------------------------------------------

    /// @notice Swaps `amountIn` USDC for `asset` and sends the whole output to SwapRouter.
    /// @dev Callable only by `swapRouter`, which must have approved this adapter for `amountIn`.
    ///      Reverts `ZeroAmount`, `AssetNotConfigured`, `ZeroOutput`, or with the Aerodrome revert
    ///      when the output is below `minAmountOut`.
    /// @param amountIn USDC to swap, in USDC base units.
    /// @param minAmountOut Minimum `asset` output, passed to Aerodrome as `amountOutMin`.
    /// @return amountOut Amount of `asset` received from Aerodrome and transferred to SwapRouter.
    // `amountOut == 0` is an exact-zero guard, not a balance-equality check.
    // slither-disable-next-line incorrect-equality
    function swap(address asset, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        if (msg.sender != swapRouter) revert Unauthorized();
        if (amountIn == 0) revert ZeroAmount();

        RouteConfig memory route = routes[asset];
        if (route.factory == address(0)) revert AssetNotConfigured(asset);

        usdc.safeTransferFrom(msg.sender, address(this), amountIn);
        usdc.forceApprove(address(router), amountIn);

        IAerodromeRouter.Route[] memory path = new IAerodromeRouter.Route[](1);
        path[0] = IAerodromeRouter.Route({
            from: address(usdc),
            to: asset,
            stable: route.stable,
            factory: route.factory
        });

        // A deadline of `block.timestamp` disables the router's deadline check. The swap runs inside
        // the caller's transaction, so `minAmountOut` is the price protection.
        uint256[] memory amounts = router.swapExactTokensForTokens(
            amountIn,
            minAmountOut,
            path,
            address(this),
            block.timestamp
        );

        // Aerodrome returns the input amount followed by each hop's output; the last entry is the
        // final output.
        amountOut = amounts[amounts.length - 1];
        if (amountOut == 0) revert ZeroOutput();
        IERC20(asset).safeTransfer(msg.sender, amountOut);
    }
}
