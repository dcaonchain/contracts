// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal subset of the Chainlink AggregatorV3 interface used by ChainlinkPriceOracle and
///         ComposedPriceOracle.
/// @dev Also used for the L2 Sequencer Uptime Feed, which exposes the same shape (answer 0 = up).
interface IChainlinkAggregator {
    function decimals() external view returns (uint8);

    /// @notice Latest round of the feed. For a price feed `answer` is the price and `updatedAt` its
    ///         timestamp; for the sequencer-uptime feed `answer` is the status and `startedAt` the
    ///         time that status began.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
