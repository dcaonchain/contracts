// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "../interfaces/IPriceOracle.sol";

/// @notice Owner-maintained IPriceOracle for chains/environments without verified Chainlink feed
///         coverage (e.g. Base Sepolia, local tests). The owner sets a conservative per-asset
///         output rate; quotes revert for unconfigured assets - never silently returning 0.
/// @dev This is a deliberate fallback: it trusts the owner-set rate rather than a live feed, so
///      on mainnet ChainlinkPriceOracle should be used instead. BatchExecutor only knows
///      IPriceOracle, so swapping between the two needs no BatchExecutor change.
contract ManualPriceOracle is IPriceOracle, Ownable2Step {
    error UnsupportedAsset(address asset);
    error ZeroAddress();
    /// @notice The computed floor rounds to zero for `usdcIn`, which would give no protection.
    error ZeroQuote(address asset, uint256 usdcIn);

    /// @notice Minimum target-asset base units accepted per 1 USDC base unit, scaled by RATE_SCALE.
    mapping(address => uint256) public minOutRatePerUsdc;

    uint256 public constant RATE_SCALE = 1e18;

    /// @notice Emitted when the rate for `asset` is set; a zero `rate` removes coverage.
    event RateSet(address indexed asset, uint256 rate);

    constructor(address _owner) Ownable(_owner) {}

    /// @notice Set the conservative output rate for `asset`. Pass 0 to remove coverage. Owner only.
    /// @param asset Target asset. Must be non-zero.
    /// @param rate  Minimum asset base units per USDC base unit, scaled by `RATE_SCALE`.
    function setRate(address asset, uint256 rate) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        minOutRatePerUsdc[asset] = rate;
        emit RateSet(asset, rate);
    }

    /// @inheritdoc IPriceOracle
    /// @dev Returns `usdcIn * rate / RATE_SCALE`, rounded down. Reverts on an unconfigured asset
    ///      and on a floor that rounds to zero.
    function quoteMinOut(address asset, uint256 usdcIn) external view returns (uint256 minOut) {
        uint256 rate = minOutRatePerUsdc[asset];
        if (rate == 0) revert UnsupportedAsset(asset);
        minOut = (usdcIn * rate) / RATE_SCALE;

        // Fail closed on a zero floor. A non-zero rate can still round the floor to zero for a
        // small `usdcIn`, which the `rate == 0` coverage check above does not catch. IPriceOracle
        // forbids returning 0 as a silent "no protection" fallback.
        if (minOut == 0) revert ZeroQuote(asset, usdcIn);
    }
}
