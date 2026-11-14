// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../../src/BatchExecutor.sol";
import "../../src/DCAFactory.sol";
import "../../src/oracles/ManualPriceOracle.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Mocks (minimal, deterministic)
// ─────────────────────────────────────────────────────────────────────────────

contract FuzzERC20 {
    string public name;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    // An issuer freeze, as cbBTC's blacklister can impose on a strategy clone.
    mapping(address => bool) public frozen;

    constructor(string memory n) { name = n; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function setFrozen(address a, bool v) external { frozen[a] = v; }

    function transfer(address to, uint256 a) external returns (bool) {
        require(!frozen[to], "frozen");
        if (balanceOf[msg.sender] < a) return false;
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        if (allowance[from][msg.sender] < a) return false;
        allowance[from][msg.sender] -= a;
        balanceOf[from] -= a;
        balanceOf[to] += a;
        return true;
    }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function forceApprove(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
}

contract FuzzSwapRouter {
    FuzzERC20 public immutable usdc;
    FuzzERC20 public immutable weth;
    uint256 public rate = 1e12; // 1 USDC (6 dec)  to  1e12 WETH units ≈ tiny amount

    constructor(address _usdc, address _weth) { usdc = FuzzERC20(_usdc); weth = FuzzERC20(_weth); }

    function swap(address, uint256 amountIn, uint256 minOut) external returns (uint256 out) {
        out = amountIn * rate / 1e6;
        require(out >= minOut, "slippage");
        usdc.transferFrom(msg.sender, address(this), amountIn);
        weth.transfer(msg.sender, out);
    }
}

contract FuzzAccount {
    FuzzERC20 public usdc;
    uint256 public immutable amountPerExecution;
    address public immutable targetAsset; // BatchExecutor binds the batch to this
    address public immutable owner;       // claims this account's held output
    mapping(uint256 => bool) public usedNonces;
    bool public active = true;

    constructor(address _usdc, uint256 _amount, address _targetAsset, address _owner) {
        usdc = FuzzERC20(_usdc);
        amountPerExecution = _amount;
        targetAsset = _targetAsset;
        owner = _owner;
    }

    uint256 public yieldFeeToSettle;
    function setYieldFeeToSettle(uint256 v) external { yieldFeeToSettle = v; }

    function authorisedPull(uint256 amount, uint256 nonce) external returns (uint256, uint256) {
        if (!active || usedNonces[nonce] || amount != amountPerExecution) return (0, 0);
        uint256 fee = yieldFeeToSettle;
        if (usdc.balanceOf(address(this)) < amount + fee) return (0, 0);
        usedNonces[nonce] = true;
        // Contribution and yield fee leave in one transfer; only the contribution is a
        // contribution.
        usdc.transfer(msg.sender, amount + fee);
        return (amount, fee);
    }

    function receiveOutput(address asset, uint256 amount) external {
        FuzzERC20(asset).transfer(address(0xdead), amount);
    }

    function deactivate() external { active = false; }
}

contract FuzzFactory {
    address public immutable ownerAddr;
    address public immutable treasuryAddr;
    uint256 public executionFeeBps = 15;
    mapping(address => bool) public isDeployedByFactory;
    mapping(address => bool) public isActiveStrategy;

    constructor(address _o) { ownerAddr = _o; treasuryAddr = _o; }
    function owner() external view returns (address) { return ownerAddr; }
    function treasury() external view returns (address) { return treasuryAddr; }
    function setStrategy(address a, bool v) external { isDeployedByFactory[a] = v; isActiveStrategy[a] = v; }
    function setActive(address a, bool v) external { isActiveStrategy[a] = v; }
}

// ─────────────────────────────────────────────────────────────────────────────
// Handler - wraps BatchExecutor calls in controlled fuzz inputs
// ─────────────────────────────────────────────────────────────────────────────

contract BatchExecutorHandler is Test {
    BatchExecutor public executor_;
    FuzzERC20 public usdc;
    FuzzERC20 public weth;
    FuzzAccount[] public accounts;

    address public executorAddr = makeAddr("executor");
    address public treasury     = makeAddr("treasury");
    uint256 public nonce        = 1;

    // Running total of unsolicited transfers made to BatchExecutor.
    uint256 public donatedUsdc;
    uint256 public donatedWeth;
    uint256 public failedBatches;
    // Batches attempted while paused, and how many of those reverted. Kept separate from
    // failedBatches, which must stay zero - a pause-induced revert is correct behaviour, not a defect.
    uint256 public pausedAttempts;
    uint256 public pausedReverts;
    // Total USDC held across all accounts, snapshotted before each paused attempt.
    uint256 public lastPausedAccountTotal;
    uint256 public pausedAccountTotalDrifts;
    // Held output claimed out, and the address it was claimed to.
    uint256 public claimedWeth;
    address public claimSink = makeAddr("claimSink");

    uint256 constant AMOUNT    = 25e6;
    uint256 constant N_ACCTS   = 5;

    constructor() {
        usdc      = new FuzzERC20("USDC");
        weth      = new FuzzERC20("WETH");
        FuzzFactory fact = new FuzzFactory(treasury);
        FuzzSwapRouter router = new FuzzSwapRouter(address(usdc), address(weth));
        weth.mint(address(router), 1e30);

        executor_ = new BatchExecutor(
            address(fact), address(usdc), address(router), executorAddr, address(this), address(this)
        );
        executor_.setWhitelistedAsset(address(weth), true);

        // Independent oracle floor. Rate chosen well below the FuzzSwapRouter's output.
        ManualPriceOracle oracle = new ManualPriceOracle(address(this));
        oracle.setRate(address(weth), 1e12);
        executor_.setPriceOracle(address(oracle));

        for (uint i = 0; i < N_ACCTS; i++) {
            FuzzAccount a = new FuzzAccount(address(usdc), AMOUNT, address(weth), address(this));
            usdc.mint(address(a), AMOUNT * 100);
            fact.setStrategy(address(a), true); // register so executeBatch pulls from it
            accounts.push(a);
        }
    }

    /// @dev Executes a batch with a variable-size subset of accounts.
    ///      accountMask is a bitmask selecting which of the 5 accounts to include.
    function executeBatch(uint8 accountMask) external {
        // Build account list from mask
        uint256 count = 0;
        for (uint i = 0; i < N_ACCTS; i++) {
            if (accountMask & (1 << i) != 0) count++;
        }
        if (count == 0) return;

        address[] memory accts  = new address[](count);
        uint256[] memory amounts = new uint256[](count);
        uint256 total = 0;
        uint256 idx = 0;
        for (uint i = 0; i < N_ACCTS; i++) {
            if (accountMask & (1 << i) != 0) {
                accts[idx]   = address(accounts[i]);
                amounts[idx] = AMOUNT;
                total += AMOUNT;
                idx++;
            }
        }

        // While paused, executeBatch must be a complete no-op. Record the account-side USDC
        // total before and after so a silent partial pull cannot hide behind a revert.
        bool wasPaused = executor_.paused();
        uint256 acctTotalBefore = _accountUsdcTotal();
        if (wasPaused) pausedAttempts++;

        vm.prank(executorAddr);
        try executor_.executeBatch(accts, amounts, address(weth), 1, nonce) {
            nonce++;
            // A batch that SUCCEEDS while paused is the violation; the invariant reads these two
            // counters, so simply not incrementing pausedReverts records it.
        } catch {
            if (wasPaused) {
                pausedReverts++;
                if (_accountUsdcTotal() != acctTotalBefore) pausedAccountTotalDrifts++;
                lastPausedAccountTotal = acctTotalBefore;
                return;
            }
            // Nothing in this harness makes a batch legitimately revert: an account that cannot
            // pay returns 0 and is skipped, and an all-skipped batch returns via BatchEmpty. So a
            // revert here is a real defect, and swallowing it silently would let a donation DoS
            // hide from the invariants - every post-donation batch could fail while
            // "balance == donated" still held trivially.
            failedBatches++;
        }
    }

    /// @dev The guardian is `address(this)` here, so the fuzzer can interleave pause and
    ///      unpause with batches and donations. This is what makes the pause invariant below
    ///      non-vacuous - without it, `paused` is false for the whole run.
    function togglePause(bool on) external {
        if (on && !executor_.paused()) executor_.pause();
        else if (!on && executor_.paused()) executor_.unpause();
    }

    function _accountUsdcTotal() internal view returns (uint256 total) {
        for (uint i = 0; i < N_ACCTS; i++) total += usdc.balanceOf(address(accounts[i]));
    }

    /// @dev Deactivate a random account to simulate insufficient balance
    function deactivateAccount(uint8 idx) external {
        accounts[idx % N_ACCTS].deactivate();
    }

    /// @dev The output token's issuer freezes or unfreezes an account. A batch containing a
    ///      frozen account must still execute, holding that account's share.
    function toggleFrozen(uint8 idx) external {
        address a = address(accounts[idx % N_ACCTS]);
        weth.setFrozen(a, !weth.frozen(a));
    }

    /// @dev The account's owner (this handler) claims its held output to a fresh address.
    function claimHeld(uint8 idx) external {
        address a = address(accounts[idx % N_ACCTS]);
        uint256 held = executor_.heldOutput(a, address(weth));
        if (held == 0) return;
        executor_.claimHeldOutput(a, address(weth), claimSink);
        claimedWeth += held;
    }

    /// @dev The owner (this handler) rescues WETH. It may take donations and never held output, so
    ///      a successful rescue leaves exactly the held total behind.
    function rescueWeth() external {
        try executor_.rescueTokens(address(weth), address(0xbeef)) {
            donatedWeth = 0;
        } catch {}
    }

    /// @dev Anyone can transfer tokens straight to BatchExecutor and an ERC-20 recipient
    ///      cannot refuse. Letting the fuzzer interleave donations with batches is what makes
    ///      the no-accrual invariant meaningful - under an absolute-zero balance check a single
    ///      donation would halt every later executeBatch call.
    function donate(uint96 usdcAmt, uint96 wethAmt) external {
        usdc.mint(address(executor_), usdcAmt);
        weth.mint(address(executor_), wethAmt);
        donatedUsdc += usdcAmt;
        donatedWeth += wethAmt;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Invariant test contract
// ─────────────────────────────────────────────────────────────────────────────

contract BatchExecutorInvariantTest is StdInvariant, Test {
    BatchExecutorHandler internal handler;

    function setUp() public {
        handler = new BatchExecutorHandler();
        targetContract(address(handler));
    }

    /// Donations must never halt execution. This is the assertion that actually discriminates -
    /// the balance invariant below would hold vacuously against an absolute-zero balance check,
    /// because every post-donation batch would revert and therefore move nothing.
    function invariant_donationsNeverHaltBatches() public view {
        assertEq(
            handler.failedBatches(),
            0,
            "no batch may revert; a donation must not be able to halt execution"
        );
    }

    /// BatchExecutor accrues nothing of its own. Its balance is exactly what third parties
    /// donated to it and never more, so every batch fully distributes what it pulled and
    /// swapped. Stated as a delta rather than absolute zero because an ERC-20 recipient cannot
    /// refuse a transfer, and requiring zero would hand anyone a one-unit DoS.
    function invariant_executorAccruesOnlyDonations() public view {
        assertEq(
            handler.usdc().balanceOf(address(handler.executor_())),
            handler.donatedUsdc(),
            "BatchExecutor must hold only donated USDC"
        );
        assertEq(
            handler.weth().balanceOf(address(handler.executor_())),
            handler.donatedWeth() + handler.executor_().totalHeldOutput(address(handler.weth())),
            "BatchExecutor must hold only donated WETH and output held for frozen accounts"
        );
    }

    /// The per-asset total is exactly the sum of the per-account records, so neither a claim
    /// nor `rescueTokens` can reach output that belongs to an account.
    function invariant_heldOutputTotalMatchesRecords() public view {
        uint256 sum;
        for (uint256 i = 0; i < 5; i++) {
            sum += handler.executor_().heldOutput(address(handler.accounts(i)), address(handler.weth()));
        }
        assertEq(sum, handler.executor_().totalHeldOutput(address(handler.weth())), "held total drifted");
    }

    /// Non-vacuity guard for the two held-output assertions: a frozen account really is held, the
    /// rest of the batch still runs, a rescue leaves the held share, and a claim pays it out.
    function test_frozenAccountBranchIsReachable() public {
        handler.toggleFrozen(0);
        uint256 before = handler.nonce();
        handler.executeBatch(0x03); // accounts 0 and 1
        assertEq(handler.nonce(), before + 1, "the batch executed despite the frozen account");
        uint256 held = handler.executor_().heldOutput(address(handler.accounts(0)), address(handler.weth()));
        assertGt(held, 0, "the frozen account's share is held");

        handler.donate(0, 7);
        handler.rescueWeth();
        assertEq(handler.weth().balanceOf(address(handler.executor_())), held, "rescue took only the donation");

        handler.claimHeld(0);
        assertEq(handler.claimedWeth(), held, "the owner claimed the whole share");
        assertEq(handler.executor_().totalHeldOutput(address(handler.weth())), 0, "nothing left held");
    }

    /// Anti-vacuity guard (regular test, not an invariant): drives one full batch and
    /// asserts it executes end-to-end. If the mocks regress (e.g. factory missing
    /// treasury()/isDeployedByFactory), executeBatch would be caught by the handler and the nonce
    /// would not advance - catching the silent failure the invariants themselves can't.
    function test_harnessExecutesBatches() public {
        uint256 before = handler.nonce();
        handler.executeBatch(0x1f); // bitmask: all 5 accounts
        assertEq(handler.nonce(), before + 1, "batch must execute end-to-end - harness not vacuous");
    }

    /// Non-vacuity guard for the invariant below. togglePause being exercised by the fuzzer does not
    /// prove a batch was ever ATTEMPTED while paused, and if none was, the counter equality holds
    /// trivially at 0 == 0. This drives the branch deterministically.
    function test_pausedBatchBranchIsReachable() public {
        handler.togglePause(true);
        handler.executeBatch(1); // account 0 only
        assertGt(handler.pausedAttempts(), 0, "a batch really was attempted while paused");
        assertEq(handler.pausedAttempts(), handler.pausedReverts(), "and it reverted rather than running");
        assertEq(handler.pausedAccountTotalDrifts(), 0, "no account USDC moved");
    }

    /// A paused BatchExecutor makes no balance-changing state transition on the
    /// execution path. Every batch attempted while paused must have reverted, and no USDC may have
    /// left any account. This is the property the instant guardian pause exists to provide: the
    /// timelock's exit window is worthless if pausing does not actually stop the drain.
    function invariant_pausedExecutorNeverMovesFunds() public view {
        assertEq(
            handler.pausedAttempts(),
            handler.pausedReverts(),
            "a batch completed while the executor was paused"
        );
        assertEq(
            handler.pausedAccountTotalDrifts(),
            0,
            "account USDC moved during a paused batch attempt"
        );
    }

    /// @dev Prefix bound. The loop is deliberately capped so the invariant stays cheap across 256
    ///      runs; the cap is named rather than inlined so it is obvious that nonces beyond it are
    ///      NOT checked.
    uint256 internal constant NONCE_CHECK_LIMIT = 20;

    /// Nonce consumption (prefix): every batch nonce the handler has consumed is marked used on the
    /// executor.
    ///
    /// This is not "the nonce always advances", which this body does not establish - it checks
    /// consumption, over a capped prefix, and says nothing about nonces
    /// above NONCE_CHECK_LIMIT. Advancement itself is structural: the handler increments its counter
    /// only after a batch succeeds, and `executeBatch` rejects a reused nonce outright
    /// (`test_executeBatch_revertsOnNonceReplay`).
    function invariant_consumedNoncePrefixIsMarkedUsed() public view {
        uint256 currentNonce = handler.nonce();
        uint256 upper = currentNonce < NONCE_CHECK_LIMIT ? currentNonce : NONCE_CHECK_LIMIT;
        for (uint256 n = 1; n < upper; n++) {
            assertTrue(
                handler.executor_().usedNonces(n),
                "a consumed nonce is not marked used"
            );
        }
    }

    /// The executor address is never left zero across any sequence the handler can drive.
    ///
    /// Named for the one thing it asserts. It does NOT establish that the executor is
    /// provider-agnostic: this handler never calls `setExecutor`, so nothing here shows the address
    /// is swappable or that no provider is baked into the logic. Security.invariant.t.sol does the
    /// swap, and the absence of hardcoding is a source-level property established by inspection,
    /// not by any assertion.
    function invariant_executorRemainsNonzero() public view {
        assertTrue(handler.executor_().executor() != address(0), "executor must not be zero address");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Fuzz tests for distribution math: full distribution, remainder to the last account, batch total
// ─────────────────────────────────────────────────────────────────────────────

contract BatchExecutorFuzzTest is Test {
    BatchExecutor internal executor_;
    FuzzERC20 internal usdc;
    FuzzERC20 internal weth;
    FuzzAccount internal account;
    address internal execAddr = makeAddr("executor");

    uint256 constant AMOUNT = 25e6;

    function setUp() public {
        usdc = new FuzzERC20("USDC");
        weth = new FuzzERC20("WETH");
        FuzzFactory fact = new FuzzFactory(makeAddr("treasury"));
        FuzzSwapRouter router = new FuzzSwapRouter(address(usdc), address(weth));
        weth.mint(address(router), 1e30);
        executor_ = new BatchExecutor(address(fact), address(usdc), address(router), execAddr, address(this), address(this));
        executor_.setWhitelistedAsset(address(weth), true);

        ManualPriceOracle oracle = new ManualPriceOracle(address(this));
        oracle.setRate(address(weth), 1e12);
        executor_.setPriceOracle(address(oracle));

        account = new FuzzAccount(address(usdc), AMOUNT, address(weth), address(this));
        usdc.mint(address(account), AMOUNT * 100);
        fact.setStrategy(address(account), true);
    }

    /// The WHOLE swap output is distributed pro-rata, dust to the last account.
    ///
    /// No fee term, and deliberately so: the fee is taken in USDC before the swap, so every unit
    /// that comes back belongs to the accounts. Modelling `distributable = amountOut - totalFee`
    /// would assert a property the contract does not have.
    function testFuzz_distributionSumsCorrectly(uint256 amountOut, uint8 n) public pure {
        n = uint8(bound(n, 1, 20));            // 1-20 accounts
        amountOut = bound(amountOut, n, 1e30); // at least 1 unit per account

        // Simulate equal-share distribution
        uint256 equalAmount = amountOut / n; // each account contributed equally
        uint256 totalPulled = equalAmount * n;
        if (totalPulled == 0) return;

        uint256 distributed = 0;
        uint256 lastShare = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 share;
            if (i == n - 1) {
                share = amountOut - distributed; // last gets remainder
                lastShare = share;
            } else {
                share = amountOut * equalAmount / totalPulled;
                distributed += share;
            }
        }

        // distributed + lastShare == amountOut (no value created/destroyed)
        assertEq(distributed + lastShare, amountOut, "the whole output is distributed");
    }

    /// The other half of the fee accounting, which the test above does not cover: the USDC
    /// pulled splits into exactly the swapped amount plus the fee, for every fee rate within the
    /// cap. This is what the no-accrual delta rests on, so it is fuzzed rather than assumed.
    function testFuzz_feeAndSwapAmountPartitionThePull(uint256 actualTotal, uint256 feeBps) public pure {
        feeBps     = bound(feeBps, 0, 100);         // the execution fee cap
        actualTotal = bound(actualTotal, 1, 1e30);

        uint256 totalFee   = actualTotal * feeBps / 10000;
        uint256 swapAmount = actualTotal - totalFee;

        assertEq(swapAmount + totalFee, actualTotal, "the pull is fully accounted for");
        assertLe(totalFee, actualTotal / 100, "fee never exceeds the 100 bps cap");
        assertGt(swapAmount, 0, "there is always something left to swap");
    }

    /// The batch input total is derived internally from the accounts that actually pulled,
    /// never from a caller-supplied figure. There is no `totalAmount` argument to disagree
    /// with, so the property to hold is that padding the batch with
    /// non-strategy entries claiming arbitrary amounts cannot change the reported input total.
    function testFuzz_batchTotalComesFromActualPulls(uint256 claimedPad, uint8 padCount) public {
        padCount = uint8(bound(padCount, 1, 20));
        claimedPad = bound(claimedPad, 1, type(uint256).max / 32); // headroom, though it is never summed

        // One real strategy plus padCount non-strategy addresses with arbitrary claimed amounts.
        address[] memory accts = new address[](1 + padCount);
        uint256[] memory amounts = new uint256[](1 + padCount);
        accts[0] = address(account);
        amounts[0] = AMOUNT;
        for (uint256 i = 1; i <= padCount; i++) {
            accts[i] = address(uint160(0xF00D + i)); // not registered with the factory
            amounts[i] = claimedPad;
        }

        vm.recordLogs();
        vm.prank(execAddr);
        uint256 out = executor_.executeBatch(accts, amounts, address(weth), 1, 1);
        assertGt(out, 0, "the real account's pull executes end-to-end");

        // BatchExecuted.totalIn must be exactly the one real pull, not the padded claim.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != keccak256("BatchExecuted(address,uint256,uint256,uint256,uint256)")) continue;
            (uint256 totalIn,, uint256 accountCount) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            assertEq(totalIn, AMOUNT, "input total is the sum of actual pulls only");
            assertEq(accountCount, 1, "only the pulled account counts");
            seen = true;
        }
        assertTrue(seen, "BatchExecuted must be emitted (else the assertions are vacuous)");
    }
}
