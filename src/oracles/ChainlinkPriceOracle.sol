// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../interfaces/IPriceOracle.sol";
import "../interfaces/IChainlinkAggregator.sol";

/// @notice IPriceOracle backed by direct Chainlink `<asset>/USD` price feeds. Returns a
///         conservative minimum output for a USDC input, which BatchExecutor enforces as a slippage
///         floor the executor cannot bypass.
/// @dev All feed addresses are set by the owner; none are hardcoded. On an L2 such as Base, the
///      Chainlink sequencer-uptime check runs before any price is trusted. USDC is valued at $1:
///      the result is a conservative sanity floor, not an exact quote, and the per-asset slippage
///      haircut absorbs USDC peg deviation and routing cost.
/// @dev Only direct `<asset>/USD` feeds are supported; this contract does not compose feeds. An
///      asset without a reliable direct USD feed is priced by ComposedPriceOracle behind an
///      OracleDispatcher, or left unconfigured here so that its quotes revert.
contract ChainlinkPriceOracle is IPriceOracle, Ownable2Step {
    error ZeroAddress();
    error UnsupportedAsset(address asset);
    /// @notice The computed floor rounds to zero for `usdcIn`, which would give no protection.
    error ZeroQuote(address asset, uint256 usdcIn);
    /// @notice The feed returned a zero or negative answer.
    error InvalidPrice(int256 answer);
    /// @notice The feed's latest round has no `updatedAt` timestamp.
    error RoundNotComplete();
    /// @notice The latest answer was carried over from an earlier round.
    error StaleRound(uint80 roundId, uint80 answeredInRound);
    /// @notice The feed answer is older than `maxStaleness` seconds. Also raised by `setAssetFeed`,
    ///         as `StalePrice(0, 0)`, when its `maxStaleness` argument is zero.
    error StalePrice(uint256 updatedAt, uint256 maxStaleness);
    error StalenessTooHigh(uint32 maxStaleness, uint32 cap);
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

    struct AssetFeed {
        address feed;          // Chainlink <asset>/USD aggregator (0 = unsupported)
        uint8   assetDecimals; // target asset token decimals (constant per token)
        uint8   feedDecimals;  // cached feed answer decimals
        uint32  maxStaleness;  // max age of a feed answer, seconds
        uint16  slippageBps;   // conservative haircut applied to the oracle quote
    }

    uint32 public constant MAX_STALENESS = 7 days;
    /// @notice Upper bound on the per-asset haircut, in basis points (10%).
    uint16 public constant MAX_SLIPPAGE_BPS = 1000;
    uint256 public constant MIN_SEQUENCER_GRACE = 1 hours;

    uint8 public immutable usdcDecimals;

    mapping(address => AssetFeed) public assetFeeds;

    /// @notice Chainlink L2 sequencer-uptime feed. Zero, once configured, disables the check.
    address public sequencerUptimeFeed;
    /// @notice Seconds to wait after the sequencer comes back up before prices are trusted.
    uint256 public sequencerGracePeriod;
    /// @notice True once `setSequencerUptimeFeed` has been called. Quotes revert until then.
    bool public sequencerConfigured;

    event AssetFeedSet(address indexed asset, address indexed feed, uint8 assetDecimals, uint32 maxStaleness, uint16 slippageBps);
    event AssetFeedRemoved(address indexed asset);
    event SequencerFeedSet(address indexed feed, uint256 gracePeriod);

    /// @param _usdc  USDC token. Read once for its decimals; 6 is used if the call fails. Must be
    ///               non-zero.
    constructor(address _usdc, address _owner) Ownable(_owner) {
        if (_usdc == address(0)) revert ZeroAddress();
        (bool ok, bytes memory data) = _usdc.staticcall(abi.encodeWithSignature("decimals()"));
        usdcDecimals = (ok && data.length >= 32) ? abi.decode(data, (uint8)) : 6;
    }

    /// @notice Configure (or update) the Chainlink USD feed backing `asset`. Owner only.
    /// @dev Caches the feed's decimals; `quoteMinOut` reverts if the feed later reports different
    ///      decimals, until the owner calls this again.
    /// @param asset         Target asset. Must be non-zero.
    /// @param feed          Chainlink <asset>/USD aggregator. Must be non-zero.
    /// @param assetDecimals Target asset token decimals. Must match the token's `decimals()`.
    /// @param maxStaleness  Max accepted age of a feed answer (seconds); in (0, MAX_STALENESS].
    /// @param slippageBps   Conservative haircut on the oracle quote; <= MAX_SLIPPAGE_BPS.
    function setAssetFeed(address asset, address feed, uint8 assetDecimals, uint32 maxStaleness, uint16 slippageBps)
        external
        onlyOwner
    {
        if (asset == address(0) || feed == address(0)) revert ZeroAddress();
        if (maxStaleness == 0) revert StalePrice(0, 0);
        if (maxStaleness > MAX_STALENESS) revert StalenessTooHigh(maxStaleness, MAX_STALENESS);
        if (slippageBps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh(slippageBps, MAX_SLIPPAGE_BPS);

        uint8 actualAssetDecimals = IERC20Metadata(asset).decimals();
        if (assetDecimals != actualAssetDecimals) {
            revert DecimalsMismatch(asset, assetDecimals, actualAssetDecimals);
        }
        uint8 feedDecimals = IChainlinkAggregator(feed).decimals();
        assetFeeds[asset] = AssetFeed({
            feed: feed,
            assetDecimals: assetDecimals,
            feedDecimals: feedDecimals,
            maxStaleness: maxStaleness,
            slippageBps: slippageBps
        });
        emit AssetFeedSet(asset, feed, assetDecimals, maxStaleness, slippageBps);
    }

    /// @notice Remove oracle coverage for `asset`; later quotes revert `UnsupportedAsset`. Owner only.
    function removeAssetFeed(address asset) external onlyOwner {
        delete assetFeeds[asset];
        emit AssetFeedRemoved(asset);
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
    ///      period, a feed whose decimals changed, a non-positive, incomplete, carried-over or stale
    ///      answer, and a floor that rounds to zero. Both divisions round down, so the returned
    ///      floor is at most two base units below the exact value.
    // slither-disable-next-line divide-before-multiply,unused-return
    function quoteMinOut(address asset, uint256 usdcIn) external view returns (uint256 minOut) {
        _checkSequencer();

        AssetFeed memory f = assetFeeds[asset];
        if (f.feed == address(0)) revert UnsupportedAsset(asset);
        uint8 liveFeedDecimals = IChainlinkAggregator(f.feed).decimals();
        if (liveFeedDecimals != f.feedDecimals) {
            revert DecimalsMismatch(f.feed, f.feedDecimals, liveFeedDecimals);
        }

        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkAggregator(f.feed).latestRoundData();
        if (answer <= 0) revert InvalidPrice(answer);
        if (updatedAt == 0) revert RoundNotComplete();
        // Reject a carried-over answer from an earlier round (defensive; harmless on modern OCR
        // feeds where answeredInRound tracks roundId).
        if (answeredInRound < roundId) revert StaleRound(roundId, answeredInRound);
        if (block.timestamp - updatedAt > f.maxStaleness) revert StalePrice(updatedAt, f.maxStaleness);

        // Safe cast: `answer > 0` is checked above, so the int256 -> uint256 cast cannot wrap.
        // Decimal normalization (USDC ~ $1):
        //   expectedOut [asset base units]
        //     = usdcIn / 10^usdcDec            (USD value of the input)
        //       * 10^assetDec                  (to asset base units)
        //       / (answer / 10^feedDec)        (USD per asset)
        //   = usdcIn * 10^assetDec * 10^feedDec / (10^usdcDec * answer)
        uint256 price = uint256(answer);
        uint256 expectedOut =
            (usdcIn * (10 ** f.assetDecimals) * (10 ** f.feedDecimals)) / ((10 ** usdcDecimals) * price);

        // Conservative floor: expected output minus the per-asset slippage haircut.
        minOut = (expectedOut * (10000 - f.slippageBps)) / 10000;

        // Fail closed on a zero floor. Two truncations can compose - expectedOut flooring to 1, then
        // the haircut flooring 1 to 0 - so a valid, non-zero price can still round the floor to zero
        // at a sub-cent input. IPriceOracle forbids returning 0 as a silent "no protection"
        // fallback, so a zero here is an unsafe quote, not a permissive one.
        if (minOut == 0) revert ZeroQuote(asset, usdcIn);
    }

    /// @dev Chainlink L2 guidance: confirm the sequencer is up and the grace period has elapsed
    ///      before trusting any data feed. Sequencer feed answer: 0 = up, 1 = down; `startedAt`
    ///      marks when the current status began. Only `answer` and `startedAt` are read.
    ///      Reverts if the check was never configured; returns immediately if it was disabled.
    // slither-disable-next-line unused-return
    function _checkSequencer() internal view {
        if (!sequencerConfigured) revert SequencerNotConfigured();
        address feed = sequencerUptimeFeed;
        if (feed == address(0)) return; // explicitly disabled (L1 / local)

        (, int256 answer, uint256 startedAt, , ) = IChainlinkAggregator(feed).latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (startedAt == 0) revert SequencerDown(); // invalid/uninitialized round
        if (block.timestamp - startedAt <= sequencerGracePeriod) {
            revert SequencerGracePeriodNotOver(block.timestamp - startedAt, sequencerGracePeriod);
        }
    }
}
