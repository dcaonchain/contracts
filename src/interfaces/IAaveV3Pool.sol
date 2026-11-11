// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Minimal Aave V3 Pool interface - only functions used by AaveV3YieldAdapter. `withdraw` treats
// `amount == type(uint256).max` as the caller's whole aToken balance and returns the amount sent.
interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}
