// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/SwapRouter.sol";
import "../../src/adapters/swap/UniswapV3Adapter.sol";
import "../../src/adapters/swap/AerodromeAdapter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Base mainnet addresses - passed as constructor args, never hardcoded in contract logic
address constant BASE_USDC            = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
address constant BASE_WETH            = 0x4200000000000000000000000000000000000006;
address constant BASE_WSTETH          = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
address constant BASE_CBBTC           = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
address constant BASE_CBETH           = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;

address constant UNISWAP_V3_ROUTER    = 0x2626664c2603336E57B271c5C0b26F421741e481;
address constant AERODROME_ROUTER     = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
address constant AERODROME_FACTORY    = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;


contract SwapAdaptersForkTest is Test {
    SwapRouter internal swapRouter;
    UniswapV3Adapter internal uniAdapter;
    AerodromeAdapter internal aeroAdapter;

    address internal batchExecutor = makeAddr("batchExecutor");
    address internal owner = makeAddr("owner");

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
        swapRouter = new SwapRouter(batchExecutor, owner);

        uniAdapter = new UniswapV3Adapter(UNISWAP_V3_ROUTER, BASE_USDC, address(swapRouter));
        aeroAdapter = new AerodromeAdapter(AERODROME_ROUTER, BASE_USDC, address(swapRouter));

        // Register adapters first, then configure routes via SwapRouter passthrough.
        //
        // NOTE: cbETH is pointed at Aerodrome here ON PURPOSE, and this is NOT the preferred route.
        // These are adapter-level tests, and the AerodromeAdapter is part of the source, so it
        // needs some asset with a real pool to prove it functions. The preferred route for cbETH is
        // Uniswap V3 two-hop via WETH; that path is covered end to end by
        // EndToEnd.fork.t.sol:test_fork_e2e_cbETH_uniswapTwoHop.
        swapRouter.setAssetAdapter(BASE_WETH,   address(uniAdapter));
        swapRouter.setAssetAdapter(BASE_WSTETH, address(uniAdapter));
        swapRouter.setAssetAdapter(BASE_CBBTC,  address(uniAdapter));
        swapRouter.setAssetAdapter(BASE_CBETH,  address(aeroAdapter));

        // Configure routes via SwapRouter (which calls adapter.setRoute as msg.sender == swapRouter)
        swapRouter.configureUniswapRoute(BASE_WETH,   address(uniAdapter), 500,  address(0),  0);
        swapRouter.configureUniswapRoute(BASE_WSTETH, address(uniAdapter), 100,  BASE_WETH,   500);
        swapRouter.configureUniswapRoute(BASE_CBBTC,  address(uniAdapter), 3000, address(0),  0);
        swapRouter.configureAerodromeRoute(BASE_CBETH, address(aeroAdapter), false, AERODROME_FACTORY);
        vm.stopPrank();
    }

    function test_fork_swap_WETH() public {
        _assertSwapProducesOutput(BASE_WETH, 100e6);
    }

    function test_fork_swap_wstETH_twoHop() public {
        _assertSwapProducesOutput(BASE_WSTETH, 100e6);
    }

    function test_fork_swap_cbBTC() public {
        _assertSwapProducesOutput(BASE_CBBTC, 100e6);
    }

    function test_fork_swap_cbETH_aerodrome() public {
        _assertSwapProducesOutput(BASE_CBETH, 100e6);
    }

    function test_fork_swap_onlyBatchExecutor_reverts() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(SwapRouter.Unauthorized.selector);
        swapRouter.swap(BASE_WETH, 100e6, 0);
    }

    function test_fork_swap_noAdapterForAsset_reverts() public {
        address unknown = makeAddr("unknown");
        _fundBatchExecutor(100e6);
        vm.startPrank(batchExecutor);
        IERC20(BASE_USDC).approve(address(swapRouter), 100e6);
        vm.expectRevert(abi.encodeWithSelector(SwapRouter.NoAdapterForAsset.selector, unknown));
        swapRouter.swap(unknown, 100e6, 0);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _assertSwapProducesOutput(address asset, uint256 amountIn) internal {
        _fundBatchExecutor(amountIn);
        uint256 balanceBefore = IERC20(asset).balanceOf(batchExecutor);

        vm.startPrank(batchExecutor);
        IERC20(BASE_USDC).approve(address(swapRouter), amountIn);
        uint256 out = swapRouter.swap(asset, amountIn, 1); // minAmountOut = 1 (fork test, not slippage test)
        vm.stopPrank();

        assertGt(out, 0, "swap output must be > 0");
        assertEq(IERC20(asset).balanceOf(batchExecutor), balanceBefore + out, "asset must land in batchExecutor");
        assertEq(IERC20(BASE_USDC).balanceOf(address(swapRouter)), 0, "SwapRouter must hold no USDC after swap");
        assertEq(IERC20(asset).balanceOf(address(swapRouter)), 0, "SwapRouter must hold no asset after swap");
    }

    function _fundBatchExecutor(uint256 amount) internal {
        deal(BASE_USDC, batchExecutor, amount);
    }
}
