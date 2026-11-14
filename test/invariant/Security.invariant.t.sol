// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/BatchExecutor.sol";
import "../../src/UserStrategyAccount.sol";
import "../../src/DCAFactory.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Mocks
// ─────────────────────────────────────────────────────────────────────────────

contract SecERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function forceApprove(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
}

contract SecFactory {
    address public immutable ownerAddr;
    SecERC20 public immutable usdcToken;
    mapping(DCAFactory.Tier => uint256) public minExecutions;
    uint256 public executionFeeBps = 15;
    uint256 public yieldFeeBps = 1500;
    uint256 public registerCount;
    uint256 public removeCount;

    constructor(address _usdc, address _owner) {
        usdcToken = SecERC20(_usdc);
        ownerAddr = _owner;
        minExecutions[DCAFactory.Tier.Weekly] = 8;
    }
    function usdc() external view returns (address) { return address(usdcToken); }
    function owner() external view returns (address) { return ownerAddr; }
    function registerStrategy(address) external { registerCount++; }
    function removeStrategy(address) external { removeCount++; }
}

// ─────────────────────────────────────────────────────────────────────────────
// Security invariant tests: parameter immutability, access control, reentrancy
// ─────────────────────────────────────────────────────────────────────────────

contract SecurityInvariantTest is Test {
    UserStrategyAccount acct;
    SecERC20 usdc;
    SecERC20 weth;
    SecFactory factory;

    address executor_  = makeAddr("executor");
    address owner_     = makeAddr("owner");
    address treasury   = makeAddr("treasury");
    address attacker   = makeAddr("attacker");

    uint256 constant AMOUNT = 25e6;

    function setUp() public {
        usdc    = new SecERC20();
        weth    = new SecERC20();
        factory = new SecFactory(address(usdc), treasury);

        UserStrategyAccount impl = new UserStrategyAccount();
        acct = UserStrategyAccount(Clones.clone(address(impl)));
        acct.initialize(
            owner_, address(weth), AMOUNT, uint8(DCAFactory.Tier.Weekly),
            false, address(0), executor_, address(factory)
        );

        // Fund and activate
        uint256 dep = AMOUNT * 8;
        usdc.mint(owner_, dep);
        vm.startPrank(owner_);
        usdc.approve(address(acct), dep);
        acct.deposit(dep);
        vm.stopPrank();
    }

    // ── Executor path cannot modify strategy parameters ───────────────────────

    function test_authorisedPull_cannotChangeTargetAsset() public {
        address assetBefore = acct.targetAsset();
        vm.warp(acct.nextExecutionTime());
        vm.prank(executor_);
        acct.authorisedPull(AMOUNT, 1);
        assertEq(acct.targetAsset(), assetBefore, "targetAsset must not change");
    }

    function test_authorisedPull_cannotChangeAmountPerExecution() public {
        uint256 amountBefore = acct.amountPerExecution();
        vm.warp(acct.nextExecutionTime());
        vm.prank(executor_);
        acct.authorisedPull(AMOUNT, 1);
        assertEq(acct.amountPerExecution(), amountBefore, "amountPerExecution must not change");
    }

    /// @dev The owner is both the authorization boundary and the output recipient,
    ///      so it is the parameter the executor path must never be able to move.
    function test_authorisedPull_cannotChangeOwner() public {
        address ownerBefore = acct.owner();
        vm.warp(acct.nextExecutionTime());
        vm.prank(executor_);
        acct.authorisedPull(AMOUNT, 1);
        assertEq(acct.owner(), ownerBefore, "owner must not change");
    }

    function test_receiveOutput_cannotChangeParams() public {
        address assetBefore = acct.targetAsset();
        uint256 amountBefore = acct.amountPerExecution();
        weth.mint(address(acct), 1e18);
        vm.prank(executor_);
        acct.receiveOutput(address(weth), 1e18);
        assertEq(acct.targetAsset(), assetBefore, "receiveOutput must not change targetAsset");
        assertEq(acct.amountPerExecution(), amountBefore, "receiveOutput must not change amount");
    }

    // ── Only authorised callers can trigger external calls ───────────────────

    function test_authorisedPull_onlyExecutor() public {
        vm.warp(acct.nextExecutionTime());
        vm.prank(attacker);
        vm.expectRevert(UserStrategyAccount.Unauthorized.selector);
        acct.authorisedPull(AMOUNT, 1);
    }

    function test_receiveOutput_onlyExecutor() public {
        vm.prank(attacker);
        vm.expectRevert(UserStrategyAccount.Unauthorized.selector);
        acct.receiveOutput(address(weth), 1e18);
    }

    function test_deposit_onlyOwner() public {
        // Only the stored owner may fund a strategy. A non-owner deposit must revert
        // before any token movement or state change, so nobody can irreversibly credit a
        // strategy they cannot withdraw from.
        uint256 depositedBefore = acct.depositedAmount();
        uint256 balanceBefore   = acct.balance();
        uint256 nextExecBefore  = acct.nextExecutionTime();
        uint256 registerBefore  = factory.registerCount();

        usdc.mint(attacker, AMOUNT);
        vm.startPrank(attacker);
        usdc.approve(address(acct), AMOUNT);
        vm.expectRevert(UserStrategyAccount.Unauthorized.selector);
        acct.deposit(AMOUNT);
        vm.stopPrank();

        assertEq(usdc.balanceOf(attacker), AMOUNT, "rejected deposit must not move caller USDC");
        assertEq(usdc.allowance(attacker, address(acct)), AMOUNT, "rejected deposit must not consume allowance");
        assertEq(acct.depositedAmount(), depositedBefore, "rejected deposit must not change depositedAmount");
        assertEq(acct.balance(), balanceBefore, "rejected deposit must not change balance");
        assertEq(acct.nextExecutionTime(), nextExecBefore, "rejected deposit must not reschedule");
        assertEq(factory.registerCount(), registerBefore, "rejected deposit must not register");
    }

    function test_withdraw_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(UserStrategyAccount.Unauthorized.selector);
        acct.withdraw();
    }

    function test_pause_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(UserStrategyAccount.Unauthorized.selector);
        acct.pause();
    }

    // ── Reentrancy protection on key functions ─────────────────────────────────
    // A simple reentrant token cannot isolate the guard, because authorisedPull
    // (onlyBatchExecutor) and withdraw (onlyOwner) would reject a token's reentry
    // on access control first. To prove the nonReentrant guard specifically, the
    // reentry must come FROM the authorised party - so MaliciousActor is installed
    // as the batchExecutor / owner, and a NotifyingERC20 calls it back mid-transfer.

    function test_authorisedPull_blocksReentrancy() public {
        NotifyingERC20 nUsdc = new NotifyingERC20();
        SecFactory nFactory = new SecFactory(address(nUsdc), treasury);
        MaliciousActor evilExecutor = new MaliciousActor();

        UserStrategyAccount impl2 = new UserStrategyAccount();
        UserStrategyAccount reAcct = UserStrategyAccount(Clones.clone(address(impl2)));
        reAcct.initialize(
            owner_, address(weth), AMOUNT, uint8(DCAFactory.Tier.Weekly),
            false, address(0), address(evilExecutor), address(nFactory)
        );

        // Fund via the real deposit flow (transferFrom does not notify).
        uint256 dep = AMOUNT * 8;
        nUsdc.mint(owner_, dep);
        vm.startPrank(owner_);
        nUsdc.approve(address(reAcct), dep);
        reAcct.deposit(dep);
        vm.stopPrank();

        // The account pays the batchExecutor (= MaliciousActor); arm the callback there.
        nUsdc.arm(address(evilExecutor));

        vm.warp(reAcct.nextExecutionTime());
        evilExecutor.attackPull(address(reAcct), AMOUNT);

        assertTrue(evilExecutor.reentered(), "reentry must actually fire (else test is vacuous)");
        assertTrue(evilExecutor.reentryBlocked(), "nonReentrant must block reentry into authorisedPull");
        assertEq(reAcct.balance(), dep - AMOUNT, "exactly one pull - no double-spend");
        assertFalse(reAcct.usedNonces(9999), "reentrant nonce never consumed");
    }

    function test_withdraw_blocksReentrancy() public {
        NotifyingERC20 nUsdc = new NotifyingERC20();
        SecFactory nFactory = new SecFactory(address(nUsdc), treasury);
        MaliciousActor evilOwner = new MaliciousActor();

        UserStrategyAccount impl2 = new UserStrategyAccount();
        UserStrategyAccount reAcct = UserStrategyAccount(Clones.clone(address(impl2)));
        reAcct.initialize(
            address(evilOwner), address(weth), AMOUNT, uint8(DCAFactory.Tier.Weekly),
            false, address(0), executor_, address(nFactory)
        );

        // deposit() is owner-only, so the malicious owner funds its own strategy.
        uint256 dep = AMOUNT * 8;
        nUsdc.mint(address(evilOwner), dep);
        evilOwner.fundStrategy(address(nUsdc), address(reAcct), dep);

        // withdraw() pays the owner (= MaliciousActor); arm the callback there.
        nUsdc.arm(address(evilOwner));
        evilOwner.attackWithdraw(address(reAcct));

        assertTrue(evilOwner.reentered(), "reentry must actually fire (else test is vacuous)");
        assertTrue(evilOwner.reentryBlocked(), "nonReentrant must block reentry into withdraw");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reentrancy helpers: a token that calls back into an armed recipient on
// transfer, and an actor installed as batchExecutor/owner that re-enters from
// within that callback (so access-control passes and only nonReentrant can block).
// ─────────────────────────────────────────────────────────────────────────────

contract NotifyingERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public armed; // recipient to notify on transfer

    function arm(address who) external { armed = who; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function forceApprove(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        if (to == armed && armed != address(0)) IReentryCallback(to).onTokens();
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
}

contract MaliciousActor {
    enum Mode { None, Pull, Withdraw }
    Mode public mode;
    address public target;
    uint256 public amount;
    bool public reentered;
    bool public reentryBlocked;

    function attackPull(address account, uint256 a) external {
        mode = Mode.Pull; target = account; amount = a;
        IReentryVictim(account).authorisedPull(a, 1); // msg.sender == this == batchExecutor
        mode = Mode.None;
    }

    function attackWithdraw(address account) external {
        mode = Mode.Withdraw; target = account;
        IReentryVictim(account).withdraw(); // msg.sender == this == owner
        mode = Mode.None;
    }

    /// Funds a strategy this contract owns. deposit() is owner-only, and mode is None
    /// here so the token callback stays inert during setup.
    function fundStrategy(address token, address account, uint256 a) external {
        NotifyingERC20(token).approve(account, a);
        IReentryVictim(account).deposit(a);
    }

    // Called by NotifyingERC20 mid-transfer; re-enters the same guarded function.
    function onTokens() external {
        if (reentered || mode == Mode.None) return;
        reentered = true;
        if (mode == Mode.Pull) {
            try IReentryVictim(target).authorisedPull(amount, 9999) { reentryBlocked = false; }
            catch { reentryBlocked = true; }
        } else {
            try IReentryVictim(target).withdraw() { reentryBlocked = false; }
            catch { reentryBlocked = true; }
        }
    }
}

interface IReentryCallback {
    function onTokens() external;
}

interface IReentryVictim {
    function authorisedPull(uint256 amount, uint256 nonce) external returns (uint256, uint256);
    function withdraw() external;
    function deposit(uint256 amount) external;
}

// ─────────────────────────────────────────────────────────────────────────────
// Provider-agnostic, no-hardcoded-address structural properties.
// The source-text half (no hardcoded addresses / no provider naming in code) is a
// property of the source itself; these tests assert the runtime structural property is real.
// ─────────────────────────────────────────────────────────────────────────────

contract ProviderAgnosticExecutorTest is Test {
    SecERC20 usdc;
    SecFactory factory;
    BatchExecutor executor_;

    address owner_      = makeAddr("owner");
    address initialExec = makeAddr("initialExecutor");
    address router      = makeAddr("router");

    function setUp() public {
        usdc    = new SecERC20();
        factory = new SecFactory(address(usdc), owner_);
        executor_ = new BatchExecutor(address(factory), address(usdc), router, initialExec, owner_, owner_);
    }

    /// No hardcoded addresses (the checkable half): the four external addresses the constructor is given are the
    /// ones the contract stores and uses.
    ///
    /// This proves injection, not the ABSENCE of hardcoding. No runtime assertion can establish
    /// "no address is baked into the source" - that is a source-level property, established by
    /// inspecting `src/` for address literals, as the header above says. Named accordingly, so
    /// nobody reads a green test as covering the stronger claim.
    function test_storesInjectedAddresses() public view {
        assertEq(address(executor_.usdc()),    address(usdc),    "usdc must be the injected address");
        assertEq(address(executor_.factory()), address(factory), "factory must be the injected address");
        assertEq(address(executor_.swapRouter()), router,        "swapRouter must be the injected address");
        assertEq(executor_.executor(),          initialExec,     "executor must be the injected address");
    }

    /// The executor is a provider-agnostic plain address, swappable via setExecutor -
    /// no automation provider is baked into the contract logic.
    function test_executorIsProviderAgnostic() public {
        address newProvider = makeAddr("anyProvider");
        vm.prank(owner_);
        executor_.setExecutor(newProvider);
        assertEq(executor_.executor(), newProvider, "executor must be swappable to any provider");
    }
}
