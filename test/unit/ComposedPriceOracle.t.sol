// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/oracles/ComposedPriceOracle.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Mocks (same shape as ChainlinkPriceOracle.t.sol)
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

    function setRounds(uint80 _roundId, uint80 _answeredInRound) external {
        roundId = _roundId;
        answeredInRound = _answeredInRound;
    }

    function setDecimals(uint8 _decimals) external {
        decimals = _decimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

contract MockToken {
    uint8 public decimals;
    constructor(uint8 _d) { decimals = _d; }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

contract ComposedPriceOracleTest is Test {
    address owner = makeAddr("owner");

    MockToken usdc;    // 6 dec
    MockToken wsteth;  // 18 dec
    MockToken cbeth;   // 18 dec

    ComposedPriceOracle oracle;
    MockAggregator wstethEthFeed; // wstETH/ETH market, 18 dec
    MockAggregator cbethEthFeed;  // cbETH/ETH market, 18 dec
    MockAggregator ethUsdFeed;    // ETH/USD, 8 dec (shared quote leg)
    MockAggregator sequencer;

    uint32 constant STALENESS = 3600;
    uint16 constant SLIPPAGE  = 100; // 1%

    function setUp() public {
        vm.warp(1_000_000);

        usdc   = new MockToken(6);
        wsteth = new MockToken(18);
        cbeth  = new MockToken(18);

        vm.startPrank(owner);
        oracle = new ComposedPriceOracle(address(usdc), owner);

        wstethEthFeed = new MockAggregator(18);
        cbethEthFeed  = new MockAggregator(18);
        ethUsdFeed    = new MockAggregator(8);

        wstethEthFeed.set(1.2e18, block.timestamp, block.timestamp); // 1 wstETH = 1.2 ETH
        cbethEthFeed.set(1.05e18, block.timestamp, block.timestamp);  // 1 cbETH  = 1.05 ETH
        ethUsdFeed.set(3000e8, block.timestamp, block.timestamp);     // ETH = $3,000

        oracle.setComposedFeed(address(wsteth), address(wstethEthFeed), address(ethUsdFeed), 18, STALENESS, STALENESS, SLIPPAGE);
        oracle.setComposedFeed(address(cbeth),  address(cbethEthFeed),  address(ethUsdFeed), 18, STALENESS, STALENESS, SLIPPAGE);

        sequencer = new MockAggregator(0);
        sequencer.set(0, block.timestamp - 7200, block.timestamp - 7200);
        oracle.setSequencerUptimeFeed(address(sequencer), 3600);
        vm.stopPrank();
    }

    // ── Composition math ───────────────────────────────────────────────────────

    function test_quote_composesTwoFeeds() public view {
        // wstETH/USD = 1.2 * 3000 = $3,600. 3600 USDC  to  1.0 wstETH, minus 1%  to  ~0.99e18.
        uint256 minOut = oracle.quoteMinOut(address(wsteth), 3600e6);
        assertApproxEqRel(minOut, 0.99e18, 0.001e18, "composed wstETH quote off");
    }

    function test_quote_composesSecondAssetSharingQuoteFeed() public view {
        // cbETH/USD = 1.05 * 3000 = $3,150. 3150 USDC  to  1.0 cbETH, minus 1%  to  ~0.99e18.
        uint256 minOut = oracle.quoteMinOut(address(cbeth), 3150e6);
        assertApproxEqRel(minOut, 0.99e18, 0.001e18, "composed cbETH quote off");
    }

    function test_quote_scalesLinearlyWithInput() public view {
        uint256 one = oracle.quoteMinOut(address(wsteth), 100e6);
        uint256 ten = oracle.quoteMinOut(address(wsteth), 1000e6);
        assertApproxEqRel(ten, one * 10, 0.0001e18, "quote must scale with USDC input");
    }

    function test_quote_higherBaseRateRaisesQuote() public {
        uint256 lo = oracle.quoteMinOut(address(wsteth), 3600e6); // 1.2 rate
        vm.prank(owner);
        wstethEthFeed.set(1.5e18, block.timestamp, block.timestamp); // wstETH worth more ETH
        uint256 hi = oracle.quoteMinOut(address(wsteth), 3600e6);
        assertLt(hi, lo, "a higher asset/ETH rate buys fewer asset units per USDC");
    }

    // ── A valid composed price whose floor rounds to zero must fail closed ──────

    /// Composition does not make a zero floor safe: on a high-unit-price 8-decimal asset the same
    /// sub-cent truncation reaches zero. Both feeds are valid; the floor is zero, which IPriceOracle
    /// forbids, so the quote reverts.
    function test_quote_revertsWhenFloorRoundsToZero() public {
        MockToken asset = new MockToken(8);
        MockAggregator baseFeed = new MockAggregator(8);
        MockAggregator quoteFeed = new MockAggregator(8);
        baseFeed.set(1e12, block.timestamp, block.timestamp);
        quoteFeed.set(1e12, block.timestamp, block.timestamp);
        vm.prank(owner);
        oracle.setComposedFeed(address(asset), address(baseFeed), address(quoteFeed), 8, STALENESS, STALENESS, SLIPPAGE);

        // expectedOut = usdcIn / 1e6, so usdcIn = 1e6 gives expectedOut 1 and the 1% haircut floors
        // it to 0.
        vm.expectRevert(
            abi.encodeWithSelector(ComposedPriceOracle.ZeroQuote.selector, address(asset), uint256(1_000_000))
        );
        oracle.quoteMinOut(address(asset), 1_000_000);

        // The first non-zero input past the boundary is still accepted.
        assertEq(oracle.quoteMinOut(address(asset), 2_000_000), 1, "first non-zero floor accepted");
    }

    function test_quote_revertsWhenBaseFeedDecimalsChange() public {
        wstethEthFeed.setDecimals(8);
        vm.expectRevert(
            abi.encodeWithSelector(
                ComposedPriceOracle.DecimalsMismatch.selector, address(wstethEthFeed), uint8(18), uint8(8)
            )
        );
        oracle.quoteMinOut(address(wsteth), 3600e6);
    }

    function test_quote_revertsWhenQuoteFeedDecimalsChange() public {
        ethUsdFeed.setDecimals(18);
        vm.expectRevert(
            abi.encodeWithSelector(
                ComposedPriceOracle.DecimalsMismatch.selector, address(ethUsdFeed), uint8(8), uint8(18)
            )
        );
        oracle.quoteMinOut(address(wsteth), 3600e6);
    }

    // ── The depeg point: a market base-feed drop raises the quantity floor ─────

    function test_quote_marketDepegRaisesQuantityFloor() public {
        uint256 healthy = oracle.quoteMinOut(address(wsteth), 3600e6);
        // Market wstETH/ETH halves (a depeg a market feed WOULD reflect, an exchange-rate feed would not).
        vm.prank(owner);
        wstethEthFeed.set(0.6e18, block.timestamp, block.timestamp);
        uint256 depegged = oracle.quoteMinOut(address(wsteth), 3600e6);
        // Floor must roughly double the asset units expected (price halved), proving the oracle tracks market.
        assertApproxEqRel(depegged, healthy * 2, 0.001e18, "market depeg must move the composed floor");
    }

    // ── Two-feed validity: EITHER feed being bad must revert ────────────────────

    function test_quote_revertsOnBaseFeedZero() public {
        wstethEthFeed.set(0, block.timestamp, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ComposedPriceOracle.InvalidPrice.selector, address(wstethEthFeed), int256(0)));
        oracle.quoteMinOut(address(wsteth), 100e6);
    }

    function test_quote_revertsOnQuoteFeedZero() public {
        ethUsdFeed.set(0, block.timestamp, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ComposedPriceOracle.InvalidPrice.selector, address(ethUsdFeed), int256(0)));
        oracle.quoteMinOut(address(wsteth), 100e6);
    }

    function test_quote_revertsOnBaseFeedNegative() public {
        wstethEthFeed.set(-1, block.timestamp, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ComposedPriceOracle.InvalidPrice.selector, address(wstethEthFeed), int256(-1)));
        oracle.quoteMinOut(address(wsteth), 100e6);
    }

    function test_quote_revertsOnBaseFeedStale() public {
        wstethEthFeed.set(1.2e18, block.timestamp, block.timestamp - (STALENESS + 1));
        vm.expectRevert(
            abi.encodeWithSelector(
                ComposedPriceOracle.StalePrice.selector, address(wstethEthFeed), block.timestamp - (STALENESS + 1), STALENESS
            )
        );
        oracle.quoteMinOut(address(wsteth), 100e6);
    }

    function test_quote_revertsOnQuoteFeedStale() public {
        ethUsdFeed.set(3000e8, block.timestamp, block.timestamp - (STALENESS + 1));
        vm.expectRevert(
            abi.encodeWithSelector(
                ComposedPriceOracle.StalePrice.selector, address(ethUsdFeed), block.timestamp - (STALENESS + 1), STALENESS
            )
        );
        oracle.quoteMinOut(address(wsteth), 100e6);
    }

    function test_quote_revertsOnBaseFeedIncompleteRound() public {
        wstethEthFeed.set(1.2e18, block.timestamp, 0);
        vm.expectRevert(abi.encodeWithSelector(ComposedPriceOracle.RoundNotComplete.selector, address(wstethEthFeed)));
        oracle.quoteMinOut(address(wsteth), 100e6);
    }

    function test_quote_revertsOnBaseFeedStaleRound() public {
        wstethEthFeed.setRounds(5, 2);
        vm.expectRevert(abi.encodeWithSelector(ComposedPriceOracle.StaleRound.selector, address(wstethEthFeed), uint80(5), uint80(2)));
        oracle.quoteMinOut(address(wsteth), 100e6);
    }

    function test_quote_perFeedStaleness() public {
        // Quote leg (ETH/USD) gets a tighter window than the base leg; an answer fresh for the base
        // window but stale for the quote window must still revert on the quote feed.
        vm.prank(owner);
        oracle.setComposedFeed(address(wsteth), address(wstethEthFeed), address(ethUsdFeed), 18, 7200, 600, SLIPPAGE);
        ethUsdFeed.set(3000e8, block.timestamp, block.timestamp - 1200); // 1200s old: ok for 7200, stale for 600
        vm.expectRevert(
            abi.encodeWithSelector(ComposedPriceOracle.StalePrice.selector, address(ethUsdFeed), block.timestamp - 1200, uint32(600))
        );
        oracle.quoteMinOut(address(wsteth), 100e6);
    }

    // ── Unsupported / sequencer / admin (mirrors ChainlinkPriceOracle) ──────────

    function test_quote_revertsOnUnsupportedAsset() public {
        address random = makeAddr("random");
        vm.expectRevert(abi.encodeWithSelector(ComposedPriceOracle.UnsupportedAsset.selector, random));
        oracle.quoteMinOut(random, 100e6);
    }

    function test_quote_revertsWhenSequencerDown() public {
        sequencer.set(1, block.timestamp - 7200, block.timestamp);
        vm.expectRevert(ComposedPriceOracle.SequencerDown.selector);
        oracle.quoteMinOut(address(wsteth), 100e6);
    }

    function test_quote_revertsWhenSequencerGraceNotElapsed() public {
        sequencer.set(0, block.timestamp - 100, block.timestamp - 100);
        vm.expectRevert(abi.encodeWithSelector(ComposedPriceOracle.SequencerGracePeriodNotOver.selector, 100, 3600));
        oracle.quoteMinOut(address(wsteth), 100e6);
    }

    function test_quote_okWhenSequencerDisabled() public {
        vm.prank(owner);
        oracle.setSequencerUptimeFeed(address(0), 0);
        assertGt(oracle.quoteMinOut(address(wsteth), 100e6), 0);
    }

    function test_quote_revertsBeforeSequencerPolicyConfigured() public {
        vm.startPrank(owner);
        ComposedPriceOracle freshOracle = new ComposedPriceOracle(address(usdc), owner);
        freshOracle.setComposedFeed(
            address(wsteth),
            address(wstethEthFeed),
            address(ethUsdFeed),
            18,
            STALENESS,
            STALENESS,
            SLIPPAGE
        );
        vm.stopPrank();

        vm.expectRevert(ComposedPriceOracle.SequencerNotConfigured.selector);
        freshOracle.quoteMinOut(address(wsteth), 100e6);
    }

    function test_setComposedFeed_onlyOwner() public {
        vm.expectRevert();
        oracle.setComposedFeed(address(wsteth), address(wstethEthFeed), address(ethUsdFeed), 18, STALENESS, STALENESS, SLIPPAGE);
    }

    function test_setComposedFeed_revertsOnSlippageAboveCap() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ComposedPriceOracle.SlippageTooHigh.selector, uint16(1001), uint16(1000))
        );
        oracle.setComposedFeed(address(wsteth), address(wstethEthFeed), address(ethUsdFeed), 18, STALENESS, STALENESS, 1001);
    }

    function test_setComposedFeed_revertsOnBaseStalenessAboveCap() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ComposedPriceOracle.StalenessTooHigh.selector,
                address(wstethEthFeed),
                uint32(7 days + 1),
                uint32(7 days)
            )
        );
        oracle.setComposedFeed(
            address(wsteth),
            address(wstethEthFeed),
            address(ethUsdFeed),
            18,
            uint32(7 days + 1),
            STALENESS,
            SLIPPAGE
        );
    }

    function test_setComposedFeed_revertsOnQuoteStalenessAboveCap() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ComposedPriceOracle.StalenessTooHigh.selector,
                address(ethUsdFeed),
                uint32(7 days + 1),
                uint32(7 days)
            )
        );
        oracle.setComposedFeed(
            address(wsteth),
            address(wstethEthFeed),
            address(ethUsdFeed),
            18,
            STALENESS,
            uint32(7 days + 1),
            SLIPPAGE
        );
    }

    function test_setSequencerUptimeFeed_revertsOnGraceBelowFloor() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ComposedPriceOracle.SequencerGraceTooShort.selector, 1 hours - 1, 1 hours)
        );
        oracle.setSequencerUptimeFeed(address(sequencer), 1 hours - 1);
    }

    function test_setSequencerUptimeFeed_revertsOnGraceWithoutFeed() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ComposedPriceOracle.InvalidSequencerConfiguration.selector, address(0), 1)
        );
        oracle.setSequencerUptimeFeed(address(0), 1);
    }

    function test_policyBoundariesAreAccepted() public {
        vm.startPrank(owner);
        oracle.setComposedFeed(
            address(wsteth),
            address(wstethEthFeed),
            address(ethUsdFeed),
            18,
            uint32(7 days),
            uint32(7 days),
            1000
        );
        oracle.setSequencerUptimeFeed(address(sequencer), 1 hours);
        vm.stopPrank();

        assertTrue(oracle.sequencerConfigured());
    }

    function test_setComposedFeed_revertsOnAssetDecimalsMismatch() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ComposedPriceOracle.DecimalsMismatch.selector, address(wsteth), uint8(8), uint8(18))
        );
        oracle.setComposedFeed(
            address(wsteth), address(wstethEthFeed), address(ethUsdFeed), 8, STALENESS, STALENESS, SLIPPAGE
        );
    }

    function test_removeComposedFeed_makesAssetUnsupported() public {
        vm.prank(owner);
        oracle.removeComposedFeed(address(wsteth));
        vm.expectRevert(abi.encodeWithSelector(ComposedPriceOracle.UnsupportedAsset.selector, address(wsteth)));
        oracle.quoteMinOut(address(wsteth), 100e6);
    }

    function test_setComposedFeed_revertsOnZeroAsset() public {
        vm.prank(owner);
        vm.expectRevert(ComposedPriceOracle.ZeroAddress.selector);
        oracle.setComposedFeed(address(0), address(wstethEthFeed), address(ethUsdFeed), 18, STALENESS, STALENESS, SLIPPAGE);
    }

    function test_setComposedFeed_revertsOnZeroBaseFeed() public {
        vm.prank(owner);
        vm.expectRevert(ComposedPriceOracle.ZeroAddress.selector);
        oracle.setComposedFeed(address(wsteth), address(0), address(ethUsdFeed), 18, STALENESS, STALENESS, SLIPPAGE);
    }

    function test_setComposedFeed_revertsOnZeroQuoteFeed() public {
        vm.prank(owner);
        vm.expectRevert(ComposedPriceOracle.ZeroAddress.selector);
        oracle.setComposedFeed(address(wsteth), address(wstethEthFeed), address(0), 18, STALENESS, STALENESS, SLIPPAGE);
    }

    function test_setComposedFeed_revertsOnZeroBaseStaleness() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ComposedPriceOracle.StalePrice.selector, address(wstethEthFeed), uint256(0), uint256(0)));
        oracle.setComposedFeed(address(wsteth), address(wstethEthFeed), address(ethUsdFeed), 18, 0, STALENESS, SLIPPAGE);
    }

    function test_setComposedFeed_revertsOnZeroQuoteStaleness() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ComposedPriceOracle.StalePrice.selector, address(ethUsdFeed), uint256(0), uint256(0)));
        oracle.setComposedFeed(address(wsteth), address(wstethEthFeed), address(ethUsdFeed), 18, STALENESS, 0, SLIPPAGE);
    }
}
