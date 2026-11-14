// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/adapters/swap/AerodromeAdapter.sol";

contract MockAerodromeRouter {
    uint256 public returnAmount;

    function setReturn(uint256 amount) external { returnAmount = amount; }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256,
        IAerodromeRouter.Route[] calldata routes,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        IAerodromeRouter.Route memory r = routes[0];
        MockERC20(r.from).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(r.to).transfer(to, returnAmount);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = returnAmount;
    }
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external { balanceOf[to] += a; }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        allowance[from][msg.sender] -= a;
        balanceOf[from] -= a;
        balanceOf[to] += a;
        return true;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }
    function forceApprove(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }
}

contract AerodromeAdapterTest is Test {
    AerodromeAdapter internal adapter;
    MockAerodromeRouter internal aeroRouter;
    MockERC20 internal usdc;
    MockERC20 internal cbEth;

    address internal swapRouter = makeAddr("swapRouter");
    address internal other = makeAddr("other");
    address internal poolFactory = makeAddr("poolFactory");

    function setUp() public {
        usdc = new MockERC20();
        cbEth = new MockERC20();
        aeroRouter = new MockAerodromeRouter();
        adapter = new AerodromeAdapter(address(aeroRouter), address(usdc), swapRouter);
    }

    // --- setRoute ---

    function test_setRoute_onlySwapRouter() public {
        vm.prank(other);
        vm.expectRevert(AerodromeAdapter.Unauthorized.selector);
        adapter.setRoute(address(cbEth), false, poolFactory);
    }

    function test_setRoute_storesConfig() public {
        vm.prank(swapRouter);
        adapter.setRoute(address(cbEth), true, poolFactory);
        (bool stable, address factory) = adapter.routes(address(cbEth));
        assertTrue(stable);
        assertEq(factory, poolFactory);
    }

    // --- swap ---

    function test_swap_executesAndReturnsOutput() public {
        _configureRoute();
        cbEth.mint(address(aeroRouter), 1e18);
        aeroRouter.setReturn(1e18);

        usdc.mint(swapRouter, 100e6);
        vm.startPrank(swapRouter);
        usdc.approve(address(adapter), 100e6);
        uint256 out = adapter.swap(address(cbEth), 100e6, 0);
        vm.stopPrank();

        assertEq(out, 1e18);
        assertEq(cbEth.balanceOf(swapRouter), 1e18);
    }

    function test_swap_revertsIfNotSwapRouter() public {
        _configureRoute();
        vm.prank(other);
        vm.expectRevert(AerodromeAdapter.Unauthorized.selector);
        adapter.swap(address(cbEth), 100e6, 0);
    }

    function test_swap_revertsOnZeroAmount() public {
        _configureRoute();
        vm.prank(swapRouter);
        vm.expectRevert(AerodromeAdapter.ZeroAmount.selector);
        adapter.swap(address(cbEth), 0, 0);
    }

    function test_swap_revertsIfAssetNotConfigured() public {
        vm.prank(swapRouter);
        vm.expectRevert(abi.encodeWithSelector(AerodromeAdapter.AssetNotConfigured.selector, address(cbEth)));
        adapter.swap(address(cbEth), 100e6, 0);
    }

    function test_swap_revertsOnZeroOutput() public {
        _configureRoute();
        aeroRouter.setReturn(0); // router returns 0 output  to  ZeroOutput

        usdc.mint(swapRouter, 100e6);
        vm.startPrank(swapRouter);
        usdc.approve(address(adapter), 100e6);
        vm.expectRevert(AerodromeAdapter.ZeroOutput.selector);
        adapter.swap(address(cbEth), 100e6, 0);
        vm.stopPrank();
    }

    // --- immutables ---

    function test_immutables() public view {
        assertEq(address(adapter.router()), address(aeroRouter));
        assertEq(address(adapter.usdc()), address(usdc));
        assertEq(adapter.swapRouter(), swapRouter);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _configureRoute() internal {
        vm.prank(swapRouter);
        adapter.setRoute(address(cbEth), false, poolFactory);
    }
}
