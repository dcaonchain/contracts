// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../../src/DCAFactory.sol";
import "../../src/UserStrategyAccount.sol";
import "../../src/interfaces/IYieldAdapter.sol";

// Non-zero `referralCommitment` for tests that do not care what it is. The factory rejects zero
// and ignores everything else, so any constant does here; production clients must not use one.
bytes32 constant TEST_COMMITMENT = keccak256("dca-test-referral-commitment");


// ─────────────────────────────────────────────────────────────────────────────
// Mock strategy implementation (minimal - just satisfy initialize signature)
// ─────────────────────────────────────────────────────────────────────────────

contract InvStrategyImpl {
    bool public initialized;
    address public factoryAddr;
    address public strategyOwner;
    /// @dev Recorded so the clone-lineage property can be checked on the adapter the factory
    ///      actually handed this account, not on one the test re-derives.
    address public boundYieldAdapter;

    function initialize(
        address _owner, address, uint256, uint8, bool, address _yieldAdapter, address, address _factory
    ) external {
        require(!initialized);
        initialized = true;
        factoryAddr = _factory;
        strategyOwner = _owner;
        boundYieldAdapter = _yieldAdapter;
    }

    function isDue(uint8, uint256) external pure returns (bool) { return false; }

    function selfRegister() external {
        DCAFactory(factoryAddr).registerStrategy(address(this));
    }

    function selfRemove() external {
        DCAFactory(factoryAddr).removeStrategy(address(this));
    }
}

/// @dev Minimal approvable yield-adapter implementation: exposes the clone lifecycle the factory
///      drives, and nothing else. Yield mechanics are covered in the adapter's own tests.
contract InvYieldAdapterImpl is IYieldAdapterImplementation {
    address public immutable base;
    address public account;

    constructor(address base_) {
        base = base_;
    }

    function initialize(address account_) external {
        require(account == address(0), "already initialized");
        account = account_;
    }

    function baseToken() external view returns (address) { return base; }
    function deposit(uint256) external {}
    function withdraw(uint256 amount) external pure returns (uint256) { return amount; }
    function withdrawAll() external pure returns (uint256) { return 0; }
    function balanceOf(address) external pure returns (uint256) { return 0; }
}

// ─────────────────────────────────────────────────────────────────────────────
// Handler
// ─────────────────────────────────────────────────────────────────────────────

contract DCAFactoryHandler is Test {
    DCAFactory public factory;
    InvStrategyImpl public impl;
    address public usdc = makeAddr("usdc");
    address public batchExecutor = makeAddr("batchExecutor");
    address public owner_ = makeAddr("owner");

    address[] public deployedStrategies;
    // Creator recorded at creation time, so owner-is-creator can be checked against a value
    // the factory never saw as calldata.
    mapping(address => address) public creatorOf;

    function deployedCount() external view returns (uint256) {
        return deployedStrategies.length;
    }

    constructor() {
        impl = new InvStrategyImpl();
        // Owner is a constructor argument; Foundry 1.8 no longer applies vm.prank to CREATE.
        factory = new DCAFactory(address(impl), batchExecutor, usdc, owner_, owner_, owner_);
        // `createStrategy` reads the executor's asset allowlist; the executor here is an EOA.
        vm.mockCall(
            batchExecutor,
            abi.encodeCall(IAssetAllowlist.whitelistedAssets, (makeAddr("weth"))),
            abi.encode(true)
        );
    }

    /// @dev `callerSeed` varies the creator so owner-is-creator is exercised against many distinct
    ///      callers rather than a single fixed one.
    function createAndRegister(uint256 callerSeed) external {
        DCAFactory.StrategyParams memory p = DCAFactory.StrategyParams({
            targetAsset: makeAddr("weth"),
            amountPerExecution: 25e6,
            tier: DCAFactory.Tier.Weekly,
            yieldAdapterImplementation: address(0)
        });

        address creator = address(uint160(uint256(keccak256(abi.encode(callerSeed)))));
        if (creator == address(0)) return;

        vm.prank(creator);
        address acct = factory.createStrategy(p, TEST_COMMITMENT);
        deployedStrategies.push(acct);
        creatorOf[acct] = creator;

        // Self-register (simulates first deposit)
        vm.prank(acct);
        factory.registerStrategy(acct);
    }

    function removeRandom(uint256 seed) external {
        uint256 count = factory.activeStrategyCount();
        if (count == 0) return;

        address[] memory active = factory.getActiveStrategies();
        address toRemove = active[seed % count];
        vm.prank(toRemove);
        factory.removeStrategy(toRemove);
    }

    function setFees(uint256 execBps, uint256 yieldBps) external {
        execBps  = bound(execBps,  0, factory.MAX_EXECUTION_FEE_BPS());
        yieldBps = bound(yieldBps, 0, factory.MAX_YIELD_FEE_BPS());
        vm.prank(owner_);
        factory.setFees(execBps, yieldBps);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Invariant test contract
// ─────────────────────────────────────────────────────────────────────────────

contract DCAFactoryInvariantTest is StdInvariant, Test {
    DCAFactoryHandler internal handler;

    function setUp() public {
        handler = new DCAFactoryHandler();
        targetContract(address(handler));
    }

    /// The registry invariants below are all "for every entry" properties, so they hold
    /// trivially against an empty registry. A stale mock initializer signature makes the
    /// factory's low-level init call fail, reverting every createStrategy with InitFailed,
    /// and leaves all of them green while testing nothing. This drives the handler directly
    /// so that failure mode is loud instead of silent.
    ///
    /// Deliberately a unit test rather than an invariant: the fuzzer picks among three handler
    /// functions, so a short run can legitimately never call createAndRegister.
    function test_handlerActuallyCreatesStrategies() public {
        handler.createAndRegister(1);

        assertEq(handler.deployedCount(), 1, "harness vacuous: createStrategy reverted");
        assertEq(handler.factory().activeStrategyCount(), 1, "harness vacuous: nothing registered");

        address acct = handler.deployedStrategies(0);
        assertEq(
            InvStrategyImpl(acct).strategyOwner(),
            handler.creatorOf(acct),
            "stored owner is not the createStrategy caller"
        );
    }

    /// Every strategy stores the address that called createStrategy. Checked against
    /// a creator the handler recorded itself, never against a value passed through the factory.
    function invariant_ownerIsAlwaysTheCreator() public view {
        uint256 n = handler.deployedCount();
        for (uint256 i = 0; i < n; i++) {
            address acct = handler.deployedStrategies(i);
            assertEq(
                InvStrategyImpl(acct).strategyOwner(),
                handler.creatorOf(acct),
                "stored owner is not the createStrategy caller"
            );
        }
    }

    /// `isActiveStrategy(account) => isDeployedByFactory[account]`. Every address in the
    /// active registry was deployed by this factory. The converse does not hold and is not asserted
    /// here - provenance-holding accounts are routinely inactive (created-but-unfunded, paused,
    /// closed), which invariant_stoppedAccountsAreNeverActive covers from the other side.
    function invariant_registryContainsOnlyKnownStrategies() public view {
        address[] memory active = handler.factory().getActiveStrategies();
        for (uint256 i = 0; i < active.length; i++) {
            assertTrue(
                handler.factory().isDeployedByFactory(active[i]),
                "registry contains unknown address"
            );
        }
    }

    /// Derived membership: isActiveStrategy agrees with actual array membership in both
    /// directions. It reads the 1-based `_strategyIndex` rather than a second boolean, but index and
    /// array are still two structures, so the correspondence is maintained by swap-with-last-and-pop
    /// and has to be asserted rather than assumed. This is that assertion.
    function invariant_activeMembershipMatchesArray() public view {
        DCAFactory f = handler.factory();
        address[] memory active = f.getActiveStrategies();
        for (uint256 i = 0; i < active.length; i++) {
            assertTrue(f.isActiveStrategy(active[i]), "array entry not reported active");
        }
        // Reverse direction over every address the handler has ever created: anything absent from
        // the array must report inactive.
        uint256 n = handler.deployedCount();
        for (uint256 i = 0; i < n; i++) {
            address acct = handler.deployedStrategies(i);
            bool inArray = false;
            for (uint256 j = 0; j < active.length; j++) {
                if (active[j] == acct) { inArray = true; break; }
            }
            assertEq(f.isActiveStrategy(acct), inArray, "membership disagrees with array");
        }
    }

    /// Provenance is permanent: every account this factory has created keeps provenance
    /// forever, whatever its registry state. resume() depends on this surviving a removal.
    function invariant_provenanceIsNeverCleared() public view {
        uint256 n = handler.deployedCount();
        for (uint256 i = 0; i < n; i++) {
            assertTrue(
                handler.factory().isDeployedByFactory(handler.deployedStrategies(i)),
                "provenance was cleared"
            );
        }
    }

    /// activeStrategyCount matches getActiveStrategies().length - no gaps.
    function invariant_registryCountMatchesLength() public view {
        assertEq(
            handler.factory().activeStrategyCount(),
            handler.factory().getActiveStrategies().length,
            "count/length mismatch"
        );
    }

    /// No address appears twice in the registry.
    function invariant_registryNoDuplicates() public view {
        address[] memory active = handler.factory().getActiveStrategies();
        for (uint256 i = 0; i < active.length; i++) {
            for (uint256 j = i + 1; j < active.length; j++) {
                assertTrue(active[i] != active[j], "duplicate in registry");
            }
        }
    }

    /// Fee parameters always within caps.
    function invariant_feeCapsNeverExceeded() public view {
        DCAFactory f = handler.factory();
        assertLe(f.executionFeeBps(),  100,  "executionFeeBps over cap");
        assertLe(f.yieldFeeBps(),      3000,      "yieldFeeBps over cap");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Fuzz tests: yield adapter lineage, fee caps
// ─────────────────────────────────────────────────────────────────────────────

contract DCAFactoryFuzzTest is Test {
    DCAFactory factory;
    InvStrategyImpl impl;
    address owner_ = makeAddr("owner");
    address usdc   = makeAddr("usdc");
    address batchExecutor = makeAddr("batchExecutor");

    function setUp() public {
        impl = new InvStrategyImpl();
        // Owner is a constructor argument; Foundry 1.8 no longer applies vm.prank to CREATE.
        factory = new DCAFactory(address(impl), batchExecutor, usdc, owner_, owner_, owner_);
        // `createStrategy` reads the executor's asset allowlist; the executor here is an EOA.
        vm.mockCall(
            batchExecutor,
            abi.encodeCall(IAssetAllowlist.whitelistedAssets, (makeAddr("weth"))),
            abi.encode(true)
        );
    }

    /// setFees must revert on any value exceeding caps.
    function testFuzz_setFees_revertsAboveExecutionCap(uint256 bps) public {
        bps = bound(bps, 100 + 1, type(uint16).max);
        vm.prank(owner_);
        vm.expectRevert();
        factory.setFees(bps, 1500);
    }

    function testFuzz_setFees_revertsAboveYieldCap(uint256 bps) public {
        bps = bound(bps, 3000 + 1, type(uint16).max);
        vm.prank(owner_);
        vm.expectRevert();
        factory.setFees(15, bps);
    }

    /// Any value within caps must be accepted.
    function testFuzz_setFees_acceptsValuesWithinCaps(uint256 e, uint256 y) public {
        e = bound(e, 0, 100);
        y = bound(y, 0, 3000);
        vm.prank(owner_);
        factory.setFees(e, y); // must not revert
        assertEq(factory.executionFeeBps(), e);
        assertEq(factory.yieldFeeBps(), y);
    }

    /// Lineage (1): createStrategy must revert for any implementation that was never approved,
    /// whatever else is true of the address.
    function testFuzz_createStrategy_rejectsUnapprovedImplementation(address implementation) public {
        vm.assume(implementation != address(0));
        // No approval given
        DCAFactory.StrategyParams memory p = _yieldParams(implementation);
        vm.expectRevert(abi.encodeWithSelector(DCAFactory.AdapterNotApproved.selector, implementation));
        factory.createStrategy(p, TEST_COMMITMENT);
    }

    /// Lineage (1): an approved implementation whose codehash no longer matches what was approved
    /// must not be clonable. Simulates a metamorphic redeploy by overwriting the code at the
    /// approved address after approval.
    function testFuzz_createStrategy_rejectsCodehashMismatch(bytes memory replacementCode) public {
        vm.assume(replacementCode.length > 0 && replacementCode.length < 2048);
        // EIP-7702 delegation designators are `0xef0100 || address`. `vm.etch` rejects the prefix rather than
        // etching it, so these inputs abort the cheatcode instead of exercising the codehash check.
        vm.assume(!(replacementCode.length >= 2 && replacementCode[0] == 0xef && replacementCode[1] == 0x01));

        InvYieldAdapterImpl implementation = new InvYieldAdapterImpl(usdc);
        vm.prank(owner_);
        factory.setApprovedYieldAdapterImplementation(address(implementation), true);
        bytes32 approved = factory.approvedYieldAdapterCodehash(address(implementation));
        assertTrue(approved != bytes32(0), "approval must have recorded a codehash");

        vm.etch(address(implementation), replacementCode);
        bytes32 actual = address(implementation).codehash;
        vm.assume(actual != approved);

        vm.expectRevert(
            abi.encodeWithSelector(
                DCAFactory.AdapterCodehashMismatch.selector, address(implementation), approved, actual
            )
        );
        factory.createStrategy(_yieldParams(address(implementation)), TEST_COMMITMENT);
    }

    /// Lineage (2): approval must reject any implementation whose base token is not the factory's.
    function testFuzz_setApprovedImplementation_rejectsForeignBaseToken(address foreignBase) public {
        vm.assume(foreignBase != usdc);

        InvYieldAdapterImpl implementation = new InvYieldAdapterImpl(foreignBase);
        vm.prank(owner_);
        vm.expectRevert(
            abi.encodeWithSelector(
                DCAFactory.AdapterBaseTokenMismatch.selector, address(implementation), foreignBase
            )
        );
        factory.setApprovedYieldAdapterImplementation(address(implementation), true);
        assertEq(
            factory.approvedYieldAdapterCodehash(address(implementation)),
            bytes32(0),
            "rejected implementation must not be recorded"
        );
    }

    /// Lineage (3): every adapter a successful creation produces is a clone bound to exactly that
    /// strategy account, for any creator.
    function testFuzz_createStrategy_adapterCloneIsBoundToItsAccount(uint256 callerSeed) public {
        InvYieldAdapterImpl implementation = new InvYieldAdapterImpl(usdc);
        vm.prank(owner_);
        factory.setApprovedYieldAdapterImplementation(address(implementation), true);

        address creator = address(uint160(uint256(keccak256(abi.encode(callerSeed)))));
        vm.assume(creator != address(0));

        vm.prank(creator);
        address acct = factory.createStrategy(_yieldParams(address(implementation)), TEST_COMMITMENT);

        // Non-vacuity: the creation actually happened and actually produced an adapter clone.
        assertTrue(factory.isDeployedByFactory(acct), "createStrategy must have recorded factory provenance");
        address adapter = InvStrategyImpl(acct).boundYieldAdapter();
        assertTrue(adapter != address(0), "a yield strategy must be given an adapter");
        assertTrue(adapter != address(implementation), "the adapter must be a clone, not the implementation");
        assertEq(InvYieldAdapterImpl(adapter).account(), acct, "clone must be bound to its own account");
        assertEq(InvYieldAdapterImpl(adapter).baseToken(), usdc, "clone must report the factory base token");
    }

    function _yieldParams(address implementation) internal returns (DCAFactory.StrategyParams memory) {
        return DCAFactory.StrategyParams({
            targetAsset: makeAddr("weth"),
            amountPerExecution: 25e6,
            tier: DCAFactory.Tier.Weekly,
            yieldAdapterImplementation: implementation
        });
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Active registry entries are live - registered, unpaused, and not closed. Exercises
// the REAL DCAFactory + UserStrategyAccount lifecycle so the
// deposit/pause/resume/withdraw/redeposit paths are covered, closed-account redeposit included.
// ─────────────────────────────────────────────────────────────────────────────

contract RegistryUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external returns (bool) {
        if (balanceOf[msg.sender] < a) return false;
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function forceApprove(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
}

contract RegistryLifecycleHandler is Test {
    DCAFactory public factory;
    RegistryUSDC public usdc;
    UserStrategyAccount[] public accounts;

    /// Ghost state for the funded-membership invariant: true once a deposit on this account has
    /// actually SUCCEEDED.
    /// Written only after the call returns, never before it and never from the account's own view,
    /// so it cannot inherit the bug it exists to detect. `_registered` is private, and reading it
    /// through a getter added for the test would make the invariant assert the contract against
    /// itself.
    mapping(address => bool) public hasDeposited;

    address public weth   = makeAddr("regWeth");
    address public owner_  = makeAddr("regOwner");

    uint256 constant AMOUNT  = 25e6;
    uint256 constant MIN_DEP = AMOUNT * 8; // weekly minimum

    constructor() {
        usdc = new RegistryUSDC();
        UserStrategyAccount impl = new UserStrategyAccount();
        // Owner is a constructor argument; Foundry 1.8 no longer applies vm.prank to CREATE.
        factory = new DCAFactory(address(impl), makeAddr("regBatchExec"), address(usdc), owner_, owner_, owner_);
        // `createStrategy` reads the executor's asset allowlist; the executor here is an EOA.
        vm.mockCall(
            makeAddr("regBatchExec"),
            abi.encodeCall(IAssetAllowlist.whitelistedAssets, (weth)),
            abi.encode(true)
        );
    }

    function createAndDeposit(uint256 seed) external {
        DCAFactory.StrategyParams memory p = DCAFactory.StrategyParams({
            targetAsset: weth,
            amountPerExecution: AMOUNT,
            tier: DCAFactory.Tier.Weekly,
            yieldAdapterImplementation: address(0)
        });
        vm.prank(owner_);
        address acct = factory.createStrategy(p, TEST_COMMITMENT);
        accounts.push(UserStrategyAccount(acct));

        uint256 dep = MIN_DEP + (seed % (MIN_DEP * 4));
        usdc.mint(owner_, dep);
        vm.startPrank(owner_);
        usdc.approve(acct, dep);
        UserStrategyAccount(acct).deposit(dep);
        vm.stopPrank();
        hasDeposited[acct] = true;
    }

    /// Creation WITHOUT a deposit. Needed because `createAndDeposit` is atomic: without this, no
    /// sequence the fuzzer could build would put an account in the created-but-unfunded state, and
    /// every action below would silently only ever see activated accounts.
    function createOnly(uint256) external {
        DCAFactory.StrategyParams memory p = DCAFactory.StrategyParams({
            targetAsset: weth,
            amountPerExecution: AMOUNT,
            tier: DCAFactory.Tier.Weekly,
            yieldAdapterImplementation: address(0)
        });
        vm.prank(owner_);
        accounts.push(UserStrategyAccount(factory.createStrategy(p, TEST_COMMITMENT)));
    }

    /// The first deposit for an account `createOnly` left unfunded. Separate from `redepositRandom`
    /// because activation has a minimum: `redepositRandom` deposits AMOUNT against a MIN_DEP of
    /// 8 * AMOUNT, so it can never be the call that activates anything.
    function activateRandom(uint256 seed) external {
        if (accounts.length == 0) return;
        address acct = address(accounts[seed % accounts.length]);
        usdc.mint(owner_, MIN_DEP);
        vm.startPrank(owner_);
        usdc.approve(acct, MIN_DEP);
        try UserStrategyAccount(acct).deposit(MIN_DEP) {
            hasDeposited[acct] = true;
        } catch {}
        vm.stopPrank();
    }

    /// The executor route to auto-pause, the one path that could set `paused == true` on a
    /// never-funded account. The factory's registry gate keeps the BatchExecutor from calling a
    /// created-only clone, but `setBatchExecutor` can repoint future clones, so the account has to
    /// guard itself. Modelled by pranking the account's own configured executor
    /// and calling `authorisedPull` directly on an account no deposit has activated; gated on
    /// `!hasDeposited` so it models only that never-funded hit. Without the account's guard this would
    /// set `paused = true`, and a following `resumeRandom` would register the unfunded account, which
    /// `invariant_activeEntriesHaveBeenFunded` catches. Without this action the fuzzer could never
    /// reach `_autoPause`: the factory's batchExecutor is an EOA that never calls.
    function autoPauseUnfundedViaExecutor(uint256 seed) external {
        if (accounts.length == 0) return;
        UserStrategyAccount a = accounts[seed % accounts.length];
        if (hasDeposited[address(a)]) return;
        vm.prank(a.batchExecutor());
        try a.authorisedPull(AMOUNT, uint256(keccak256(abi.encode(seed, address(a))))) {} catch {}
    }

    function pauseRandom(uint256 seed) external {
        if (accounts.length == 0) return;
        vm.prank(owner_);
        try accounts[seed % accounts.length].pause() {} catch {}
    }

    function resumeRandom(uint256 seed) external {
        if (accounts.length == 0) return;
        vm.prank(owner_);
        try accounts[seed % accounts.length].resume() {} catch {}
    }

    function withdrawRandom(uint256 seed) external {
        if (accounts.length == 0) return;
        vm.prank(owner_);
        try accounts[seed % accounts.length].withdraw() {} catch {}
    }

    function accountCount() external view returns (uint256) {
        return accounts.length;
    }

    /// A closed strategy must reject redeposit and never re-register.
    function redepositRandom(uint256 seed) external {
        if (accounts.length == 0) return;
        UserStrategyAccount a = accounts[seed % accounts.length];
        usdc.mint(owner_, AMOUNT);
        vm.startPrank(owner_);
        usdc.approve(address(a), AMOUNT);
        // Ghost written INSIDE the try, so it can never read false for an account that did activate.
        // Today this cannot be a first deposit (AMOUNT is below the MIN_DEP activation minimum), but
        // pinning the ghost to the call actually succeeding is what keeps that true if the minimum
        // or this amount ever changes.
        try a.deposit(AMOUNT) { hasDeposited[address(a)] = true; } catch {}
        vm.stopPrank();
    }
}

contract RegistryLifecycleInvariantTest is StdInvariant, Test {
    RegistryLifecycleHandler internal handler;

    function setUp() public {
        handler = new RegistryLifecycleHandler();
        targetContract(address(handler));
    }

    /// Every address in the active registry is a live strategy -
    /// registered, not paused, and not closed/withdrawn.
    function invariant_activeRegistryEntriesAreLive() public view {
        address[] memory active = handler.factory().getActiveStrategies();
        for (uint256 i = 0; i < active.length; i++) {
            UserStrategyAccount a = UserStrategyAccount(active[i]);
            assertTrue(handler.factory().isDeployedByFactory(active[i]), "unknown registry entry");
            assertFalse(a.paused(), "paused strategy must not be in active registry");
            assertFalse(a.closed(), "closed strategy must not be in active registry");
        }
    }

    /// Membership implies the account took a first deposit.
    ///
    /// Stated separately because the assertions above cannot express it. A created-but-never-funded
    /// account that reached the registry via `pause()` then `resume()` is unpaused, unclosed and
    /// factory-deployed, so it satisfies every one of them. Without the `pause()` activation guard
    /// this fails on the three-step sequence directly; the assertions above could only catch it
    /// stochastically, and only if the fuzzer went on to append `withdraw()` to that exact sequence
    /// on that exact account and trip the `closed` check.
    ///
    /// The ghost is the handler's record of a deposit that RETURNED, not a read of the account, so
    /// this compares the registry against what actually happened rather than against the same flag
    /// the contract used to decide.
    function invariant_activeEntriesHaveBeenFunded() public view {
        address[] memory active = handler.factory().getActiveStrategies();
        for (uint256 i = 0; i < active.length; i++) {
            assertTrue(
                handler.hasDeposited(active[i]),
                "registry holds an account that never took a deposit"
            );
        }
    }

    /// Permanent provenance and active-implies-deployed, stated from the account side, over
    /// accounts the registry array cannot show. A stopped account reports inactive while keeping
    /// provenance, which is exactly the separation BatchExecutor relies on - and the reason the
    /// converse of active-implies-deployed must not be asserted.
    function invariant_stoppedAccountsAreNeverActive() public view {
        DCAFactory f = handler.factory();
        uint256 n = handler.accountCount();
        for (uint256 i = 0; i < n; i++) {
            UserStrategyAccount a = handler.accounts(i);
            assertTrue(f.isDeployedByFactory(address(a)), "provenance lost");
            if (a.paused() || a.closed()) {
                assertFalse(f.isActiveStrategy(address(a)), "a stopped account reports active");
            }
        }
    }
}
