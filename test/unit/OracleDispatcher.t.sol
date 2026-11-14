// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/oracles/OracleDispatcher.sol";
import "../../src/oracles/ChainlinkPriceOracle.sol";
import "../../src/oracles/ComposedPriceOracle.sol";
import "../../src/interfaces/IPriceOracle.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Mocks
// ─────────────────────────────────────────────────────────────────────────────

contract MockAggregator {
    uint8 public decimals;
    int256 internal answer;
    uint256 internal startedAt;
    uint256 internal updatedAt;
    uint80 internal roundId = 1;
    uint80 internal answeredInRound = 1;

    constructor(uint8 _decimals) {
        decimals = _decimals;
    }

    function set(int256 _answer, uint256 _startedAt, uint256 _updatedAt) external {
        answer = _answer;
        startedAt = _startedAt;
        updatedAt = _updatedAt;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

contract MockToken {
    uint8 public decimals;
    constructor(uint8 _d) { decimals = _d; }
}

/// @dev Minimal IPriceOracle returning a fixed value, to test routing in isolation.
contract StubOracle is IPriceOracle {
    uint256 public immutable value;
    constructor(uint256 _v) { value = _v; }
    function quoteMinOut(address, uint256) external view returns (uint256) { return value; }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

contract OracleDispatcherTest is Test {
    address owner = makeAddr("owner");

    OracleDispatcher dispatcher;
    address weth = makeAddr("weth");
    address wsteth = makeAddr("wsteth");

    function setUp() public {
        vm.prank(owner);
        dispatcher = new OracleDispatcher(owner);
    }

    // ── Routing ──────────────────────────────────────────────────────────────

    function test_routesToConfiguredOracle() public {
        StubOracle a = new StubOracle(111);
        StubOracle b = new StubOracle(222);
        vm.startPrank(owner);
        dispatcher.setAssetOracle(weth, address(a));
        dispatcher.setAssetOracle(wsteth, address(b));
        vm.stopPrank();

        assertEq(dispatcher.quoteMinOut(weth, 1e6), 111, "weth must route to oracle a");
        assertEq(dispatcher.quoteMinOut(wsteth, 1e6), 222, "wsteth must route to oracle b");
    }

    function test_quoteRevertsForUnroutedAsset() public {
        vm.expectRevert(abi.encodeWithSelector(OracleDispatcher.UnsupportedAsset.selector, weth));
        dispatcher.quoteMinOut(weth, 1e6);
    }

    function test_removeRouteMakesAssetUnsupported() public {
        StubOracle a = new StubOracle(111);
        vm.startPrank(owner);
        dispatcher.setAssetOracle(weth, address(a));
        dispatcher.removeAssetOracle(weth);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(OracleDispatcher.UnsupportedAsset.selector, weth));
        dispatcher.quoteMinOut(weth, 1e6);
    }

    function test_reroutePicksNewOracle() public {
        StubOracle a = new StubOracle(111);
        StubOracle b = new StubOracle(222);
        vm.startPrank(owner);
        dispatcher.setAssetOracle(weth, address(a));
        dispatcher.setAssetOracle(weth, address(b)); // overwrite
        vm.stopPrank();
        assertEq(dispatcher.quoteMinOut(weth, 1e6), 222, "re-route must take effect");
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    function test_setAssetOracle_onlyOwner() public {
        StubOracle a = new StubOracle(111);
        vm.expectRevert();
        dispatcher.setAssetOracle(weth, address(a));
    }

    function test_setAssetOracle_revertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(OracleDispatcher.ZeroAddress.selector);
        dispatcher.setAssetOracle(weth, address(0));
    }

    // ── A failing underlying oracle bubbles up (no silent zero) ─────────────────

    function test_underlyingRevertPropagates() public {
        // Composed oracle with no feed configured for the asset reverts UnsupportedAsset;
        // the dispatcher must surface that, not swallow it.
        MockToken usdc = new MockToken(6);
        ComposedPriceOracle composed = new ComposedPriceOracle(address(usdc), owner);
        vm.startPrank(owner);
        composed.setSequencerUptimeFeed(address(0), 0);
        dispatcher.setAssetOracle(wsteth, address(composed));
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(ComposedPriceOracle.UnsupportedAsset.selector, wsteth));
        dispatcher.quoteMinOut(wsteth, 100e6);
    }

    /// The MUST binds the value the dispatcher forwards, not only the missing-route case. A
    /// faulty routed oracle returning 0 must be rejected, never forwarded as a silent zero quote.
    function test_forwardedZeroQuoteReverts() public {
        StubOracle faulty = new StubOracle(0);
        vm.prank(owner);
        dispatcher.setAssetOracle(weth, address(faulty));
        vm.expectRevert(abi.encodeWithSelector(OracleDispatcher.ZeroQuote.selector, weth, uint256(100e6)));
        dispatcher.quoteMinOut(weth, 100e6);
    }

    // ── End-to-end: real Chainlink (direct) + Composed (two-feed) behind one router ──

    function test_e2e_directAndComposedThroughDispatcher() public {
        MockToken usdc = new MockToken(6);
        MockToken directAsset = new MockToken(18);
        MockToken composedAsset = new MockToken(18);

        // Direct path: WETH via ChainlinkPriceOracle (ETH/USD, 8 dec).
        ChainlinkPriceOracle direct = new ChainlinkPriceOracle(address(usdc), owner);
        MockAggregator ethUsd = new MockAggregator(8);
        ethUsd.set(3000e8, block.timestamp, block.timestamp);

        // Composed path: wstETH via ComposedPriceOracle (wstETH/ETH 18 dec × ETH/USD 8 dec).
        ComposedPriceOracle composed = new ComposedPriceOracle(address(usdc), owner);
        MockAggregator wstethEth = new MockAggregator(18);
        wstethEth.set(1.2e18, block.timestamp, block.timestamp);
        MockAggregator ethUsd2 = new MockAggregator(8);
        ethUsd2.set(3000e8, block.timestamp, block.timestamp);

        vm.startPrank(owner);
        direct.setSequencerUptimeFeed(address(0), 0);
        composed.setSequencerUptimeFeed(address(0), 0);
        direct.setAssetFeed(address(directAsset), address(ethUsd), 18, 3600, 100);
        composed.setComposedFeed(address(composedAsset), address(wstethEth), address(ethUsd2), 18, 3600, 3600, 100);
        dispatcher.setAssetOracle(address(directAsset), address(direct));
        dispatcher.setAssetOracle(address(composedAsset), address(composed));
        vm.stopPrank();

        // WETH: 3000 USDC @ $3000  to  ~1.0 WETH, minus 1% ≈ 0.99e18.
        assertApproxEqRel(
            dispatcher.quoteMinOut(address(directAsset), 3000e6), 0.99e18, 0.001e18, "direct WETH via dispatcher"
        );
        // wstETH: 3600 USDC @ (1.2 × $3000 = $3600)  to  ~1.0 wstETH, minus 1% ≈ 0.99e18.
        assertApproxEqRel(
            dispatcher.quoteMinOut(address(composedAsset), 3600e6), 0.99e18, 0.001e18, "composed wstETH via dispatcher"
        );
    }
}
