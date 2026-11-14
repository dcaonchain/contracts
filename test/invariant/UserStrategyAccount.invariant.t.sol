// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../../src/UserStrategyAccount.sol";
import "../../src/DCAFactory.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Mocks
// ─────────────────────────────────────────────────────────────────────────────

contract InvERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external returns (bool) {
        if (balanceOf[msg.sender] < a) return false;
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        allowance[from][msg.sender] -= a; balanceOf[from] -= a; balanceOf[to] += a; return true;
    }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function forceApprove(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
}

contract InvFactory {
    address public immutable ownerAddr;
    InvERC20 public immutable usdcToken;
    mapping(DCAFactory.Tier => uint256) public minExecutions;
    uint256 public executionFeeBps = 15;
    uint256 public yieldFeeBps = 1500;
    uint256 public registerCount;
    uint256 public removeCount;

    constructor(address _usdc, address _owner) {
        usdcToken = InvERC20(_usdc);
        ownerAddr = _owner;
        minExecutions[DCAFactory.Tier.Weekly] = 8;
    }

    function usdc() external view returns (address) { return address(usdcToken); }
    function owner() external view returns (address) { return ownerAddr; }
    /// @dev `withdraw()` pays the terminal yield fee here, so a yield-enabled handler needs it.
    function treasury() external view returns (address) { return ownerAddr; }
    function registerStrategy(address) external { registerCount++; }
    function removeStrategy(address) external { removeCount++; }
}

// ─────────────────────────────────────────────────────────────────────────────
// Handler
// ─────────────────────────────────────────────────────────────────────────────

contract USAHandler is Test {
    UserStrategyAccount public acct;
    InvERC20 public usdc;
    InvERC20 public weth;
    InvFactory public factory;

    address public executor   = makeAddr("executor");
    address public owner_     = makeAddr("owner");
    address public treasury   = makeAddr("treasury");

    uint256 constant AMOUNT   = 25e6;
    uint256 constant MIN_DEP  = AMOUNT * 8; // weekly min
    uint256 public totalDeposited;
    uint256 public totalPulled;

    // Snapshot of immutable params at init - used to check that they never change
    address public snapTargetAsset;
    uint256 public snapAmountPerExecution;
    uint8   public snapTier;
    address public snapOwner;
    bool    public snapYieldEnabled;

    constructor() {
        usdc    = new InvERC20();
        weth    = new InvERC20();
        factory = new InvFactory(address(usdc), treasury);

        UserStrategyAccount impl = new UserStrategyAccount();
        acct = UserStrategyAccount(Clones.clone(address(impl)));
        acct.initialize(
            owner_, address(weth), AMOUNT, uint8(DCAFactory.Tier.Weekly),
            false, address(0), executor, address(factory)
        );

        // Snapshot immutable params
        snapTargetAsset        = acct.targetAsset();
        snapAmountPerExecution = acct.amountPerExecution();
        snapTier               = uint8(acct.tier());
        snapOwner              = acct.owner();
        snapYieldEnabled       = acct.yieldEnabled();
    }

    function deposit(uint256 seed) external {
        uint256 amount = MIN_DEP + (seed % (MIN_DEP * 10));
        usdc.mint(owner_, amount);
        vm.startPrank(owner_);
        usdc.approve(address(acct), amount);
        try acct.deposit(amount) {
            totalDeposited += amount;
        } catch {}
        vm.stopPrank();
    }

    function pull(uint256 nonceSeed) external {
        uint256 n = (nonceSeed % 10000) + 1;
        vm.warp(acct.nextExecutionTime());
        vm.prank(executor);
        try acct.authorisedPull(AMOUNT, n) returns (uint256 got, uint256) {
            if (got > 0) totalPulled += got;
        } catch {}
    }

    function pause_() external {
        if (!acct.paused()) {
            vm.prank(owner_);
            try acct.pause() {} catch {}
        }
    }

    function resume_() external {
        if (acct.paused()) {
            vm.prank(owner_);
            try acct.resume() {} catch {}
        }
    }

    function withdraw_() external {
        vm.prank(owner_);
        try acct.withdraw() {
            totalDeposited = 0;
            totalPulled = 0;
        } catch {}
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Invariant tests
// ─────────────────────────────────────────────────────────────────────────────

contract UserStrategyAccountInvariantTest is StdInvariant, Test {
    USAHandler internal handler;

    function setUp() public {
        handler = new USAHandler();
        targetContract(address(handler));
    }

    /// Strategy parameters never change after initialize().
    function invariant_paramsNeverChange() public view {
        UserStrategyAccount acct = handler.acct();
        assertEq(acct.targetAsset(),        handler.snapTargetAsset(),        "targetAsset changed");
        assertEq(acct.amountPerExecution(), handler.snapAmountPerExecution(), "amountPerExecution changed");
        assertEq(uint8(acct.tier()),        handler.snapTier(),               "tier changed");
        assertEq(acct.owner(),              handler.snapOwner(),              "owner changed");
        assertEq(acct.yieldEnabled(),       handler.snapYieldEnabled(),       "yieldEnabled changed");
    }

    /// The account's `balance` field never overstates the USDC it actually holds, so a withdrawal
    /// sized from that field cannot revert for want of tokens.
    ///
    /// Named and described for what it asserts. It is NOT "withdraw() is always callable": that is
    /// strictly stronger and does not hold in every case - a yield-enabled account with positive
    /// yield pays the yield fee to `factory.treasury()` before paying the owner, so a treasury the
    /// base token refuses to pay reverts the whole withdrawal. This checks the accounting
    /// precondition only, on the idle-balance path.
    function invariant_balanceFieldMatchesTokenBalance() public view {
        UserStrategyAccount acct = handler.acct();
        uint256 contractBal = handler.usdc().balanceOf(address(acct));
        uint256 trackedBal  = acct.balance();
        assertEq(contractBal, trackedBal, "balance field must match actual USDC held");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Fuzz tests: exact pulls and pending-output recovery
// ─────────────────────────────────────────────────────────────────────────────

contract UserStrategyAccountFuzzTest is Test {
    UserStrategyAccount impl;
    InvERC20 usdc;
    InvERC20 weth;
    InvFactory factory;

    address executor_ = makeAddr("executor");
    address owner_    = makeAddr("owner");
    address treasury  = makeAddr("treasury");

    uint256 constant AMOUNT = 25e6;

    function setUp() public {
        usdc    = new InvERC20();
        weth    = new InvERC20();
        factory = new InvFactory(address(usdc), treasury);
        impl    = new UserStrategyAccount();
    }

    function _deploy() internal returns (UserStrategyAccount acct) {
        acct = _deploy(address(weth));
    }

    /// @dev `receiveOutput` accepts only the account's own target asset, so a test that drives
    ///      it with another token deploys an account that buys that token.
    function _deploy(address target) internal returns (UserStrategyAccount acct) {
        acct = UserStrategyAccount(Clones.clone(address(impl)));
        acct.initialize(
            owner_, target, AMOUNT, uint8(DCAFactory.Tier.Weekly),
            false, address(0), executor_, address(factory)
        );
        uint256 dep = AMOUNT * 8;
        usdc.mint(owner_, dep);
        vm.startPrank(owner_);
        usdc.approve(address(acct), dep);
        acct.deposit(dep);
        vm.stopPrank();
    }

    /// authorisedPull with any amount != amountPerExecution must revert or return 0.
    function testFuzz_authorisedPull_onlyExactAmount(uint256 wrongAmount) public {
        UserStrategyAccount acct = _deploy();
        vm.assume(wrongAmount != AMOUNT);
        vm.warp(acct.nextExecutionTime());
        vm.prank(executor_);
        vm.expectRevert(); // WrongAmount
        acct.authorisedPull(wrongAmount, 999);
    }

    /// authorisedPull with correct amount succeeds and transfers exactly amountPerExecution.
    function testFuzz_authorisedPull_transfersExactAmount(uint256 nonce) public {
        UserStrategyAccount acct = _deploy();
        nonce = bound(nonce, 1, type(uint256).max);
        vm.warp(acct.nextExecutionTime());
        uint256 before = usdc.balanceOf(executor_);
        vm.prank(executor_);
        (uint256 got, ) = acct.authorisedPull(AMOUNT, nonce);
        assertEq(got, AMOUNT, "must transfer exactly amountPerExecution");
        assertEq(usdc.balanceOf(executor_) - before, AMOUNT, "executor receives exact amount");
    }

    /// pendingWithdrawals[asset] accumulates correctly across multiple receiveOutput calls.
    function testFuzz_pendingWithdrawals_neverLost(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 0, 1e30);
        amount2 = bound(amount2, 0, 1e30);

        // Use a fail-transfer token to force fallback path
        FailToken ft = new FailToken();
        UserStrategyAccount acct = _deploy(address(ft));
        ft.mint(address(acct), amount1 + amount2);

        vm.prank(executor_);
        acct.receiveOutput(address(ft), amount1);

        vm.prank(executor_);
        acct.receiveOutput(address(ft), amount2);

        assertEq(
            acct.pendingWithdrawals(address(ft)),
            amount1 + amount2,
            "pendingWithdrawals must accumulate without loss"
        );
    }

    /// Pending recovery reconciles against the real balance. For ANY divergence
    /// between the recorded amount and what the account actually holds, recovery moves exactly
    /// the real balance and always clears the record. Deliberately not asserted as
    /// `recorded <= balanceOf` at all times: a downward rebase can break that after the mapping
    /// is written, and hardening withdrawPending cannot make it true beforehand.
    function testFuzz_withdrawPending_recoversRealBalanceAndClears(uint256 recorded, uint256 held)
        public
    {
        recorded = bound(recorded, 1, 1e30); // non-zero: the gate must authorise recovery
        held     = bound(held, 0, 1e30);     // unconstrained relative to `recorded`

        FailToken ft = new FailToken();
        UserStrategyAccount acct = _deploy(address(ft));
        ft.mint(address(acct), held);

        vm.prank(executor_);
        acct.receiveOutput(address(ft), recorded);
        assertEq(acct.pendingWithdrawals(address(ft)), recorded, "record written as notified");

        ft.setFail(false);
        vm.prank(owner_);
        acct.withdrawPending(address(ft));

        assertEq(ft.balanceOf(owner_), held, "recovery moves exactly the real balance");
        assertEq(ft.balanceOf(address(acct)), 0, "no recoverable output left locked");
        assertEq(acct.pendingWithdrawals(address(ft)), 0, "record always cleared");
    }
}

contract FailToken {
    mapping(address => uint256) public balanceOf;
    // Delivery fails by default so receiveOutput takes the fallback path. Cleared to let a
    // later recovery through.
    bool public shouldFail = true;

    function setFail(bool v) external { shouldFail = v; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external returns (bool) {
        if (shouldFail) return false;
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
    function approve(address, uint256) external pure returns (bool) { return true; }
    function forceApprove(address, uint256) external pure returns (bool) { return true; }
    function allowance(address, address) external pure returns (uint256) { return type(uint256).max; }
}

// ─────────────────────────────────────────────────────────────────────────────
// Yield lifecycle
//
// Everything above runs with yield DISABLED, where `depositedAmount` and `balance` move together and
// no fee path is reachable. These assert the accounting that only exists once a venue can return
// more than it was given.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Conforming venue that moves real balances and can accrue beyond the principal supplied.
contract InvVenue {
    InvERC20 public immutable token;

    constructor(InvERC20 t) { token = t; }

    function deposit(uint256 amount) external {
        require(token.transferFrom(msg.sender, address(this), amount), "pull failed");
    }

    function withdraw(uint256 amount) external returns (uint256 sent) {
        uint256 held = token.balanceOf(address(this));
        sent = held < amount ? held : amount;
        require(sent + YIELD_WITHDRAWAL_TOLERANCE >= amount, "venue: shortfall");
        require(token.transfer(msg.sender, sent), "transfer failed");
    }

    function withdrawAll() external returns (uint256 sent) {
        sent = token.balanceOf(address(this));
        if (sent > 0) require(token.transfer(msg.sender, sent), "transfer failed");
    }

    function balanceOf(address) external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}

contract YieldLifecycleHandler is Test {
    UserStrategyAccount public acct;
    InvERC20 public usdc;
    InvVenue public venue;
    InvFactory public factory;

    address public executor = makeAddr("yieldExecutor");
    address public owner_ = makeAddr("yieldOwner");
    address public treasury = makeAddr("yieldTreasury");

    uint256 constant AMOUNT = 25e6;
    uint256 constant MIN_DEP = AMOUNT * 8;

    /// @dev Every base unit that entered, and every base unit that left. The two sides of the
    ///      conservation invariant; nothing here is derived from the contract's own fields.
    uint256 public totalDeposited;
    uint256 public totalAccrued;
    uint256 public totalDrawn;
    uint256 public totalExited;
    uint256 public totalYieldFee;

    constructor() {
        usdc = new InvERC20();
        InvERC20 weth = new InvERC20();
        factory = new InvFactory(address(usdc), treasury);
        venue = new InvVenue(usdc);

        UserStrategyAccount impl = new UserStrategyAccount();
        acct = UserStrategyAccount(Clones.clone(address(impl)));
        acct.initialize(
            owner_, address(weth), AMOUNT, uint8(DCAFactory.Tier.Weekly),
            true, address(venue), executor, address(factory)
        );
    }

    function deposit(uint256 seed) external {
        uint256 amount = MIN_DEP + (seed % (MIN_DEP * 4));
        usdc.mint(owner_, amount);
        vm.startPrank(owner_);
        usdc.approve(address(acct), amount);
        try acct.deposit(amount) {
            totalDeposited += amount;
        } catch {}
        vm.stopPrank();
    }

    /// @dev The whole reason this handler exists: a venue whose position grows beyond what was
    ///      supplied. Bounded well below the book so both fee branches are reachable.
    function accrue(uint256 seed) external {
        if (acct.closed()) return;
        uint256 amount = seed % (AMOUNT * 4);
        if (amount == 0) return;
        usdc.mint(address(venue), amount);
        totalAccrued += amount;
    }

    function pull(uint256 nonceSeed) external {
        uint256 n = (nonceSeed % 10000) + 1;
        if (acct.nextExecutionTime() > block.timestamp) vm.warp(acct.nextExecutionTime());
        vm.prank(executor);
        try acct.authorisedPull(AMOUNT, n) returns (uint256 got, uint256 fee) {
            totalDrawn += got + fee;
            totalYieldFee += fee;
        } catch {}
    }

    function pause_() external {
        vm.prank(owner_);
        try acct.pause() {} catch {}
    }

    function resume_() external {
        vm.prank(owner_);
        try acct.resume() {} catch {}
    }

    /// @dev Seed-gated so closure is RARE. `withdraw` is terminal, so an ungated action closes the
    ///      account within the first few calls of most sequences and everything after it is a no-op -
    ///      which leaves the long mixed lifecycles this handler exists to explore unexplored. The
    ///      probe that showed this: with closure ungated, the sequences that charged a fee at all
    ///      shrank to two calls.
    function withdraw_(uint256 seed) external {
        if (seed % 8 != 0) return;
        uint256 treasuryBefore = usdc.balanceOf(factory.treasury());
        uint256 ownerBefore = usdc.balanceOf(owner_);
        vm.prank(owner_);
        try acct.withdraw() {
            uint256 feePaid = usdc.balanceOf(factory.treasury()) - treasuryBefore;
            totalYieldFee += feePaid;
            totalExited += feePaid + (usdc.balanceOf(owner_) - ownerBefore);
        } catch {}
    }

    function reachable() public view returns (uint256) {
        return acct.balance() + venue.balanceOf(address(acct));
    }
}

contract UserStrategyAccountYieldLifecycleInvariantTest is StdInvariant, Test {
    YieldLifecycleHandler internal handler;

    function setUp() public {
        handler = new YieldLifecycleHandler();
        targetContract(address(handler));
    }

    /// Every base unit that entered is either still reachable or has left through one of
    /// the two exits. Nothing is created, and nothing is stranded.
    ///
    /// Stated over MEASURED movements - the handler's own running totals - rather than over the
    /// account's fields, so a bug that corrupted `balance` or `depositedAmount` cannot also corrupt
    /// the expectation it is checked against.
    function invariant_everyBaseUnitIsAccountedFor() public view {
        assertEq(
            handler.totalDeposited() + handler.totalAccrued(),
            handler.totalDrawn() + handler.totalExited() + handler.reachable(),
            "deposits plus yield must equal what left plus what remains"
        );
    }

    /// The protocol never collects more than its share of the yield, over any sequence.
    ///
    /// Per charge the quote satisfies `fee * 10000 <= realizedYield * b` in both branches, and every
    /// base unit of yield enters at most one realization, so the bound survives summation. It is the
    /// direction that matters: flooring and absorbed venue shortfalls push the collected total DOWN,
    /// never up, so all rounding drift is the user's gain.
    function invariant_yieldFeesNeverExceedTheProtocolShare() public view {
        assertLe(
            handler.totalYieldFee() * 10_000,
            handler.totalAccrued() * handler.factory().yieldFeeBps(),
            "collected yield fee exceeded the rate applied to all yield that ever accrued"
        );
    }

    /// The principal book never exceeds what the account can reach, so the
    /// saturating clamp in the book transition is never the thing keeping it non-negative.
    ///
    /// Yield-first spending is what makes this hold: a draw consumes untaxed yield before principal,
    /// so `principalPart <= depositedAmount` identically whenever the venue delivers no more than it
    /// reported. Reaching the clamp would mean a venue delivered beyond its own prior report.
    function invariant_theBookNeverExceedsReachableValue() public view {
        assertLe(
            handler.acct().depositedAmount(),
            handler.reachable(),
            "principal book exceeded reachable value"
        );
    }
}
