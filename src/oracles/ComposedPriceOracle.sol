// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../interfaces/IPriceOracle.sol";
import "../interfaces/IChainlinkAggregator.sol";

/// @notice IPriceOracle backed by a two-feed composition `asset/USD = (asset/ETH) * (ETH/USD)`, for
///         assets that have no direct `<asset>/USD` Chainlink feed on the target chain (e.g. wstETH,
///         cbETH on Base) but do have a market `<asset>/ETH` feed plus the shared `ETH/USD` feed.
///         Deployed alongside `ChainlinkPriceOracle` behind an `OracleDispatcher` (per-asset routing),
///         so the direct-feed and composed-feed code paths stay isolated and independently testable.
///
/// @dev SAFETY-CRITICAL CHOICE - MARKET vs EXCHANGE-RATE BASE FEED.
///      The base feed MUST be the *market* `<asset>/ETH` price (e.g. Chainlink "WSTETH / ETH"), not a
///      protocol *exchange-rate* feed (e.g. "wstETH-stETH Exchange Rate"). An exchange-rate feed
///      reports redemption value and does NOT fall during a market depeg, so composing it would keep
///      the reported asset price too high and the minimum output quantity too low. That silently
///      weakens protection rather than forcing legitimate swaps to revert. Only a market feed makes
///      this composition depeg-aware. The contract cannot tell the two apart on-chain; this is an
///      operator responsibility at config time.
///
/// @dev Cost of composition compared with the single-feed oracle:
///      - two feeds per asset means two staleness windows, two round-validity checks, two failure
///        modes;
///      - the shared ETH/USD feed is a single point of failure for every composed asset;
///      - compounded decimal normalization across three token/feed decimal sets.
///      Everything else (sequencer-uptime gate, slippage haircut, USDC valued at $1) matches
///      `ChainlinkPriceOracle` so the two can sit behind one `IPriceOracle` consumer. Errors match
///      too, except that feed errors carry the address of the feed that failed.
contract ComposedPriceOracle is IPriceOracle, Ownable2Step {
    error ZeroAddress();
    error UnsupportedAsset(address asset);
    /// @notice The computed floor rounds to zero for `usdcIn`, which would give no protection.
    error ZeroQuote(address asset, uint256 usdcIn);
    /// @notice `feed` returned a zero or negative answer.
    error InvalidPrice(address feed, int256 answer);
    /// @notice The latest round of `feed` has no `updatedAt` timestamp.
    error RoundNotComplete(address feed);
    /// @notice The latest answer of `feed` was carried over from an earlier round.
    error StaleRound(address feed, uint80 roundId, uint80 answeredInRound);
    /// @notice The answer of `feed` is older than `maxStaleness` seconds. Also raised by
    ///         `setComposedFeed`, with both numbers zero, when the staleness argument for `feed` is
    ///         zero.
    error StalePrice(address feed, uint256 updatedAt, uint256 maxStaleness);
    error StalenessTooHigh(address feed, uint32 maxStaleness, uint32 cap);
    error SlippageTooHigh(uint16 bps, uint16 cap);
    error DecimalsMismatch(address source, uint8 expected, uint8 actual);
    /// @notice A disabled sequencer check (zero feed) was given a non-zero grace period.
    error InvalidSequencerConfiguration(address feed, uint256 gracePeriod);
    /// @notice `setSequencerUptimeFeed` has never been called; quotes stay closed until it is.
    error SequencerNotConfigured();
    /// @notice The sequencer-uptime feed reports the sequencer down, or has no valid round.
    error SequencerDown();
    error SequencerGraceTooShort(uint256 gracePeriod, uint256 minimum);
    error SequencerGracePeriodNotOver(uint256 sinceUp, uint256 grace);

    /// @dev One composed route: asset/USD = (baseFeed: asset/INT) * (quoteFeed: INT/USD).
    ///      For wstETH/cbETH on Base, INT == ETH: baseFeed = market asset/ETH, quoteFeed = ETH/USD.
    struct ComposedFeed {
        address baseFeed;          // market <asset>/<INT> aggregator (0 = unsupported)
        address quoteFeed;         // <INT>/USD aggregator
        uint8   assetDecimals;     // target asset token decimals
        uint8   baseFeedDecimals;  // cached baseFeed answer decimals
        uint8   quoteFeedDecimals; // cached quoteFeed answer decimals
        uint32  baseMaxStaleness;  // max age of a baseFeed answer, seconds
        uint32  quoteMaxStaleness; // max age of a quoteFeed answer, seconds
        uint16  slippageBps;       // conservative haircut applied to the composed quote
    }

    uint32 public constant MAX_STALENESS = 7 days;
    /// @notice Upper bound on the per-asset haircut, in basis points (10%).
    uint16 public constant MAX_SLIPPAGE_BPS = 1000;
    uint256 public constant MIN_SEQUENCER_GRACE = 1 hours;

    uint8 public immutable usdcDecimals;

    mapping(address => ComposedFeed) public composedFeeds;

    /// @notice Chainlink L2 sequencer-uptime feed. Zero, once configured, disables the check.
    address public sequencerUptimeFeed;
    /// @notice Seconds to wait after the sequencer comes back up before prices are trusted.
    uint256 public sequencerGracePeriod;
    /// @notice True once `setSequencerUptimeFeed` has been called. Quotes revert until then.
    bool public sequencerConfigured;

    event ComposedFeedSet(
        address indexed asset,
        address indexed baseFeed,
        address indexed quoteFeed,
        uint8 assetDecimals,
        uint32 baseMaxStaleness,
        uint32 quoteMaxStaleness,
        uint16 slippageBps
    );
    event ComposedFeedRemoved(address indexed asset);
    event SequencerFeedSet(address indexed feed, uint256 gracePeriod);

    /// @param _usdc  USDC token. Read once for its decimals; 6 is used if the call fails. Must be
    ///               non-zero.
    constructor(address _usdc, address _owner) Ownable(_owner) {
        if (_usdc == address(0)) revert ZeroAddress();
        (bool ok, bytes memory data) = _usdc.staticcall(abi.encodeWithSignature("decimals()"));
        usdcDecimals = (ok && data.length >= 32) ? abi.decode(data, (uint8)) : 6;
    }

    /// @notice Configure (or update) the composed route backing `asset`. Owner only.
    /// @dev Caches both feeds' decimals; `quoteMinOut` reverts if either feed later reports
    ///      different decimals, until the owner calls this again.
    /// @param asset             Target asset. Must be non-zero.
    /// @param baseFeed          MARKET `<asset>/<INT>` aggregator (NOT an exchange-rate feed - see
    ///                          contract docs). Must be non-zero.
    /// @param quoteFeed         `<INT>/USD` aggregator (e.g. ETH/USD). Must be non-zero.
    /// @param assetDecimals     Target asset token decimals. Must match the token's `decimals()`.
    /// @param baseMaxStaleness  Max accepted age of a baseFeed answer (seconds); in (0, MAX_STALENESS].
    /// @param quoteMaxStaleness Max accepted age of a quoteFeed answer (seconds); in (0, MAX_STALENESS].
    /// @param slippageBps       Conservative haircut on the composed quote; <= MAX_SLIPPAGE_BPS.
    function setComposedFeed(
        address asset,
        address baseFeed,
        address quoteFeed,
        uint8 assetDecimals,
        uint32 baseMaxStaleness,
        uint32 quoteMaxStaleness,
        uint16 slippageBps
    ) external onlyOwner {
        if (asset == address(0) || baseFeed == address(0) || quoteFeed == address(0)) revert ZeroAddress();
        if (baseMaxStaleness == 0) revert StalePrice(baseFeed, 0, 0);
        if (quoteMaxStaleness == 0) revert StalePrice(quoteFeed, 0, 0);
        if (baseMaxStaleness > MAX_STALENESS) {
            revert StalenessTooHigh(baseFeed, baseMaxStaleness, MAX_STALENESS);
        }
        if (quoteMaxStaleness > MAX_STALENESS) {
            revert StalenessTooHigh(quoteFeed, quoteMaxStaleness, MAX_STALENESS);
        }
        if (slippageBps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh(slippageBps, MAX_SLIPPAGE_BPS);

        uint8 actualAssetDecimals = IERC20Metadata(asset).decimals();
        if (assetDecimals != actualAssetDecimals) {
            revert DecimalsMismatch(asset, assetDecimals, actualAssetDecimals);
        }
        composedFeeds[asset] = ComposedFeed({
            baseFeed: baseFeed,
            quoteFeed: quoteFeed,
            assetDecimals: assetDecimals,
            baseFeedDecimals: IChainlinkAggregator(baseFeed).decimals(),
            quoteFeedDecimals: IChainlinkAggregator(quoteFeed).decimals(),
            baseMaxStaleness: baseMaxStaleness,
            quoteMaxStaleness: quoteMaxStaleness,
            slippageBps: slippageBps
        });
        emit ComposedFeedSet(
            asset, baseFeed, quoteFeed, assetDecimals, baseMaxStaleness, quoteMaxStaleness, slippageBps
        );
    }

    /// @notice Remove oracle coverage for `asset`; later quotes revert `UnsupportedAsset`. Owner only.
    function removeComposedFeed(address asset) external onlyOwner {
        delete composedFeeds[asset];
        emit ComposedFeedRemoved(asset);
    }

    /// @notice Set the L2 sequencer-uptime feed and grace period. Owner only. Must be called once
    ///         before any quote succeeds.
    /// @dev Passing `feed == address(0)` with `gracePeriod == 0` disables the check, which is only
    ///      appropriate on L1 or in local tests.
    /// @param feed        Chainlink sequencer-uptime feed, or zero to disable the check.
    /// @param gracePeriod Seconds to wait after the sequencer is back up; at least
    ///                    `MIN_SEQUENCER_GRACE` when `feed` is set, and zero when it is not.
    function setSequencerUptimeFeed(address feed, uint256 gracePeriod) external onlyOwner {
        if (feed == address(0)) {
            if (gracePeriod != 0) revert InvalidSequencerConfiguration(feed, gracePeriod);
        } else if (gracePeriod < MIN_SEQUENCER_GRACE) {
            revert SequencerGraceTooShort(gracePeriod, MIN_SEQUENCER_GRACE);
        }
        sequencerUptimeFeed = feed;
        sequencerGracePeriod = gracePeriod;
        sequencerConfigured = true;
        emit SequencerFeedSet(feed, gracePeriod);
    }

    /// @inheritdoc IPriceOracle
    /// @dev Reverts on an unconfigured asset, a sequencer that is down or within its grace
    ///      period, either feed changing its decimals or returning a non-positive, incomplete,
    ///      carried-over or stale answer, and a floor that rounds to zero. Both divisions round
    ///      down, so the returned floor is at most two base units below the exact value.
    // slither-disable-next-line divide-before-multiply
    function quoteMinOut(address asset, uint256 usdcIn) external view returns (uint256 minOut) {
        _checkSequencer();

        ComposedFeed memory f = composedFeeds[asset];
        if (f.baseFeed == address(0)) revert UnsupportedAsset(asset);
        _validateDecimals(f.baseFeed, f.baseFeedDecimals);
        _validateDecimals(f.quoteFeed, f.quoteFeedDecimals);

        uint256 basePrice  = _readValidatedPrice(f.baseFeed,  f.baseMaxStaleness);   // asset/INT, baseFeedDecimals
        uint256 quotePrice = _readValidatedPrice(f.quoteFeed, f.quoteMaxStaleness);  // INT/USD,  quoteFeedDecimals

        // Decimal normalization (USDC ~ $1), composing two feeds:
        //   asset/USD price = (basePrice / 10^baseDec) * (quotePrice / 10^quoteDec)   [USD per asset]
        //   expectedOut [asset base units]
        //     = (usdcIn / 10^usdcDec) * 10^assetDec / (asset/USD price)
        //     = usdcIn * 10^assetDec * 10^baseDec * 10^quoteDec
        //       / (10^usdcDec * basePrice * quotePrice)
        uint256 expectedOut = (
            usdcIn
            * (10 ** f.assetDecimals)
            * (10 ** f.baseFeedDecimals)
            * (10 ** f.quoteFeedDecimals)
        ) / ((10 ** usdcDecimals) * basePrice * quotePrice);

        minOut = (expectedOut * (10000 - f.slippageBps)) / 10000;

        // Fail closed on a zero floor. Two truncations can compose - expectedOut flooring to 1, then
        // the haircut flooring 1 to 0 - so a valid, non-zero price can still round the floor to zero
        // at a sub-cent input. IPriceOracle forbids returning 0 as a silent "no protection" fallback.
        if (minOut == 0) revert ZeroQuote(asset, usdcIn);
    }

    function _validateDecimals(address source, uint8 expected) internal view {
        uint8 actual = IChainlinkAggregator(source).decimals();
        if (actual != expected) revert DecimalsMismatch(source, expected, actual);
    }

    /// @dev Read and validate one Chainlink feed; returns the positive price as uint256. Reverts on a
    ///      non-positive, incomplete, carried-over or stale answer. `startedAt` is not read.
    // slither-disable-next-line unused-return
    function _readValidatedPrice(address feed, uint32 maxStaleness) internal view returns (uint256) {
        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkAggregator(feed).latestRoundData();
        if (answer <= 0) revert InvalidPrice(feed, answer);
        if (updatedAt == 0) revert RoundNotComplete(feed);
        if (answeredInRound < roundId) revert StaleRound(feed, roundId, answeredInRound);
        if (block.timestamp - updatedAt > maxStaleness) revert StalePrice(feed, updatedAt, maxStaleness);
        return uint256(answer);
    }

    /// @dev Chainlink L2 guidance, identical to ChainlinkPriceOracle: confirm the sequencer is up
    ///      (answer 0) and the grace period since `startedAt` has elapsed before trusting any feed.
    ///      Only `answer` and `startedAt` are read. Reverts if the check was never configured;
    ///      returns immediately if it was disabled.
    // slither-disable-next-line unused-return
    function _checkSequencer() internal view {
        if (!sequencerConfigured) revert SequencerNotConfigured();
        address feed = sequencerUptimeFeed;
        if (feed == address(0)) return;

        (, int256 answer, uint256 startedAt, , ) = IChainlinkAggregator(feed).latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (startedAt == 0) revert SequencerDown();
        if (block.timestamp - startedAt <= sequencerGracePeriod) {
            revert SequencerGracePeriodNotOver(block.timestamp - startedAt, sequencerGracePeriod);
        }
    }
}
