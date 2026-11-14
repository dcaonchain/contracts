// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/adapters/swap/UniswapV3Adapter.sol";

contract MockUniswapRouter {
    address public immutable weth;
    uint256 public returnAmount;

    constructor(address _weth) { weth = _weth; }
    function setReturn(uint256 amount) external { returnAmount = amount; }

    function exactInputSingle(IUniswapV3Router.ExactInputSingleParams calldata params)
        external returns (uint256)
    {
        MockERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        MockERC20(params.tokenOut).transfer(params.recipient, returnAmount);
        return returnAmount;
    }

    function exactInput(IUniswapV3Router.ExactInputParams calldata params)
        external returns (uint256)
    {
        // Decode first token (bytes 0-19) and last token (last 20 bytes) from path
        address tokenIn = address(bytes20(params.path[:20]));
        address tokenOut = address(bytes20(params.path[params.path.length - 20:]));
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        MockERC20(tokenOut).transfer(params.recipient, returnAmount);
        return returnAmount;
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
}

contract UniswapV3AdapterTest is Test {
    UniswapV3Adapter internal adapter;
    MockUniswapRouter internal uniRouter;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockERC20 internal wstEth;

    address internal swapRouter = makeAddr("swapRouter");
    address internal other = makeAddr("other");

    function setUp() public {
        usdc = new MockERC20();
        weth = new MockERC20();
        wstEth = new MockERC20();
        uniRouter = new MockUniswapRouter(address(weth));
        adapter = new UniswapV3Adapter(address(uniRouter), address(usdc), swapRouter);
    }

    // --- setRoute ---

    function test_setRoute_onlySwapRouter() public {
        vm.prank(other);
        vm.expectRevert(UniswapV3Adapter.Unauthorized.selector);
        adapter.setRoute(address(weth), 500, address(0), 0);
    }

    function test_setRoute_storesConfig() public {
        vm.prank(swapRouter);
        adapter.setRoute(address(weth), 500, address(0), 0);
        (uint24 fee, address hop, uint24 hopFee) = adapter.routes(address(weth));
        assertEq(fee, 500);
        assertEq(hop, address(0));
        assertEq(hopFee, 0);
    }

    // --- swap direct ---

    function test_swap_direct_executesAndReturnsOutput() public {
        _configureDirectRoute(address(weth), 500);
        weth.mint(address(uniRouter), 1e18);
        uniRouter.setReturn(1e18);

        usdc.mint(swapRouter, 100e6);
        vm.startPrank(swapRouter);
        usdc.approve(address(adapter), 100e6);
        uint256 out = adapter.swap(address(weth), 100e6, 0);
        vm.stopPrank();

        assertEq(out, 1e18);
        assertEq(weth.balanceOf(swapRouter), 1e18);
    }

    function test_swap_revertsIfNotSwapRouter() public {
        _configureDirectRoute(address(weth), 500);
        vm.prank(other);
        vm.expectRevert(UniswapV3Adapter.Unauthorized.selector);
        adapter.swap(address(weth), 100e6, 0);
    }

    function test_swap_revertsIfAssetNotConfigured() public {
        vm.prank(swapRouter);
        vm.expectRevert(abi.encodeWithSelector(UniswapV3Adapter.AssetNotConfigured.selector, address(weth)));
        adapter.swap(address(weth), 100e6, 0);
    }

    function test_swap_revertsOnZeroAmount() public {
        _configureDirectRoute(address(weth), 500);
        vm.prank(swapRouter);
        vm.expectRevert(UniswapV3Adapter.ZeroAmount.selector);
        adapter.swap(address(weth), 0, 0);
    }

    // --- two-hop (wstETH pattern) ---

    function test_swap_twoHop_routesThroughHopToken() public {
        // USDC  to  WETH  to  wstETH
        vm.prank(swapRouter);
        adapter.setRoute(address(wstEth), 100, address(weth), 500);

        wstEth.mint(address(uniRouter), 1e18);
        uniRouter.setReturn(1e18);

        usdc.mint(swapRouter, 100e6);
        vm.startPrank(swapRouter);
        usdc.approve(address(adapter), 100e6);
        uint256 out = adapter.swap(address(wstEth), 100e6, 0);
        vm.stopPrank();

        assertGt(out, 0);
    }

    // --- immutables ---

    function test_immutables() public view {
        assertEq(address(adapter.router()), address(uniRouter));
        assertEq(address(adapter.usdc()), address(usdc));
        assertEq(adapter.swapRouter(), swapRouter);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _configureDirectRoute(address asset, uint24 fee) internal {
        vm.prank(swapRouter);
        adapter.setRoute(asset, fee, address(0), 0);
    }
}
