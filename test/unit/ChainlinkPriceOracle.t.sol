// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/oracles/ChainlinkPriceOracle.sol";

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

contract ChainlinkPriceOracleTest is Test {
    address owner = makeAddr("owner");

    MockToken usdc;   // 6 dec
    MockToken weth;   // 18 dec
    MockToken cbbtc;  // 8 dec

    ChainlinkPriceOracle oracle;
    MockAggregator wethFeed;   // WETH/USD, 8 dec
    MockAggregator cbbtcFeed;  // cbBTC/USD, 8 dec
    MockAggregator sequencer;  // L2 sequencer uptime feed

    uint32 constant STALENESS = 3600;
    uint16 constant SLIPPAGE  = 100; // 1%

    function setUp() public {
        vm.warp(1_000_000); // non-trivial timestamp for staleness/grace math

        usdc  = new MockToken(6);
        weth  = new MockToken(18);
        cbbtc = new MockToken(8);

        vm.startPrank(owner);
        oracle = new ChainlinkPriceOracle(address(usdc), owner);

        wethFeed  = new MockAggregator(8);
        cbbtcFeed = new MockAggregator(8);
        wethFeed.set(3000e8, block.timestamp, block.timestamp);   // $3,000
        cbbtcFeed.set(95000e8, block.timestamp, block.timestamp); // $95,000

        oracle.setAssetFeed(address(weth),  address(wethFeed),  18, STALENESS, SLIPPAGE);
        oracle.setAssetFeed(address(cbbtc), address(cbbtcFeed), 8,  STALENESS, SLIPPAGE);

        // Sequencer up since well before now, grace already elapsed.
        sequencer = new MockAggregator(0);
        sequencer.set(0, block.timestamp - 7200, block.timestamp - 7200);
        oracle.setSequencerUptimeFeed(address(sequencer), 3600);
        vm.stopPrank();
    }

    // ── Decimal normalization ─────────────────────────────────────────────────

    function test_quote_normalizesDecimals_18decAsset() public view {
        // 100 USDC at $3,000  to  ~0.03333 WETH, minus 1%  to  ~0.033 WETH (1e18 base units).
        uint256 minOut = oracle.quoteMinOut(address(weth), 100e6);
        assertApproxEqRel(minOut, 33e15, 0.01e18, "WETH 18-dec quote off");
    }

    function test_quote_normalizesDecimals_8decAsset() public view {
        // 100 USDC at $95,000  to  ~0.001052 cbBTC, minus 1%  to  ~104,210 base units (8 dec).
        uint256 minOut = oracle.quoteMinOut(address(cbbtc), 100e6);
        assertApproxEqRel(minOut, 104210, 0.01e18, "cbBTC 8-dec quote off");
    }

    function test_quote_scalesLinearlyWithInput() public view {
        uint256 one = oracle.quoteMinOut(address(weth), 100e6);
        uint256 ten = oracle.quoteMinOut(address(weth), 1000e6);
        assertApproxEqRel(ten, one * 10, 0.0001e18, "quote must scale with USDC input");
    }

    function test_quote_higherSlippageLowersFloor() public {
        uint256 tight = oracle.quoteMinOut(address(weth), 100e6); // 1%
        vm.prank(owner);
        oracle.setAssetFeed(address(weth), address(wethFeed), 18, STALENESS, 500); // 5%
        uint256 loose = oracle.quoteMinOut(address(weth), 100e6);
        assertLt(loose, tight, "higher slippage bps must lower the floor");
    }

    function test_quote_revertsWhenFeedDecimalsChange() public {
        wethFeed.setDecimals(18);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceOracle.DecimalsMismatch.selector, address(wethFeed), uint8(8), uint8(18)
            )
        );
        oracle.quoteMinOut(address(weth), 100e6);
    }

    // ── Price validity ─────────────────────────────────────────────────────────

    function test_quote_revertsOnUnsupportedAsset() public {
        address random = makeAddr("random");
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceOracle.UnsupportedAsset.selector, random));
        oracle.quoteMinOut(random, 100e6);
    }

    function test_quote_revertsOnZeroAnswer() public {
        wethFeed.set(0, block.timestamp, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceOracle.InvalidPrice.selector, int256(0)));
        oracle.quoteMinOut(address(weth), 100e6);
    }

    function test_quote_revertsOnNegativeAnswer() public {
        wethFeed.set(-1, block.timestamp, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceOracle.InvalidPrice.selector, int256(-1)));
        oracle.quoteMinOut(address(weth), 100e6);
    }

    function test_quote_revertsOnIncompleteRound() public {
        wethFeed.set(3000e8, block.timestamp, 0); // updatedAt == 0
        vm.expectRevert(ChainlinkPriceOracle.RoundNotComplete.selector);
        oracle.quoteMinOut(address(weth), 100e6);
    }

    function test_quote_revertsOnStalePrice() public {
        wethFeed.set(3000e8, block.timestamp, block.timestamp - (STALENESS + 1));
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceOracle.StalePrice.selector, block.timestamp - (STALENESS + 1), STALENESS
            )
        );
        oracle.quoteMinOut(address(weth), 100e6);
    }

    function test_quote_revertsOnStaleRound() public {
        // answeredInRound (2) < roundId (5): a carried-over answer from an earlier round.
        wethFeed.setRounds(5, 2);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceOracle.StaleRound.selector, uint80(5), uint80(2)));
        oracle.quoteMinOut(address(weth), 100e6);
    }

    // ── A valid price whose floor rounds to zero must fail closed ──────────────

    /// On an 8-decimal asset at a high unit price, two truncations compose (expectedOut floors to 1,
    /// the 1% haircut floors 1 to 0) for a sub-cent input. The price is valid; the floor is zero,
    /// which IPriceOracle forbids, so the quote reverts rather than returning 0.
    function test_quote_revertsWhenFloorRoundsToZero() public {
        // cbBTC at $95,000: expectedOut = usdcIn / 950, so usdcIn = 950 gives expectedOut 1, and the
        // 1% haircut then floors it to 0.
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPriceOracle.ZeroQuote.selector, address(cbbtc), uint256(950))
        );
        oracle.quoteMinOut(address(cbbtc), 950);
    }

    /// The first non-zero input past that boundary is still accepted.
    function test_quote_firstNonZeroFloorIsAccepted() public view {
        // usdcIn = 1900 gives expectedOut 2, and the 1% haircut floors it to 1.
        assertEq(oracle.quoteMinOut(address(cbbtc), 1900), 1, "first non-zero floor accepted");
    }

    function test_quote_acceptsAnswerAtStalenessBoundary() public view {
        // exactly maxStaleness old is still acceptable (strict > check)
        uint256 minOut = oracle.quoteMinOut(address(weth), 100e6);
        assertGt(minOut, 0);
    }

    // ── L2 sequencer uptime ──────────────────────────────────────────────────

    function test_quote_revertsWhenSequencerDown() public {
        sequencer.set(1, block.timestamp - 7200, block.timestamp); // answer 1 = down
        vm.expectRevert(ChainlinkPriceOracle.SequencerDown.selector);
        oracle.quoteMinOut(address(weth), 100e6);
    }

    function test_quote_revertsWhenSequencerGracePeriodNotElapsed() public {
        // Sequencer back up only 100s ago, grace is 3600s.
        sequencer.set(0, block.timestamp - 100, block.timestamp - 100);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPriceOracle.SequencerGracePeriodNotOver.selector, 100, 3600)
        );
        oracle.quoteMinOut(address(weth), 100e6);
    }

    function test_quote_revertsWhenSequencerRoundInvalid() public {
        sequencer.set(0, 0, block.timestamp); // startedAt == 0
        vm.expectRevert(ChainlinkPriceOracle.SequencerDown.selector);
        oracle.quoteMinOut(address(weth), 100e6);
    }

    function test_quote_okWhenSequencerCheckDisabled() public {
        vm.prank(owner);
        oracle.setSequencerUptimeFeed(address(0), 0); // disabled (e.g. L1/testnet)
        uint256 minOut = oracle.quoteMinOut(address(weth), 100e6);
        assertGt(minOut, 0, "no sequencer check when feed unset");
    }

    function test_quote_revertsBeforeSequencerPolicyConfigured() public {
        vm.startPrank(owner);
        ChainlinkPriceOracle freshOracle = new ChainlinkPriceOracle(address(usdc), owner);
        freshOracle.setAssetFeed(address(weth), address(wethFeed), 18, STALENESS, SLIPPAGE);
        vm.stopPrank();

        vm.expectRevert(ChainlinkPriceOracle.SequencerNotConfigured.selector);
        freshOracle.quoteMinOut(address(weth), 100e6);
    }

    // ── Admin / config ──────────────────────────────────────────────────────

    function test_setAssetFeed_onlyOwner() public {
        vm.expectRevert();
        oracle.setAssetFeed(address(weth), address(wethFeed), 18, STALENESS, SLIPPAGE);
    }

    function test_setAssetFeed_revertsOnSlippageAboveCap() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPriceOracle.SlippageTooHigh.selector, uint16(1001), uint16(1000))
        );
        oracle.setAssetFeed(address(weth), address(wethFeed), 18, STALENESS, 1001);
    }

    function test_setAssetFeed_revertsOnStalenessAboveCap() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceOracle.StalenessTooHigh.selector, uint32(7 days + 1), uint32(7 days)
            )
        );
        oracle.setAssetFeed(address(weth), address(wethFeed), 18, uint32(7 days + 1), SLIPPAGE);
    }

    function test_setSequencerUptimeFeed_revertsOnGraceBelowFloor() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPriceOracle.SequencerGraceTooShort.selector, 1 hours - 1, 1 hours)
        );
        oracle.setSequencerUptimeFeed(address(sequencer), 1 hours - 1);
    }

    function test_setSequencerUptimeFeed_revertsOnGraceWithoutFeed() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPriceOracle.InvalidSequencerConfiguration.selector, address(0), 1)
        );
        oracle.setSequencerUptimeFeed(address(0), 1);
    }

    function test_policyBoundariesAreAccepted() public {
        vm.startPrank(owner);
        oracle.setAssetFeed(address(weth), address(wethFeed), 18, uint32(7 days), 1000);
        oracle.setSequencerUptimeFeed(address(sequencer), 1 hours);
        vm.stopPrank();

        assertTrue(oracle.sequencerConfigured());
    }

    function test_setAssetFeed_revertsOnAssetDecimalsMismatch() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPriceOracle.DecimalsMismatch.selector, address(weth), uint8(8), uint8(18))
        );
        oracle.setAssetFeed(address(weth), address(wethFeed), 8, STALENESS, SLIPPAGE);
    }

    function test_removeAssetFeed_makesAssetUnsupported() public {
        vm.prank(owner);
        oracle.removeAssetFeed(address(weth));
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceOracle.UnsupportedAsset.selector, address(weth)));
        oracle.quoteMinOut(address(weth), 100e6);
    }

    function test_usdcDecimals_readFromToken() public view {
        assertEq(oracle.usdcDecimals(), 6, "USDC decimals must be read from the token");
    }
}
