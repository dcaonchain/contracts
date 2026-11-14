// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/oracles/ComposedPriceOracle.sol";
import "../../src/oracles/ChainlinkPriceOracle.sol";
import "../../src/oracles/OracleDispatcher.sol";
import "../../src/interfaces/IChainlinkAggregator.sol";
import "../../src/SwapRouter.sol";
import "../../src/adapters/swap/UniswapV3Adapter.sol";
import "../../src/adapters/swap/AerodromeAdapter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Base mainnet - tokens (passed as args, never hardcoded in contract logic)
address constant BASE_USDC   = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
address constant BASE_WETH   = 0x4200000000000000000000000000000000000006;
address constant BASE_WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
address constant BASE_CBETH  = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;

// Base mainnet - Chainlink feeds. Each feed's identity is checked on chain through `description()`.
address constant ETHUSD_FEED       = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70; // "ETH / USD",  8 dec
address constant WSTETH_ETH_MARKET = 0x43a5C292A453A3bF3606fa856197f09D7B74251a; // "WSTETH / ETH" market, 18 dec
address constant CBETH_ETH_MARKET  = 0x806b4Ac04501c29769051e42783cF04dCE41440b; // "CBETH / ETH" market, 18 dec
// NB: 0xf586…d5A0 is "STETH / ETH" (~1.0), NOT wstETH - do not use it for wstETH.
address constant SEQUENCER_FEED    = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433; // L2 sequencer uptime

// DEX routing
address constant UNISWAP_V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
address constant AERODROME_ROUTER  = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
address constant AERODROME_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

interface IDecimals {
    function decimals() external view returns (uint8);
}

interface IAggregatorDescription {
    function description() external view returns (string memory);
}

/// @notice Fork validation for the composed oracle: against REAL Base feeds + REAL DEX liquidity,
///         the conservative composed floor must be (a) > 0, (b) below the realised swap output, and
///         (c) close to it (so a decimals bug or a wrong/exchange-rate feed would fail loudly).
contract ComposedPriceOracleForkTest is Test {
    ComposedPriceOracle internal composed;
    SwapRouter internal swapRouter;
    UniswapV3Adapter internal uniAdapter;
    AerodromeAdapter internal aeroAdapter;

    address internal batchExecutor = makeAddr("batchExecutor");
    address internal owner = makeAddr("owner");

    // Realistic per-leg values. Deliberately NOT one shared window: the LST/ETH base legs update
    // roughly daily while ETH/USD updates in minutes, and a single window wide enough for the base leg
    // would accept a badly stale quote leg (86400 for both would be 24x looser on the quote leg).
    uint32 internal constant BASE_STALENESS  = 90000; // base leg, LST/ETH
    uint32 internal constant QUOTE_STALENESS = 3600;  // quote leg, ETH/USD
    uint16 internal constant SLIPPAGE  = 200;   // 2%

    function setUp() public {
        // Pinned block for determinism. Set BASE_FORK_BLOCK to pin; 0 => latest (first run).
        uint256 forkBlock = vm.envOr("BASE_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        } else {
            vm.createSelectFork(vm.envString("BASE_RPC_URL"), forkBlock);
        }
        emit log_named_uint("fork block", block.number);

        vm.startPrank(owner);
        composed = new ComposedPriceOracle(BASE_USDC, owner);
        composed.setSequencerUptimeFeed(SEQUENCER_FEED, 3600);
        // base = MARKET asset/ETH (18 dec), quote = ETH/USD (8 dec)
        composed.setComposedFeed(BASE_WSTETH, WSTETH_ETH_MARKET, ETHUSD_FEED, 18, BASE_STALENESS, QUOTE_STALENESS, SLIPPAGE);
        composed.setComposedFeed(BASE_CBETH,  CBETH_ETH_MARKET,  ETHUSD_FEED, 18, BASE_STALENESS, QUOTE_STALENESS, SLIPPAGE);

        // Swap stack mirrors the routing in SwapAdapters.fork.t.sol. Both wstETH and cbETH route via
        // Uniswap V3 two-hop through WETH (the Aerodrome USDC/cbETH pool is too thin).
        swapRouter = new SwapRouter(batchExecutor, owner);
        uniAdapter  = new UniswapV3Adapter(UNISWAP_V3_ROUTER, BASE_USDC, address(swapRouter));
        aeroAdapter = new AerodromeAdapter(AERODROME_ROUTER, BASE_USDC, address(swapRouter));
        swapRouter.setAssetAdapter(BASE_WSTETH, address(uniAdapter));
        swapRouter.setAssetAdapter(BASE_CBETH,  address(uniAdapter));
        swapRouter.configureUniswapRoute(BASE_WSTETH, address(uniAdapter), 100, BASE_WETH, 500);
        swapRouter.configureUniswapRoute(BASE_CBETH,  address(uniAdapter), 500, BASE_WETH, 500);
        vm.stopPrank();
    }

    // ── Feed/asset decimals match the oracle configuration ──────────────────────

    function test_fork_feedDecimalsMatchConfig() public view {
        assertEq(IChainlinkAggregator(ETHUSD_FEED).decimals(), 8, "ETH/USD must be 8 dec");
        assertEq(IChainlinkAggregator(WSTETH_ETH_MARKET).decimals(), 18, "wstETH/ETH must be 18 dec");
        assertEq(IChainlinkAggregator(CBETH_ETH_MARKET).decimals(), 18, "cbETH/ETH must be 18 dec");
        assertEq(IDecimals(BASE_WSTETH).decimals(), 18, "wstETH token must be 18 dec");
        assertEq(IDecimals(BASE_CBETH).decimals(), 18, "cbETH token must be 18 dec");
        assertEq(IDecimals(BASE_USDC).decimals(), 6, "USDC must be 6 dec");
    }

    function test_fork_feedDescriptionsMatchMarketRoutes() public view {
        assertEq(
            IAggregatorDescription(WSTETH_ETH_MARKET).description(), "WSTETH / ETH", "wstETH market feed"
        );
        assertEq(
            IAggregatorDescription(CBETH_ETH_MARKET).description(), "CBETH / ETH", "cbETH market feed"
        );
        assertEq(IAggregatorDescription(ETHUSD_FEED).description(), "ETH / USD", "shared quote feed");
    }

    // ── Oracle price matches the live feeds (deterministic, no DEX dependency) ──

    function test_fork_composedPriceMatchesFeeds_wstETH() public view {
        _assertQuoteMatchesFeeds(BASE_WSTETH, WSTETH_ETH_MARKET, 1000e6);
    }

    function test_fork_composedPriceMatchesFeeds_cbETH() public view {
        _assertQuoteMatchesFeeds(BASE_CBETH, CBETH_ETH_MARKET, 1000e6);
    }

    // ── End-to-end: deep liquidity, real swap clears the floor (both assets) ────

    function test_fork_wstETH_swapClearsComposedFloor() public {
        _assertSwapClearsFloor(BASE_WSTETH, "wstETH");
    }

    function test_fork_cbETH_swapClearsComposedFloor() public {
        _assertSwapClearsFloor(BASE_CBETH, "cbETH");
    }

    function _assertSwapClearsFloor(address asset, string memory label) internal {
        uint256 amountIn = 1000e6;
        uint256 oracleMinOut = composed.quoteMinOut(asset, amountIn);

        deal(BASE_USDC, batchExecutor, amountIn);
        vm.startPrank(batchExecutor);
        IERC20(BASE_USDC).approve(address(swapRouter), amountIn);
        uint256 out = swapRouter.swap(asset, amountIn, 1);
        vm.stopPrank();

        emit log_named_string("asset", label);
        emit log_named_uint("floor   ", oracleMinOut);
        emit log_named_uint("realised", out);
        // Conservative floor is just below realised output (never blocks an honest swap) and within
        // ~10% of it (a decimals bug or wrong/exchange-rate feed would blow this band).
        assertLe(oracleMinOut, out, "floor must be <= realised output");
        assertGe(oracleMinOut * 10000, out * 9000, "floor must track market within ~10%");
    }

    // -------------------------------------------------------------------------

    /// @dev Recompute the floor from the raw on-chain feed answers and assert the oracle matches
    ///      exactly (same integer arithmetic). Ties the oracle output to live feed values.
    function _assertQuoteMatchesFeeds(address asset, address baseFeed, uint256 amountIn) internal view {
        (, int256 baseAns, , , )  = IChainlinkAggregator(baseFeed).latestRoundData();
        (, int256 quoteAns, , , ) = IChainlinkAggregator(ETHUSD_FEED).latestRoundData();
        assertGt(baseAns, 0, "base feed answer must be > 0");
        assertGt(quoteAns, 0, "quote feed answer must be > 0");

        // assetDecimals 18, baseFeedDecimals 18, quoteFeedDecimals 8, usdcDecimals 6.
        uint256 expectedOut =
            (amountIn * (10 ** 18) * (10 ** 18) * (10 ** 8)) / ((10 ** 6) * uint256(baseAns) * uint256(quoteAns));
        uint256 expectedFloor = expectedOut * (10000 - SLIPPAGE) / 10000;

        assertEq(composed.quoteMinOut(asset, amountIn), expectedFloor, "oracle floor must match feed arithmetic");
    }
}
