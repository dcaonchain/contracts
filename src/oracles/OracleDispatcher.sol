// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "../interfaces/IPriceOracle.sol";

/// @notice An `IPriceOracle` that routes each asset to its own underlying oracle, so `BatchExecutor`
///         (which holds a single `priceOracle`) can cover assets priced by different mechanisms.
///
/// @dev For example, an asset with a direct `<asset>/USD` feed routes to a `ChainlinkPriceOracle`,
///      while one priced as `asset/ETH * ETH/USD` routes to a `ComposedPriceOracle`. Keeping the two
///      pricing mechanisms in separate contracts - rather than as modes inside one oracle - isolates
///      their failure domains: a fault in the composed path can only affect composed assets, and it is
///      unambiguous which oracle priced a given asset.
///
/// @dev This contract holds NO pricing logic and performs NO sequencer/staleness checks itself - it is
///      a pure router. Each underlying oracle enforces its own sequencer-uptime gate, staleness, and
///      slippage. The dispatcher only resolves `asset -> oracle` and forwards the call; per the
///      `IPriceOracle` contract, a missing route reverts (never returns 0 as silent "no protection").
contract OracleDispatcher is IPriceOracle, Ownable2Step {
    error ZeroAddress();
    error UnsupportedAsset(address asset);
    /// @notice The routed oracle returned a zero floor for `usdcIn`, which would give no protection.
    error ZeroQuote(address asset, uint256 usdcIn);

    /// @notice Underlying oracle per asset. Zero means the asset is unsupported.
    mapping(address => IPriceOracle) public oracles;

    event AssetOracleSet(address indexed asset, address indexed oracle);
    event AssetOracleRemoved(address indexed asset);

    constructor(address _owner) Ownable(_owner) {}

    /// @notice Route quotes for `asset` to `oracle`, replacing any existing route. Owner only.
    /// @dev `oracle` must implement `IPriceOracle`; this is not checked on-chain.
    /// @param asset  Target asset. Must be non-zero.
    /// @param oracle Underlying oracle. Must be non-zero.
    function setAssetOracle(address asset, address oracle) external onlyOwner {
        if (asset == address(0) || oracle == address(0)) revert ZeroAddress();
        oracles[asset] = IPriceOracle(oracle);
        emit AssetOracleSet(asset, oracle);
    }

    /// @notice Remove the route for `asset`; later quotes revert `UnsupportedAsset`. Owner only.
    function removeAssetOracle(address asset) external onlyOwner {
        delete oracles[asset];
        emit AssetOracleRemoved(asset);
    }

    /// @inheritdoc IPriceOracle
    /// @dev Reverts on a missing route, propagates any revert from the routed oracle, and reverts
    ///      if the routed oracle returns zero.
    function quoteMinOut(address asset, uint256 usdcIn) external view returns (uint256 minOut) {
        IPriceOracle oracle = oracles[asset];
        if (address(oracle) == address(0)) revert UnsupportedAsset(asset);
        minOut = oracle.quoteMinOut(asset, usdcIn);
        // The dispatcher is itself an IPriceOracle, so the MUST binds the value it forwards, not only
        // the missing-route case above: a faulty routed oracle returning 0 must not slip through as a
        // silent "no protection" quote.
        if (minOut == 0) revert ZeroQuote(asset, usdcIn);
    }
}
