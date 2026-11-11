// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Minimal Uniswap V3 SwapRouter02 interface - only functions used by UniswapV3Adapter. The param
// structs follow SwapRouter02, which has no `deadline` field; the original Uniswap V3 SwapRouter
// does, so its selectors differ and it is not compatible with this interface.
interface IUniswapV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut);
    function exactInput(ExactInputParams calldata params) external returns (uint256 amountOut);
}
