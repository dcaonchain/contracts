// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/oracles/ManualPriceOracle.sol";

contract ManualPriceOracleTest is Test {
    address owner = makeAddr("owner");
    address weth  = makeAddr("weth");

    ManualPriceOracle oracle;

    function setUp() public {
        // Owner is set from the constructor argument, not msg.sender, so no prank is
        // needed here. Foundry 1.8 stopped applying vm.prank to CREATE, so a prank here
        // would leak into the first test instead of being consumed by the deployment.
        oracle = new ManualPriceOracle(owner);
    }

    function test_quote_revertsForUnconfiguredAsset() public {
        vm.expectRevert(abi.encodeWithSelector(ManualPriceOracle.UnsupportedAsset.selector, weth));
        oracle.quoteMinOut(weth, 100e6);
    }

    function test_quote_appliesConfiguredRate() public {
        vm.prank(owner);
        oracle.setRate(weth, 5e17); // floor = usdcIn / 2
        assertEq(oracle.quoteMinOut(weth, 100e6), 50e6, "floor = usdcIn * rate / 1e18");
    }

    function test_setRate_onlyOwner() public {
        vm.expectRevert();
        oracle.setRate(weth, 5e17);
    }

    function test_setRate_zeroRemovesCoverage() public {
        vm.startPrank(owner);
        oracle.setRate(weth, 5e17);
        oracle.setRate(weth, 0);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(ManualPriceOracle.UnsupportedAsset.selector, weth));
        oracle.quoteMinOut(weth, 100e6);
    }

    // ── A non-zero rate must still fail closed when the quote rounds to zero ────────────────────────

    /// A configured (non-zero) rate does not stop the floor rounding to zero for a small input, which
    /// the `rate == 0` coverage check does not catch. IPriceOracle forbids returning 0, so it reverts.
    function test_quote_revertsWhenNonZeroRateRoundsToZero() public {
        vm.prank(owner);
        oracle.setRate(weth, 1e15); // RATE_SCALE / 1000 => floor = usdcIn / 1000, coverage is set
        vm.expectRevert(abi.encodeWithSelector(ManualPriceOracle.ZeroQuote.selector, weth, uint256(999)));
        oracle.quoteMinOut(weth, 999); // 999 / 1000 == 0
    }

    /// The first non-zero input past that boundary is still accepted unchanged.
    function test_quote_firstNonZeroBoundaryIsAccepted() public {
        vm.prank(owner);
        oracle.setRate(weth, 1e15);
        assertEq(oracle.quoteMinOut(weth, 1000), 1, "1000 / 1000 == 1 is the first accepted floor");
    }
}
