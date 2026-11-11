// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Minimal Aerodrome Router interface - different ABI from Uniswap V3
interface IAerodromeRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}
