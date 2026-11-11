// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../interfaces/ISwapAdapter.sol";
import "../../interfaces/IUniswapV3Router.sol";

/// @notice Swaps USDC into a target asset through Uniswap V3, on behalf of SwapRouter only.
/// @dev Supports a direct single-pool swap and a two-hop swap through one intermediate token
///      (e.g. USDC to WETH to wstETH). Routes are set per asset through SwapRouter, whose owner
///      configures them. All addresses are injected at construction; none is hardcoded.
///      The adapter holds no funds between calls: it pulls exactly `amountIn`, swaps all of it, and
///      sends the whole output back to SwapRouter in the same call.
contract UniswapV3Adapter is ISwapAdapter {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice The caller is not `swapRouter`.
    error Unauthorized();
    /// @notice No route is set for `asset` (its `fee` is zero).
    error AssetNotConfigured(address asset);
    error ZeroAmount();
    error ZeroOutput();

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    // Uniswap V3 route for one target asset. Fee tiers are in hundredths of a basis point
    // (e.g. 500, 3000, 10000).
    struct RouteConfig {
        // Tier of the pool that outputs the asset; the only pool on a direct route. 0 = not set.
        uint24 fee;
        // Intermediate token for a two-hop route; address(0) = direct swap.
        address hopToken;
        // Tier of the USDC-to-hopToken pool; used only when hopToken != address(0).
        uint24 hopFee;
    }

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice The Uniswap V3 swap router (SwapRouter02 interface) this adapter trades through.
    IUniswapV3Router public immutable router;
    IERC20 public immutable usdc;
    /// @notice The SwapRouter contract; the only address allowed to call `setRoute` and `swap`.
    address public immutable swapRouter;

    mapping(address => RouteConfig) public routes;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event RouteSet(address indexed asset, uint24 fee, address hopToken, uint24 hopFee);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @dev Arguments are not checked for zero; a zero address leaves the adapter unusable.
    constructor(address _router, address _usdc, address _swapRouter) {
        router = IUniswapV3Router(_router);
        usdc = IERC20(_usdc);
        swapRouter = _swapRouter;
    }

    // -------------------------------------------------------------------------
    // Configuration
    // -------------------------------------------------------------------------

    /// @notice Sets or replaces the route for `asset`. Callable only by `swapRouter`, which exposes it
    ///         to its owner as `configureUniswapRoute`.
    /// @dev Values are not validated. Setting `fee` to zero disables swaps into `asset`.
    function setRoute(address asset, uint24 fee, address hopToken, uint24 hopFee) external {
        if (msg.sender != swapRouter) revert Unauthorized();
        routes[asset] = RouteConfig(fee, hopToken, hopFee);
        emit RouteSet(asset, fee, hopToken, hopFee);
    }

    // -------------------------------------------------------------------------
    // ISwapAdapter
    // -------------------------------------------------------------------------

    /// @notice Swaps `amountIn` USDC for `asset` and sends the whole output to SwapRouter.
    /// @dev Callable only by `swapRouter`, which must have approved this adapter for `amountIn`.
    ///      Reverts `ZeroAmount`, `AssetNotConfigured`, `ZeroOutput`, or with the Uniswap revert when
    ///      the output is below `minAmountOut`.
    /// @param amountIn USDC to swap, in USDC base units.
    /// @param minAmountOut Minimum `asset` output, passed to Uniswap as `amountOutMinimum`.
    /// @return amountOut Amount of `asset` received from Uniswap and transferred to SwapRouter.
    function swap(address asset, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        if (msg.sender != swapRouter) revert Unauthorized();
        if (amountIn == 0) revert ZeroAmount();

        RouteConfig memory route = routes[asset];
        if (route.fee == 0) revert AssetNotConfigured(asset);

        usdc.safeTransferFrom(msg.sender, address(this), amountIn);
        usdc.forceApprove(address(router), amountIn);

        if (route.hopToken == address(0)) {
            amountOut = _swapDirect(asset, amountIn, minAmountOut, route.fee);
        } else {
            amountOut = _swapTwoHop(asset, amountIn, minAmountOut, route);
        }

        if (amountOut == 0) revert ZeroOutput();
        IERC20(asset).safeTransfer(msg.sender, amountOut);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @dev Single-pool exact-input swap. `sqrtPriceLimitX96 = 0` sets no price limit, so the whole
    ///      input is swapped and `minAmountOut` is the only price protection.
    function _swapDirect(address asset, uint256 amountIn, uint256 minAmountOut, uint24 fee)
        internal
        returns (uint256)
    {
        return router.exactInputSingle(
            IUniswapV3Router.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: asset,
                fee: fee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @dev Two-pool exact-input swap, USDC to `hopToken` to `asset`. `minAmountOut` bounds the
    ///      final output only; the intermediate amount is unbounded.
    function _swapTwoHop(address asset, uint256 amountIn, uint256 minAmountOut, RouteConfig memory route)
        internal
        returns (uint256)
    {
        // Uniswap V3 packed path: 20-byte token, 3-byte fee, 20-byte token, 3-byte fee, 20-byte
        // token, in swap order. `abi.encodePacked` of a uint24 is exactly 3 bytes.
        bytes memory path = abi.encodePacked(
            address(usdc),
            route.hopFee,
            route.hopToken,
            route.fee,
            asset
        );

        return router.exactInput(
            IUniswapV3Router.ExactInputParams({
                path: path,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: minAmountOut
            })
        );
    }
}
