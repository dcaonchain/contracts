// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "../../src/adapters/yield/AaveV3YieldAdapter.sol";

// Base mainnet addresses - injected into adapter, never hardcoded in contract logic
address constant BASE_USDC       = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
address constant BASE_AAVE_POOL  = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
address constant BASE_A_USDC     = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;

// Whale with USDC on Base mainnet

contract AaveV3YieldAdapterForkTest is Test {
    AaveV3YieldAdapter internal implementation;
    AaveV3YieldAdapter internal adapter; // clone bound to `account`

    address internal account = makeAddr("account");

    /// @dev Mirrors DCAFactory.createStrategy: clone the reviewed implementation, then bind it.
    function _cloneFor(address boundAccount) internal returns (AaveV3YieldAdapter clone) {
        clone = AaveV3YieldAdapter(Clones.clone(address(implementation)));
        clone.initialize(boundAccount);
    }

    function setUp() public {
        // Pinned block for determinism. Set BASE_FORK_BLOCK to pin; 0 => latest.
        uint256 forkBlock = vm.envOr("BASE_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        } else {
            vm.createSelectFork(vm.envString("BASE_RPC_URL"), forkBlock);
        }
        emit log_named_uint("fork block", block.number);
        implementation = new AaveV3YieldAdapter(BASE_AAVE_POOL, BASE_USDC, BASE_A_USDC);
        adapter = _cloneFor(account);
    }

    /// @dev Two clones of one implementation hold independent Aave positions against the real pool.
    ///      This is the property EIP-1167 has to preserve for the shared-implementation model to work.
    function test_fork_clonesHoldIndependentPositions() public {
        address second = makeAddr("secondAccount");
        AaveV3YieldAdapter other = _cloneFor(second);

        _fundAccount(account, 100e6);
        _fundAccount(second, 40e6);

        vm.startPrank(account);
        IERC20(BASE_USDC).approve(address(adapter), 100e6);
        adapter.deposit(100e6);
        vm.stopPrank();

        vm.startPrank(second);
        IERC20(BASE_USDC).approve(address(other), 40e6);
        other.deposit(40e6);
        vm.stopPrank();

        assertApproxEqAbs(
            adapter.balanceOf(account), 100e6, YIELD_WITHDRAWAL_TOLERANCE, "first clone holds its own position"
        );
        assertApproxEqAbs(
            other.balanceOf(second), 40e6, YIELD_WITHDRAWAL_TOLERANCE, "second clone holds its own position"
        );

        // Closing one position leaves the other intact.
        vm.prank(second);
        other.withdrawAll();
        assertEq(other.balanceOf(second), 0);
        assertApproxEqAbs(
            adapter.balanceOf(account), 100e6, YIELD_WITHDRAWAL_TOLERANCE, "first position untouched"
        );
    }

    function test_fork_deposit_suppliesUsdcToAave() public {
        uint256 amount = 100e6; // 100 USDC
        _fundAccount(account, amount);

        vm.startPrank(account);
        IERC20(BASE_USDC).approve(address(adapter), amount);
        adapter.deposit(amount);
        vm.stopPrank();

        assertEq(IERC20(BASE_USDC).balanceOf(account), 0, "USDC should leave account");
        assertGt(adapter.balanceOf(account), 0, "aUSDC balance should increase");
    }

    function test_fork_withdraw_returnsExactAmount() public {
        uint256 amount = 100e6;
        _fundAccount(account, amount);

        vm.startPrank(account);
        IERC20(BASE_USDC).approve(address(adapter), amount);
        adapter.deposit(amount);

        uint256 received = adapter.withdraw(amount);
        vm.stopPrank();

        assertGe(received + YIELD_WITHDRAWAL_TOLERANCE, amount, "received must be within tolerance");
        assertGe(
            IERC20(BASE_USDC).balanceOf(account) + YIELD_WITHDRAWAL_TOLERANCE,
            amount,
            "USDC should be back in account"
        );
    }

    function test_fork_withdrawAll_clearsFull_aTokenBalance() public {
        uint256 amount = 100e6;
        _fundAccount(account, amount);

        vm.startPrank(account);
        IERC20(BASE_USDC).approve(address(adapter), amount);
        adapter.deposit(amount);

        // Advance time so yield accrues
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 100);

        uint256 aBalance = adapter.balanceOf(account);
        assertGt(aBalance, amount, "yield should have accrued");

        adapter.withdrawAll();
        vm.stopPrank();

        assertEq(adapter.balanceOf(account), 0, "aToken balance must be zero after withdrawAll");
        assertGt(IERC20(BASE_USDC).balanceOf(account), amount, "should receive principal + yield");
    }

    // -------------------------------------------------------------------------
    // The bounded-deposit rule against real Aave, not a mock
    // -------------------------------------------------------------------------

    /// The constraint that forced the deposit bound to be a LOWER bound. Base aUSDC revision 5
    /// floors both scaled minting and balance reporting, so an exact-credit rule rejects ordinary
    /// deposits. Measured here the way `deposit` measures it - as a delta across the supply -
    /// against the real pool at a real block.
    function test_fork_deposit_mintRoundingStaysWithinTolerance() public {
        uint256 amount = 100e6;
        _fundAccount(account, amount);

        uint256 positionBefore = adapter.balanceOf(account);
        vm.startPrank(account);
        IERC20(BASE_USDC).approve(address(adapter), amount);
        adapter.deposit(amount); // would revert DepositShortfall if real Aave breached the bound
        vm.stopPrank();

        uint256 credited = adapter.balanceOf(account) - positionBefore;
        assertGe(
            credited + YIELD_WITHDRAWAL_TOLERANCE,
            amount,
            "real Aave credits within the proven tolerance"
        );

        assertLe(credited, amount, "revision-5 floor rounding cannot over-credit this mint");
    }

    /// The same bound on a clone whose position is already non-empty and accruing. This is the case
    /// an absolute-balance check would get wrong in both directions: accrued interest inflates the
    /// balance, and a prior deposit would cover for a second one that credited nothing.
    function test_fork_deposit_boundHoldsOnTopUpIntoAnAccruingPosition() public {
        _fundAccount(account, 250e6);

        vm.startPrank(account);
        IERC20(BASE_USDC).approve(address(adapter), 250e6);
        adapter.deposit(100e6);

        // Let interest accrue so the position is no longer a clean multiple of what was supplied.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 100);

        uint256 positionBefore = adapter.balanceOf(account);
        assertGt(positionBefore, 100e6, "interest accrued before the top-up");

        adapter.deposit(150e6);
        vm.stopPrank();

        uint256 credited = adapter.balanceOf(account) - positionBefore;
        assertGe(credited + YIELD_WITHDRAWAL_TOLERANCE, 150e6, "top-up credited within tolerance");
        // The pre-read normalized income and supply's state update resolve to the same index at one
        // timestamp. Existing accrual is already present in positionBefore, so the top-up delta may
        // consume a fractional carry but cannot exceed the amount supplied.
        assertLe(credited, 150e6, "top-up delta cannot over-credit the supplied amount");
    }

    /// Regression against the exact block and amount that revision 5 credits two units short.
    /// Tolerance 1 reverts this call; tolerance 2 admits it without compiling any Aave source.
    function test_fork_deposit_acceptsObservedTwoUnitShortfall() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 51_860_076);
        implementation = new AaveV3YieldAdapter(BASE_AAVE_POOL, BASE_USDC, BASE_A_USDC);
        adapter = _cloneFor(account);

        uint256 amount = 60_000_002;
        _fundAccount(account, amount);
        vm.startPrank(account);
        IERC20(BASE_USDC).approve(address(adapter), amount);
        adapter.deposit(amount);
        vm.stopPrank();

        assertEq(adapter.balanceOf(account), amount - YIELD_WITHDRAWAL_TOLERANCE);
    }

    function test_fork_unauthorized_reverts() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(AaveV3YieldAdapter.Unauthorized.selector);
        adapter.deposit(100e6);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _fundAccount(address to, uint256 amount) internal {
        deal(BASE_USDC, to, amount);
    }
}
