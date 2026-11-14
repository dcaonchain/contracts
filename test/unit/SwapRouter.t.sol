// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/SwapRouter.sol";
import "../../src/interfaces/ISwapAdapter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// -------------------------------------------------------------------------
// Mocks
// -------------------------------------------------------------------------

contract MockERC20 {
    string public name;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name) { name = _name; }

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract MockAdapter is ISwapAdapter {
    MockERC20 public immutable usdc;
    uint256 public immutable returnAmount;

    constructor(address _usdc, uint256 _returnAmount) {
        usdc = MockERC20(_usdc);
        returnAmount = _returnAmount;
    }

    function swap(address asset, uint256 amountIn, uint256) external returns (uint256) {
        // Pull USDC from caller (SwapRouter)
        usdc.transferFrom(msg.sender, address(this), amountIn);
        // Send output asset to caller
        MockERC20(asset).transfer(msg.sender, returnAmount);
        return returnAmount;
    }
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

contract SwapRouterTest is Test {
    SwapRouter internal router;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockAdapter internal adapter;

    address internal batchExecutor = makeAddr("batchExecutor");
    address internal owner = makeAddr("owner");
    address internal other = makeAddr("other");

    function setUp() public {
        usdc = new MockERC20("USDC");
        weth = new MockERC20("WETH");

        vm.prank(owner);
        router = new SwapRouter(batchExecutor, owner);

        adapter = new MockAdapter(address(usdc), 1e18);
        weth.mint(address(adapter), 10e18);

        vm.prank(owner);
        router.setAssetAdapter(address(weth), address(adapter));
    }

    // --- swap ---

    function test_swap_routesToCorrectAdapter() public {
        usdc.mint(batchExecutor, 100e6);

        vm.startPrank(batchExecutor);
        usdc.approve(address(router), 100e6);
        uint256 out = router.swap(address(weth), 100e6, 0);
        vm.stopPrank();

        assertEq(out, 1e18);
        assertEq(weth.balanceOf(batchExecutor), 1e18);
        assertEq(usdc.balanceOf(batchExecutor), 0);
    }

    function test_swap_revertsIfNotBatchExecutor() public {
        vm.prank(other);
        vm.expectRevert(SwapRouter.Unauthorized.selector);
        router.swap(address(weth), 100e6, 0);
    }

    function test_swap_revertsIfNoAdapter() public {
        address unknown = makeAddr("unknown");
        vm.prank(batchExecutor);
        vm.expectRevert(abi.encodeWithSelector(SwapRouter.NoAdapterForAsset.selector, unknown));
        router.swap(unknown, 100e6, 0);
    }

    function test_swap_revertsOnZeroAmount() public {
        vm.prank(batchExecutor);
        vm.expectRevert(SwapRouter.ZeroAmount.selector);
        router.swap(address(weth), 0, 0);
    }

    // --- setAssetAdapter ---

    function test_setAssetAdapter_onlyOwner() public {
        vm.prank(other);
        vm.expectRevert();
        router.setAssetAdapter(address(weth), address(adapter));
    }

    function test_setAssetAdapter_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit SwapRouter.AdapterSet(address(weth), address(adapter));
        router.setAssetAdapter(address(weth), address(adapter));
    }

    function test_setAssetAdapter_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(SwapRouter.ZeroAddress.selector);
        router.setAssetAdapter(address(0), address(adapter));
    }

    // --- setBatchExecutor ---

    function test_setBatchExecutor_onlyOwner() public {
        vm.prank(other);
        vm.expectRevert();
        router.setBatchExecutor(makeAddr("new"));
    }

    function test_setBatchExecutor_updatesAndNewCallerCanSwap() public {
        address newExecutor = makeAddr("newExecutor");
        vm.prank(owner);
        router.setBatchExecutor(newExecutor);

        usdc.mint(newExecutor, 100e6);
        vm.startPrank(newExecutor);
        usdc.approve(address(router), 100e6);
        uint256 out = router.swap(address(weth), 100e6, 0);
        vm.stopPrank();

        assertEq(out, 1e18);
    }

    // --- constructor ---

    function test_constructor_revertsOnZeroBatchExecutor() public {
        vm.expectRevert(SwapRouter.ZeroAddress.selector);
        new SwapRouter(address(0), owner);
    }

    // --- configureUniswapRoute / configureAerodromeRoute ---

    function test_configureUniswapRoute_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(SwapRouter.ZeroAddress.selector);
        router.configureUniswapRoute(address(0), address(adapter), 500, address(0), 0);
    }

    function test_configureUniswapRoute_revertsIfSetRouteFails() public {
        // adapter (MockAdapter) has no setRoute() - low-level call returns ok=false
        vm.prank(owner);
        vm.expectRevert(SwapRouter.RouteConfigFailed.selector);
        router.configureUniswapRoute(address(weth), address(adapter), 500, address(0), 0);
    }

    function test_configureAerodromeRoute_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(SwapRouter.ZeroAddress.selector);
        router.configureAerodromeRoute(address(0), address(adapter), false, makeAddr("factory"));
    }

    function test_configureAerodromeRoute_revertsIfSetRouteFails() public {
        vm.prank(owner);
        vm.expectRevert(SwapRouter.RouteConfigFailed.selector);
        router.configureAerodromeRoute(address(weth), address(adapter), false, makeAddr("factory"));
    }

    // --- two-step ownership (Ownable2Step) ---

    function test_ownership_isTwoStep() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        router.transferOwnership(newOwner);
        assertEq(router.owner(), owner, "owner unchanged until accepted");
        assertEq(router.pendingOwner(), newOwner, "pending owner set");

        vm.prank(newOwner);
        router.acceptOwnership();
        assertEq(router.owner(), newOwner, "ownership transfers only after accept");
    }

    // --- immutables / state ---

    function test_initialState() public view {
        assertEq(router.batchExecutor(), batchExecutor);
        assertEq(router.owner(), owner);
        assertEq(address(router.adapters(address(weth))), address(adapter));
    }
}
