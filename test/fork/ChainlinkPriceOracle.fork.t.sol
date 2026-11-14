// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/oracles/ChainlinkPriceOracle.sol";
import "../../src/interfaces/IChainlinkAggregator.sol";
import "../../src/SwapRouter.sol";
import "../../src/adapters/swap/UniswapV3Adapter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Base mainnet - tokens (passed as args, never hardcoded in contract logic)
address constant BASE_USDC  = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
address constant BASE_WETH  = 0x4200000000000000000000000000000000000006;
address constant BASE_CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

// Base mainnet - Chainlink feeds. Their identity is verified on chain below via description(), so a
// wrong constant here fails the suite rather than testing the wrong feed.
address constant WETH_USD_FEED  = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70; // "ETH / USD",   8 dec
address constant CBBTC_USD_FEED = 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D; // "CBBTC / USD", 8 dec
address constant SEQUENCER_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433; // L2 sequencer uptime

address constant UNISWAP_V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @dev `description()` is deliberately absent from `IChainlinkAggregator`, which carries only the
///      subset the oracle calls on chain. Declared locally so this test can read feed identity without
///      widening the oracle's interface.
interface IFeedDescription {
    function description() external view returns (string memory);
}

/// @notice Fork validation for the DIRECT-feed oracle, mirroring `ComposedPriceOracle.fork.t.sol`.
///
/// @dev A real swap must clear the oracle floor for **every** enabled asset. wstETH and cbETH are
///      covered by the composed fork suite. WETH and cbBTC route through `ChainlinkPriceOracle`, which
///      the unit suite exercises only against mocked feeds, and the end-to-end fork suite deliberately
///      swaps in a
///      `ManualPriceOracle` at roughly 0.1% of market so its runs stay deterministic and independent of
///      feed availability, which is a reasonable choice for that suite but means it proves the wiring
///      delivers rather than that the floor is survivable.
///
///      A strict staleness bound is used here (`maxStaleness = 3600`), not a generous one. A feed that
///      had gone stale at the pinned block would revert these tests rather than pass quietly, which is
///      the point.
contract ChainlinkPriceOracleForkTest is Test {
    ChainlinkPriceOracle internal oracle;
    SwapRouter internal swapRouter;
    UniswapV3Adapter internal uniAdapter;

    address internal batchExecutor = makeAddr("batchExecutor");
    address internal owner = makeAddr("owner");

    // Realistic per-asset oracle settings: a one-hour staleness bound and a 2% haircut.
    uint32 internal constant MAX_STALENESS = 3600; // 1h
    uint16 internal constant SLIPPAGE      = 200;  // 2%

    function setUp() public {
        // Pinned block for determinism. Set BASE_FORK_BLOCK to pin; 0 => latest.
        uint256 forkBlock = vm.envOr("BASE_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        } else {
            vm.createSelectFork(vm.envString("BASE_RPC_URL"), forkBlock);
        }
        emit log_named_uint("fork block", block.number);

        vm.startPrank(owner);
        oracle = new ChainlinkPriceOracle(BASE_USDC, owner);
        oracle.setSequencerUptimeFeed(SEQUENCER_FEED, 3600);
        oracle.setAssetFeed(BASE_WETH,  WETH_USD_FEED,  18, MAX_STALENESS, SLIPPAGE);
        oracle.setAssetFeed(BASE_CBBTC, CBBTC_USD_FEED, 8,  MAX_STALENESS, SLIPPAGE);

        // Routing: both are single-hop on Uniswap V3, WETH at the 3000 tier and cbBTC at 500.
        swapRouter = new SwapRouter(batchExecutor, owner);
        uniAdapter = new UniswapV3Adapter(UNISWAP_V3_ROUTER, BASE_USDC, address(swapRouter));
        swapRouter.setAssetAdapter(BASE_WETH,  address(uniAdapter));
        swapRouter.setAssetAdapter(BASE_CBBTC, address(uniAdapter));
        swapRouter.configureUniswapRoute(BASE_WETH,  address(uniAdapter), 3000, address(0), 0);
        swapRouter.configureUniswapRoute(BASE_CBBTC, address(uniAdapter), 500,  address(0), 0);
        vm.stopPrank();
    }

    // ── The feeds are the assets they are configured as ──────────────────────────

    /// A mislabelled feed is the failure this check exists for: an off-chain registry can name a
    /// STETH/ETH feed as wstETH, so identity is read from the feed itself.
    function test_fork_feedIdentityAndDecimals() public view {
        assertEq(IFeedDescription(WETH_USD_FEED).description(), "ETH / USD", "WETH feed identity");
        // Exact on-chain string, read rather than guessed: this feed reports "cbBTC / USD", with the
        // token's own casing, where the ETH feed reports "ETH / USD".
        assertEq(IFeedDescription(CBBTC_USD_FEED).description(), "cbBTC / USD", "cbBTC feed identity");
        assertEq(IChainlinkAggregator(WETH_USD_FEED).decimals(), 8, "ETH/USD must be 8 dec");
        assertEq(IChainlinkAggregator(CBBTC_USD_FEED).decimals(), 8, "CBBTC/USD must be 8 dec");
        assertEq(IDecimals(BASE_WETH).decimals(), 18, "WETH token must be 18 dec");
        assertEq(IDecimals(BASE_CBBTC).decimals(), 8, "cbBTC token must be 8 dec");
        assertEq(IDecimals(BASE_USDC).decimals(), 6, "USDC must be 6 dec");
    }

    // ── Floor matches the live feed arithmetic (no DEX dependency) ───────────────

    function test_fork_chainlinkPriceMatchesFeed_WETH() public view {
        _assertQuoteMatchesFeed(BASE_WETH, WETH_USD_FEED, 18, 1000e6);
    }

    function test_fork_chainlinkPriceMatchesFeed_cbBTC() public view {
        _assertQuoteMatchesFeed(BASE_CBBTC, CBBTC_USD_FEED, 8, 1000e6);
    }

    // ── End-to-end: a real swap at a realistic size clears the real floor ───────

    function test_fork_WETH_swapClearsChainlinkFloor() public {
        // Uniswap V3 3000 tier: 30 bps of the deviation below is the pool fee, by construction.
        _assertSwapClearsFloor(BASE_WETH, "WETH", 30);
    }

    function test_fork_cbBTC_swapClearsChainlinkFloor() public {
        // Uniswap V3 500 tier: 5 bps of the deviation is the pool fee.
        _assertSwapClearsFloorAtSize(BASE_CBBTC, "cbBTC 1,000 USDC", 5, 1000e6);
    }

    /// One point is not enough to call the 2% oracle haircut suitable for cbBTC. These larger probes
    /// use the same single-hop route and turn material depth deterioration into
    /// a failing check. They are measurements at one block, not permanent batch-size guarantees.
    function test_fork_cbBTC_10kSwapClearsChainlinkFloor() public {
        _assertSwapClearsFloorAtSize(BASE_CBBTC, "cbBTC 10,000 USDC", 5, 10_000e6);
    }

    function test_fork_cbBTC_50kSwapClearsChainlinkFloor() public {
        _assertSwapClearsFloorAtSize(BASE_CBBTC, "cbBTC 50,000 USDC", 5, 50_000e6);
    }

    /// An unconfigured asset must **revert**, never return a zero floor. A silent zero is the failure
    /// that makes every other check here meaningless, because a batch would then execute with no
    /// protection at all.
    ///
    /// A `floor > 1` assertion would prove only that the floor is not one base unit, not that it is
    /// not trivially low. The arithmetic tests above are what establish the floor's magnitude; this
    /// is the negative control.
    function test_fork_unconfiguredAssetRevertsRatherThanQuotingZero() public {
        address unconfigured = makeAddr("noFeedForThisAsset");
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceOracle.UnsupportedAsset.selector, unconfigured));
        oracle.quoteMinOut(unconfigured, 1000e6);
    }

    /// @param poolFeeBps The Uniswap tier the route uses. The realised price is expected to sit at
    ///        least this far below the feed mid, so the band below is derived from the route rather
    ///        than picked round.
    function _assertSwapClearsFloor(address asset, string memory label, uint256 poolFeeBps) internal {
        _assertSwapClearsFloorAtSize(asset, label, poolFeeBps, 1000e6);
    }

    function _assertSwapClearsFloorAtSize(
        address asset,
        string memory label,
        uint256 poolFeeBps,
        uint256 amountIn
    ) internal {
        uint256 oracleMinOut = oracle.quoteMinOut(asset, amountIn);

        deal(BASE_USDC, batchExecutor, amountIn);
        vm.startPrank(batchExecutor);
        IERC20(BASE_USDC).approve(address(swapRouter), amountIn);
        uint256 out = swapRouter.swap(asset, amountIn, 1);
        vm.stopPrank();

        emit log_named_string("asset", label);
        emit log_named_uint("floor   ", oracleMinOut);
        emit log_named_uint("realised", out);

        // The property that matters operationally: the floor must never block an honest swap.
        assertLe(oracleMinOut, out, "floor must be <= realised output");

        // And the band that makes this test able to fail. Compare the realised output against the
        // FEED MID (the floor with the 2% haircut removed) rather than against the floor itself, so
        // the tolerance can be derived from the route instead of picked round:
        //
        //   adverse side   = the pool's own fee, plus 50 bps for basis and price impact
        //   favourable side = 50 bps, since a route quoting well ABOVE the feed is also suspicious
        //
        // A +/-10% band, as in the composed suite, would admit a wrong but plausibly-priced feed:
        // cbBTC's real deviation is 51 bps, so 1000 bps of slack would check almost nothing.
        uint256 feedMid = oracleMinOut * 10000 / (10000 - SLIPPAGE);
        assertGe(
            out * 10000,
            feedMid * (10000 - (poolFeeBps + 50)),
            "realised output is further below the feed mid than the pool fee plus 50 bps explains"
        );
        assertLe(out * 10000, feedMid * 10050, "realised output is implausibly above the feed mid");
    }

    /// @dev Recompute the floor from the raw on-chain answer and assert the oracle matches exactly,
    ///      tying its output to a live feed value rather than to another of its own reads.
    function _assertQuoteMatchesFeed(
        address asset,
        address feed,
        uint8 assetDecimals,
        uint256 amountIn
    ) internal view {
        (, int256 answer, , , ) = IChainlinkAggregator(feed).latestRoundData();
        assertGt(answer, 0, "feed answer must be > 0");

        // feedDecimals 8, usdcDecimals 6.
        uint256 expectedOut =
            (amountIn * (10 ** assetDecimals) * (10 ** 8)) / ((10 ** 6) * uint256(answer));
        uint256 expectedFloor = expectedOut * (10000 - SLIPPAGE) / 10000;

        assertEq(oracle.quoteMinOut(asset, amountIn), expectedFloor, "oracle floor must match feed arithmetic");
    }
}
