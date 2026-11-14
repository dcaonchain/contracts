// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/DCAFactory.sol";
import "../../src/UserStrategyAccount.sol";
import "../../src/interfaces/IYieldAdapter.sol";

// Non-zero `referralCommitment`; the factory rejects zero and ignores everything else.
bytes32 constant ACTIVATION_COMMITMENT = keccak256("dca-activation-test-commitment");

/// @dev Minimal transferring token. Both halves of the lifecycle have to be real here - the account
///      owns `_registered` and the factory owns membership - so the deposit path needs a token it
///      can actually move.
contract ActivationERC20 {
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

/// @notice Activation is the gate on the whole pause/resume lifecycle.
/// @dev Against a REAL factory holding REAL accounts, because the property spans both: `_registered`
///      is the account's, membership is the factory's, and a mock on either side would let the two
///      agree by assumption rather than by construction. A suite that mocks whichever half it is not
///      testing cannot see a disagreement between them.
contract StrategyActivationTest is Test {
    DCAFactory internal factory;
    ActivationERC20 internal usdc;

    address internal deployer = makeAddr("deployer");
    address internal user     = makeAddr("user");
    address internal weth     = makeAddr("weth");
    address internal executor = makeAddr("batchExecutor");

    uint256 constant AMOUNT  = 5_000_000;   // the factory's minimum per execution
    uint256 constant DEPOSIT = 8 * AMOUNT;  // the weekly tier minimum, exactly 8 executions

    function setUp() public {
        usdc = new ActivationERC20();
        UserStrategyAccount impl = new UserStrategyAccount();

        factory = new DCAFactory(
            address(impl), executor, address(usdc), deployer, deployer, deployer
        );
        // `createStrategy` reads the executor's asset allowlist; the executor here is an EOA.
        vm.mockCall(
            executor,
            abi.encodeCall(IAssetAllowlist.whitelistedAssets, (weth)),
            abi.encode(true)
        );
    }

    /// A created, never-funded weekly strategy owned by `user`. Deliberately NOT deposited.
    function _created() internal returns (UserStrategyAccount acct) {
        DCAFactory.StrategyParams memory p = DCAFactory.StrategyParams({
            targetAsset: weth,
            amountPerExecution: AMOUNT,
            tier: DCAFactory.Tier.Weekly,
            yieldAdapterImplementation: address(0)
        });
        vm.prank(user);
        acct = UserStrategyAccount(factory.createStrategy(p, ACTIVATION_COMMITMENT));
    }

    function _fund(UserStrategyAccount acct) internal {
        usdc.mint(user, DEPOSIT);
        vm.startPrank(user);
        usdc.approve(address(acct), DEPOSIT);
        acct.deposit(DEPOSIT);
        vm.stopPrank();
    }

    /// The exact hard floor is one unit above the shared withdrawal tolerance. Against the
    /// real factory/account pair, that boundary can activate only with a real deposit and its due
    /// pull transfers a non-zero amount before advancing the window.
    function test_minimumEconomicBoundsRequireARealPullBeforeWindowAdvance() public {
        vm.startPrank(deployer);
        factory.setMinAmountPerExecution(YIELD_WITHDRAWAL_TOLERANCE + 1);
        factory.setMinExecutions(DCAFactory.Tier.Weekly, 1);
        vm.stopPrank();

        DCAFactory.StrategyParams memory p = DCAFactory.StrategyParams({
            targetAsset: weth,
            amountPerExecution: YIELD_WITHDRAWAL_TOLERANCE + 1,
            tier: DCAFactory.Tier.Weekly,
            yieldAdapterImplementation: address(0)
        });
        vm.prank(user);
        UserStrategyAccount acct = UserStrategyAccount(factory.createStrategy(p, ACTIVATION_COMMITMENT));

        usdc.mint(user, YIELD_WITHDRAWAL_TOLERANCE + 1);
        vm.startPrank(user);
        usdc.approve(address(acct), YIELD_WITHDRAWAL_TOLERANCE + 1);
        acct.deposit(YIELD_WITHDRAWAL_TOLERANCE + 1);
        vm.stopPrank();

        uint256 due = acct.nextExecutionTime();
        vm.warp(due);
        vm.prank(executor);
        (uint256 gotTolerance, ) = acct.authorisedPull(YIELD_WITHDRAWAL_TOLERANCE + 1, 1);
        assertEq(
            gotTolerance,
            YIELD_WITHDRAWAL_TOLERANCE + 1,
            "the minimum execution still moves value"
        );
        assertGt(acct.nextExecutionTime(), due, "a real pull advances to the next window");
    }

    /// The guard itself: there is nothing to pause before the first deposit, and the state the call
    /// would create is the entry to a never-funded account reaching the registry.
    function test_pause_revertsBeforeFirstDeposit() public {
        UserStrategyAccount acct = _created();

        vm.prank(user);
        vm.expectRevert(UserStrategyAccount.NotActivated.selector);
        acct.pause();

        assertFalse(acct.paused(), "a rejected pause must not have set the flag");
        assertFalse(factory.isActiveStrategy(address(acct)), "still not in the registry");
    }

    /// The whole sequence, end to end: `resume()` is unreachable because `pause()` is, so a
    /// never-funded account has no route into the registry at all.
    ///
    /// Asserting the second revert matters as much as the first. `NotPaused` is what proves the
    /// account never entered the paused state, rather than entering it and being refused entry to
    /// the registry later - the difference between fixing the root cause and fixing a symptom.
    function test_neverFundedAccountCannotBecomeActive() public {
        UserStrategyAccount acct = _created();

        vm.startPrank(user);
        vm.expectRevert(UserStrategyAccount.NotActivated.selector);
        acct.pause();

        vm.expectRevert(UserStrategyAccount.NotPaused.selector);
        acct.resume();
        vm.stopPrank();

        assertEq(factory.activeStrategyCount(), 0, "registry stays empty");
        assertFalse(factory.isActiveStrategy(address(acct)));
        assertTrue(factory.isDeployedByFactory(address(acct)), "provenance is untouched");
    }

    /// The legitimate counterpart of that sequence, which must keep working. Same four calls,
    /// with the deposit that activates the strategy first, so `_registered` is true and `withdraw()`
    /// deregisters. This account is registered and funded throughout, so it does not discriminate
    /// between candidate fixes; it pins that the guard left the ordinary lifecycle alone.
    function test_activatedPauseResumeWithdraw_removesFromRegistry() public {
        UserStrategyAccount acct = _created();
        _fund(acct);
        assertTrue(factory.isActiveStrategy(address(acct)), "the first deposit registers");

        vm.startPrank(user);
        acct.pause();
        assertFalse(factory.isActiveStrategy(address(acct)), "pause removes");

        acct.resume();
        assertTrue(factory.isActiveStrategy(address(acct)), "resume re-registers");

        acct.withdraw();
        vm.stopPrank();

        assertTrue(acct.closed(), "withdraw is terminal");
        assertFalse(factory.isActiveStrategy(address(acct)), "a closed strategy leaves the registry");
        assertEq(factory.activeStrategyCount(), 0);
    }

    /// A real insufficient-balance auto-pause, then resume. Auto-pause leaves `_registered` true
    /// while removing the registry entry, so `resume()` is the only way back in - the guard
    /// must not reach this path. Drains the deposit through `authorisedPull` rather than asserting
    /// on a manually paused account, because the state that matters here is the one only the
    /// executor can produce.
    function test_autoPausedAccountStillResumesAndPauses() public {
        UserStrategyAccount acct = _created();
        _fund(acct); // exactly 8 executions

        for (uint256 i = 0; i < 8; i++) {
            vm.warp(acct.nextExecutionTime());
            vm.prank(executor);
            (uint256 gotWindow, ) = acct.authorisedPull(AMOUNT, i);
            assertEq(gotWindow, AMOUNT, "each funded window pulls in full");
        }
        assertEq(acct.balance(), 0, "the deposit is spent");
        assertFalse(acct.paused(), "draining alone does not pause");

        // The ninth window has nothing to pull: balance + TOLERANCE < amount trips the auto-pause.
        vm.warp(acct.nextExecutionTime());
        vm.prank(executor);
        (uint256 gotUnfunded, ) = acct.authorisedPull(AMOUNT, 8);
        assertEq(gotUnfunded, 0, "an unfunded window pulls nothing");

        assertTrue(acct.paused(), "auto-paused");
        assertEq(
            uint8(acct.pauseReason()),
            uint8(UserStrategyAccount.PauseReason.InsufficientBalance),
            "auto-pause, not a manual one"
        );
        assertFalse(factory.isActiveStrategy(address(acct)), "auto-pause removes from the registry");

        // The account stays activated through all of that, so re-entry works and a later manual
        // pause is still accepted. An implementation that gated re-entry on current funding would
        // fail here: this account is empty.
        vm.startPrank(user);
        acct.resume();
        assertTrue(factory.isActiveStrategy(address(acct)), "resume re-registers an empty account");

        acct.pause();
        vm.stopPrank();
        assertEq(uint8(acct.pauseReason()), uint8(UserStrategyAccount.PauseReason.ManualPause));
    }

    /// `pause()` refuses a never-funded account, and so must the executor path: an `_autoPause` that
    /// set `paused = true` unconditionally would be a second, unguarded route to the paused state. A
    /// replacement executor (`setBatchExecutor` can repoint future clones) that calls
    /// `authorisedPull` on a created-only account reaches `_autoPause` on the empty-balance gate.
    ///
    /// The account must guard itself rather than lean on the executor's registry filter: the guard
    /// skips the pause for a never-registered account, so `authorisedPull` returns 0 like any other
    /// skip and `paused` stays false. `paused == true` therefore implies activation through every
    /// path that sets it.
    function test_autoPauseCannotActivateNeverFundedAccount() public {
        UserStrategyAccount acct = _created();

        // nextExecutionTime is 0 before the first deposit, so the timing gate passes and the empty
        // balance reaches _autoPause. An unguarded _autoPause would set paused = true here.
        vm.prank(executor);
        (uint256 gotCreatedOnly, ) = acct.authorisedPull(AMOUNT, 0);
        assertEq(gotCreatedOnly, 0, "an unfunded account pulls nothing");

        assertFalse(acct.paused(), "the executor path must not pause a never-activated account");
        assertFalse(factory.isActiveStrategy(address(acct)), "still not in the registry");

        // paused stays false, so resume() has no route to registerStrategy: the never-funded account
        // cannot enter the registry at all, on the account's own terms.
        vm.prank(user);
        vm.expectRevert(UserStrategyAccount.NotPaused.selector);
        acct.resume();
        assertEq(factory.activeStrategyCount(), 0, "registry stays empty");
    }

    /// The end-state the activation guard exists to prevent, approached through the executor path, is
    /// unreachable. The sequence: create -> executor auto-pause -> resume (registers unfunded) ->
    /// withdraw (skips deregistration because `_registered` is false) -> a closed strategy stranded in
    /// the active registry that nobody, not even the timelock, can remove. With the `_autoPause`
    /// guard, step two never sets `paused`, so every later step falls away.
    function test_executorAutoPauseCannotStrandClosedStrategyInRegistry() public {
        UserStrategyAccount acct = _created();

        // Step 2: a direct executor pull reaches _autoPause on the never-funded account.
        vm.prank(executor);
        acct.authorisedPull(AMOUNT, 0);

        // Steps 3-5 collapse: paused never became true, so resume() cannot register the account, and
        // a later withdraw() closes a strategy that was never in the registry - nothing is stranded.
        vm.startPrank(user);
        vm.expectRevert(UserStrategyAccount.NotPaused.selector);
        acct.resume();
        acct.withdraw();
        vm.stopPrank();

        assertTrue(acct.closed(), "withdraw is terminal");
        assertFalse(factory.isActiveStrategy(address(acct)), "no closed strategy is left stranded");
        assertEq(factory.activeStrategyCount(), 0, "the stranded end-state is unreachable via _autoPause");
    }

    /// `withdraw()` clears `_registered` only when the caught `removeStrategy` actually ran. Clearing
    /// it regardless would let a swallowed failure destroy the only evidence that deregistration is
    /// still owed and leave the entry unremovable. The realistic trigger is an owner starving the call
    /// of gas (EIP-150); here the swallowed revert is produced deterministically against the REAL
    /// factory with `mockCallRevert` on that single call.
    ///
    /// `_registered` is private, so the assertion is behavioural: after the swallowed removal, a
    /// closed account with `_registered` still true can retry deregistration via `pause()` (the one
    /// route left on a closed account). Had the flag been cleared, `pause()` would revert
    /// `NotActivated` and the stranded entry could never be removed.
    function test_withdrawKeepsDeregistrationRetriableWhenRemovalSwallowed() public {
        UserStrategyAccount acct = _created();
        _fund(acct);
        assertTrue(factory.isActiveStrategy(address(acct)), "funded and registered");

        vm.mockCallRevert(
            address(factory),
            abi.encodeWithSelector(DCAFactory.removeStrategy.selector, address(acct)),
            "OOG"
        );

        vm.prank(user);
        acct.withdraw();
        vm.clearMockedCalls();

        assertTrue(acct.closed(), "withdraw is still terminal");
        assertTrue(factory.isActiveStrategy(address(acct)), "the swallowed removal left the entry in the registry");

        // `_registered` survived, so the owner can still retry removal.
        vm.prank(user);
        acct.pause();
        assertFalse(factory.isActiveStrategy(address(acct)), "the retry removed the stranded entry");
    }
}
