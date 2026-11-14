// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/UserStrategyAccount.sol";
import "../../src/DCAFactory.sol";
import "../../src/adapters/yield/AaveV3YieldAdapter.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

// -------------------------------------------------------------------------
// Mocks
// -------------------------------------------------------------------------

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

contract MockYieldAdapter {
    MockERC20 public usdc;
    mapping(address => uint256) public deposits;
    bool public shouldFail;
    /// @dev Non-conforming behaviour, on purpose: a real adapter must revert rather than return
    ///      short, so these knobs let the account's own defences be exercised directly.
    uint256 public shortfallOnWithdraw;
    uint256 public extraOnWithdraw;

    constructor(address _usdc) { usdc = MockERC20(_usdc); }
    function setFail(bool v) external { shouldFail = v; }
    function setShortfall(uint256 v) external { shortfallOnWithdraw = v; }
    function setExtra(uint256 v) external { extraOnWithdraw = v; }

    function deposit(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        deposits[msg.sender] += amount;
    }
    function withdraw(uint256 amount) external returns (uint256) {
        require(!shouldFail, "yield failure");
        uint256 received = amount + extraOnWithdraw - shortfallOnWithdraw;
        // A CONFORMING venue reverts rather than silently under-delivering when the position cannot
        // cover the request: AaveV3YieldAdapter clamps to its aToken balance and then fails its own
        // shortfall postcondition. Without this the mock's base token just returns false, the
        // adapter ignores it, and the account auto-pauses where a conforming venue would merely skip - which
        // turns the ordinary "venue cannot fund contribution plus fee" case into a fault.
        require(usdc.balanceOf(address(this)) >= received, "insufficient position");
        usdc.transfer(msg.sender, received);
        return received;
    }
    function withdrawAll() external returns (uint256) {
        uint256 bal = usdc.balanceOf(address(this));
        if (bal > 0) usdc.transfer(msg.sender, bal);
        return bal;
    }
    function balanceOf(address) external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
}

/// @dev A venue that actually conforms to IYieldAdapter, unlike MockYieldAdapter above: it never
///      returns base tokens it does not hold, and it reverts rather than returning materially short.
///      Structurally the AaveV3YieldAdapter contract with Aave replaced by a plain balance.
///
///      `overReturn` exercises the one legitimate way a yield-enabled account ends up holding idle
///      USDC. The interface bounds a venue from below (`received >= amount - TOLERANCE`) and not
///      from above, so returning more than requested is conforming, and `authorisedPull` credits
///      the surplus to `balance`. Aave never does it; the interface admits it.
contract MockConformingVenue {
    error VenueShortfall(uint256 requested, uint256 received);

    MockERC20 public immutable usdc;
    uint256 public overReturn;
    /// @dev Units this venue fails to credit on EACH deposit, modelling Aave's liquidity-index
    ///      rounding. It holds the base tokens either way; only its report lags, which is
    ///      what makes a top-up's credited delta smaller than the amount supplied.
    uint256 public depositLag;
    uint256 private _uncredited;

    constructor(address _usdc) { usdc = MockERC20(_usdc); }

    function setOverReturn(uint256 v) external { overReturn = v; }

    function setDepositLag(uint256 v) external { depositLag = v; }

    /// @dev Return values are checked, unlike the loose mock above: this one is meant to model a
    ///      conforming venue, and a silently failed transfer here would make a test pass for the
    ///      wrong reason.
    function deposit(uint256 amount) external {
        require(usdc.transferFrom(msg.sender, address(this), amount), "deposit transfer failed");
        _uncredited += depositLag;
    }

    function withdraw(uint256 amount) external returns (uint256 received) {
        uint256 held = usdc.balanceOf(address(this));
        uint256 want = amount + overReturn;
        received = held < want ? held : want;
        if (received + YIELD_WITHDRAWAL_TOLERANCE < amount) revert VenueShortfall(amount, received);
        require(usdc.transfer(msg.sender, received), "withdraw transfer failed");
    }

    function withdrawAll() external returns (uint256 received) {
        received = usdc.balanceOf(address(this));
        if (received > 0) require(usdc.transfer(msg.sender, received), "withdrawAll transfer failed");
    }

    function balanceOf(address) external view returns (uint256) {
        uint256 held = usdc.balanceOf(address(this));
        return held > _uncredited ? held - _uncredited : 0;
    }
}

/// @dev Every call reverts, including `balanceOf`.
contract MockRevertingAdapter {
    fallback() external { revert("adapter is down"); }
}

/// @dev Reverts with revert data that is exactly one huge word, so it is indistinguishable from a
///      successful answer on length alone. This is the case that makes the staticcall's success flag
///      load-bearing rather than redundant with the length check.
contract MockRevertingWordAdapter {
    fallback() external { assembly { mstore(0, not(0)) revert(0, 32) } }
}

/// @dev Answers `balanceOf` with half a word. Cannot be written as a normal function - the ABI
///      encoder would pad it back to 32 bytes, which is the whole point of the case.
contract MockTruncatingAdapter {
    fallback() external { assembly { mstore(0, 1) return(0, 16) } }
}

/// @dev Answers with two words. A conforming adapter returns exactly one, and reading only the
///      first word of a longer answer means trusting an encoding nobody agreed to.
contract MockOverlongAdapter {
    fallback() external { assembly { mstore(0, not(0)) mstore(32, not(0)) return(0, 64) } }
}

/// @dev Well-formed answers, all of them false: it takes deposits without holding anything and
///      reports a position of type(uint256).max. Two properties need exactly this shape - that an
///      absurd venue balance cannot overflow the funding comparison, and that `closed` decides on
///      its own, which a conforming adapter can never show because withdraw() empties it first.
/// @dev Reports an absurd position once `setLie(true)` is on, whatever it actually holds.
///
///      Its deposit conforms, unlike the rest of it. The account measures the pull and the
///      position credit itself, so an adapter that pulls nothing can never be deposited into
///      and the funding views below could not be reached through one. Switching the lie on after
///      the deposit lands is also the more honest shape of the case: a venue that reports truthfully
///      at deposit time and drifts afterwards, which is precisely the window nothing re-checks.
contract MockLyingAdapter {
    MockERC20 public immutable usdc;
    bool public lie;

    constructor(address _usdc) { usdc = MockERC20(_usdc); }

    function setLie(bool v) external { lie = v; }

    function deposit(uint256 amount) external {
        require(usdc.transferFrom(msg.sender, address(this), amount), "deposit transfer failed");
    }
    function withdraw(uint256) external pure returns (uint256) { return 0; }
    function withdrawAll() external returns (uint256 received) {
        received = usdc.balanceOf(address(this));
        if (received > 0) require(usdc.transfer(msg.sender, received), "withdrawAll transfer failed");
    }
    function balanceOf(address) external view returns (uint256) {
        return lie ? type(uint256).max : usdc.balanceOf(address(this));
    }
}

/// @dev A venue that REPORTS an absurd position while DELIVERING honestly, and that can over-return
///      on a draw so the account is left with a non-zero tracked `balance`. Together those are the
///      exact `_satAdd(balance, venue)` case: every other over-reporting mock here
///      either refuses to deliver, which diverts to the shortfall path, or leaves `balance` at zero,
///      where the saturating addition is indistinguishable from a plain one.
contract MockOverReportingVenue {
    MockERC20 public immutable usdc;
    uint256 public position;
    uint256 public overReturn;
    bool public lie;

    constructor(address _usdc) { usdc = MockERC20(_usdc); }

    function setLie(bool v) external { lie = v; }

    /// @dev Units handed back ON TOP of what was asked for, which is what leaves idle `balance`
    ///      behind after settlement. Conforming: the interface permits a venue to return more.
    function setOverReturn(uint256 v) external { overReturn = v; }

    function deposit(uint256 amount) external {
        require(usdc.transferFrom(msg.sender, address(this), amount), "deposit transfer failed");
        position += amount;
    }

    function withdraw(uint256 amount) external returns (uint256 sent) {
        sent = amount + overReturn;
        if (sent > position) sent = position;
        position -= sent;
        require(usdc.transfer(msg.sender, sent), "withdraw transfer failed");
    }

    function withdrawAll() external returns (uint256 sent) {
        sent = position;
        position = 0;
        if (sent > 0) require(usdc.transfer(msg.sender, sent), "withdrawAll transfer failed");
    }

    function balanceOf(address) external view returns (uint256) {
        return lie ? type(uint256).max : position;
    }
}

/// @dev Aave's pool, reduced to the one behaviour the deposit postcondition turns on: it credits
///      `shortfall` fewer receipt tokens than it was supplied. Lets the REAL AaveV3YieldAdapter run
///      behind a real account, which is what makes the adapter's own check observable from the
///      account's side.
/// @dev Pulls in full, and its reported position DROPS across the deposit. Exercises the clamp in
///      the account's credited-delta computation: without it the subtraction underflows and panics
///      instead of reverting with the named shortfall error.
contract MockShrinkingPositionAdapter {
    MockERC20 public immutable usdc;
    uint256 public position;

    constructor(address _usdc) { usdc = MockERC20(_usdc); }

    function seed(uint256 v) external { position = v; }

    function deposit(uint256 amount) external {
        require(usdc.transferFrom(msg.sender, address(this), amount), "pull failed");
        position = position / 2;
    }
    function withdraw(uint256) external pure returns (uint256) { return 0; }
    function withdrawAll() external returns (uint256 received) {
        received = usdc.balanceOf(address(this));
        if (received > 0) require(usdc.transfer(msg.sender, received), "transfer failed");
    }
    function balanceOf(address) external view returns (uint256) { return position; }
}

/// @dev Pulls in full every time, but credits only the FIRST deposit and pockets the rest. Catches
///      a bound measured against an absolute position rather than a per-call delta: the first
///      deposit's credit would otherwise cover for a second one that credited nothing.
contract MockCreditOnceAdapter {
    MockERC20 public immutable usdc;
    uint256 public position;

    constructor(address _usdc) { usdc = MockERC20(_usdc); }

    function deposit(uint256 amount) external {
        require(usdc.transferFrom(msg.sender, address(this), amount), "pull failed");
        if (position == 0) position = amount;
    }
    function withdraw(uint256) external pure returns (uint256) { return 0; }
    function withdrawAll() external returns (uint256 received) {
        received = usdc.balanceOf(address(this));
        if (received > 0) require(usdc.transfer(msg.sender, received), "transfer failed");
    }
    function balanceOf(address) external view returns (uint256) { return position; }
}

/// @dev Pushes base tokens INTO the account instead of pulling any out, which is the one way the
///      account's before/after subtraction could underflow if it were unclamped.
contract MockRefundingAdapter {
    MockERC20 public immutable usdc;

    constructor(address _usdc) { usdc = MockERC20(_usdc); }

    function deposit(uint256 amount) external { usdc.transfer(msg.sender, amount); }
    function withdraw(uint256) external pure returns (uint256) { return 0; }
    function withdrawAll() external pure returns (uint256) { return 0; }
    function balanceOf(address) external pure returns (uint256) { return 0; }
}

contract MockUnderCreditingAavePool {
    MockERC20 public immutable aToken;
    uint256 public immutable shortfall;

    constructor(address _aToken, uint256 _shortfall) {
        aToken = MockERC20(_aToken);
        shortfall = _shortfall;
    }

    function supply(address, uint256 amount, address onBehalfOf, uint16) external {
        aToken.mint(onBehalfOf, amount - shortfall);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        MockERC20(asset).mint(to, amount);
        return amount;
    }
}

contract MockFactory {
    address public immutable usdc;
    address public immutable owner;
    mapping(DCAFactory.Tier => uint256) public minExecutions;
    uint256 public executionFeeBps = 15;
    uint256 public yieldFeeBps = 1500;
    uint256 public registerCount;
    uint256 public removeCount;

    constructor(address _usdc, address _owner) {
        usdc = _usdc;
        owner = _owner;
        minExecutions[DCAFactory.Tier.Daily]    = 10;
        minExecutions[DCAFactory.Tier.Weekly]   = 8;
        minExecutions[DCAFactory.Tier.BiWeekly] = 6;
        minExecutions[DCAFactory.Tier.Monthly]  = 3;
    }

    /// @dev Lets a test fund an account to an exact balance instead of the tier minimum, which is
    ///      what the funding-boundary cases need.
    function setMinExecutions(DCAFactory.Tier tier, uint256 n) external { minExecutions[tier] = n; }

    /// @dev Governance may change the yield rate between executions (`DCAFactory.setYieldFeeBps`),
    ///      and the account charges at realization, so which rate was in force when is observable.
    function setYieldFeeBps(uint256 bps) external { yieldFeeBps = bps; }

    function registerStrategy(address) external { registerCount++; }
    function removeStrategy(address) external { removeCount++; }
    function treasury() external view returns (address) { return owner; }
}

// -------------------------------------------------------------------------
// Test setup helpers
// -------------------------------------------------------------------------

contract UserStrategyAccountTest is Test {
    UserStrategyAccount internal impl;
    UserStrategyAccount internal acct;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockFactory internal factory;
    MockYieldAdapter internal yieldAdapter;

    address internal owner    = makeAddr("owner");
    address internal executor = makeAddr("executor");
    address internal treasury = makeAddr("treasury");

    uint256 constant AMOUNT = 25e6;       // 25 USDC per execution
    uint256 constant DEPOSIT = 200e6;     // 8 × 25 USDC (meets weekly minimum)

    function setUp() public {
        usdc         = new MockERC20();
        weth         = new MockERC20();
        factory      = new MockFactory(address(usdc), treasury);
        yieldAdapter = new MockYieldAdapter(address(usdc));
        impl         = new UserStrategyAccount();

        // Deploy proxy and initialize
        acct = UserStrategyAccount(Clones.clone(address(impl)));
        acct.initialize(
            owner,
            address(weth),
            AMOUNT,
            uint8(DCAFactory.Tier.Weekly),
            false,          // yieldEnabled
            address(0),     // yieldAdapter
            executor,
            address(factory)
        );
    }

    /// @dev Replaces `acct` with an otherwise identical account that buys `token`: `receiveOutput`
    ///      accepts only an account's own target asset.
    function _retarget(address token) internal {
        acct = UserStrategyAccount(Clones.clone(address(impl)));
        acct.initialize(owner, token, AMOUNT, uint8(DCAFactory.Tier.Weekly), false, address(0), executor, address(factory));
    }

    function _deposit(uint256 amount) internal {
        usdc.mint(owner, amount);
        vm.startPrank(owner);
        usdc.approve(address(acct), amount);
        acct.deposit(amount);
        vm.stopPrank();
    }

    function _deployWithYield() internal returns (UserStrategyAccount yAcct) {
        yAcct = UserStrategyAccount(Clones.clone(address(impl)));
        yAcct.initialize(
            owner,
            address(weth),
            AMOUNT,
            uint8(DCAFactory.Tier.Weekly),
            true,
            address(yieldAdapter),
            executor,
            address(factory)
        );
        usdc.mint(owner, DEPOSIT);
        vm.startPrank(owner);
        usdc.approve(address(yAcct), DEPOSIT);
        yAcct.deposit(DEPOSIT);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // initialize
    // -------------------------------------------------------------------------

    function test_initialize_setsAllParams() public view {
        assertEq(acct.owner(), owner);
        assertEq(acct.targetAsset(), address(weth));
        assertEq(acct.amountPerExecution(), AMOUNT);
        assertEq(uint8(acct.tier()), uint8(DCAFactory.Tier.Weekly));
        assertFalse(acct.yieldEnabled());
        assertEq(acct.batchExecutor(), executor);
        assertEq(address(acct.factory()), address(factory));
    }

    function test_initialize_cannotBeCalledTwice() public {
        vm.expectRevert();
        acct.initialize(owner, address(weth), AMOUNT, 0, false, address(0), executor, address(factory));
    }

    // -------------------------------------------------------------------------
    // deposit
    // -------------------------------------------------------------------------

    function test_deposit_registersOnFirstDeposit() public {
        assertEq(factory.registerCount(), 0);
        _deposit(DEPOSIT);
        assertEq(factory.registerCount(), 1);
    }

    function test_deposit_secondDepositDoesNotReRegister() public {
        _deposit(DEPOSIT);
        _deposit(10e6);
        assertEq(factory.registerCount(), 1);
    }

    function test_deposit_setsNextExecutionTime() public {
        _deposit(DEPOSIT);
        assertGt(acct.nextExecutionTime(), 0);
    }

    function test_deposit_revertsIfBelowMinimum() public {
        uint256 min = AMOUNT * factory.minExecutions(DCAFactory.Tier.Weekly); // 25 * 8 = 200
        usdc.mint(owner, min - 1);
        vm.startPrank(owner);
        usdc.approve(address(acct), min - 1);
        vm.expectRevert(abi.encodeWithSelector(UserStrategyAccount.BelowMinimumDeposit.selector, min - 1, min));
        acct.deposit(min - 1);
        vm.stopPrank();
    }

    function test_deposit_withYield_depositsToAdapter() public {
        UserStrategyAccount yAcct = _deployWithYield();
        // Balance should be in Aave, not in account
        assertEq(yAcct.balance(), 0);
        assertGt(yieldAdapter.balanceOf(address(yAcct)), 0);
    }

    // --- deposit: bounded-deposit postcondition ---

    /// A real AaveV3YieldAdapter clone behind a real account, on a pool that under-credits by
    /// `shortfall`. Both contracts under test are the shipped ones; only the venue is a mock.
    function _deployWithRealAaveAdapter(uint256 shortfall)
        internal
        returns (UserStrategyAccount a, AaveV3YieldAdapter adapter)
    {
        factory.setMinExecutions(DCAFactory.Tier.Weekly, 0);
        MockERC20 aUsdc = new MockERC20();
        MockUnderCreditingAavePool pool = new MockUnderCreditingAavePool(address(aUsdc), shortfall);
        AaveV3YieldAdapter adapterImpl =
            new AaveV3YieldAdapter(address(pool), address(usdc), address(aUsdc));

        a = UserStrategyAccount(Clones.clone(address(impl)));
        adapter = AaveV3YieldAdapter(Clones.clone(address(adapterImpl)));
        a.initialize(
            owner, address(weth), AMOUNT, uint8(DCAFactory.Tier.Weekly),
            true, address(adapter), executor, address(factory)
        );
        adapter.initialize(address(a));
    }

    /// Pins WHICH side rejects a material shortfall, not merely that one does. Both checks are
    /// live, and the adapter sees it first, so this is the adapter's error surfacing through the
    /// account. Delete the adapter's own check and the deposit still fails - the account's
    /// independent re-validation catches it - but with `YieldDepositShortfall` instead, and this
    /// test fails. That is what makes the adapter-side check testable rather than merely asserted.
    function test_deposit_materialMintShortfallIsRejectedAtTheAdapter() public {
        uint256 shortfall = YIELD_WITHDRAWAL_TOLERANCE + 1;
        (UserStrategyAccount a,) = _deployWithRealAaveAdapter(shortfall);

        usdc.mint(owner, AMOUNT);
        vm.startPrank(owner);
        usdc.approve(address(a), AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV3YieldAdapter.DepositShortfall.selector, AMOUNT, AMOUNT - shortfall
            )
        );
        a.deposit(AMOUNT);
        vm.stopPrank();

        assertEq(usdc.balanceOf(owner), AMOUNT, "deposit unwound, nothing stranded");
        assertEq(a.depositedAmount(), 0);
    }

    /// The same pairing at the accepted boundary: Aave's two-unit mint rounding must pass through
    /// BOTH checks, adapter and account. If either comparison were an equality, this would revert.
    function test_deposit_mintRoundingWithinToleranceLandsThroughTheAccount() public {
        (UserStrategyAccount a, AaveV3YieldAdapter adapter) =
            _deployWithRealAaveAdapter(YIELD_WITHDRAWAL_TOLERANCE);

        usdc.mint(owner, AMOUNT);
        vm.startPrank(owner);
        usdc.approve(address(a), AMOUNT);
        a.deposit(AMOUNT);
        vm.stopPrank();

        assertEq(a.depositedAmount(), AMOUNT, "principal recorded in full");
        assertEq(a.balance(), 0, "yield path does not credit idle balance");
        assertEq(
            adapter.balanceOf(address(a)),
            AMOUNT - YIELD_WITHDRAWAL_TOLERANCE,
            "position is at the accepted shortfall boundary"
        );
        assertEq(usdc.balanceOf(address(a)), 0, "the account kept none of it");
    }

    /// Checked without deriving the mock from the constant under test. A literal two-unit
    /// mint shortfall must cross both the real adapter check and the account's independent check.
    function test_deposit_literalTwoUnitMintShortfallLandsThroughAdapterAndAccount() public {
        (UserStrategyAccount a, AaveV3YieldAdapter adapter) = _deployWithRealAaveAdapter(2);

        usdc.mint(owner, AMOUNT);
        vm.startPrank(owner);
        usdc.approve(address(a), AMOUNT);
        a.deposit(AMOUNT);
        vm.stopPrank();

        assertEq(adapter.balanceOf(address(a)), AMOUNT - 2);
        assertEq(a.depositedAmount(), AMOUNT);
    }

    /// The credit half is a DELTA across this one call, not a reading of the absolute position.
    /// A top-up into a venue that pulls in full and credits nothing must be rejected even though
    /// the position is already large enough to satisfy an absolute comparison.
    function test_deposit_topUpBoundIsMeasuredPerCallNotAgainstAbsolutePosition() public {
        factory.setMinExecutions(DCAFactory.Tier.Weekly, 0);
        MockCreditOnceAdapter adapter = new MockCreditOnceAdapter(address(usdc));
        UserStrategyAccount a = _deployWithAdapter(address(adapter));

        usdc.mint(owner, 2 * AMOUNT);
        vm.startPrank(owner);
        usdc.approve(address(a), 2 * AMOUNT);
        a.deposit(AMOUNT);
        assertEq(adapter.balanceOf(address(a)), AMOUNT, "first deposit credited");

        vm.expectRevert(
            abi.encodeWithSelector(UserStrategyAccount.YieldDepositShortfall.selector, AMOUNT, 0)
        );
        a.deposit(AMOUNT); // pulled in full, credited nothing
        vm.stopPrank();

        assertEq(a.depositedAmount(), AMOUNT, "only the credited deposit is recorded");
    }

    /// The clamp branch on the credited delta. A venue whose reported position drops across the
    /// deposit must report zero credit and hit the named error, not panic on an underflow.
    function test_deposit_shrinkingVenuePositionIsRejectedNotPanicking() public {
        factory.setMinExecutions(DCAFactory.Tier.Weekly, 0);
        MockShrinkingPositionAdapter adapter = new MockShrinkingPositionAdapter(address(usdc));
        adapter.seed(10 * AMOUNT); // a position to lose
        UserStrategyAccount a = _deployWithAdapter(address(adapter));

        usdc.mint(owner, AMOUNT);
        vm.startPrank(owner);
        usdc.approve(address(a), AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(UserStrategyAccount.YieldDepositShortfall.selector, AMOUNT, 0)
        );
        a.deposit(AMOUNT);
        vm.stopPrank();
    }

    /// The account measures the pull from its OWN base-token balance, so an adapter that hands
    /// tokens back instead of taking them reports zero moved and hits the named revert rather than
    /// panicking on an underflow.
    function test_deposit_adapterThatPushesTokensBackIsRejected() public {
        factory.setMinExecutions(DCAFactory.Tier.Weekly, 0);
        MockRefundingAdapter refunder = new MockRefundingAdapter(address(usdc));
        UserStrategyAccount a = _deployWithAdapter(address(refunder));
        usdc.mint(address(refunder), AMOUNT);

        usdc.mint(owner, AMOUNT);
        vm.startPrank(owner);
        usdc.approve(address(a), AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(UserStrategyAccount.YieldDepositNotPulled.selector, AMOUNT, 0)
        );
        a.deposit(AMOUNT);
        vm.stopPrank();
    }

    function test_deposit_revertsIfNotOwner() public {
        address stranger = makeAddr("stranger");
        usdc.mint(stranger, DEPOSIT);
        vm.startPrank(stranger);
        usdc.approve(address(acct), DEPOSIT);
        vm.expectRevert(UserStrategyAccount.Unauthorized.selector);
        acct.deposit(DEPOSIT);
        vm.stopPrank();

        // Rejected before any transfer, accounting, registration or scheduling.
        assertEq(usdc.balanceOf(stranger), DEPOSIT);
        assertEq(usdc.balanceOf(address(acct)), 0);
        assertEq(usdc.allowance(stranger, address(acct)), DEPOSIT);
        assertEq(acct.depositedAmount(), 0);
        assertEq(acct.balance(), 0);
        assertEq(acct.nextExecutionTime(), 0);
        assertEq(factory.registerCount(), 0);
    }

    function test_deposit_revertsIfNotOwner_onYieldEnabledStrategy() public {
        UserStrategyAccount yAcct = _deployWithYield();
        uint256 adapterBefore = yieldAdapter.balanceOf(address(yAcct));

        address stranger = makeAddr("stranger");
        usdc.mint(stranger, DEPOSIT);
        vm.startPrank(stranger);
        usdc.approve(address(yAcct), DEPOSIT);
        vm.expectRevert(UserStrategyAccount.Unauthorized.selector);
        yAcct.deposit(DEPOSIT);
        vm.stopPrank();

        assertEq(usdc.balanceOf(stranger), DEPOSIT);
        assertEq(yieldAdapter.balanceOf(address(yAcct)), adapterBefore, "no yield-adapter interaction");
    }

    function test_deposit_ownerCanTopUpAfterActivation() public {
        _deposit(DEPOSIT);
        uint256 balanceBefore = acct.balance();
        _deposit(50e6);
        assertEq(acct.balance(), balanceBefore + 50e6);
        assertEq(acct.depositedAmount(), DEPOSIT + 50e6);
    }

    // -------------------------------------------------------------------------
    // authorisedPull
    // -------------------------------------------------------------------------

    function test_authorisedPull_succeeds() public {
        _deposit(DEPOSIT);
        vm.warp(acct.nextExecutionTime());

        vm.prank(executor);
        (uint256 pulled, ) = acct.authorisedPull(AMOUNT, 1);
        assertEq(pulled, AMOUNT);
        assertEq(usdc.balanceOf(executor), AMOUNT);
    }

    function test_authorisedPull_revertsIfNotExecutor() public {
        _deposit(DEPOSIT);
        vm.warp(acct.nextExecutionTime());
        vm.prank(owner);
        vm.expectRevert(UserStrategyAccount.Unauthorized.selector);
        acct.authorisedPull(AMOUNT, 1);
    }

    function test_authorisedPull_revertsIfTooEarly() public {
        _deposit(DEPOSIT);
        // Don't warp - still too early
        vm.prank(executor);
        vm.expectRevert(); // TooEarly
        acct.authorisedPull(AMOUNT, 1);
    }

    function test_authorisedPull_revertsIfWrongAmount() public {
        _deposit(DEPOSIT);
        vm.warp(acct.nextExecutionTime());
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(UserStrategyAccount.WrongAmount.selector, AMOUNT + 1, AMOUNT));
        acct.authorisedPull(AMOUNT + 1, 1);
    }

    function test_authorisedPull_revertsOnNonceReplay() public {
        _deposit(DEPOSIT * 2);
        vm.warp(acct.nextExecutionTime());
        vm.prank(executor); acct.authorisedPull(AMOUNT, 42);

        vm.warp(acct.nextExecutionTime());
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(UserStrategyAccount.NonceUsed.selector, 42));
        acct.authorisedPull(AMOUNT, 42);
    }

    function test_authorisedPull_autoPausesOnInsufficientBalance() public {
        _deposit(AMOUNT * 8); // exactly min
        // Drain all but insufficient for next pull
        for (uint256 i = 1; i <= 8; i++) {
            vm.warp(acct.nextExecutionTime());
            vm.prank(executor);
            acct.authorisedPull(AMOUNT, i);
        }
        // Now balance is 0
        vm.warp(acct.nextExecutionTime());
        vm.prank(executor);
        (uint256 pulled, ) = acct.authorisedPull(AMOUNT, 99);
        assertEq(pulled, 0);
        assertTrue(acct.paused());
        assertEq(uint8(acct.pauseReason()), uint8(UserStrategyAccount.PauseReason.InsufficientBalance));
    }

    /// A closed account is terminal and must simply be skipped. This is the account-level half of
    /// the guard: BatchExecutor's registry check stops the call from being made at all, so
    /// this test reaches the guard directly - the MockFactory here keeps no registry.
    ///
    /// Without the explicit `closed` check, withdraw() having zeroed `balance` would send a closed
    /// account down the insufficient-balance path instead, auto-pausing it and emitting Paused for a
    /// strategy the owner had already exited.
    function test_authorisedPull_closedAccountIsSkippedNotAutoPaused() public {
        _deposit(DEPOSIT);
        vm.warp(acct.nextExecutionTime());
        vm.prank(owner);
        acct.withdraw();
        assertTrue(acct.closed(), "precondition: the strategy is closed");
        assertFalse(acct.paused(), "precondition: withdraw does not pause");

        vm.prank(executor);
        (uint256 pulled, ) = acct.authorisedPull(AMOUNT, 7);

        assertEq(pulled, 0, "a closed account contributes nothing");
        assertFalse(acct.paused(), "a closed account is skipped, never auto-paused");
        // pauseReason is not asserted: InsufficientBalance is the enum's zero value, so an
        // unpaused account already reads as InsufficientBalance and the field proves nothing
        // here. `paused` is the load-bearing signal.
    }

    /// The skip writes nothing: the account's own replay slot stays unwritten and the execution
    /// window does not move.
    ///
    /// `usedNonces` here is the ACCOUNT-local replay guard. The batch nonce is a different mapping
    /// on BatchExecutor, and it is consumed before any pull, so a skipped account
    /// never makes a batch id reusable. What this asserts is that `authorisedPull` returned at its
    /// first guard without writing state.
    function test_authorisedPull_closedAccountLeavesAccountNonceUnused() public {
        _deposit(DEPOSIT);
        vm.warp(acct.nextExecutionTime());
        uint256 windowBefore = acct.nextExecutionTime();
        vm.prank(owner);
        acct.withdraw();

        vm.prank(executor);
        acct.authorisedPull(AMOUNT, 7);

        assertFalse(acct.usedNonces(7), "the account-local replay slot was never written");
        assertEq(acct.nextExecutionTime(), windowBefore, "the execution window did not move");
        assertEq(usdc.balanceOf(executor), 0, "no USDC left the account");
    }

    /// Paired control on the same guard: a paused account behaves identically.
    function test_authorisedPull_pausedAccountLeavesAccountNonceUnused() public {
        _deposit(DEPOSIT);
        vm.warp(acct.nextExecutionTime());
        vm.prank(owner);
        acct.pause();

        vm.prank(executor);
        (uint256 pulled, ) = acct.authorisedPull(AMOUNT, 7);

        assertEq(pulled, 0, "a paused account contributes nothing");
        assertFalse(acct.usedNonces(7), "the account-local replay slot was never written");
        assertEq(usdc.balanceOf(executor), 0, "no USDC left the account");
    }

    function test_authorisedPull_advancesNextExecutionTime() public {
        _deposit(DEPOSIT);
        vm.warp(acct.nextExecutionTime());
        uint256 before = acct.nextExecutionTime();
        vm.prank(executor);
        acct.authorisedPull(AMOUNT, 1);
        assertGt(acct.nextExecutionTime(), before);
    }

    function test_authorisedPull_yieldFailure_skipsWithoutPause() public {
        UserStrategyAccount yAcct = _deployWithYield();
        yieldAdapter.setFail(true);

        vm.warp(yAcct.nextExecutionTime());
        vm.prank(executor);
        (uint256 pulled, ) = yAcct.authorisedPull(AMOUNT, 1);
        assertEq(pulled, 0);
        assertFalse(yAcct.paused()); // no pause on yield failure
    }

    // -------------------------------------------------------------------------
    // Withdrawal-shortfall postcondition
    // -------------------------------------------------------------------------

    /// @dev A shortfall inside YIELD_WITHDRAWAL_TOLERANCE is routine venue rounding. It must execute
    ///      and must not pause, or the strategy would stall on every withdrawal.
    function test_authorisedPull_shortfallWithinToleranceDoesNotPause() public {
        UserStrategyAccount yAcct = _deployWithYield();
        yieldAdapter.setShortfall(YIELD_WITHDRAWAL_TOLERANCE);

        vm.warp(yAcct.nextExecutionTime());
        vm.prank(executor);
        (uint256 pulled, ) = yAcct.authorisedPull(AMOUNT, 1);

        assertEq(pulled, AMOUNT - YIELD_WITHDRAWAL_TOLERANCE, "the actual amount is forwarded");
        assertFalse(yAcct.paused(), "a tolerated rounding shortfall must not stall the strategy");
    }

    /// @dev One unit past the tolerance is an adapter-conformance failure. The account pauses rather
    ///      than reverting - a reverting account would let one bad venue brick the whole batch - and
    ///      the withdrawn funds are credited so they stay reachable.
    function test_authorisedPull_shortfallBeyondTolerancePauses() public {
        UserStrategyAccount yAcct = _deployWithYield();
        uint256 shortfall = YIELD_WITHDRAWAL_TOLERANCE + 1;
        yieldAdapter.setShortfall(shortfall);

        vm.warp(yAcct.nextExecutionTime());
        vm.prank(executor);
        (uint256 pulled, ) = yAcct.authorisedPull(AMOUNT, 1);

        assertEq(pulled, 0, "no pull on a material shortfall");
        assertTrue(yAcct.paused());
        assertEq(uint8(yAcct.pauseReason()), uint8(UserStrategyAccount.PauseReason.InsufficientBalance));
        assertEq(yAcct.balance(), AMOUNT - shortfall, "the withdrawn amount is still accounted for");
    }

    /// @dev THE property: the shortfall check reads `received`, not the post-credit balance. With idle
    ///      USDC already in the account, a balance-only check would find enough to cover the pull and
    ///      let a material shortfall through unnoticed. Pins that the masking path is closed.
    function test_authorisedPull_idleBalanceCannotMaskMaterialShortfall() public {
        UserStrategyAccount yAcct = _deployWithYield();

        // Build idle balance the honest way: an over-returning withdrawal leaves residue behind
        // after the pull takes exactly amountPerExecution.
        uint256 residue = 10e6;
        usdc.mint(address(yieldAdapter), residue);
        yieldAdapter.setExtra(residue);
        vm.warp(yAcct.nextExecutionTime());
        vm.prank(executor);
        yAcct.authorisedPull(AMOUNT, 1);
        yieldAdapter.setExtra(0);
        assertEq(yAcct.balance(), residue, "idle balance is in place for the next window");

        // The first rejected value, deliberately. A mutation widening the account's independent
        // check by one must not survive merely because the idle residue makes total balance ample.
        uint256 shortfall = YIELD_WITHDRAWAL_TOLERANCE + 1;
        assertGt(residue, shortfall, "residue must be able to cover the shortfall for this to bite");
        yieldAdapter.setShortfall(shortfall);

        vm.warp(yAcct.nextExecutionTime());
        vm.prank(executor);
        (uint256 pulled, ) = yAcct.authorisedPull(AMOUNT, 2);

        assertEq(pulled, 0, "material shortfall must not be absorbed by idle balance");
        assertTrue(yAcct.paused(), "material shortfall must pause even when the balance looks sufficient");
        assertEq(yAcct.balance(), residue + AMOUNT - shortfall, "everything withdrawn is still accounted for");
    }

    // -------------------------------------------------------------------------
    // receiveOutput
    // -------------------------------------------------------------------------

    /// @dev Output is delivered to the strategy owner. There is no destination override.
    function test_receiveOutput_transfersToOwner() public {
        weth.mint(address(acct), 1e18);
        vm.prank(executor);
        acct.receiveOutput(address(weth), 1e18);
        assertEq(weth.balanceOf(owner), 1e18);
        assertEq(acct.pendingWithdrawals(address(weth)), 0);
    }

    function test_receiveOutput_fallsBackToPending_ifTransferFails() public {
        // Deploy a "broken" WETH that always returns false on transfer
        MockERC20FailTransfer failToken = new MockERC20FailTransfer();
        _retarget(address(failToken));
        failToken.mint(address(acct), 1e18);

        vm.prank(executor);
        acct.receiveOutput(address(failToken), 1e18);

        assertEq(acct.pendingWithdrawals(address(failToken)), 1e18);
        assertEq(failToken.balanceOf(owner), 0);
    }

    function test_receiveOutput_revertsIfNotExecutor() public {
        vm.prank(owner);
        vm.expectRevert(UserStrategyAccount.Unauthorized.selector);
        acct.receiveOutput(address(weth), 1e18);
    }

    // -------------------------------------------------------------------------
    // receiveOutput tolerates non-standard transfer return values
    //
    // A `returns (bool)` decode happens in the caller's frame, so a token that omits the bool,
    // returns the wrong width, or returns a dirty bool would revert receiveOutput outside any
    // catch and take the whole batch down at _distributeOutput. The low-level-call cure treats
    // every non-standard return as a failed delivery and falls back, never reverting.
    // -------------------------------------------------------------------------

    /// USDT-style: transfer moves the tokens but returns no data. This must be a successful
    /// delivery to the owner, not a revert and not a pending fallback.
    function test_receiveOutput_nonStandardReturn_emptyReturn_deliversToOwner() public {
        MockNonStandardReturnToken tok = new MockNonStandardReturnToken();
        _retarget(address(tok));
        tok.setRetMode(MockNonStandardReturnToken.Ret.Empty);
        tok.mint(address(acct), 1e18);

        vm.prank(executor);
        acct.receiveOutput(address(tok), 1e18);

        assertEq(tok.balanceOf(owner), 1e18, "USDT-style empty return must deliver to owner");
        assertEq(acct.pendingWithdrawals(address(tok)), 0, "no pending on a successful delivery");
    }

    /// An undersized (16-byte) return must not revert; it is treated as a failed delivery and held.
    function test_receiveOutput_nonStandardReturn_undersizedReturn_fallsBackWithoutRevert() public {
        MockNonStandardReturnToken tok = new MockNonStandardReturnToken();
        _retarget(address(tok));
        tok.setRetMode(MockNonStandardReturnToken.Ret.Bytes16);
        tok.mint(address(acct), 1e18);

        vm.prank(executor);
        acct.receiveOutput(address(tok), 1e18); // must not revert

        assertEq(acct.pendingWithdrawals(address(tok)), 1e18, "undersized return falls back to pending");
        assertEq(tok.balanceOf(owner), 0, "nothing delivered on the fallback path");
    }

    /// A dirty bool (a 32-byte word that is neither 0 nor 1) is the case a naive `abi.decode(bool)`
    /// cure would still revert on, because the bool decode validates the word. It must fall back.
    function test_receiveOutput_nonStandardReturn_dirtyBoolReturn_fallsBackWithoutRevert() public {
        MockNonStandardReturnToken tok = new MockNonStandardReturnToken();
        _retarget(address(tok));
        tok.setRetMode(MockNonStandardReturnToken.Ret.DirtyBool);
        tok.mint(address(acct), 1e18);

        vm.prank(executor);
        acct.receiveOutput(address(tok), 1e18); // must not revert

        assertEq(acct.pendingWithdrawals(address(tok)), 1e18, "dirty bool return falls back to pending");
        assertEq(tok.balanceOf(owner), 0, "nothing delivered on the fallback path");
    }

    /// A clean `true` return still delivers (behaviour preserved).
    function test_receiveOutput_nonStandardReturn_cleanTrue_deliversToOwner() public {
        MockNonStandardReturnToken tok = new MockNonStandardReturnToken();
        _retarget(address(tok));
        tok.setRetMode(MockNonStandardReturnToken.Ret.CleanTrue);
        tok.mint(address(acct), 1e18);

        vm.prank(executor);
        acct.receiveOutput(address(tok), 1e18);

        assertEq(tok.balanceOf(owner), 1e18, "clean true still delivers");
        assertEq(acct.pendingWithdrawals(address(tok)), 0, "no pending on a successful delivery");
    }

    /// A clean `false` return still falls back (behaviour preserved).
    function test_receiveOutput_nonStandardReturn_cleanFalse_fallsBackToPending() public {
        MockNonStandardReturnToken tok = new MockNonStandardReturnToken();
        _retarget(address(tok));
        tok.setRetMode(MockNonStandardReturnToken.Ret.CleanFalse);
        tok.mint(address(acct), 1e18);

        vm.prank(executor);
        acct.receiveOutput(address(tok), 1e18);

        assertEq(acct.pendingWithdrawals(address(tok)), 1e18, "clean false falls back to pending");
        assertEq(tok.balanceOf(owner), 0, "nothing delivered on the fallback path");
    }

    // -------------------------------------------------------------------------
    // receiveOutput bounds the token's returndata and gas
    //
    // A low-level call that copies the token's whole returndata before checking its length, and
    // forwards nearly all gas, is not enough: a token that burns gas and then returns or reverts with
    // a large payload would leave the account out of gas before the fallback is written, reverting
    // the batch.
    // -------------------------------------------------------------------------

    uint256 internal constant BOMB_SIZE = 256 * 1024;
    /// Enough for the token to expand its memory to BOMB_SIZE and return it.
    uint256 internal constant BOMB_KEEP_GAS = 200_000;
    uint256 internal constant RECEIVE_GAS = 1_000_000;

    function _receiveFrom(MockReturndataToken tok, uint256 gasForCall) internal {
        tok.mint(address(acct), 1e18);
        vm.prank(executor);
        acct.receiveOutput{gas: gasForCall}(address(tok), 1e18);
    }

    /// Burn the forwarded gas down to what a 256 KiB payload costs, then return it. Without the
    /// bounds the account would be left with about 1/64 of its gas and run out copying the payload.
    function test_receiveOutput_bounded_returndataBomb_fallsBackWithoutRevert() public {
        MockReturndataToken tok = new MockReturndataToken();
        _retarget(address(tok));
        tok.setBomb(BOMB_SIZE, BOMB_KEEP_GAS, false);

        _receiveFrom(tok, RECEIVE_GAS);

        assertEq(acct.pendingWithdrawals(address(tok)), 1e18, "returndata bomb falls back to pending");
    }

    /// The same payload as revert data. A failed call's returndata was copied just the same.
    function test_receiveOutput_bounded_revertDataBomb_fallsBackWithoutRevert() public {
        MockReturndataToken tok = new MockReturndataToken();
        _retarget(address(tok));
        tok.setBomb(BOMB_SIZE, BOMB_KEEP_GAS, true);

        _receiveFrom(tok, RECEIVE_GAS);

        assertEq(acct.pendingWithdrawals(address(tok)), 1e18, "revert-data bomb falls back to pending");
        assertEq(tok.balanceOf(owner), 0, "a reverted transfer moves nothing");
    }

    /// A token that consumes every unit of gas it is given must still leave enough to record the
    /// fallback. Given 63/64 of the frame, the pending write would run out of gas.
    function test_receiveOutput_bounded_gasBurningToken_fallsBackWithoutRevert() public {
        MockReturndataToken tok = new MockReturndataToken();
        _retarget(address(tok));
        tok.setBurnAll(true);

        _receiveFrom(tok, RECEIVE_GAS);

        assertEq(acct.pendingWithdrawals(address(tok)), 1e18, "gas-burning token falls back to pending");
        assertEq(tok.balanceOf(owner), 0, "an out-of-gas transfer moves nothing");
    }

    /// Only empty returndata or exactly 32 bytes can be a delivery; every other length, including
    /// a 64 KiB payload the token can afford to return, is a fallback. The mock always moves the
    /// balance, so the pending record is the only thing that tells the two outcomes apart.
    function test_receiveOutput_bounded_returnLengths_onlyEmptyOrOneWordDeliver() public {
        uint256[8] memory lengths = [uint256(0), 1, 16, 31, 32, 33, 64, 64 * 1024];
        for (uint256 i = 0; i < lengths.length; i++) {
            MockReturndataToken tok = new MockReturndataToken();
            _retarget(address(tok));
            tok.setReturn(lengths[i], 1);

            _receiveFrom(tok, RECEIVE_GAS);

            bool delivers = lengths[i] == 0 || lengths[i] == 32;
            assertEq(
                acct.pendingWithdrawals(address(tok)),
                delivers ? 0 : 1e18,
                string.concat("returndata length ", vm.toString(lengths[i]))
            );
        }
    }

    /// For a 32-byte return only the exact word 1 is a delivery. Covers a left-aligned bool and a
    /// word whose low byte is 1 under dirty high bits, which a byte-wise check would accept.
    function test_receiveOutput_bounded_oneWordReturn_onlyExactOneDelivers() public {
        uint256[6] memory words = [uint256(0), 1, 2, 1 << 248, (1 << 255) | 1, type(uint256).max];
        for (uint256 i = 0; i < words.length; i++) {
            MockReturndataToken tok = new MockReturndataToken();
            _retarget(address(tok));
            tok.setReturn(32, words[i]);

            _receiveFrom(tok, RECEIVE_GAS);

            assertEq(
                acct.pendingWithdrawals(address(tok)),
                words[i] == 1 ? 0 : 1e18,
                string.concat("returned word ", vm.toString(bytes32(words[i])))
            );
        }
    }

    function testFuzz_receiveOutput_bounded_oneWordReturn_onlyExactOneDelivers(uint256 word) public {
        MockReturndataToken tok = new MockReturndataToken();
        _retarget(address(tok));
        tok.setReturn(32, word);

        _receiveFrom(tok, RECEIVE_GAS);

        assertEq(acct.pendingWithdrawals(address(tok)), word == 1 ? 0 : 1e18, "only the word 1 delivers");
    }

    /// Whatever gas the caller supplies, the outcome is a delivery, a pending record, or an explicit
    /// InsufficientOutputGas. Never a bare out-of-gas, and never a working token starved into the
    /// fallback, which is what would let a gas estimate settle on a limit that defers delivery.
    function testFuzz_receiveOutput_bounded_gasBoundary(uint256 gasForCall, bool burner) public {
        gasForCall = bound(gasForCall, 60_000, 400_000);
        MockReturndataToken tok = new MockReturndataToken();
        _retarget(address(tok));
        if (burner) tok.setBurnAll(true);
        else tok.setReturn(32, 1);
        tok.mint(address(acct), 1e18);

        vm.prank(executor);
        (bool ok, bytes memory ret) = address(acct).call{gas: gasForCall}(
            abi.encodeCall(UserStrategyAccount.receiveOutput, (address(tok), 1e18))
        );

        if (!ok) {
            assertEq(bytes4(ret), BoundedTransfer.InsufficientOutputGas.selector, "only an explicit gas refusal");
            assertEq(acct.pendingWithdrawals(address(tok)), 0, "a refusal records nothing");
            return;
        }
        assertEq(acct.pendingWithdrawals(address(tok)), burner ? 1e18 : 0, "burner pends, working token delivers");
        assertEq(tok.balanceOf(owner), burner ? 0 : 1e18, "working token always reaches the owner");
    }

    /// Below the threshold the call refuses before touching the token.
    function test_receiveOutput_bounded_tooLittleGas_revertsBeforeTransfer() public {
        MockReturndataToken tok = new MockReturndataToken();
        _retarget(address(tok));
        tok.setReturn(32, 1);
        tok.mint(address(acct), 1e18);

        vm.prank(executor);
        // Selector only: the `available` argument depends on the gas spent before the check.
        vm.expectPartialRevert(BoundedTransfer.InsufficientOutputGas.selector);
        acct.receiveOutput{gas: 100_000}(address(tok), 1e18);

        assertEq(tok.balanceOf(address(acct)), 1e18, "token untouched");
    }

    function test_withdrawPending_clearsBalance() public {
        MockERC20FailTransfer failToken = new MockERC20FailTransfer();
        _retarget(address(failToken));
        failToken.mint(address(acct), 1e18);
        vm.prank(executor);
        acct.receiveOutput(address(failToken), 1e18);

        // Now fix the token and withdraw
        failToken.setShouldFail(false);
        vm.prank(owner);
        acct.withdrawPending(address(failToken));

        assertEq(acct.pendingWithdrawals(address(failToken)), 0);
        assertEq(failToken.balanceOf(owner), 1e18);
    }

    // -------------------------------------------------------------------------
    // withdrawPending hardening
    //
    // Recovery reconciles against the account's real balance instead of the recorded
    // amount, so a record that overstates what the account holds cannot lock the tokens.
    // -------------------------------------------------------------------------

    /// Records `amount` pending on `tok` without requiring the account to actually hold it.
    function _recordPending(MockOutputToken tok, uint256 amount) internal {
        tok.setFailMode(MockOutputToken.Fail.ReturnFalse);
        vm.prank(executor);
        acct.receiveOutput(address(tok), amount);
        tok.setFailMode(MockOutputToken.Fail.None);
    }

    /// 1. The primary case: recorded 100, only 99 held. Transferring the recorded
    ///    amount would revert and strand the 99 forever.
    function test_withdrawPending_recordedExceedsBalance_recoversActualHeld() public {
        MockOutputToken tok = new MockOutputToken();
        _retarget(address(tok));
        tok.mint(address(acct), 99);

        _recordPending(tok, 100);
        assertEq(acct.pendingWithdrawals(address(tok)), 100, "record overstates by 1");

        vm.prank(owner);
        acct.withdrawPending(address(tok));

        assertEq(tok.balanceOf(owner), 99, "owner receives everything the account held");
        assertEq(tok.balanceOf(address(acct)), 0, "no recoverable output left locked");
        assertEq(acct.pendingWithdrawals(address(tok)), 0, "record cleared");
    }

    /// 2. Fee-on-transfer: the account is credited less than BatchExecutor sent, so the
    ///    record overstates from the moment it is written.
    function test_withdrawPending_feeOnTransferDivergence() public {
        MockOutputToken tok = new MockOutputToken();
        _retarget(address(tok));
        tok.setFeeBps(100); // 1%

        // BatchExecutor sends 1000; the account is credited 990.
        tok.mint(address(this), 1000);
        tok.transfer(address(acct), 1000);
        assertEq(tok.balanceOf(address(acct)), 990);

        // receiveOutput is notified with the sent amount, not the received amount.
        _recordPending(tok, 1000);
        assertEq(acct.pendingWithdrawals(address(tok)), 1000, "record may exceed real balance");

        vm.prank(owner);
        acct.withdrawPending(address(tok));

        // The account is debited its full real balance; the fee is charged on the way out,
        // so the owner is credited slightly less than the account gave up.
        assertEq(tok.balanceOf(address(acct)), 0, "account fully drained of recoverable output");
        assertEq(tok.balanceOf(owner), 990 - 9, "owner credited net of the outgoing fee");
        assertEq(acct.pendingWithdrawals(address(tok)), 0);
    }

    /// 3. Balance falls after the record is written (downward rebase).
    function test_withdrawPending_balanceDecreasedAfterRecording() public {
        MockOutputToken tok = new MockOutputToken();
        _retarget(address(tok));
        tok.mint(address(acct), 100);
        _recordPending(tok, 100);

        tok.burn(address(acct), 30); // rebase down to 70

        vm.prank(owner);
        acct.withdrawPending(address(tok));

        assertEq(tok.balanceOf(owner), 70, "recovers the post-rebase balance");
        assertEq(acct.pendingWithdrawals(address(tok)), 0, "record cleared");
    }

    /// 4. Stale record, nothing held: clears without reverting and moves no tokens.
    function test_withdrawPending_staleRecordZeroBalance_clearsWithoutRevert() public {
        MockOutputToken tok = new MockOutputToken();
        _retarget(address(tok));
        _recordPending(tok, 100); // recorded, but the account never held any

        assertEq(tok.balanceOf(address(acct)), 0);

        vm.prank(owner);
        acct.withdrawPending(address(tok));

        assertEq(acct.pendingWithdrawals(address(tok)), 0, "stale record cleared");
        assertEq(tok.balanceOf(owner), 0, "no transfer attempted");
    }

    /// 5. The gate is what stops withdrawPending becoming a generic ERC-20 sweep. With no
    ///    record, tracked USDC must not move and strategy accounting must not change.
    ///    Mandatory: without it, an owner could drain live USDC without decrementing
    ///    `balance` or `depositedAmount`, bypassing the terminal withdraw() path.
    function test_withdrawPending_noRecord_cannotSweepTrackedUsdc() public {
        _deposit(DEPOSIT);

        uint256 balBefore        = acct.balance();
        uint256 depositedBefore  = acct.depositedAmount();
        uint256 usdcHeldBefore   = usdc.balanceOf(address(acct));
        uint256 ownerUsdcBefore  = usdc.balanceOf(owner);

        assertEq(acct.pendingWithdrawals(address(usdc)), 0, "precondition: no pending USDC record");

        // Refused outright, not merely gated on the absent record.
        vm.prank(owner);
        vm.expectRevert(UserStrategyAccount.PrincipalNotRecoverable.selector);
        acct.withdrawPending(address(usdc));

        assertEq(usdc.balanceOf(address(acct)), usdcHeldBefore, "no USDC moved");
        assertEq(usdc.balanceOf(owner), ownerUsdcBefore, "owner credited nothing");
        assertEq(acct.balance(), balBefore, "balance untouched");
        assertEq(acct.depositedAmount(), depositedBefore, "depositedAmount untouched");
        assertFalse(acct.closed(), "strategy still open");
        assertFalse(acct.paused(), "strategy still active");
    }

    /// Whichever executor is bound, `receiveOutput` accepts only the account's target asset, so
    /// it can never record a pending USDC balance for `withdrawPending` to pay out.
    function test_receiveOutput_refusesAnyAssetButTheTarget() public {
        _deposit(DEPOSIT);
        MockOutputToken other = new MockOutputToken();
        address[2] memory assets = [address(usdc), address(other)];
        for (uint256 i; i < assets.length; ++i) {
            vm.prank(executor);
            vm.expectRevert(abi.encodeWithSelector(UserStrategyAccount.WrongOutputAsset.selector, assets[i]));
            acct.receiveOutput(assets[i], 1);
            assertEq(acct.pendingWithdrawals(assets[i]), 0, "no record for a non-target asset");
        }
        // Zero amounts are refused too: the asset check comes first.
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(UserStrategyAccount.WrongOutputAsset.selector, address(usdc)));
        acct.receiveOutput(address(usdc), 0);
        assertEq(acct.balance(), DEPOSIT, "principal untouched");
    }

    /// Even with a USDC record present, `withdrawPending(usdc)` refuses to pay out principal.
    function test_withdrawPending_refusesUsdcEvenWithARecord() public {
        _deposit(DEPOSIT);
        // A record no code path can create, injected to test the second guard alone.
        // Slot 13 is `pendingWithdrawals` in the compiled layout; the precondition below checks it.
        bytes32 slot = keccak256(abi.encode(address(usdc), uint256(13)));
        vm.store(address(acct), slot, bytes32(uint256(1)));
        assertEq(acct.pendingWithdrawals(address(usdc)), 1, "precondition: injected USDC record");

        vm.prank(owner);
        vm.expectRevert(UserStrategyAccount.PrincipalNotRecoverable.selector);
        acct.withdrawPending(address(usdc));
        assertEq(usdc.balanceOf(address(acct)), DEPOSIT, "principal stays in the account");
        assertEq(usdc.balanceOf(owner), 0, "owner paid nothing");
    }

    /// 5b. Same gate, unsolicited target-asset tokens donated to the account.
    function test_withdrawPending_noRecord_cannotSweepDonatedTargetAsset() public {
        weth.mint(address(acct), 5e18); // donated, never went through receiveOutput

        vm.prank(owner);
        acct.withdrawPending(address(weth));

        assertEq(weth.balanceOf(address(acct)), 5e18, "donation stays put without a record");
        assertEq(weth.balanceOf(owner), 0);
    }

    /// 6. A reverting recovery transfer must preserve both the record and the balance,
    ///    so recovery stays retriable (checks-effects-interactions, not fire-and-forget).
    function test_withdrawPending_transferReverts_preservesPendingAndBalance() public {
        MockOutputToken tok = new MockOutputToken();
        _retarget(address(tok));
        tok.mint(address(acct), 100);
        _recordPending(tok, 100);

        tok.setFailMode(MockOutputToken.Fail.Revert);
        vm.prank(owner);
        vm.expectRevert();
        acct.withdrawPending(address(tok));

        assertEq(acct.pendingWithdrawals(address(tok)), 100, "record survives the revert");
        assertEq(tok.balanceOf(address(acct)), 100, "tokens survive the revert");

        // Still recoverable once the token stops blocking.
        tok.setFailMode(MockOutputToken.Fail.None);
        vm.prank(owner);
        acct.withdrawPending(address(tok));
        assertEq(tok.balanceOf(owner), 100, "retry succeeds");
    }

    /// 6b. Same property when the token returns false rather than reverting: SafeERC20
    ///     turns that into a revert, so the record must survive equally.
    function test_withdrawPending_transferReturnsFalse_preservesPending() public {
        MockOutputToken tok = new MockOutputToken();
        _retarget(address(tok));
        tok.mint(address(acct), 100);
        _recordPending(tok, 100);

        tok.setFailMode(MockOutputToken.Fail.ReturnFalse);
        vm.prank(owner);
        vm.expectRevert();
        acct.withdrawPending(address(tok));

        assertEq(acct.pendingWithdrawals(address(tok)), 100, "record survives");
        assertEq(tok.balanceOf(address(acct)), 100, "tokens survive");
    }

    /// 7. Access control: recovery is owner-only, and no new caller role exists.
    function test_withdrawPending_revertsForNonOwner() public {
        MockOutputToken tok = new MockOutputToken();
        _retarget(address(tok));
        tok.mint(address(acct), 100);
        _recordPending(tok, 100);

        vm.prank(executor);
        vm.expectRevert(UserStrategyAccount.Unauthorized.selector);
        acct.withdrawPending(address(tok));

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(UserStrategyAccount.Unauthorized.selector);
        acct.withdrawPending(address(tok));

        assertEq(acct.pendingWithdrawals(address(tok)), 100, "record untouched by failed calls");
    }

    /// 8. Batch-path safety: a delivery failure must fall back without reverting
    ///    receiveOutput, or one bad recipient would revert the whole batch.
    function test_receiveOutput_deliveryFailureDoesNotRevertBatchPath() public {
        MockOutputToken tok = new MockOutputToken();
        _retarget(address(tok));
        tok.mint(address(acct), 1e18);

        tok.setFailMode(MockOutputToken.Fail.Revert);
        vm.prank(executor);
        acct.receiveOutput(address(tok), 1e18); // must not revert

        assertEq(acct.pendingWithdrawals(address(tok)), 1e18, "recorded pending");
        assertEq(tok.balanceOf(address(acct)), 1e18, "output stays in the account");
    }

    /// 9. Normal delivery still goes straight to the owner and records nothing.
    function test_receiveOutput_successLeavesNoPendingRecord() public {
        MockOutputToken tok = new MockOutputToken();
        _retarget(address(tok));
        tok.mint(address(acct), 1e18);

        vm.prank(executor);
        acct.receiveOutput(address(tok), 1e18);

        assertEq(tok.balanceOf(owner), 1e18, "delivered to owner");
        assertEq(acct.pendingWithdrawals(address(tok)), 0, "no pending record");
    }

    /// 10. Repeated failures accumulate, and recovery then uses the real balance rather
    ///     than the accumulated number. No double recovery after the record clears.
    function test_withdrawPending_multipleFailedDeliveries_recoverOnceAtRealBalance() public {
        MockOutputToken tok = new MockOutputToken();
        _retarget(address(tok));
        tok.mint(address(acct), 30); // account really holds 30 across all three attempts

        _recordPending(tok, 10);
        _recordPending(tok, 10);
        _recordPending(tok, 10);
        assertEq(acct.pendingWithdrawals(address(tok)), 30, "records accumulate");

        // Balance then falls below the accumulated record.
        tok.burn(address(acct), 5);

        vm.prank(owner);
        acct.withdrawPending(address(tok));

        assertEq(tok.balanceOf(owner), 25, "recovers the real balance, not the accumulated 30");
        assertEq(acct.pendingWithdrawals(address(tok)), 0);

        // Second call is a no-op: no double recovery.
        tok.mint(address(acct), 7); // a later donation is not claimable without a new record
        vm.prank(owner);
        acct.withdrawPending(address(tok));
        assertEq(tok.balanceOf(owner), 25, "no double recovery");
        assertEq(tok.balanceOf(address(acct)), 7, "post-clear balance stays put");
    }

    // -------------------------------------------------------------------------
    // withdraw (always available)
    // -------------------------------------------------------------------------

    function test_withdraw_returnsBalanceToOwner() public {
        _deposit(DEPOSIT);
        vm.prank(owner);
        acct.withdraw();
        assertEq(usdc.balanceOf(owner), DEPOSIT);
        assertEq(acct.balance(), 0);
    }

    function test_withdraw_worksWhenPaused() public {
        _deposit(DEPOSIT);
        vm.prank(owner);
        acct.pause();
        assertTrue(acct.paused());

        vm.prank(owner);
        acct.withdraw(); // must not revert
        assertEq(usdc.balanceOf(owner), DEPOSIT);
    }

    function test_withdraw_callsRemoveStrategy() public {
        _deposit(DEPOSIT);
        uint256 before = factory.removeCount();
        vm.prank(owner);
        acct.withdraw();
        assertEq(factory.removeCount(), before + 1);
    }

    function test_withdraw_onlyOwner() public {
        _deposit(DEPOSIT);
        vm.prank(makeAddr("other"));
        vm.expectRevert(UserStrategyAccount.Unauthorized.selector);
        acct.withdraw();
    }

    // -------------------------------------------------------------------------
    // pause / resume
    // -------------------------------------------------------------------------

    function test_pause_setsManualPauseReason() public {
        _deposit(DEPOSIT);
        vm.prank(owner);
        acct.pause();
        assertTrue(acct.paused());
        assertEq(uint8(acct.pauseReason()), uint8(UserStrategyAccount.PauseReason.ManualPause));
    }

    function test_pause_revertsIfAlreadyPaused() public {
        _deposit(DEPOSIT);
        vm.startPrank(owner);
        acct.pause();
        vm.expectRevert(UserStrategyAccount.AlreadyPaused.selector);
        acct.pause();
        vm.stopPrank();
    }

    function test_resume_unpausesAndRegisters() public {
        _deposit(DEPOSIT);
        vm.startPrank(owner);
        acct.pause();
        uint256 regBefore = factory.registerCount();
        acct.resume();
        vm.stopPrank();
        assertFalse(acct.paused());
        assertEq(factory.registerCount(), regBefore + 1);
    }

    function test_resume_revertsIfNotPaused() public {
        _deposit(DEPOSIT);
        vm.prank(owner);
        vm.expectRevert(UserStrategyAccount.NotPaused.selector);
        acct.resume();
    }

    // -------------------------------------------------------------------------
    // isDue
    // -------------------------------------------------------------------------

    function test_isDue_trueWhenConditionsMet() public {
        _deposit(DEPOSIT);
        vm.warp(acct.nextExecutionTime());
        assertTrue(acct.isDue(uint8(DCAFactory.Tier.Weekly), block.timestamp));
    }

    function test_isDue_falseWhenPaused() public {
        _deposit(DEPOSIT);
        vm.prank(owner);
        acct.pause();
        vm.warp(acct.nextExecutionTime());
        assertFalse(acct.isDue(uint8(DCAFactory.Tier.Weekly), block.timestamp));
    }

    function test_isDue_falseWhenWrongTier() public {
        _deposit(DEPOSIT);
        vm.warp(acct.nextExecutionTime());
        assertFalse(acct.isDue(uint8(DCAFactory.Tier.Daily), block.timestamp));
    }

    function test_isDue_falseWhenTooEarly() public {
        _deposit(DEPOSIT);
        assertFalse(acct.isDue(uint8(DCAFactory.Tier.Weekly), block.timestamp));
    }

    // -------------------------------------------------------------------------
    // isDueAndFunded
    //
    // Every funding case asserts the view AND the outcome of the pull it claims to predict. The
    // predicate's whole value is that it agrees with authorisedPull, so a test that only reads the
    // view proves nothing about the property being claimed.
    // -------------------------------------------------------------------------

    /// Deploys an idle-only strategy holding exactly `idle` USDC. Waives the first-deposit tier
    /// minimum so the balance can sit on a tolerance boundary instead of eight executions above it.
    function _deployWithIdle(uint256 idle) internal returns (UserStrategyAccount a) {
        factory.setMinExecutions(DCAFactory.Tier.Weekly, 0);
        a = UserStrategyAccount(Clones.clone(address(impl)));
        a.initialize(
            owner, address(weth), AMOUNT, uint8(DCAFactory.Tier.Weekly),
            false, address(0), executor, address(factory)
        );
        usdc.mint(owner, idle);
        vm.startPrank(owner);
        usdc.approve(address(a), idle);
        a.deposit(idle);
        vm.stopPrank();
    }

    /// Deploys a yield strategy whose venue position is exactly `venue` USDC, on its own adapter
    /// instance so `balanceOf` is this strategy's position and not a shared pot.
    function _deployWithVenue(uint256 venue)
        internal
        returns (UserStrategyAccount a, MockConformingVenue adapter)
    {
        factory.setMinExecutions(DCAFactory.Tier.Weekly, 0);
        adapter = new MockConformingVenue(address(usdc));
        a = UserStrategyAccount(Clones.clone(address(impl)));
        a.initialize(
            owner, address(weth), AMOUNT, uint8(DCAFactory.Tier.Weekly),
            true, address(adapter), executor, address(factory)
        );
        usdc.mint(owner, venue);
        vm.startPrank(owner);
        usdc.approve(address(a), venue);
        a.deposit(venue);
        vm.stopPrank();
    }

    /// Deploys a yield strategy bound to `adapter` with no position anywhere, for the malformed-read
    /// cases where the adapter never answers honestly in the first place.
    function _deployWithAdapter(address adapter) internal returns (UserStrategyAccount a) {
        a = UserStrategyAccount(Clones.clone(address(impl)));
        a.initialize(
            owner, address(weth), AMOUNT, uint8(DCAFactory.Tier.Weekly),
            true, adapter, executor, address(factory)
        );
    }

    /// @dev `_untaxedYield` as the account computes it, from the outside: tracked balance plus the
    ///      venue's own report, above the book. Read rather than re-derived from deposits, because
    ///      the venue's report is exactly the input whose drift these tests are about.
    function _untaxed(UserStrategyAccount a, MockConformingVenue venue) internal view returns (uint256) {
        uint256 reachable = a.balance() + venue.balanceOf(address(a));
        return reachable > a.depositedAmount() ? reachable - a.depositedAmount() : 0;
    }

    function _due(UserStrategyAccount a) internal view returns (bool) {
        return a.isDueAndFunded(uint8(DCAFactory.Tier.Weekly), block.timestamp);
    }

    // --- idle funding boundary ---

    function test_isDueAndFunded_idleExactlyCoversOneExecution() public {
        UserStrategyAccount a = _deployWithIdle(AMOUNT);
        vm.warp(a.nextExecutionTime());

        assertTrue(_due(a), "exactly funded");

        vm.prank(executor);
        (uint256 pulled1_, ) = a.authorisedPull(AMOUNT, 1);
        assertEq(pulled1_, AMOUNT, "and the pull delivers in full");
    }

    /// One unit short is still fundable: authorisedPull tolerates up to YIELD_WITHDRAWAL_TOLERANCE
    /// and forwards the short amount rather than stalling the strategy.
    function test_isDueAndFunded_idleOneUnitShortIsStillFunded() public {
        UserStrategyAccount a = _deployWithIdle(AMOUNT - 1);
        vm.warp(a.nextExecutionTime());

        assertTrue(_due(a), "within the tolerance");

        vm.prank(executor);
        (uint256 pulled2_, ) = a.authorisedPull(AMOUNT, 1);
        assertEq(pulled2_, AMOUNT - 1, "and the pull goes through short");
        assertFalse(a.paused(), "no auto-pause inside the tolerance");
    }

    /// Two units short is the exact tolerance boundary and still executes.
    function test_isDueAndFunded_idleTwoUnitsShortIsStillFunded() public {
        UserStrategyAccount a = _deployWithIdle(AMOUNT - 2);
        vm.warp(a.nextExecutionTime());

        assertTrue(_due(a), "at the tolerance");

        vm.prank(executor);
        (uint256 pulled3_, ) = a.authorisedPull(AMOUNT, 1);
        assertEq(pulled3_, AMOUNT - 2, "and the pull goes through short");
        assertFalse(a.paused(), "no auto-pause at the tolerance");
    }

    /// Three units short is past the tolerance, which is where the pull auto-pauses.
    function test_isDueAndFunded_idleThreeUnitsShortIsNotFunded() public {
        UserStrategyAccount a = _deployWithIdle(AMOUNT - 3);
        vm.warp(a.nextExecutionTime());

        assertFalse(_due(a), "past the tolerance");

        vm.prank(executor);
        (uint256 pulled4_, ) = a.authorisedPull(AMOUNT, 1);
        assertEq(pulled4_, 0, "and the pull pulls nothing");
        assertTrue(a.paused(), "it auto-pauses instead");
    }

    // --- venue funding boundary ---

    function test_isDueAndFunded_venueExactlyCoversOneExecution() public {
        (UserStrategyAccount a,) = _deployWithVenue(AMOUNT);
        vm.warp(a.nextExecutionTime());

        assertTrue(_due(a), "the venue position covers it");

        vm.prank(executor);
        (uint256 pulled5_, ) = a.authorisedPull(AMOUNT, 1);
        assertEq(pulled5_, AMOUNT, "and the pull delivers in full");
    }

    function test_isDueAndFunded_venueOneUnitShortIsStillFunded() public {
        (UserStrategyAccount a,) = _deployWithVenue(AMOUNT - 1);
        vm.warp(a.nextExecutionTime());

        assertTrue(_due(a), "within the tolerance");

        vm.prank(executor);
        (uint256 pulled6_, ) = a.authorisedPull(AMOUNT, 1);
        assertEq(pulled6_, AMOUNT - 1, "and the pull goes through short");
        assertFalse(a.paused());
    }

    /// Past the tolerance a conforming venue reverts, which authorisedPull catches as a yield
    /// failure and skips - no pause, retry next window.
    function test_isDueAndFunded_venueThreeUnitsShortIsNotFunded() public {
        (UserStrategyAccount a,) = _deployWithVenue(AMOUNT - 3);
        vm.warp(a.nextExecutionTime());

        assertFalse(_due(a), "past the tolerance");

        vm.prank(executor);
        (uint256 pulled7_, ) = a.authorisedPull(AMOUNT, 1);
        assertEq(pulled7_, 0, "and the pull pulls nothing");
    }

    /// The case that decides the whole predicate. Counting available funding as idle plus venue
    /// balance is the obvious reading, and it is wrong for a
    /// yield strategy. authorisedPull asks the venue for the WHOLE amount and idle USDC cannot top up
    /// a short answer, so an account with a full idle balance and an empty venue funds nothing.
    ///
    /// The state is reached honestly: a venue that returns more than requested is conforming (the
    /// interface bounds it from below only), and the surplus lands in `balance`.
    function test_isDueAndFunded_idleUsdcDoesNotFundAYieldStrategy() public {
        (UserStrategyAccount a, MockConformingVenue adapter) = _deployWithVenue(3 * AMOUNT);

        // Window 1: the venue hands back 2x. One AMOUNT goes to the batch, one stays idle.
        adapter.setOverReturn(AMOUNT);
        vm.warp(a.nextExecutionTime());
        vm.prank(executor);
        a.authorisedPull(AMOUNT, 1);

        // Window 2: normal return. The venue empties, idle is untouched.
        adapter.setOverReturn(0);
        vm.warp(a.nextExecutionTime());
        vm.prank(executor);
        a.authorisedPull(AMOUNT, 2);

        assertEq(adapter.balanceOf(address(a)), 0, "venue position is gone");
        assertEq(a.balance(), AMOUNT, "idle alone would cover a full execution");

        vm.warp(a.nextExecutionTime());
        assertFalse(_due(a), "but a yield strategy cannot spend its idle balance");

        vm.prank(executor);
        (uint256 pulled8_, ) = a.authorisedPull(AMOUNT, 3);
        assertEq(pulled8_, 0, "and the pull confirms it: the empty venue cannot cover the draw");
        assertTrue(a.paused(), "so the strategy pauses for its owner rather than skipping forever");
        assertEq(a.balance(), AMOUNT, "the idle balance is still sitting there, withdrawable");
    }

    /// Below the tolerance the shortfall clamp makes `required` zero, so an empty strategy would
    /// read as funded. That is not a harmless over-report: `authorisedPull` clears its own gate in
    /// this configuration, transfers nothing, and still advances the execution window. Reporting it
    /// funded would hand the executor a strategy whose only effect is to cost its owner a window.
    ///
    /// The factory refuses an amount this small, so the account is initialised directly here, outside
    /// the factory's range, to exercise the view on its own.
    function test_isDueAndFunded_anEmptyStrategyIsNotFundedEvenBelowTheTolerance() public {
        UserStrategyAccount a = UserStrategyAccount(Clones.clone(address(impl)));
        a.initialize(
            owner, address(weth), 1, uint8(DCAFactory.Tier.Weekly),
            false, address(0), executor, address(factory)
        );

        assertEq(a.balance(), 0, "nothing to spend");
        assertFalse(_due(a), "and therefore not funded, clamp or no clamp");

        // What the view is refusing to recommend: a pull that moves nothing and burns the window.
        vm.prank(executor);
        (uint256 pulled9_, ) = a.authorisedPull(1, 1);
        assertEq(pulled9_, 0, "the pull really does transfer nothing");
        assertGt(a.nextExecutionTime(), 0, "while still advancing the execution window");
    }

    /// The same hole on the yield path, which needs its own case: the two branches carry separate
    /// zero-source guards and the idle test cannot speak for the venue one.
    function test_isDueAndFunded_anEmptyVenueIsNotFundedEvenBelowTheTolerance() public {
        MockConformingVenue adapter = new MockConformingVenue(address(usdc));
        UserStrategyAccount a = UserStrategyAccount(Clones.clone(address(impl)));
        a.initialize(
            owner, address(weth), 1, uint8(DCAFactory.Tier.Weekly),
            true, address(adapter), executor, address(factory)
        );

        assertEq(adapter.balanceOf(address(a)), 0, "no position anywhere");
        assertFalse(_due(a), "and therefore not funded, clamp or no clamp");

        // The yield pull classifies the empty venue before asking it, and below the
        // tolerance only the `venue > 0` guard tells "empty" from "funded". So unlike the idle case
        // above, the window is NOT burned. The account was never registered, so `_autoPause` is a
        // no-op and the pull is a plain skip.
        vm.prank(executor);
        (uint256 pulled10_, ) = a.authorisedPull(1, 1);
        assertEq(pulled10_, 0, "the pull transfers nothing");
        assertEq(a.nextExecutionTime(), 0, "and does not advance the execution window");
    }

    /// The complement: one unit is a real execution at that size, and is reported as such.
    function test_isDueAndFunded_oneUnitFundsAOneUnitExecution() public {
        factory.setMinExecutions(DCAFactory.Tier.Weekly, 0);
        UserStrategyAccount a = UserStrategyAccount(Clones.clone(address(impl)));
        a.initialize(
            owner, address(weth), 1, uint8(DCAFactory.Tier.Weekly),
            false, address(0), executor, address(factory)
        );
        usdc.mint(owner, 1);
        vm.startPrank(owner);
        usdc.approve(address(a), 1);
        a.deposit(1);
        vm.stopPrank();

        vm.warp(a.nextExecutionTime());
        assertTrue(_due(a), "funded");

        vm.prank(executor);
        (uint256 pulled11_, ) = a.authorisedPull(1, 1);
        assertEq(pulled11_, 1, "and the pull delivers it");
    }

    // --- state exclusions ---

    function test_isDueAndFunded_falseWhenPaused() public {
        UserStrategyAccount a = _deployWithIdle(10 * AMOUNT);
        vm.warp(a.nextExecutionTime());
        vm.prank(owner);
        a.pause();

        assertFalse(_due(a), "paused, however well funded");
    }

    /// `closed` has to decide on its own, not lean on withdraw() having emptied the funding source.
    /// A conforming venue is emptied by withdraw(), so the funding check would answer false anyway
    /// and hide whether the terminal-state check is even consulted. This adapter keeps reporting a
    /// position after closure, which leaves `closed` as the only thing that can say no.
    function test_isDueAndFunded_falseWhenClosed() public {
        factory.setMinExecutions(DCAFactory.Tier.Weekly, 0);
        MockLyingAdapter liar = new MockLyingAdapter(address(usdc));
        UserStrategyAccount a = _deployWithAdapter(address(liar));
        usdc.mint(owner, AMOUNT);
        vm.startPrank(owner);
        usdc.approve(address(a), AMOUNT);
        a.deposit(AMOUNT);
        vm.stopPrank();

        // Only now does it start lying: the deposit itself had to conform to get this far.
        liar.setLie(true);

        vm.warp(a.nextExecutionTime());
        assertTrue(_due(a), "funded while open, on the adapter's own word");

        vm.prank(owner);
        a.withdraw();

        assertTrue(a.closed(), "terminal");
        assertFalse(_due(a), "a terminated strategy is never due, however it reports funding");
    }

    /// A broken adapter reporting an absurd position must not be able to revert this view. Adding
    /// the tolerance to the reported balance would overflow here rather than answering.
    function test_isDueAndFunded_absurdVenueBalanceDoesNotRevert() public {
        MockLyingAdapter liar = new MockLyingAdapter(address(usdc));
        liar.setLie(true);
        UserStrategyAccount a = _deployWithAdapter(address(liar));
        assertTrue(a.isDueAndFunded(uint8(DCAFactory.Tier.Weekly), block.timestamp));
    }

    function test_isDueAndFunded_falseOnWrongTier() public {
        UserStrategyAccount a = _deployWithIdle(10 * AMOUNT);
        vm.warp(a.nextExecutionTime());

        assertFalse(a.isDueAndFunded(uint8(DCAFactory.Tier.Daily), block.timestamp), "weekly strategy");
        assertTrue(_due(a), "same account, its own tier");
    }

    function test_isDueAndFunded_falseWhenNotYetDue() public {
        UserStrategyAccount a = _deployWithIdle(10 * AMOUNT);

        assertFalse(_due(a), "window has not opened");
        assertGt(a.nextExecutionTime(), block.timestamp, "and it really has not");
    }

    // --- malformed adapter reads ---

    function test_isDueAndFunded_falseWhenAdapterReverts() public {
        UserStrategyAccount a = _deployWithAdapter(address(new MockRevertingAdapter()));
        assertFalse(a.isDueAndFunded(uint8(DCAFactory.Tier.Weekly), block.timestamp));
    }

    /// Revert data of exactly one word looks like a successful answer to a length check alone. The
    /// staticcall's success flag is what tells them apart, and it has to be consulted first.
    function test_isDueAndFunded_falseWhenAdapterRevertsWithAWord() public {
        UserStrategyAccount a = _deployWithAdapter(address(new MockRevertingWordAdapter()));
        assertFalse(a.isDueAndFunded(uint8(DCAFactory.Tier.Weekly), block.timestamp));
    }

    function test_isDueAndFunded_falseWhenAdapterTruncatesItsAnswer() public {
        UserStrategyAccount a = _deployWithAdapter(address(new MockTruncatingAdapter()));
        assertFalse(a.isDueAndFunded(uint8(DCAFactory.Tier.Weekly), block.timestamp));
    }

    function test_isDueAndFunded_falseWhenAdapterOverrunsItsAnswer() public {
        UserStrategyAccount a = _deployWithAdapter(address(new MockOverlongAdapter()));
        assertFalse(a.isDueAndFunded(uint8(DCAFactory.Tier.Weekly), block.timestamp));
    }

    /// A staticcall to a code-less address succeeds and returns nothing, which a bare `try` would
    /// not survive.
    function test_isDueAndFunded_falseWhenAdapterHasNoCode() public {
        UserStrategyAccount a = _deployWithAdapter(makeAddr("adapterWithNoCode"));
        assertFalse(a.isDueAndFunded(uint8(DCAFactory.Tier.Weekly), block.timestamp));
    }

    /// `getDueFundedAccounts` is free of cross-page duplicates only for a caller paging the CURRENT
    /// window, and this pair of tests marks exactly where that stops being true. Both are needed:
    /// the first without the second states a guarantee the code does not have.
    ///
    /// The setup either way: the cursor walks registry indices and removal only ever swaps the LAST
    /// entry DOWN, so the one way an EXISTING entry's index rises is `resume` after a pause. Whether
    /// that re-added entry can ALSO be due depends entirely on the `windowStart` the caller passed.
    function test_isDueAndFunded_aResumedStrategyIsNotDueInTheCurrentWindow() public {
        UserStrategyAccount a = _deployWithIdle(10 * AMOUNT);
        vm.warp(a.nextExecutionTime());
        uint256 windowStart = block.timestamp;
        assertTrue(a.isDueAndFunded(uint8(DCAFactory.Tier.Weekly), windowStart), "due before the pause");

        vm.startPrank(owner);
        a.pause();
        a.resume();
        vm.stopPrank();

        assertGt(a.nextExecutionTime(), windowStart, "resume anchors forward, past the open window");
        assertFalse(
            a.isDueAndFunded(uint8(DCAFactory.Tier.Weekly), windowStart),
            "so a mid-page re-registration cannot reappear as due to a current-window caller"
        );
    }

    /// The hole in the above: `resume` anchors to the NEXT boundary exactly, so a strategy that was
    /// already selectable for that boundary is selectable for it AGAIN afterwards. Both assertions
    /// are needed. Without the first, a regression that made the strategy unselectable before the
    /// pause would still pass, and there would be nothing for the second selection to duplicate.
    ///
    /// This is the timing ingredient only. `RegistryPagination.t.sol` proves the complete cross-page
    /// collision against a real registry, which is what the `getDueFundedAccounts` NatSpec
    /// actually claims.
    function test_isDueAndFunded_aResumedStrategyIsDueAgainToAFutureWindowCaller() public {
        UserStrategyAccount a = _deployWithIdle(10 * AMOUNT);
        vm.warp(a.nextExecutionTime());

        // Derived from the tier calendar, exactly as a caller pre-building next week's batch would.
        // Reading `nextExecutionTime()` back after the resume instead would make the assertion below
        // hold for ANY anchor the contract picked, which proves nothing about the collision.
        uint256 nextWindow = block.timestamp + 7 days;

        assertTrue(
            a.isDueAndFunded(uint8(DCAFactory.Tier.Weekly), nextWindow),
            "selectable for that window before the pause"
        );

        vm.startPrank(owner);
        a.pause();
        a.resume();
        vm.stopPrank();

        assertEq(a.nextExecutionTime(), nextWindow, "resume lands on the boundary a caller can predict");
        assertTrue(
            a.isDueAndFunded(uint8(DCAFactory.Tier.Weekly), nextWindow),
            "and selectable for the same window again after it"
        );
    }

    /// The raw timing view is deliberately funding-blind, so an unfunded strategy stays visible to
    /// monitoring after the funded selector drops it.
    function test_isDue_ignoresFundingWhileIsDueAndFundedDoesNot() public {
        UserStrategyAccount a = _deployWithIdle(AMOUNT - YIELD_WITHDRAWAL_TOLERANCE - 1);
        vm.warp(a.nextExecutionTime());

        assertTrue(a.isDue(uint8(DCAFactory.Tier.Weekly), block.timestamp), "still due");
        assertFalse(_due(a), "but not fundable");
    }

    /// Funding-blind is not state-blind: a terminated strategy answers false to BOTH views.
    ///
    /// The `paused` assertion is the point of the test, not scenery. `withdraw()` sets `closed` and
    /// leaves `paused` alone, so every other clause here still reads exactly as it did while the
    /// strategy was live - tier matches, the window is open, `paused` is false. Only the `closed`
    /// guard can produce the answer below, which is why removing it fails this test rather than
    /// being masked by the pause clause.
    ///
    /// This pins the view alone. It cannot cover the case the guard exists for - a closed account
    /// left in the registry by a failed `removeStrategy`, which `getDueAccounts` would then report
    /// as due - because MockFactory keeps no registry to be left in.
    function test_isDue_isFalseAfterWithdrawWithoutAnyPause() public {
        UserStrategyAccount a = _deployWithIdle(10 * AMOUNT);
        vm.warp(a.nextExecutionTime());
        assertTrue(a.isDue(uint8(DCAFactory.Tier.Weekly), block.timestamp), "due while live");

        vm.prank(owner);
        a.withdraw();

        assertTrue(a.closed(), "withdraw is terminal");
        assertFalse(a.paused(), "and it does NOT pause, so the timing half alone would still say due");
        assertGe(block.timestamp, a.nextExecutionTime(), "the window it was due for is still open");

        assertFalse(a.isDue(uint8(DCAFactory.Tier.Weekly), block.timestamp), "yet the raw view says no");
        assertFalse(_due(a), "as does the funded one");
    }

    // -------------------------------------------------------------------------
    // Anchor math
    // -------------------------------------------------------------------------

    function test_nextAnchor_daily_alwaysNextMidnight() public {
        // Deploy a daily strategy
        UserStrategyAccount daily = UserStrategyAccount(Clones.clone(address(impl)));
        daily.initialize(owner, address(weth), AMOUNT, uint8(DCAFactory.Tier.Daily),
            false, address(0), executor, address(factory));

        // Deposit at an arbitrary mid-day timestamp
        // Daily minExecutions = 10, so minimum = 10 * 25e6 = 250e6
        uint256 dailyMin = AMOUNT * 10;
        vm.warp(1_704_067_200 + 43200); // Jan 1 2024 12:00 UTC
        usdc.mint(owner, dailyMin);
        vm.startPrank(owner);
        usdc.approve(address(daily), dailyMin);
        daily.deposit(dailyMin);
        vm.stopPrank();

        // nextExecutionTime should be exactly the next midnight
        uint256 next = daily.nextExecutionTime();
        assertEq(next % 86400, 0, "anchor must be midnight UTC");
        assertGt(next, block.timestamp, "anchor must be in future");
    }

    function test_nextAnchor_weekly_alwaysMonday() public {
        _deposit(DEPOSIT);
        uint256 next = acct.nextExecutionTime();
        // Verify it's a Monday: (timestamp / 86400 + 3) % 7 == 0
        // Unix epoch day 0 = Thursday. Monday is (day + 3) % 7 == 0.
        uint256 dayOfWeek = (next / 86400 + 3) % 7; // 0=Monday
        assertEq(dayOfWeek, 0, "weekly anchor must be a Monday");
    }

    function test_nextAnchor_biweekly_alwaysMonday() public {
        UserStrategyAccount biweekly = UserStrategyAccount(Clones.clone(address(impl)));
        biweekly.initialize(owner, address(weth), AMOUNT, uint8(DCAFactory.Tier.BiWeekly),
            false, address(0), executor, address(factory));

        uint256 biweeklyMin = AMOUNT * 6; // BiWeekly minExecutions = 6
        usdc.mint(owner, biweeklyMin);
        vm.startPrank(owner);
        usdc.approve(address(biweekly), biweeklyMin);
        biweekly.deposit(biweeklyMin);
        vm.stopPrank();

        uint256 next = biweekly.nextExecutionTime();
        // Anchored to a 14-day grid starting on the reference Monday  to  must land on a Monday
        uint256 dayOfWeek = (next / 86400 + 3) % 7; // 0=Monday
        assertEq(dayOfWeek, 0, "biweekly anchor must be a Monday");
        assertGt(next, block.timestamp, "anchor must be in future");
    }

    function test_nextAnchor_monthly_firstOfNextMonth() public {
        UserStrategyAccount monthly = UserStrategyAccount(Clones.clone(address(impl)));
        monthly.initialize(owner, address(weth), AMOUNT, uint8(DCAFactory.Tier.Monthly),
            false, address(0), executor, address(factory));

        uint256 monthlyMin = AMOUNT * 3; // Monthly minExecutions = 3
        vm.warp(1_704_067_200 + 43200); // Jan 1 2024 12:00 UTC
        usdc.mint(owner, monthlyMin);
        vm.startPrank(owner);
        usdc.approve(address(monthly), monthlyMin);
        monthly.deposit(monthlyMin);
        vm.stopPrank();

        // Feb 1 2024 00:00 UTC
        uint256 next = monthly.nextExecutionTime();
        assertEq(next % 86400, 0, "monthly anchor must be midnight UTC");
        assertEq(next, 1_706_745_600, "monthly anchor must be first of next month");
    }

    function test_nextAnchor_monthly_yearRollover() public {
        // December  to  January of next year exercises the m==12 rollover branch
        UserStrategyAccount monthly = UserStrategyAccount(Clones.clone(address(impl)));
        monthly.initialize(owner, address(weth), AMOUNT, uint8(DCAFactory.Tier.Monthly),
            false, address(0), executor, address(factory));

        uint256 monthlyMin = AMOUNT * 3;
        vm.warp(1_702_000_000); // Dec 8 2023 ~01:46 UTC
        usdc.mint(owner, monthlyMin);
        vm.startPrank(owner);
        usdc.approve(address(monthly), monthlyMin);
        monthly.deposit(monthlyMin);
        vm.stopPrank();

        // Jan 1 2024 00:00 UTC
        uint256 next = monthly.nextExecutionTime();
        assertEq(next, 1_704_067_200, "monthly anchor must roll over to Jan 1 next year");
    }

    // -------------------------------------------------------------------------
    // Yield-enabled paths (authorisedPull success, withdraw fee collection)
    // -------------------------------------------------------------------------

    function test_authorisedPull_withYield_succeeds() public {
        UserStrategyAccount yAcct = _deployWithYield();
        vm.warp(yAcct.nextExecutionTime());

        vm.prank(executor);
        (uint256 pulled, ) = yAcct.authorisedPull(AMOUNT, 1);

        assertEq(pulled, AMOUNT);
        assertEq(usdc.balanceOf(executor), AMOUNT);
        assertEq(yAcct.balance(), 0); // withdrawn from Aave then pulled, nothing left idle
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Yield is charged as it is REALIZED, not only at close, so yield spent by executions is
    // charged too.
    // ─────────────────────────────────────────────────────────────────────────

    /// AMOUNT = 25e6, b = 1500, so the gross-up cap is 25e6 * 1500 / 8500 = 4_411_764. With 20 USDC
    /// of accrued yield the pool is below `AMOUNT + cap`, so the whole pool is realized and charged
    /// at the plain rate instead.
    function test_authorisedPull_chargesYieldFeeOnYieldFundedExecution() public {
        UserStrategyAccount yAcct = _deployWithYield();
        usdc.mint(address(yieldAdapter), 20e6); // the venue accrues

        uint256 untaxed = 20e6;
        uint256 expectedFee = untaxed * 1500 / 10000;

        vm.warp(yAcct.nextExecutionTime());
        uint256 executorBefore = usdc.balanceOf(executor);
        vm.prank(executor);
        (uint256 pulled, uint256 fee) = yAcct.authorisedPull(AMOUNT, 1);

        assertEq(pulled, AMOUNT, "the contribution is whole");
        assertEq(fee, expectedFee, "15% of the realized yield, charged now rather than at close");
        assertEq(usdc.balanceOf(executor) - executorBefore, AMOUNT + fee,
            "contribution and fee leave in one transfer");
        // The draw is 25 + 3 = 28 against a 20 pool, so yield covers 20 of it and principal covers
        // the remaining 8. Yield first, principal only for the excess.
        assertEq(yAcct.depositedAmount(), DEPOSIT - (AMOUNT + expectedFee - untaxed),
            "principal moved by exactly the part the yield could not cover");
    }

    /// The event must report what was CHARGED on, not the pool. When more yield has accrued than one
    /// execution can consume, the cap applies and only the consumed part is realized.
    function test_authorisedPull_eventReportsRealizedYieldNotTheUntaxedPool() public {
        UserStrategyAccount yAcct = _deployWithYield();
        usdc.mint(address(yieldAdapter), 500e6); // far more than one execution can consume

        uint256 cap = AMOUNT * 1500 / 8500;
        uint256 realized = AMOUNT + cap; // what actually leaves

        vm.warp(yAcct.nextExecutionTime());
        vm.expectEmit(true, false, false, true, address(yAcct));
        emit UserStrategyAccount.YieldFeeCharged(address(yAcct), realized, cap);
        vm.prank(executor);
        (, uint256 fee) = yAcct.authorisedPull(AMOUNT, 1);

        assertEq(fee, cap, "the fee is capped at one execution's worth");
        // Not `fee * 10000 / realized == 1500`: that quotient floors one unit low. The exact
        // statement is that the fee IS the floored share of what left.
        assertEq(fee, realized * 1500 / 10000, "the cap is the floored 15% of what left");
    }

    /// A venue that can fund the contribution but not the contribution plus the fee cannot perform
    /// its configured execution, so it pauses for its owner rather than skipping: no partial
    /// purchase, no fee debt, the window is not consumed, and no `YieldFailure` is raised, because
    /// the venue did nothing wrong.
    function test_authorisedPull_pausesWhenVenueCannotFundContributionPlusFee() public {
        UserStrategyAccount yAcct = _deployWithYield();

        // Spend the whole book first: with no yield accrued, eight pulls of 25 drain 200 exactly.
        // A thin venue alone is not enough - with the book still full there is no untaxed yield, so
        // no fee is quoted and the old gate would pass.
        for (uint256 i = 1; i <= 8; i++) {
            vm.warp(yAcct.nextExecutionTime());
            vm.prank(executor);
            yAcct.authorisedPull(AMOUNT, i);
        }
        assertEq(yAcct.depositedAmount(), 0, "the book is spent");

        // Now the venue holds pure yield: enough for the contribution, not for contribution + fee.
        usdc.mint(address(yieldAdapter), AMOUNT + 1e6);

        uint256 anchorBefore = yAcct.nextExecutionTime();
        vm.warp(anchorBefore);
        vm.recordLogs();
        vm.prank(executor);
        (uint256 pulled, uint256 fee) = yAcct.authorisedPull(AMOUNT, 9);

        assertEq(pulled, 0, "no partial purchase");
        assertEq(fee, 0, "and no fee debt");
        assertEq(yAcct.nextExecutionTime(), anchorBefore, "the window is not consumed");
        assertTrue(yAcct.paused(), "a venue short of the full draw pauses");
        assertEq(uint8(yAcct.pauseReason()), uint8(UserStrategyAccount.PauseReason.InsufficientBalance));
        assertFalse(_sawYieldFailure(vm.getRecordedLogs()), "depletion is not a venue incident");
    }

    /// The fee-stalled state WITH PRINCIPAL STILL IN THE BOOK. The existing stall test
    /// reaches the state with `depositedAmount == 0`, which leaves open whether the gate depends on
    /// an empty book. It does not: what stalls an execution is the venue being unable to fund
    /// `amount + fee`, whatever the book holds.
    ///
    /// Stalling is a PAUSE, not a skip and not a fault. Recovery would wait on yield to grow
    /// the venue by the fee, which can take years, so the strategy stops and its owner decides. The
    /// window is not consumed, the treasury is not paid, the view agrees it is not fundable, and the
    /// owner's funds stay withdrawable throughout.
    function test_authorisedPull_feeStalledWithPrincipalRemainingPauses() public {
        factory.setMinExecutions(DCAFactory.Tier.Weekly, 0);
        MockConformingVenue venue = new MockConformingVenue(address(usdc));
        UserStrategyAccount a = _deployWithAdapter(address(venue));

        // One execution plus a unit of principal, so the first pull leaves the book non-empty.
        uint256 seed = AMOUNT + 1e6;
        usdc.mint(owner, seed);
        vm.startPrank(owner);
        usdc.approve(address(a), seed);
        a.deposit(seed);
        vm.stopPrank();

        vm.warp(a.nextExecutionTime());
        vm.prank(executor);
        a.authorisedPull(AMOUNT, 1);
        assertEq(a.depositedAmount(), 1e6, "principal remains, which is the whole point of this case");

        // Yield arrives, but only as much as one contribution: enough for `amount`, short of
        // `amount + fee`. `untaxed` is 25, the quote is 3.75, and the venue holds 26.
        usdc.mint(address(venue), AMOUNT);

        uint256 anchorBefore = a.nextExecutionTime();
        uint256 bookBefore = a.depositedAmount();
        uint256 treasuryBefore = usdc.balanceOf(factory.treasury());
        vm.warp(anchorBefore);

        assertFalse(_due(a), "the view must report it unfundable, so the executor stops submitting it");

        vm.prank(executor);
        (uint256 pulled, uint256 fee) = a.authorisedPull(AMOUNT, 2);

        assertEq(pulled, 0, "no partial purchase");
        assertEq(fee, 0, "and no fee debt");
        assertEq(a.nextExecutionTime(), anchorBefore, "the window is not consumed");
        assertEq(a.depositedAmount(), bookBefore, "and the book is untouched");
        assertTrue(a.paused(), "a fee-stalled strategy pauses for its owner");
        assertEq(usdc.balanceOf(factory.treasury()), treasuryBefore, "nothing reaches the treasury");

        // Still the owner's money, and still reachable.
        vm.prank(owner);
        a.withdraw();
        assertGt(usdc.balanceOf(owner), 0, "a stalled strategy is not a stuck one");
    }

    /// The OTHER branch. `test_authorisedPull_toleratedShortfallIsBorneByTheFeeFirst`
    /// covers `quoted >= shortfall`, where the fee absorbs everything and the contribution is whole.
    /// Here the quote is SMALLER than the shortfall, so the fee is exhausted first and the remainder
    /// reaches the purchase: the contribution comes out short by exactly `shortfall - quoted`.
    ///
    /// Asserting "the contribution is always whole" would be wrong, and this is the case that proves
    /// it. What the design guarantees is the ORDER - fee first, contribution second - not that the
    /// contribution never moves.
    function test_authorisedPull_shortfallBeyondTheQuoteReachesTheContribution() public {
        UserStrategyAccount yAcct = _deployWithYield();

        // An untaxed pool of 10 quotes a fee of 1, against a shortfall of 2.
        uint256 untaxed = 10;
        usdc.mint(address(yieldAdapter), untaxed);
        yieldAdapter.setShortfall(2);
        uint256 quoted = untaxed * factory.yieldFeeBps() / 10_000;
        assertEq(quoted, 1, "the arithmetic this case depends on");

        vm.warp(yAcct.nextExecutionTime());
        vm.prank(executor);
        (uint256 pulled, uint256 fee) = yAcct.authorisedPull(AMOUNT, 1);

        assertEq(fee, 0, "the fee is exhausted before the contribution is touched");
        assertEq(pulled, AMOUNT - (2 - quoted), "and the remainder of the shortfall lands there");
        assertFalse(yAcct.paused(), "a shortfall inside the tolerance is not a conformance failure");
    }

    /// A mid-plan top-up is fresh PRINCIPAL, not yield. It must not enlarge the untaxed
    /// pool - otherwise depositing more money would retroactively create a fee on it.
    ///
    /// `deposit` books the full `amount` while `_untaxedYield` reads the venue's own report, so the
    /// two move together on a conforming venue and the pool is unchanged. Where the venue credits
    /// less than it was handed - Aave's liquidity-index rounding, bounded by the tolerance
    /// - the pool SHRINKS by that lag. The direction is what matters: it can never grow, so a top-up
    /// never enlarges the yield-fee base, and the owner absorbs the rounding rather than the protocol
    /// charging for it.
    function test_deposit_topUpNeverEnlargesTheUntaxedPool() public {
        MockConformingVenue venue = new MockConformingVenue(address(usdc));
        UserStrategyAccount a = _deployWithAdapter(address(venue));
        usdc.mint(owner, DEPOSIT + 2 * AMOUNT);
        vm.startPrank(owner);
        usdc.approve(address(a), DEPOSIT + 2 * AMOUNT);
        a.deposit(DEPOSIT);
        vm.stopPrank();

        usdc.mint(address(venue), 40e6); // real accrued yield, which the top-up must not disturb

        uint256 before = _untaxed(a, venue);
        assertEq(before, 40e6, "the pool this test is about");

        vm.prank(owner);
        a.deposit(AMOUNT);
        assertEq(_untaxed(a, venue), before, "a conforming top-up is neither taxed nor untaxed");

        // Now the venue under-credits by the full tolerance on the next deposit.
        venue.setDepositLag(YIELD_WITHDRAWAL_TOLERANCE);
        vm.prank(owner);
        a.deposit(AMOUNT);

        uint256 after_ = _untaxed(a, venue);
        assertLe(after_, before, "the untaxed pool may never grow across a top-up");
        assertEq(before - after_, YIELD_WITHDRAWAL_TOLERANCE, "and shrinks by exactly the lag, borne by the owner");
    }

    /// A top-up un-stalls a FEE-STALLED strategy - the state is about funding, so adding
    /// funds ends it - but it does NOT resume a PAUSED one. Pausing is a decision; stalling is a
    /// condition. Conflating them would let a deposit silently restart a strategy whose owner, or
    /// whose auto-pause, had stopped it.
    function test_deposit_topUpUnstallsAFeeStallButNeverResumesAPause() public {
        factory.setMinExecutions(DCAFactory.Tier.Weekly, 0);
        MockConformingVenue venue = new MockConformingVenue(address(usdc));
        UserStrategyAccount a = _deployWithAdapter(address(venue));
        usdc.mint(owner, AMOUNT + 1e6 + DEPOSIT);
        vm.startPrank(owner);
        usdc.approve(address(a), AMOUNT + 1e6 + DEPOSIT);
        a.deposit(AMOUNT + 1e6);
        vm.stopPrank();

        vm.warp(a.nextExecutionTime());
        vm.prank(executor);
        a.authorisedPull(AMOUNT, 1);

        usdc.mint(address(venue), AMOUNT); // enough for the contribution, short of contribution + fee
        vm.warp(a.nextExecutionTime());
        assertFalse(_due(a), "the strategy is fee-stalled");

        vm.prank(owner);
        a.deposit(DEPOSIT);
        assertTrue(_due(a), "and a top-up ends the stall");

        vm.prank(executor);
        (uint256 pulled, uint256 fee) = a.authorisedPull(AMOUNT, 2);
        assertEq(pulled, AMOUNT, "the execution that was stalled now runs");
        assertGt(fee, 0, "and the yield it was stalled on is charged");

        // The other half: a pause is not a funding condition and a deposit must not lift it.
        vm.prank(owner);
        a.pause();
        usdc.mint(owner, DEPOSIT);
        vm.startPrank(owner);
        usdc.approve(address(a), DEPOSIT);
        a.deposit(DEPOSIT);
        vm.stopPrank();

        assertTrue(a.paused(), "a deposit is not a resume");
        assertFalse(_due(a), "and a paused strategy is never due, however well funded");
    }

    /// A tolerated venue shortfall is borne by the fee first, so the owner's purchase stays whole
    /// while the fee the protocol collects is the one that shrinks.
    function test_authorisedPull_toleratedShortfallIsBorneByTheFeeFirst() public {
        UserStrategyAccount yAcct = _deployWithYield();
        usdc.mint(address(yieldAdapter), 20e6);
        yieldAdapter.setShortfall(1); // one base unit short of the requested draw

        uint256 quoted = 20e6 * 1500 / 10000;

        vm.warp(yAcct.nextExecutionTime());
        vm.prank(executor);
        (uint256 pulled, uint256 fee) = yAcct.authorisedPull(AMOUNT, 1);

        assertEq(pulled, AMOUNT, "the contribution is untouched");
        assertEq(fee, quoted - 1, "the protocol absorbed the whole shortfall");
    }

    /// With yield disabled nothing about this path changed: same transfer, same book transition,
    /// and no fee of any kind.
    function test_authorisedPull_yieldDisabledIsBehaviourEquivalent() public {
        _deposit(DEPOSIT);
        uint256 bookBefore = acct.depositedAmount();
        uint256 balanceBefore = acct.balance();
        uint256 executorBefore = usdc.balanceOf(executor);

        vm.warp(acct.nextExecutionTime());
        vm.prank(executor);
        (uint256 pulled, uint256 fee) = acct.authorisedPull(AMOUNT, 1);

        assertEq(pulled, AMOUNT, "unchanged contribution");
        assertEq(fee, 0, "a yield-disabled account can never owe a yield fee");
        assertEq(usdc.balanceOf(executor) - executorBefore, AMOUNT, "and transfers exactly that");
        assertEq(acct.depositedAmount(), bookBefore - AMOUNT, "book debited by the pull alone");
        assertEq(acct.balance(), balanceBefore - AMOUNT, "balance debited by the pull alone");
    }

    /// The terminal fee base is everything the account can reach, not just what the venue returned.
    /// Idle `balance` is inside the book, so leaving it out would understate the base.
    function test_withdraw_feeBaseIncludesIdleBalance() public {
        UserStrategyAccount yAcct = _deployWithYield();

        // An adapter-conformance failure is the only way a yield-enabled account holds idle USDC:
        // it credits the measured delta, then auto-pauses without pulling. The shortfall has to be
        // PARTIAL - a total one returns nothing and leaves no idle balance at all, which is what
        // made an earlier version of this test pass without testing anything.
        uint256 idle = AMOUNT - 10e6;
        yieldAdapter.setShortfall(10e6);
        vm.warp(yAcct.nextExecutionTime());
        vm.prank(executor);
        yAcct.authorisedPull(AMOUNT, 1);
        assertTrue(yAcct.paused(), "a material shortfall auto-pauses");
        assertEq(yAcct.balance(), idle, "and leaves the measured delta as idle balance");

        usdc.mint(address(yieldAdapter), 10e6); // then the venue accrues real yield
        uint256 treasuryBefore = usdc.balanceOf(factory.treasury());
        uint256 ownerBefore = usdc.balanceOf(owner);

        vm.prank(owner);
        yAcct.withdraw();

        // reachable = idle + venue = 15 + 195 = 210, book = 200, so 10 of yield at 15% = 1.5.
        // Against `received` ALONE the base would be 195 - 200, clamped to zero, and the fee would
        // be nothing - so this number is what separates the two implementations.
        uint256 expectedFee = 10e6 * 1500 / 10000;
        assertEq(usdc.balanceOf(factory.treasury()) - treasuryBefore, expectedFee,
            "the fee is charged against the FULL reachable value, idle balance included");
        assertEq(usdc.balanceOf(owner) - ownerBefore, DEPOSIT + 10e6 - expectedFee,
            "and the owner receives everything else");
        assertEq(yAcct.balance(), 0, "the account is emptied");
    }

    /// A venue that reports `type(uint256).max` while the account already holds idle
    /// `balance` is the exact `_satAdd` case - the one input where the reachable-value sum would
    /// overflow rather than answer.
    ///
    /// The claim is NOT that the fee is correct: against a lying venue it cannot be, and the
    /// interface says so. The claim is that the damage is BOUNDED and nothing is lost. A saturating
    /// `untaxed` puts `_quoteYieldFee` in its capped branch, so one execution can move at most
    /// `amount * b / (10000 - b)` of fee however large the lie - that cap is the whole blast radius
    /// - the view still answers instead of reverting, and at closure every real base
    /// unit the account holds is split between the owner and the treasury with none stranded.
    function test_authorisedPull_saturatingVenueReportIsCappedAndStrandsNothing() public {
        MockOverReportingVenue venue = new MockOverReportingVenue(address(usdc));
        UserStrategyAccount a = _deployWithAdapter(address(venue));
        usdc.mint(owner, DEPOSIT);
        vm.startPrank(owner);
        usdc.approve(address(a), DEPOSIT);
        a.deposit(DEPOSIT);
        vm.stopPrank();

        // One honest execution that hands back more than it was asked for, which is what leaves the
        // account with tracked idle `balance`. Without this the saturating addition has a zero
        // left operand and is indistinguishable from a plain one.
        uint256 extra = 7;
        venue.setOverReturn(extra);
        vm.warp(a.nextExecutionTime());
        vm.prank(executor);
        (uint256 pulled0, uint256 fee0) = a.authorisedPull(AMOUNT, 1);
        assertEq(pulled0, AMOUNT, "the honest execution is fully funded");
        assertEq(fee0, 0, "no yield has accrued yet, so no fee is owed");
        assertEq(a.balance(), extra, "the over-return is tracked as idle balance");

        // Now it lies, and keeps delivering. `_untaxedYield` saturates.
        venue.setLie(true);
        vm.warp(a.nextExecutionTime());
        assertTrue(_due(a), "the view must answer, not revert, on a saturating report");

        uint256 cap = AMOUNT * factory.yieldFeeBps() / (10_000 - factory.yieldFeeBps());
        vm.prank(executor);
        (uint256 pulled1, uint256 fee1) = a.authorisedPull(AMOUNT, 2);

        assertFalse(a.paused(), "a delivering venue must not trip the shortfall path");
        assertEq(pulled1, AMOUNT, "the contribution is unaffected by the lie");
        assertEq(fee1, cap, "an unbounded report is capped at one execution's gross-up");
        assertLe(fee1, cap, "and can never exceed it");

        // Closure: measured deltas only, so the lie cannot inflate the payout either. What must hold
        // is conservation - owner plus treasury equals every real base unit the account can reach.
        uint256 realHoldings = usdc.balanceOf(address(a)) + usdc.balanceOf(address(venue));
        uint256 treasuryBefore = usdc.balanceOf(factory.treasury());
        uint256 ownerBefore = usdc.balanceOf(owner);

        vm.prank(owner);
        a.withdraw();

        uint256 toTreasury = usdc.balanceOf(factory.treasury()) - treasuryBefore;
        uint256 toOwner = usdc.balanceOf(owner) - ownerBefore;
        assertEq(toOwner + toTreasury, realHoldings, "every real unit is paid out, none stranded");
        assertEq(usdc.balanceOf(address(a)), 0, "and nothing is left behind in the account");
    }

    /// Each realization is charged at the rate in force AT THAT REALIZATION. Charging only at close
    /// could use one rate - whichever happened to be set on the day the owner withdrew - so the
    /// distinction is worth pinning.
    ///
    /// Each pull here sits in the capped branch, where the quote is exactly `amount * b / (10000-b)`
    /// and so depends on `b` alone. That makes the rate change visible as an exact number rather
    /// than as a ratio of two pool sizes that also moved.
    function test_authorisedPull_eachRealizationUsesTheRateInForceAtTheTime() public {
        MockConformingVenue venue = new MockConformingVenue(address(usdc));
        UserStrategyAccount a = _deployWithAdapter(address(venue));
        usdc.mint(owner, DEPOSIT);
        vm.startPrank(owner);
        usdc.approve(address(a), DEPOSIT);
        a.deposit(DEPOSIT);
        vm.stopPrank();

        // Enough accrued yield that every execution below stays in the capped branch.
        usdc.mint(address(venue), 100e6);

        uint256 capAt1500 = AMOUNT * 1500 / (10_000 - 1500);
        uint256 capAt3000 = AMOUNT * 3000 / (10_000 - 3000);

        vm.warp(a.nextExecutionTime());
        vm.prank(executor);
        (, uint256 fee1500) = a.authorisedPull(AMOUNT, 1);
        assertEq(fee1500, capAt1500, "charged at the rate in force for the first execution");

        factory.setYieldFeeBps(3000);
        vm.warp(a.nextExecutionTime());
        vm.prank(executor);
        (, uint256 fee3000) = a.authorisedPull(AMOUNT, 2);
        assertEq(fee3000, capAt3000, "the second execution follows the new rate, not the old one");
        assertGt(fee3000, fee1500, "and the raise really moved it");

        // Switched off between executions: the next realization is free, and the pool it did not
        // charge is still there to be charged later.
        factory.setYieldFeeBps(0);
        vm.warp(a.nextExecutionTime());
        vm.prank(executor);
        (uint256 pulled3, uint256 fee0) = a.authorisedPull(AMOUNT, 3);
        assertEq(pulled3, AMOUNT, "a zero rate changes nothing about the contribution");
        assertEq(fee0, 0, "no fee is owed while the rate is off");

        // Back on for closure. The terminal charge takes the residual at the rate in force now -
        // it does not retroactively price what the off period realized.
        factory.setYieldFeeBps(1500);
        uint256 reachable = usdc.balanceOf(address(venue)) + a.balance();
        uint256 residual = reachable - a.depositedAmount();
        uint256 treasuryBefore = usdc.balanceOf(factory.treasury());

        vm.prank(owner);
        a.withdraw();

        assertEq(
            usdc.balanceOf(factory.treasury()) - treasuryBefore,
            residual * 1500 / 10_000,
            "the terminal charge uses the rate in force at closure"
        );
    }

    /// Value that arrives without passing through `deposit` or the venue is not in the
    /// book, so it is not in the fee base either - and it is not swept out at closure.
    ///
    /// Two inbound routes, two different answers, and the difference is the point:
    ///
    /// - **Base tokens sent straight to the account.** Tracked `balance` only ever moves on a
    ///   measured inflow, so a bare `transfer` moves nothing. It raises no fee, and `withdraw` pays
    ///   out `reachable - fee` computed from the book rather than from `usdc.balanceOf(this)`, so it
    ///   stays where it landed. Donating to an account is throwing USDC away; it is NOT a way to
    ///   enlarge a payout, and not a way to enlarge a fee either.
    /// - **Base tokens sent to the venue.** Those DO raise the reported position, and the design
    ///   taxes them as realized yield. That is intended: the venue's balance is the account's own
    ///   value, and the clone is per account, so this enriches and charges one owner only.
    function test_untrackedInboundValueIsNeitherChargedNorSwept() public {
        MockConformingVenue venue = new MockConformingVenue(address(usdc));
        UserStrategyAccount a = _deployWithAdapter(address(venue));
        usdc.mint(owner, DEPOSIT);
        vm.startPrank(owner);
        usdc.approve(address(a), DEPOSIT);
        a.deposit(DEPOSIT);
        vm.stopPrank();

        uint256 stray = 9e6;
        uint256 venueGift = 40e6;
        usdc.mint(address(a), stray); // straight at the account: invisible to the book
        usdc.mint(address(venue), venueGift); // at the venue: indistinguishable from accrued yield

        assertEq(a.balance(), 0, "a bare transfer must not move tracked balance");

        uint256 treasuryBefore = usdc.balanceOf(factory.treasury());
        uint256 ownerBefore = usdc.balanceOf(owner);

        vm.prank(owner);
        a.withdraw();

        // The venue gift is charged; the stray is not part of the base it was charged against.
        assertEq(
            usdc.balanceOf(factory.treasury()) - treasuryBefore,
            venueGift * factory.yieldFeeBps() / 10_000,
            "only value the account can reach through its book is charged"
        );
        assertEq(
            usdc.balanceOf(owner) - ownerBefore,
            DEPOSIT + venueGift - venueGift * factory.yieldFeeBps() / 10_000,
            "the owner receives principal plus net venue value, and nothing of the stray transfer"
        );
        assertEq(usdc.balanceOf(address(a)), stray, "the stray stays where it landed, unsweepable");
    }

    function test_withdraw_withYield_collectsYieldFee() public {
        UserStrategyAccount yAcct = _deployWithYield(); // deposits 200e6 into adapter
        // Simulate accrued yield: mint extra USDC into the adapter so withdrawAll returns more
        uint256 yield = 20e6;
        usdc.mint(address(yieldAdapter), yield);

        uint256 fee = yield * factory.yieldFeeBps() / 10000; // 15% of 20 = 3 USDC
        address treasuryAddr = factory.treasury();

        vm.prank(owner);
        yAcct.withdraw();

        assertEq(usdc.balanceOf(treasuryAddr), fee, "treasury receives yield fee");
        assertEq(usdc.balanceOf(owner), DEPOSIT + yield - fee, "owner receives principal + net yield");
        assertEq(yAcct.balance(), 0);
    }

    function test_withdraw_withYield_noYield_noFee() public {
        // Zero accrued yield  to  yieldEarned == 0  to  fee == 0  to  else branch (no treasury transfer)
        UserStrategyAccount yAcct = _deployWithYield(); // adapter holds exactly DEPOSIT
        address treasuryAddr = factory.treasury();

        vm.prank(owner);
        yAcct.withdraw();

        assertEq(usdc.balanceOf(treasuryAddr), 0, "no fee when no yield");
        assertEq(usdc.balanceOf(owner), DEPOSIT, "owner receives full principal");
    }

    function test_withdraw_withYield_negativeDrift_noFeeAndOwnerBearsLoss() public {
        // A below-principal venue position (negative drift) must charge NO yield fee.
        // Same "yield only when positive" guard as the zero-yield case, exercised from the loss side:
        // received < depositedAmount => yieldEarned == 0 => no treasury transfer, owner bears the loss.
        UserStrategyAccount yAcct = _deployWithYield(); // adapter holds exactly DEPOSIT
        address treasuryAddr = factory.treasury();

        // Drive the position below the deposited principal, modelling a venue loss.
        uint256 loss = 1_000_000; // 1 USDC
        vm.prank(address(yieldAdapter));
        usdc.transfer(address(0xdEaD), loss);
        assertLt(yieldAdapter.balanceOf(address(yAcct)), DEPOSIT, "position drifted below principal");

        vm.prank(owner);
        yAcct.withdraw();

        assertEq(usdc.balanceOf(treasuryAddr), 0, "no yield fee on a below-principal position");
        assertEq(usdc.balanceOf(owner), DEPOSIT - loss, "owner bears the loss, receives the reduced position");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // A strategy is active only while it can fund its complete next draw. Underfunding
    // pauses, on the pull and through `reconcileFunding`; a funded venue that refuses is a skip; an
    // unreadable venue is never taken for depletion.
    // ─────────────────────────────────────────────────────────────────────────

    /// A strategy whose BatchExecutor is a role mock, so `reconcileFunding` can read a real
    /// `executor()`. `funding` is deposited into the venue (yield on) or held idle (yield off).
    function _reconcilable(bool withYield, uint256 funding)
        internal
        returns (UserStrategyAccount a, MockSwitchableVenue venue, MockExecutorRole role)
    {
        factory.setMinExecutions(DCAFactory.Tier.Weekly, 0);
        role = new MockExecutorRole(executor);
        if (withYield) venue = new MockSwitchableVenue(address(usdc));
        a = UserStrategyAccount(Clones.clone(address(impl)));
        a.initialize(
            owner, address(weth), AMOUNT, uint8(DCAFactory.Tier.Weekly),
            withYield, address(venue), address(role), address(factory)
        );
        usdc.mint(owner, funding);
        vm.startPrank(owner);
        usdc.approve(address(a), funding);
        a.deposit(funding);
        vm.stopPrank();
    }

    /// Leaves exactly `left` in the venue, modelling a position spent or lost outside this account.
    function _shrinkVenue(MockSwitchableVenue venue, uint256 left) internal {
        uint256 held = usdc.balanceOf(address(venue));
        vm.prank(address(venue));
        usdc.transfer(address(0xdEaD), held - left);
    }

    function _sawYieldFailure(Vm.Log[] memory logs) internal pure returns (bool) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == UserStrategyAccount.YieldFailure.selector) {
                return true;
            }
        }
        return false;
    }

    function _assertInsufficientBalancePause(UserStrategyAccount a) internal view {
        assertTrue(a.paused(), "paused");
        assertEq(
            uint8(a.pauseReason()), uint8(UserStrategyAccount.PauseReason.InsufficientBalance),
            "for insufficient balance, not as a manual pause"
        );
    }

    // --- the pull ---

    /// The emptied-venue state itself: the position is gone, so the strategy has finished. It pauses
    /// and leaves the registry on its first empty window, as a yield-off account does, and the venue is
    /// never asked for a withdrawal that cannot succeed.
    function test_authorisedPull_emptyVenuePausesWithoutCallingTheVenue() public {
        (UserStrategyAccount a, MockSwitchableVenue venue, MockExecutorRole role) = _reconcilable(true, 2 * AMOUNT);
        _shrinkVenue(venue, 0);
        vm.warp(a.nextExecutionTime());
        uint256 anchorBefore = a.nextExecutionTime();
        uint256 removalsBefore = factory.removeCount();

        vm.expectCall(address(venue), abi.encodeWithSelector(MockSwitchableVenue.withdraw.selector), 0);
        vm.recordLogs();
        vm.prank(address(role));
        (uint256 pulled, uint256 fee) = a.authorisedPull(AMOUNT, 1);

        assertEq(pulled + fee, 0, "nothing moves");
        _assertInsufficientBalancePause(a);
        assertEq(factory.removeCount(), removalsBefore + 1, "and it leaves the registry");
        assertFalse(_sawYieldFailure(vm.getRecordedLogs()), "an empty position is not a venue incident");
        assertEq(a.nextExecutionTime(), anchorBefore, "the anchor is not advanced");
        assertTrue(a.usedNonces(1), "the nonce is consumed, like every other post-nonce pause");
    }

    function test_authorisedPull_venueBelowOneContributionPauses() public {
        (UserStrategyAccount a, MockSwitchableVenue venue, MockExecutorRole role) = _reconcilable(true, 2 * AMOUNT);
        _shrinkVenue(venue, AMOUNT / 2);
        vm.warp(a.nextExecutionTime());

        vm.recordLogs();
        vm.prank(address(role));
        (uint256 pulled,) = a.authorisedPull(AMOUNT, 1);

        assertEq(pulled, 0);
        _assertInsufficientBalancePause(a);
        assertFalse(_sawYieldFailure(vm.getRecordedLogs()), "no YieldFailure for depletion");
        assertEq(usdc.balanceOf(address(venue)), AMOUNT / 2, "and the residual stays withdrawable");
    }

    /// The boundary is on the complete draw, with the tolerance: `venue == draw - TOLERANCE` is funded.
    /// A refusal there is the venue's fault, so it stays a `YieldFailure` skip and names the full draw.
    function test_authorisedPull_refusalAtTheFundedBoundaryIsAYieldFailureSkip() public {
        (UserStrategyAccount a, MockSwitchableVenue venue, MockExecutorRole role) =
            _reconcilable(true, AMOUNT - YIELD_WITHDRAWAL_TOLERANCE);
        venue.setRefuse(true);
        vm.warp(a.nextExecutionTime());
        uint256 anchorBefore = a.nextExecutionTime();
        uint256 removalsBefore = factory.removeCount();

        vm.expectEmit(true, true, false, true, address(a));
        emit UserStrategyAccount.YieldFailure(address(a), address(venue), AMOUNT, block.timestamp);
        vm.prank(address(role));
        (uint256 pulled,) = a.authorisedPull(AMOUNT, 1);

        assertEq(pulled, 0, "skipped");
        assertFalse(a.paused(), "a funded position whose venue refuses is not paused");
        assertEq(factory.removeCount(), removalsBefore, "and stays registered");
        assertEq(a.nextExecutionTime(), anchorBefore, "to retry the same window's successor");
    }

    function test_authorisedPull_oneUnitBelowTheBoundaryPausesEvenWhenTheVenueWouldRefuse() public {
        (UserStrategyAccount a, MockSwitchableVenue venue, MockExecutorRole role) =
            _reconcilable(true, AMOUNT - YIELD_WITHDRAWAL_TOLERANCE - 1);
        venue.setRefuse(true);
        vm.warp(a.nextExecutionTime());

        vm.expectCall(address(venue), abi.encodeWithSelector(MockSwitchableVenue.withdraw.selector), 0);
        vm.recordLogs();
        vm.prank(address(role));
        a.authorisedPull(AMOUNT, 1);

        _assertInsufficientBalancePause(a);
        assertFalse(_sawYieldFailure(vm.getRecordedLogs()), "classified before the venue is asked");
    }

    /// An unreadable position is an incident, not depletion: the pull reverts (BatchExecutor turns
    /// that into `AccountSkipped`) and the strategy is not paused.
    function test_authorisedPull_unreadableVenueRevertsAndDoesNotPause() public {
        for (uint8 mode = 1; mode <= 4; mode++) {
            (UserStrategyAccount a, MockSwitchableVenue venue, MockExecutorRole role) = _reconcilable(true, AMOUNT);
            _breakVenueRead(venue, mode);
            vm.warp(a.nextExecutionTime());

            vm.expectRevert(UserStrategyAccount.VenueUnreadable.selector);
            vm.prank(address(role));
            a.authorisedPull(AMOUNT, 1);

            assertFalse(a.paused(), "never paused on an unreadable venue");
            assertFalse(a.usedNonces(1), "and the nonce write rolls back with the revert");
        }
    }

    /// With a venue that refuses every withdrawal, the pull pauses exactly the accounts the
    /// funded view rejects, and raises `YieldFailure` exactly for the ones it accepts. So a
    /// `YieldFailure` always comes from a position that covered the complete draw.
    function testFuzz_authorisedPull_yieldFailureOnlyFromAFundedPosition(uint256 deposited, uint256 accrued) public {
        deposited = bound(deposited, 1, 3 * AMOUNT);
        accrued   = bound(accrued, 0, 2 * AMOUNT);
        (UserStrategyAccount a, MockSwitchableVenue venue, MockExecutorRole role) = _reconcilable(true, deposited);
        usdc.mint(address(venue), accrued);
        venue.setRefuse(true);
        vm.warp(a.nextExecutionTime());
        bool funded = _due(a);

        vm.recordLogs();
        vm.prank(address(role));
        (uint256 pulled,) = a.authorisedPull(AMOUNT, 1);

        assertEq(pulled, 0, "the venue refuses, so nothing is ever pulled");
        assertEq(a.paused(), !funded, "paused iff the view called it unfunded");
        assertEq(_sawYieldFailure(vm.getRecordedLogs()), funded, "YieldFailure iff it was funded");
    }

    // --- reconcileFunding: authorization ---

    function test_reconcile_strangerCannotCall() public {
        (UserStrategyAccount a,,) = _reconcilable(false, AMOUNT / 2);
        vm.warp(a.nextExecutionTime());

        vm.expectRevert(UserStrategyAccount.Unauthorized.selector);
        vm.prank(makeAddr("stranger"));
        a.reconcileFunding();
    }

    function test_reconcile_ownerCanReconcile() public {
        (UserStrategyAccount a,,) = _reconcilable(false, AMOUNT / 2);
        vm.warp(a.nextExecutionTime());

        vm.prank(owner);
        assertTrue(a.reconcileFunding(), "the owner may pause their own underfunded strategy");
        _assertInsufficientBalancePause(a);
    }

    /// The executor is read live from the account's BatchExecutor, so a rotation moves the right at
    /// once and nothing on the account has to be updated.
    function test_reconcile_followsExecutorRotation() public {
        (UserStrategyAccount a,, MockExecutorRole role) = _reconcilable(false, AMOUNT / 2);
        vm.warp(a.nextExecutionTime());
        address successor = makeAddr("successor");
        role.setExecutor(successor);

        vm.expectRevert(UserStrategyAccount.Unauthorized.selector);
        vm.prank(executor);
        a.reconcileFunding();

        vm.prank(successor);
        assertTrue(a.reconcileFunding(), "the current executor may reconcile");
        _assertInsufficientBalancePause(a);
    }

    // --- reconcileFunding: no transition ---

    function _assertNoTransition(UserStrategyAccount a, address caller) internal {
        bool pausedBefore = a.paused();
        uint8 reasonBefore = uint8(a.pauseReason());
        uint256 anchorBefore = a.nextExecutionTime();
        uint256 removalsBefore = factory.removeCount();

        vm.recordLogs();
        vm.prank(caller);
        bool pausedNow = a.reconcileFunding();

        assertFalse(pausedNow, "nothing to do");
        assertEq(vm.getRecordedLogs().length, 0, "and nothing emitted");
        assertEq(a.paused(), pausedBefore, "pause state unchanged");
        assertEq(uint8(a.pauseReason()), reasonBefore, "pause reason unchanged");
        assertEq(a.nextExecutionTime(), anchorBefore, "anchor unchanged");
        assertEq(factory.removeCount(), removalsBefore, "registry untouched");
    }

    function test_reconcile_neverRegisteredIsANoOp() public {
        MockExecutorRole role = new MockExecutorRole(executor);
        UserStrategyAccount a = UserStrategyAccount(Clones.clone(address(impl)));
        a.initialize(
            owner, address(weth), AMOUNT, uint8(DCAFactory.Tier.Weekly),
            false, address(0), address(role), address(factory)
        );
        _assertNoTransition(a, executor);
    }

    function test_reconcile_notYetDueIsANoOp() public {
        (UserStrategyAccount a,,) = _reconcilable(false, AMOUNT / 2);
        assertLt(block.timestamp, a.nextExecutionTime(), "the window has not opened");
        _assertNoTransition(a, executor);
    }

    /// The initially-unpaused precondition of the reconcile property: a manual pause is left exactly as it is,
    /// reason included, however underfunded the strategy.
    function test_reconcile_alreadyPausedIsANoOp() public {
        (UserStrategyAccount a,,) = _reconcilable(false, AMOUNT / 2);
        vm.prank(owner);
        a.pause();
        vm.warp(a.nextExecutionTime());
        _assertNoTransition(a, executor);
    }

    function test_reconcile_closedIsANoOp() public {
        (UserStrategyAccount a,,) = _reconcilable(false, AMOUNT / 2);
        vm.prank(owner);
        a.withdraw();
        vm.warp(a.nextExecutionTime());
        _assertNoTransition(a, executor);
    }

    function test_reconcile_fundedIsANoOp() public {
        (UserStrategyAccount a,,) = _reconcilable(true, AMOUNT - YIELD_WITHDRAWAL_TOLERANCE);
        vm.warp(a.nextExecutionTime());
        _assertNoTransition(a, executor);
    }

    function test_reconcile_secondCallIsANoOp() public {
        (UserStrategyAccount a,,) = _reconcilable(false, AMOUNT / 2);
        vm.warp(a.nextExecutionTime());
        vm.prank(executor);
        assertTrue(a.reconcileFunding());
        _assertNoTransition(a, executor);
    }

    // --- reconcileFunding: the transition ---

    function _assertReconcilePauses(UserStrategyAccount a, MockSwitchableVenue venue) internal {
        vm.warp(a.nextExecutionTime());
        uint256 anchorBefore = a.nextExecutionTime();
        uint256 removalsBefore = factory.removeCount();
        uint256 accountUsdc = usdc.balanceOf(address(a));
        uint256 venueUsdc = address(venue) == address(0) ? 0 : usdc.balanceOf(address(venue));

        if (address(venue) != address(0)) {
            vm.expectCall(address(venue), abi.encodeWithSelector(MockSwitchableVenue.withdraw.selector), 0);
        }
        vm.expectEmit(true, false, false, true, address(a));
        emit UserStrategyAccount.Paused(address(a), UserStrategyAccount.PauseReason.InsufficientBalance);
        vm.prank(executor);
        assertTrue(a.reconcileFunding(), "paused by this call");

        _assertInsufficientBalancePause(a);
        assertEq(factory.removeCount(), removalsBefore + 1, "and removed from the registry");
        assertEq(a.nextExecutionTime(), anchorBefore, "no execution anchor moves");
        assertEq(usdc.balanceOf(address(a)), accountUsdc, "no tokens leave the account");
        if (address(venue) != address(0)) {
            assertEq(usdc.balanceOf(address(venue)), venueUsdc, "or the venue");
        }
    }

    function test_reconcile_pausesAnEmptyVenue() public {
        (UserStrategyAccount a, MockSwitchableVenue venue,) = _reconcilable(true, 2 * AMOUNT);
        _shrinkVenue(venue, 0);
        _assertReconcilePauses(a, venue);
    }

    function test_reconcile_pausesAVenueBelowOneContribution() public {
        (UserStrategyAccount a, MockSwitchableVenue venue,) = _reconcilable(true, 2 * AMOUNT);
        _shrinkVenue(venue, AMOUNT / 2);
        _assertReconcilePauses(a, venue);
    }

    /// The fee gap: enough for the contribution, not for the contribution plus its yield fee. Book 1,
    /// venue 26, so the untaxed pool is 25 and the draw is 25 + 3.75.
    function test_reconcile_pausesAVenueShortOnlyOfTheYieldFee() public {
        (UserStrategyAccount a, MockSwitchableVenue venue,) = _reconcilable(true, 1e6);
        usdc.mint(address(venue), AMOUNT);
        vm.warp(a.nextExecutionTime());
        assertGe(usdc.balanceOf(address(venue)), AMOUNT, "the contribution alone is covered");
        _assertReconcilePauses(a, venue);
    }

    function test_reconcile_pausesOneUnitBelowTheBoundary() public {
        (UserStrategyAccount a, MockSwitchableVenue venue,) =
            _reconcilable(true, AMOUNT - YIELD_WITHDRAWAL_TOLERANCE - 1);
        _assertReconcilePauses(a, venue);
    }

    function test_reconcile_pausesAnIdleBalanceBelowOneContribution() public {
        (UserStrategyAccount a,,) = _reconcilable(false, AMOUNT / 2);
        _assertReconcilePauses(a, MockSwitchableVenue(address(0)));
    }

    /// The recovery path the pause asks for: top up, then resume.
    function test_reconcile_ownerRecoversByTopUpAndResume() public {
        (UserStrategyAccount a,,) = _reconcilable(false, AMOUNT / 2);
        vm.warp(a.nextExecutionTime());
        vm.prank(executor);
        a.reconcileFunding();

        usdc.mint(owner, AMOUNT);
        vm.startPrank(owner);
        usdc.approve(address(a), AMOUNT);
        a.deposit(AMOUNT);
        a.resume();
        vm.stopPrank();

        vm.warp(a.nextExecutionTime());
        assertTrue(_due(a), "funded and due again");
    }

    // --- reconcileFunding: unreadable venue ---

    /// Every malformed answer the fail-soft view maps to false, plus a venue that lost its code. The
    /// view says "not funded" for all of them, and that must never become a pause.
    function test_reconcile_unreadableVenueRevertsAndDoesNotPause() public {
        for (uint8 mode = 1; mode <= 4; mode++) {
            (UserStrategyAccount a, MockSwitchableVenue venue,) = _reconcilable(true, AMOUNT / 2);
            _breakVenueRead(venue, mode);
            vm.warp(a.nextExecutionTime());
            assertFalse(_due(a), "the fail-soft view reads it as not funded");

            vm.expectRevert(UserStrategyAccount.VenueUnreadable.selector);
            vm.prank(executor);
            a.reconcileFunding();

            assertFalse(a.paused(), "but reconciliation does not pause it");
        }
    }

    /// 1-3 break the answer; 4 removes the venue's code.
    function _breakVenueRead(MockSwitchableVenue venue, uint8 mode) internal {
        if (mode == 4) vm.etch(address(venue), hex"");
        else venue.setReadMode(mode);
    }

    /// On a registered, unpaused, open, due account with a readable venue, a reconcile
    /// pauses it exactly when the funded view rejects it, and says so in its return value.
    function testFuzz_reconcile_pausesExactlyTheUnfunded(uint256 deposited, uint256 accrued, bool withYield) public {
        deposited = bound(deposited, 1, 3 * AMOUNT);
        accrued   = bound(accrued, 0, 2 * AMOUNT);
        (UserStrategyAccount a, MockSwitchableVenue venue,) = _reconcilable(withYield, deposited);
        if (withYield) usdc.mint(address(venue), accrued);
        vm.warp(a.nextExecutionTime());
        bool funded = _due(a);

        vm.prank(executor);
        bool pausedNow = a.reconcileFunding();

        assertEq(pausedNow, !funded, "returns true iff it paused");
        assertEq(a.paused(), !funded, "paused iff the complete draw was not covered");
    }
}

// -------------------------------------------------------------------------
// Helper: ERC20 that fails transfer
// -------------------------------------------------------------------------
/// @notice Configurable output token for the pending-recovery tests: delivery can fail by
///         returning false or by reverting, transfers can charge a fee, and the balance can be cut
///         from outside to model a downward rebase.
contract MockOutputToken {
    enum Fail { None, ReturnFalse, Revert }

    mapping(address => uint256) public balanceOf;
    Fail public failMode;
    uint256 public feeBps;

    function setFailMode(Fail m) external { failMode = m; }
    function setFeeBps(uint256 b) external { feeBps = b; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }

    /// @dev Models any balance decrease this contract does not control: a downward rebase,
    ///      a supply adjustment, an external clawback.
    function burn(address from, uint256 a) external { balanceOf[from] -= a; }

    function transfer(address to, uint256 a) external returns (bool) {
        if (failMode == Fail.ReturnFalse) return false;
        if (failMode == Fail.Revert) revert("token: transfer blocked");
        balanceOf[msg.sender] -= a;
        uint256 fee = a * feeBps / 10000;
        balanceOf[to] += a - fee;
        return true;
    }

    function approve(address, uint256) external returns (bool) { return true; }
    function allowance(address, address) external pure returns (uint256) { return type(uint256).max; }
    function forceApprove(address, uint256) external returns (bool) { return true; }
}

contract MockERC20FailTransfer {
    mapping(address => uint256) public balanceOf;
    bool public shouldFail = true;

    function setShouldFail(bool v) external { shouldFail = v; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }

    function transfer(address to, uint256 a) external returns (bool) {
        if (shouldFail) return false;
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        balanceOf[from] -= a;
        balanceOf[to] += a;
        return true;
    }
    function approve(address, uint256) external returns (bool) { return true; }
    function allowance(address, address) external pure returns (uint256) { return type(uint256).max; }
    function forceApprove(address, uint256) external returns (bool) { return true; }
}

/// @dev Models a token whose `transfer` returns a non-standard value. The balance move always
///      happens; only the returned bytes vary, controlled by `retMode`. `Empty` is the USDT shape
///      (no return data), `Bytes16` an undersized return, `DirtyBool` a 32-byte word that is neither
///      0 nor 1. A `returns (bool)` decode of any of these reverts in the *caller's* frame, which is
///      the exact hazard `receiveOutput` must tolerate. Assembly is required because a Solidity
///      `returns (bool)` signature cannot itself emit these shapes.
contract MockNonStandardReturnToken {
    enum Ret { Empty, Bytes16, DirtyBool, CleanTrue, CleanFalse }

    mapping(address => uint256) public balanceOf;
    Ret public retMode; // defaults to Empty (USDT-style)

    function setRetMode(Ret m) external { retMode = m; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }

    function transfer(address to, uint256 a) external returns (bool) {
        Ret m = retMode;
        // Successful shapes (Empty, CleanTrue) actually move the balance; the failure shapes
        // (Bytes16, DirtyBool, CleanFalse) report failure and move nothing, mirroring real tokens.
        if (m == Ret.Empty || m == Ret.CleanTrue) {
            balanceOf[msg.sender] -= a;
            balanceOf[to] += a;
        }
        assembly {
            switch m
            case 0 { return(0, 0) }                       // Empty: no return data
            case 1 { mstore(0, 1) return(0, 16) }         // Bytes16: undersized
            case 2 { mstore(0, 2) return(0, 32) }         // DirtyBool: word is 2
            case 3 { mstore(0, 1) return(0, 32) }         // CleanTrue
            case 4 { mstore(0, 0) return(0, 32) }         // CleanFalse
        }
        return true; // unreachable; satisfies the compiler's return check
    }

    function approve(address, uint256) external returns (bool) { return true; }
    function allowance(address, address) external pure returns (uint256) { return type(uint256).max; }
}

/// @dev A token whose `transfer` returns or reverts with arbitrary bytes, or burns its gas.
///      `setReturn` picks the return length and first word; the balance always moves, so a test
///      tells delivery from fallback by the account's pending record alone. `setBomb` first burns
///      gas down to `keepGas`, then returns or reverts with `size` zero bytes, which is the payload
///      shape that ran the old caller out of gas while copying it. `setBurnAll` never returns.
contract MockReturndataToken {
    mapping(address => uint256) public balanceOf;
    uint256 public retSize;
    uint256 public retWord = 1;
    uint256 public keepGas;
    bool public revertInstead;
    bool public burnAll;

    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function setReturn(uint256 size, uint256 word) external { retSize = size; retWord = word; }
    function setBurnAll(bool v) external { burnAll = v; }

    function setBomb(uint256 size, uint256 keepGas_, bool revertInstead_) external {
        retSize = size;
        retWord = 0;
        keepGas = keepGas_;
        revertInstead = revertInstead_;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        if (burnAll) {
            while (true) {}
        }
        uint256 keep = keepGas;
        if (keep != 0) {
            while (gasleft() > keep) {}
        }

        uint256 size = retSize;
        uint256 word = retWord;
        if (revertInstead) {
            assembly { revert(0, size) }
        }
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        assembly {
            mstore(0, word)
            return(0, size)
        }
    }
}

/// @dev A venue that holds a real position and can be made to fail in the two ways the account separates.
///      `refuse` makes `withdraw` revert while `balanceOf` keeps reporting the position, as a paused
///      or frozen reserve does. `readMode` breaks the `balanceOf` answer itself: 1 reverts, 2 returns
///      half a word, 3 returns two words.
contract MockSwitchableVenue {
    MockERC20 public immutable usdc;
    bool public refuse;
    uint8 public readMode;

    constructor(address _usdc) { usdc = MockERC20(_usdc); }

    function setRefuse(bool v) external { refuse = v; }
    function setReadMode(uint8 v) external { readMode = v; }

    function deposit(uint256 amount) external {
        require(usdc.transferFrom(msg.sender, address(this), amount), "deposit transfer failed");
    }

    function withdraw(uint256 amount) external returns (uint256 received) {
        require(!refuse, "venue refuses");
        uint256 held = usdc.balanceOf(address(this));
        received = held < amount ? held : amount;
        require(received + YIELD_WITHDRAWAL_TOLERANCE >= amount, "venue shortfall");
        require(usdc.transfer(msg.sender, received), "withdraw transfer failed");
    }

    function withdrawAll() external returns (uint256 received) {
        received = usdc.balanceOf(address(this));
        if (received > 0) require(usdc.transfer(msg.sender, received), "withdrawAll transfer failed");
    }

    function balanceOf(address) external view returns (uint256) {
        uint8 mode = readMode;
        uint256 held = usdc.balanceOf(address(this));
        if (mode == 1) revert("venue unreadable");
        if (mode == 2) assembly { mstore(0, held) return(0, 16) }
        if (mode == 3) assembly { mstore(0, held) mstore(32, held) return(0, 64) }
        return held;
    }
}

/// @dev Stands in for BatchExecutor's `executor()` read in `reconcileFunding`.
contract MockExecutorRole {
    address public executor;
    constructor(address e) { executor = e; }
    function setExecutor(address e) external { executor = e; }
}
