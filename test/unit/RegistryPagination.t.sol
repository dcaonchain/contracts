// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/DCAFactory.sol";
import "../../src/UserStrategyAccount.sol";

// Non-zero `referralCommitment` for tests that do not care what it is. The factory rejects zero
// and ignores everything else, so any constant does here; a real client must not reuse one.
bytes32 constant TEST_COMMITMENT = keccak256("dca-test-referral-commitment");


/// @dev Minimal transferring token. The other unit suites mock the factory or the account; this one
///      needs both to be real, so it needs a token the real deposit path can actually move.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external { balanceOf[to] += a; }

    function transfer(address to, uint256 a) external returns (bool) {
        if (balanceOf[msg.sender] < a) return false;
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        if (allowance[from][msg.sender] < a || balanceOf[from] < a) return false;
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

/// @notice Pagination of `getDueFundedAccounts` against a REAL factory holding REAL accounts.
/// @dev Uses real accounts rather than a mock strategy implementation whose `isDueAndFunded`
///      ignores timing. The property here IS the timing: it is
///      the interaction between the registry's swap-with-last-and-pop and a strategy's execution
///      anchor, and neither half can stand in for the other.
///
///      The pair below is the whole claim the paging contract makes about duplicates, split into the
///      case that holds and the case that does not.
contract RegistryPaginationTest is Test {
    DCAFactory internal factory;
    UserStrategyAccount internal impl;
    MockERC20 internal usdc;

    address internal owner     = makeAddr("owner");
    address internal guardian  = makeAddr("guardian");
    address internal treasury  = makeAddr("treasury");
    address internal executor  = makeAddr("batchExecutor");
    address internal weth      = makeAddr("weth");

    uint256 constant AMOUNT  = 5_000_000;   // the factory's minimum per execution
    uint256 constant DEPOSIT = 8 * AMOUNT;  // the weekly tier minimum

    function setUp() public {
        usdc = new MockERC20();
        impl = new UserStrategyAccount();

        factory = new DCAFactory(address(impl), executor, address(usdc), owner, treasury, guardian);
        // `createStrategy` reads the executor's asset allowlist; the executor here is an EOA.
        vm.mockCall(
            executor,
            abi.encodeCall(IAssetAllowlist.whitelistedAssets, (weth)),
            abi.encode(true)
        );
    }

    /// Creates a funded, registered weekly strategy owned by `user`.
    function _strategy(string memory label) internal returns (UserStrategyAccount acct) {
        address user = makeAddr(label);
        DCAFactory.StrategyParams memory p = DCAFactory.StrategyParams({
            targetAsset: weth,
            amountPerExecution: AMOUNT,
            tier: DCAFactory.Tier.Weekly,
            yieldAdapterImplementation: address(0)
        });

        vm.prank(user);
        acct = UserStrategyAccount(factory.createStrategy(p, TEST_COMMITMENT));

        usdc.mint(user, DEPOSIT);
        vm.startPrank(user);
        usdc.approve(address(acct), DEPOSIT);
        acct.deposit(DEPOSIT);
        vm.stopPrank();
    }

    function _page(uint256 windowStart, uint256 cursor, uint256 limit)
        internal
        view
        returns (address[] memory accounts, uint256 nextCursor)
    {
        return factory.getDueFundedAccounts(DCAFactory.Tier.Weekly, windowStart, cursor, limit);
    }

    function _contains(address[] memory list, address target) internal pure returns (bool) {
        for (uint256 i = 0; i < list.length; i++) if (list[i] == target) return true;
        return false;
    }

    /// Pins the registry's exact contents and order, not just its length or its tail.
    ///
    /// The tests below turn on one entry MOVING from a visited index to an unvisited one. A tail
    /// check alone cannot tell that apart from the entry being duplicated in the array while its
    /// original occurrence survives, and both produce the same two pages, so both tests would pass
    /// against a registry that was corrupt in exactly the way they exist to rule out.
    function _assertRegistry(address first, address second, address third, string memory when)
        internal
        view
    {
        address[] memory active = factory.getActiveStrategies();
        assertEq(active.length, 3, string.concat("registry size ", when));
        assertEq(active[0], first, string.concat("slot 0 ", when));
        assertEq(active[1], second, string.concat("slot 1 ", when));
        assertEq(active[2], third, string.concat("slot 2 ", when));
    }

    /// A caller paging the OPEN window cannot be handed the same strategy twice, because `resume`
    /// anchors past the window it is paging.
    ///
    /// The moving strategy is `b`, the MIDDLE one, on purpose. `b` sits inside page 1 under the
    /// real append ordering and under a re-registration that prepended instead, so page 1 cannot be
    /// what fails if registration order breaks. That leaves the post-resume registry assertion as
    /// the thing responsible for catching it, which is the point of having it.
    function test_openWindowPagingCannotReturnAStrategyTwice() public {
        UserStrategyAccount a = _strategy("a");
        UserStrategyAccount b = _strategy("b");
        UserStrategyAccount c = _strategy("c");
        vm.warp(b.nextExecutionTime());
        uint256 openWindow = block.timestamp;
        _assertRegistry(address(a), address(b), address(c), "before the pause");

        (address[] memory page1, uint256 next1) = _page(openWindow, 0, 2);
        assertTrue(_contains(page1, address(b)), "page 1 hands out the strategy");
        assertEq(next1, 2, "and there is registry behind it");

        // Removal swaps the last entry down into the freed slot, then re-registration appends, so
        // `b` leaves a visited index and lands at the tail: inside the span page 2 will inspect.
        vm.startPrank(b.owner());
        b.pause();
        b.resume();
        vm.stopPrank();
        _assertRegistry(address(a), address(c), address(b), "after the resume");

        (address[] memory page2,) = _page(openWindow, next1, 2);
        assertFalse(_contains(page2, address(b)), "but it is no longer due for the open window");
    }

    /// The same sequence and the same registry mutation, from a caller that pre-built the NEXT
    /// window. Only `windowStart` differs, so the opposite outcome is attributable to it alone.
    /// `resume` anchors to exactly that boundary, so the strategy comes back on page 2 having
    /// already come back on page 1. This is why `getDueFundedAccounts` documents deduplication as a
    /// caller obligation, and why an off-chain caller should deduplicate unconditionally.
    function test_futureWindowPagingCanReturnAStrategyTwice() public {
        UserStrategyAccount a = _strategy("a");
        UserStrategyAccount b = _strategy("b");
        UserStrategyAccount c = _strategy("c");
        vm.warp(b.nextExecutionTime());
        // Derived from the tier calendar, as a caller pre-building next week would. Reading the
        // account's anchor back after the resume would make this hold for any anchor at all.
        uint256 futureWindow = block.timestamp + 7 days;
        _assertRegistry(address(a), address(b), address(c), "before the pause");

        (address[] memory page1, uint256 next1) = _page(futureWindow, 0, 2);
        assertTrue(_contains(page1, address(b)), "page 1 hands out the strategy");
        assertEq(next1, 2, "and there is registry behind it");

        vm.startPrank(b.owner());
        b.pause();
        b.resume();
        vm.stopPrank();
        _assertRegistry(address(a), address(c), address(b), "after the resume");
        assertEq(b.nextExecutionTime(), futureWindow, "resume lands on the boundary the caller chose");

        (address[] memory page2,) = _page(futureWindow, next1, 2);
        assertTrue(_contains(page2, address(b)), "and page 2 hands out the same strategy again");
    }
}
