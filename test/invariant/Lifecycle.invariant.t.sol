// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "../../src/BatchExecutor.sol";
import "../../src/DCAFactory.sol";
import "../../src/SwapRouter.sol";
import "../../src/UserStrategyAccount.sol";
import "../../src/interfaces/IYieldAdapter.sol";
import "../../src/oracles/ManualPriceOracle.sol";

bytes32 constant LIFECYCLE_COMMITMENT = keccak256("lifecycle-invariant-commitment");

contract LcToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blockedRecipient;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
    }

    function setBlockedRecipient(address recipient, bool blocked) external {
        blockedRecipient[recipient] = blocked;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function forceApprove(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (blockedRecipient[to]) return false;
        if (balanceOf[msg.sender] < amount) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] < amount || balanceOf[from] < amount) return false;
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract LcSwapAdapter is ISwapAdapter {
    LcToken public immutable usdc;
    uint256 public outputBps = 10_000;
    bool public ignoreMinOut;

    constructor(LcToken usdc_) {
        usdc = usdc_;
    }

    function configure(uint256 outputBps_, bool ignoreMinOut_) external {
        outputBps = outputBps_;
        ignoreMinOut = ignoreMinOut_;
    }

    function swap(address asset, uint256 amountIn, uint256 minAmountOut) external returns (uint256 amountOut) {
        require(usdc.transferFrom(msg.sender, address(this), amountIn), "USDC pull");
        amountOut = amountIn * outputBps / 10_000;
        if (!ignoreMinOut) require(amountOut >= minAmountOut, "min out");
        LcToken(asset).mint(msg.sender, amountOut);
    }
}

contract LcYieldAdapter is IYieldAdapterImplementation {
    LcToken public immutable token;
    address public account;
    bool public roundingLoss;
    bool public revertWithdraw;

    constructor(LcToken token_) {
        token = token_;
    }

    modifier onlyAccount() {
        require(msg.sender == account, "account only");
        _;
    }

    function initialize(address account_) external {
        require(account == address(0), "initialized");
        account = account_;
    }

    function baseToken() external view returns (address) {
        return address(token);
    }

    function configure(bool roundingLoss_, bool revertWithdraw_) external {
        roundingLoss = roundingLoss_;
        revertWithdraw = revertWithdraw_;
    }

    function deposit(uint256 amount) external onlyAccount {
        require(token.transferFrom(msg.sender, address(this), amount), "deposit pull");
        if (roundingLoss && amount >= YIELD_WITHDRAWAL_TOLERANCE) {
            token.burn(address(this), YIELD_WITHDRAWAL_TOLERANCE);
        }
    }

    function withdraw(uint256 amount) external onlyAccount returns (uint256 received) {
        if (revertWithdraw) revert("venue unavailable");
        uint256 held = token.balanceOf(address(this));
        uint256 requested = roundingLoss && amount > 0 ? amount - 1 : amount;
        received = requested < held ? requested : held;
        if (received > 0) require(token.transfer(msg.sender, received), "withdraw transfer");
        // Revision 5 converts a burn to scaled units with ceil rounding. Model the proven
        // per-withdrawal position destruction budget separately from the tolerated return.
        if (roundingLoss && held > received) {
            uint256 remaining = held - received;
            uint256 roundingBurn = remaining < YIELD_WITHDRAWAL_TOLERANCE
                ? remaining
                : YIELD_WITHDRAWAL_TOLERANCE;
            token.burn(address(this), roundingBurn);
        }
    }

    function withdrawAll() external onlyAccount returns (uint256 received) {
        received = token.balanceOf(address(this));
        if (received > 0) require(token.transfer(msg.sender, received), "withdraw all transfer");
    }

    function balanceOf(address) external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}

contract LifecycleHandler is Test {
    uint256 internal constant ACCOUNT_COUNT = 4;
    uint256 internal constant MIN_EXECUTIONS = 8;

    LcToken public usdc;
    LcToken public asset;
    LcSwapAdapter public swapAdapter;
    LcYieldAdapter public yieldImplementation;
    DCAFactory public factory;
    BatchExecutor public batch;
    SwapRouter public router;
    ManualPriceOracle public oracle;

    UserStrategyAccount[ACCOUNT_COUNT] internal accounts;
    address[ACCOUNT_COUNT] internal owners;
    uint256[ACCOUNT_COUNT] internal executionAmounts;
    address[ACCOUNT_COUNT] internal initialAdapters;
    uint256[ACCOUNT_COUNT] public successfulDeposits;
    uint256[ACCOUNT_COUNT] public successfulYieldPulls;

    address public executor = address(0xE0E0);
    address public treasury = address(0x7E45);
    address public attacker = address(0xBAD);
    uint256 public nextNonce = 1;

    uint256 public created;
    uint256 public firstDeposits;
    uint256 public topUps;
    uint256 public exactPulls;
    uint256 public shortPulls;
    uint256 public skippedEntries;
    uint256 public successfulBatches;
    uint256 public unequalDistributions;
    uint256 public pendingFallbacks;
    uint256 public pendingRecoveries;
    uint256 public pauseAttempts;
    uint256 public pauseReverts;
    uint256 public yieldFailures;
    uint256 public withdrawals;
    uint256 public pausedWithdrawals;
    uint256 public terminalDeregistrations;
    uint256 public donationsUsdc;
    uint256 public donationsAsset;
    uint256 public oracleFloorRejections;
    uint256 public wrongPullRejections;
    uint256 public reconciledPauses;
    uint256 public reconcileNoOps;

    uint256 public unexpectedBatchReverts;
    uint256 public executorBalanceViolations;
    uint256 public distributionViolations;
    uint256 public oracleFloorViolations;
    uint256 public pullBoundViolations;
    uint256 public pendingAuthViolations;
    uint256 public pendingAccountingViolations;
    uint256 public terminalViolations;
    uint256 public reconcileViolations;

    constructor() {
        usdc = new LcToken();
        asset = new LcToken();
        UserStrategyAccount implementation = new UserStrategyAccount();

        factory = new DCAFactory(
            address(implementation), address(0xBEEF), address(usdc), address(this), treasury, address(this)
        );
        router = new SwapRouter(address(0xBEEF), address(this));
        batch =
            new BatchExecutor(address(factory), address(usdc), address(router), executor, address(this), address(this));
        factory.setBatchExecutor(address(batch));
        router.setBatchExecutor(address(batch));

        swapAdapter = new LcSwapAdapter(usdc);
        router.setAssetAdapter(address(asset), address(swapAdapter));
        batch.setWhitelistedAsset(address(asset), true);

        oracle = new ManualPriceOracle(address(this));
        oracle.setRate(address(asset), 5e17);
        batch.setPriceOracle(address(oracle));

        yieldImplementation = new LcYieldAdapter(usdc);
        factory.setApprovedYieldAdapterImplementation(address(yieldImplementation), true);

        executionAmounts = [uint256(10e6), uint256(20e6), uint256(15e6), uint256(25e6)];
        for (uint256 i = 0; i < ACCOUNT_COUNT; i++) {
            owners[i] = address(uint160(0xA100 + i));
            DCAFactory.StrategyParams memory params = DCAFactory.StrategyParams({
                targetAsset: address(asset),
                amountPerExecution: executionAmounts[i],
                tier: DCAFactory.Tier.Weekly,
                yieldAdapterImplementation: i < 2 ? address(0) : address(yieldImplementation)
            });
            vm.prank(owners[i]);
            accounts[i] = UserStrategyAccount(factory.createStrategy(params, LIFECYCLE_COMMITMENT));
            initialAdapters[i] = address(accounts[i].yieldAdapter());
            created++;
        }
        LcYieldAdapter(initialAdapters[3]).configure(true, false);
    }

    function accountAt(uint256 i) external view returns (UserStrategyAccount) {
        return accounts[i];
    }

    function ownerAt(uint256 i) external view returns (address) {
        return owners[i];
    }

    function amountAt(uint256 i) external view returns (uint256) {
        return executionAmounts[i];
    }

    function adapterAt(uint256 i) external view returns (address) {
        return initialAdapters[i];
    }

    function deposit(uint8 indexSeed, uint96 extraSeed) public {
        uint256 i = uint256(indexSeed) % ACCOUNT_COUNT;
        UserStrategyAccount account = accounts[i];
        if (account.closed()) return;

        bool first = account.nextExecutionTime() == 0;
        uint256 minimum = first ? executionAmounts[i] * MIN_EXECUTIONS : 1;
        uint256 amount = minimum + (uint256(extraSeed) % (executionAmounts[i] * 4));
        usdc.mint(owners[i], amount);
        vm.startPrank(owners[i]);
        usdc.approve(address(account), amount);
        try account.deposit(amount) {
            successfulDeposits[i]++;
            if (first) firstDeposits++;
            else topUps++;
        } catch {}
        vm.stopPrank();
    }

    function pauseAccount(uint8 indexSeed) public {
        uint256 i = uint256(indexSeed) % ACCOUNT_COUNT;
        UserStrategyAccount account = accounts[i];
        if (account.closed() || account.nextExecutionTime() == 0 || account.paused()) return;
        vm.prank(owners[i]);
        account.pause();
    }

    function resumeAccount(uint8 indexSeed) public {
        uint256 i = uint256(indexSeed) % ACCOUNT_COUNT;
        UserStrategyAccount account = accounts[i];
        if (account.closed() || !account.paused()) return;
        vm.prank(owners[i]);
        account.resume();
    }

    function toggleProtocolPause(bool paused_) public {
        if (paused_ && !batch.paused()) batch.pause();
        if (!paused_ && batch.paused()) batch.unpause();
        if (paused_ && !factory.paused()) factory.pause();
        if (!paused_ && factory.paused()) factory.unpause();
    }

    function donate(uint96 usdcAmount, uint96 assetAmount) public {
        usdc.mint(address(batch), usdcAmount);
        asset.mint(address(batch), assetAmount);
        donationsUsdc += usdcAmount;
        donationsAsset += assetAmount;
    }

    function execute(uint8 mask, bool includeUnknown, bool forcePending) public {
        uint256 count = includeUnknown ? 1 : 0;
        for (uint256 i = 0; i < ACCOUNT_COUNT; i++) {
            if ((mask & (uint8(1) << uint8(i))) != 0) count++;
        }
        if (count == 0) return;

        address[] memory submitted = new address[](count);
        uint256[] memory amounts = new uint256[](count);
        uint256 cursor;
        uint256 warpTo = block.timestamp;
        for (uint256 i = 0; i < ACCOUNT_COUNT; i++) {
            if ((mask & (uint8(1) << uint8(i))) == 0) continue;
            submitted[cursor] = address(accounts[i]);
            amounts[cursor] = executionAmounts[i];
            uint256 due = accounts[i].nextExecutionTime();
            if (due > warpTo) warpTo = due;
            if (forcePending) asset.setBlockedRecipient(owners[i], true);
            cursor++;
        }
        if (includeUnknown) {
            submitted[cursor] = address(0xFACADE);
            amounts[cursor] = type(uint96).max;
        }
        vm.warp(warpTo);

        uint256 openingUsdc = usdc.balanceOf(address(batch));
        uint256 openingAsset = asset.balanceOf(address(batch));
        uint256[ACCOUNT_COUNT] memory depBefore;
        uint256[ACCOUNT_COUNT] memory ownerAssetBefore;
        uint256[ACCOUNT_COUNT] memory accountAssetBefore;
        for (uint256 i = 0; i < ACCOUNT_COUNT; i++) {
            depBefore[i] = accounts[i].depositedAmount();
            ownerAssetBefore[i] = asset.balanceOf(owners[i]);
            accountAssetBefore[i] = asset.balanceOf(address(accounts[i]));
        }

        bool wasPaused = batch.paused();
        if (wasPaused) pauseAttempts++;
        vm.prank(executor);
        try batch.executeBatch(submitted, amounts, address(asset), 1, nextNonce) returns (uint256 out) {
            nextNonce++;
            if (wasPaused) return;
            _recordSuccessfulBatch(
                mask, includeUnknown, forcePending, out, depBefore, ownerAssetBefore, accountAssetBefore
            );
        } catch {
            if (wasPaused) pauseReverts++;
            else unexpectedBatchReverts++;
        }

        if (usdc.balanceOf(address(batch)) != openingUsdc || asset.balanceOf(address(batch)) != openingAsset) {
            executorBalanceViolations++;
        }
    }

    function _recordSuccessfulBatch(
        uint8 mask,
        bool includeUnknown,
        bool forcePending,
        uint256 out,
        uint256[ACCOUNT_COUNT] memory depBefore,
        uint256[ACCOUNT_COUNT] memory ownerAssetBefore,
        uint256[ACCOUNT_COUNT] memory accountAssetBefore
    ) internal {
        uint256[ACCOUNT_COUNT] memory pulled;
        uint256 totalPulled;
        uint256 contributors;
        uint256 lastContributor;
        for (uint256 i = 0; i < ACCOUNT_COUNT; i++) {
            uint256 afterDep = accounts[i].depositedAmount();
            pulled[i] = depBefore[i] > afterDep ? depBefore[i] - afterDep : 0;
            if (pulled[i] > 0) {
                totalPulled += pulled[i];
                contributors++;
                lastContributor = i;
                if (pulled[i] == executionAmounts[i]) exactPulls++;
                if (pulled[i] < executionAmounts[i]
                    && pulled[i] + YIELD_WITHDRAWAL_TOLERANCE >= executionAmounts[i]) shortPulls++;
                if (accounts[i].yieldEnabled()) successfulYieldPulls[i]++;
            } else if ((mask & (uint8(1) << uint8(i))) != 0) {
                skippedEntries++;
            }
        }
        if (includeUnknown) skippedEntries++;
        if (out == 0) return;

        successfulBatches++;
        if (contributors > 1) unequalDistributions++;
        uint256 distributed;
        for (uint256 i = 0; i < ACCOUNT_COUNT; i++) {
            if (pulled[i] == 0) continue;
            uint256 expected = i == lastContributor ? out - distributed : out * pulled[i] / totalPulled;
            if (i != lastContributor) distributed += expected;
            uint256 observed = asset.balanceOf(owners[i]) - ownerAssetBefore[i] + asset.balanceOf(address(accounts[i]))
                - accountAssetBefore[i];
            if (observed != expected) distributionViolations++;
            if (forcePending && accounts[i].pendingWithdrawals(address(asset)) > 0) pendingFallbacks++;
        }
    }

    function attemptOracleFloor(uint8 indexSeed) public {
        if (batch.paused()) return;
        // Use liquid accounts so an underfunded yield withdrawal cannot turn this
        // oracle probe into a valid empty batch before the price floor is checked.
        uint256 i = uint256(indexSeed) % 2;
        UserStrategyAccount account = accounts[i];
        if (!factory.isActiveStrategy(address(account)) || account.paused() || account.closed()) return;
        if (account.depositedAmount() < executionAmounts[i]) return;
        vm.warp(account.nextExecutionTime());
        uint256 beforeDep = account.depositedAmount();
        address[] memory submitted = new address[](1);
        submitted[0] = address(account);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = executionAmounts[i];
        swapAdapter.configure(1_000, true);
        vm.prank(executor);
        try batch.executeBatch(submitted, amounts, address(asset), 1, nextNonce) {
            oracleFloorViolations++;
            nextNonce++;
        } catch {
            oracleFloorRejections++;
            if (account.depositedAmount() != beforeDep) oracleFloorViolations++;
        }
        swapAdapter.configure(10_000, false);
    }

    function attemptWrongPull(uint8 indexSeed) public {
        if (batch.paused()) return;
        uint256 i = uint256(indexSeed) % ACCOUNT_COUNT;
        UserStrategyAccount account = accounts[i];
        if (!factory.isActiveStrategy(address(account)) || account.closed()) return;
        vm.warp(account.nextExecutionTime());
        uint256 beforeDep = account.depositedAmount();
        address[] memory submitted = new address[](1);
        submitted[0] = address(account);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = executionAmounts[i] + 1;
        vm.prank(executor);
        try batch.executeBatch(submitted, amounts, address(asset), 1, nextNonce) {
            nextNonce++;
            wrongPullRejections++;
            if (account.depositedAmount() != beforeDep) pullBoundViolations++;
        } catch {
            unexpectedBatchReverts++;
        }
    }

    function triggerYieldFailure(uint8 indexSeed) public {
        if (batch.paused()) return;
        uint256 i = 2 + (uint256(indexSeed) % 2);
        UserStrategyAccount account = accounts[i];
        if (!factory.isActiveStrategy(address(account)) || account.closed()) return;
        LcYieldAdapter adapter = LcYieldAdapter(address(account.yieldAdapter()));
        adapter.configure(adapter.roundingLoss(), true);
        uint256 beforeDep = account.depositedAmount();
        execute(uint8(1) << uint8(i), false, false);
        adapter.configure(adapter.roundingLoss(), false);
        if (account.depositedAmount() == beforeDep && !account.paused()) yieldFailures++;
    }

    /// On a registered, unpaused, open, due account with a readable venue, a reconcile pauses it
    /// exactly when the funded view rejects it, moves no token and keeps the anchor.
    /// Every other account is left alone. Every venue in this model is readable, so a revert is a
    /// violation too.
    function reconcile(uint8 indexSeed, bool warpToDue) public {
        uint256 i = uint256(indexSeed) % ACCOUNT_COUNT;
        UserStrategyAccount account = accounts[i];
        uint256 anchor = account.nextExecutionTime();
        if (warpToDue && anchor > block.timestamp) vm.warp(anchor);

        bool wasPaused = account.paused();
        bool eligible = anchor != 0 && !wasPaused && !account.closed() && block.timestamp >= anchor;
        bool funded = account.isDueAndFunded(uint8(DCAFactory.Tier.Weekly), block.timestamp);
        uint256 accountUsdc = usdc.balanceOf(address(account));

        vm.prank(executor);
        try account.reconcileFunding() returns (bool pausedNow) {
            bool expected = eligible && !funded;
            if (pausedNow != expected) reconcileViolations++;
            if (account.paused() != (wasPaused || expected)) reconcileViolations++;
            if (account.nextExecutionTime() != anchor) reconcileViolations++;
            if (usdc.balanceOf(address(account)) != accountUsdc) reconcileViolations++;
            if (pausedNow) reconciledPauses++;
            else reconcileNoOps++;
        } catch {
            reconcileViolations++;
        }
    }

    function recoverPending(uint8 indexSeed) public {
        uint256 i = uint256(indexSeed) % ACCOUNT_COUNT;
        UserStrategyAccount account = accounts[i];
        if (account.pendingWithdrawals(address(asset)) == 0) return;
        uint256 beforeUsdc = usdc.balanceOf(address(account));
        uint256 beforeDeposited = account.depositedAmount();
        uint256 beforeOwnerAsset = asset.balanceOf(owners[i]);

        vm.prank(attacker);
        try account.withdrawPending(address(asset)) {
            pendingAuthViolations++;
        } catch {}

        asset.setBlockedRecipient(owners[i], false);
        vm.prank(owners[i]);
        account.withdrawPending(address(asset));
        pendingRecoveries++;
        if (
            account.pendingWithdrawals(address(asset)) != 0 || usdc.balanceOf(address(account)) != beforeUsdc
                || account.depositedAmount() != beforeDeposited || asset.balanceOf(owners[i]) <= beforeOwnerAsset
        ) pendingAccountingViolations++;
    }

    function withdraw(uint8 indexSeed, bool pauseFactory, bool pauseBatch) public {
        uint256 i = uint256(indexSeed) % ACCOUNT_COUNT;
        UserStrategyAccount account = accounts[i];
        if (account.closed() || account.depositedAmount() == 0) return;
        if (pauseFactory && !factory.paused()) factory.pause();
        if (pauseBatch && !batch.paused()) batch.pause();

        vm.prank(owners[i]);
        try account.withdraw() {
            withdrawals++;
            if (pauseFactory || pauseBatch || account.paused()) pausedWithdrawals++;
            if (account.closed() && !factory.isActiveStrategy(address(account))) terminalDeregistrations++;
            else terminalViolations++;
        } catch {
            terminalViolations++;
        }
    }
}

contract LifecycleInvariantTest is StdInvariant, Test {
    LifecycleHandler internal handler;

    function setUp() public {
        handler = new LifecycleHandler();
        targetContract(address(handler));
    }

    function invariant_noAccountingOrAuthorizationViolation() public view {
        assertEq(handler.unexpectedBatchReverts(), 0, "unexpected live batch revert");
        assertEq(handler.executorBalanceViolations(), 0, "executor balance drift");
        assertEq(handler.distributionViolations(), 0, "distribution mismatch");
        assertEq(handler.oracleFloorViolations(), 0, "oracle floor bypassed");
        assertEq(handler.pullBoundViolations(), 0, "wrong pull changed principal");
        assertEq(handler.pendingAuthViolations(), 0, "non-owner recovered pending output");
        assertEq(handler.pendingAccountingViolations(), 0, "pending recovery touched principal");
        assertEq(handler.terminalViolations(), 0, "terminal deregistration failed");
        assertEq(handler.reconcileViolations(), 0, "reconcile paused the wrong account");
    }

    function invariant_executorRetainsOnlyDonations() public view {
        assertEq(
            handler.usdc().balanceOf(address(handler.batch())),
            handler.donationsUsdc(),
            "only donated USDC may remain"
        );
        assertEq(
            handler.asset().balanceOf(address(handler.batch())),
            handler.donationsAsset(),
            "only donated target asset may remain"
        );
    }

    function invariant_registryAndCloneLineageStayConsistent() public view {
        DCAFactory factory = handler.factory();
        address[] memory active = factory.getActiveStrategies();
        assertEq(active.length, factory.activeStrategyCount(), "active count mismatch");

        for (uint256 i = 0; i < 4; i++) {
            UserStrategyAccount account = handler.accountAt(i);
            bool found;
            for (uint256 j = 0; j < active.length; j++) {
                if (active[j] == address(account)) found = true;
            }
            assertEq(factory.isActiveStrategy(address(account)), found, "array/index mismatch");
            assertTrue(factory.isDeployedByFactory(address(account)), "provenance cleared");
            if (account.closed() || account.paused()) assertFalse(found, "stopped account active");

            address adapter = handler.adapterAt(i);
            if (i < 2) {
                assertEq(adapter, address(0), "idle strategy gained adapter");
            } else {
                assertEq(LcYieldAdapter(adapter).account(), address(account), "wrong clone binding");
                assertEq(LcYieldAdapter(adapter).baseToken(), address(handler.usdc()), "wrong base token");
                assertTrue(adapter != handler.adapterAt(i == 2 ? 3 : 2), "shared clone");
            }
        }
    }

    function invariant_principalAndYieldDeficitStayBounded() public view {
        LcToken usdc = handler.usdc();
        for (uint256 i = 0; i < 4; i++) {
            UserStrategyAccount account = handler.accountAt(i);
            if (account.closed()) {
                assertEq(account.depositedAmount(), 0, "closed principal nonzero");
                assertEq(account.balance(), 0, "closed idle balance nonzero");
                continue;
            }
            uint256 value = usdc.balanceOf(address(account));
            if (account.yieldEnabled()) value += usdc.balanceOf(address(account.yieldAdapter()));
            uint256 principal = account.depositedAmount();
            uint256 deficit = principal > value ? principal - value : 0;
            assertLe(
                deficit,
                (handler.successfulDeposits(i) + handler.successfulYieldPulls(i))
                    * YIELD_WITHDRAWAL_TOLERANCE,
                "deficit exceeds deposit and ceil-burn rounding budget"
            );
            if (!account.yieldEnabled()) {
                assertEq(account.balance(), usdc.balanceOf(address(account)), "idle accounting drift");
                assertEq(deficit, 0, "idle account insolvent");
            }
            assertEq(account.pendingWithdrawals(address(usdc)), 0, "USDC pending record exists");
        }
    }

    function test_allRequiredPathsAreReachable() public {
        for (uint8 i = 0; i < 4; i++) {
            handler.deposit(i, 0);
        }
        handler.deposit(3, 1);
        handler.donate(7, 11);
        handler.execute(0x0f, true, false);
        handler.execute(0x03, false, true);
        handler.recoverPending(0);
        handler.attemptOracleFloor(1);
        handler.attemptWrongPull(2);
        handler.triggerYieldFailure(2);
        handler.pauseAccount(1);
        handler.execute(0x02, false, false);
        handler.resumeAccount(1);
        handler.toggleProtocolPause(true);
        handler.execute(0x01, false, false);
        handler.withdraw(3, true, true);

        // Spend account 0 down to less than one execution WITHOUT submitting the empty window,
        // which is what an executor selecting only funded accounts does, then reconcile it: once
        // before it is due (a no-op) and once when it is (the pause).
        handler.toggleProtocolPause(false);
        UserStrategyAccount drained = handler.accountAt(0);
        for (uint256 k = 0; k < 64; k++) {
            if (!drained.isDueAndFunded(uint8(DCAFactory.Tier.Weekly), drained.nextExecutionTime())) break;
            handler.execute(0x01, false, false);
        }
        handler.reconcile(0, false);
        handler.reconcile(0, true);

        assertEq(handler.created(), 4, "creation path");
        assertGe(handler.firstDeposits(), 4, "first deposits");
        assertGt(handler.topUps(), 0, "top-up path");
        assertGt(handler.successfulBatches(), 0, "successful batch");
        assertGt(handler.unequalDistributions(), 0, "unequal distribution");
        assertGt(handler.exactPulls(), 0, "exact pull");
        assertGt(handler.shortPulls(), 0, "short pull");
        assertGt(handler.skippedEntries(), 0, "skipped entry");
        assertGt(handler.pendingFallbacks(), 0, "pending fallback");
        assertGt(handler.pendingRecoveries(), 0, "pending recovery");
        assertGt(handler.oracleFloorRejections(), 0, "oracle rejection");
        assertGt(handler.wrongPullRejections(), 0, "wrong pull rejection");
        assertGt(handler.yieldFailures(), 0, "yield failure");
        assertGt(handler.pauseAttempts(), 0, "paused batch attempt");
        assertEq(handler.pauseAttempts(), handler.pauseReverts(), "paused batch must revert");
        assertGt(handler.pausedWithdrawals(), 0, "withdrawal while paused");
        assertGt(handler.terminalDeregistrations(), 0, "terminal deregistration");
        assertGt(handler.reconcileNoOps(), 0, "reconcile with nothing to do");
        assertGt(handler.reconciledPauses(), 0, "reconcile pausing an underfunded account");
        assertTrue(drained.paused(), "the drained account is paused");
        invariant_noAccountingOrAuthorizationViolation();
        invariant_executorRetainsOnlyDonations();
        invariant_registryAndCloneLineageStayConsistent();
        invariant_principalAndYieldDeficitStayBounded();
    }
}

/// @dev Standalone constructor-based target for Medusa and Echidna. It inherits the exact handler
/// used by Foundry so all three engines exercise one state model rather than parallel approximations.
contract LifecycleFuzzer is LifecycleHandler {
    function property_no_recorded_violation() public view returns (bool) {
        return unexpectedBatchReverts == 0 && executorBalanceViolations == 0 && distributionViolations == 0
            && oracleFloorViolations == 0 && pullBoundViolations == 0 && pendingAuthViolations == 0
            && pendingAccountingViolations == 0 && terminalViolations == 0 && reconcileViolations == 0;
    }

    function property_executor_retains_only_donations() public view returns (bool) {
        return usdc.balanceOf(address(batch)) == donationsUsdc && asset.balanceOf(address(batch)) == donationsAsset;
    }

    function property_registry_and_clones_consistent() public view returns (bool) {
        address[] memory active = factory.getActiveStrategies();
        if (active.length != factory.activeStrategyCount()) return false;
        for (uint256 i = 0; i < ACCOUNT_COUNT; i++) {
            bool found;
            for (uint256 j = 0; j < active.length; j++) {
                if (active[j] == address(accounts[i])) found = true;
            }
            if (factory.isActiveStrategy(address(accounts[i])) != found) return false;
            if (!factory.isDeployedByFactory(address(accounts[i]))) return false;
            if ((accounts[i].closed() || accounts[i].paused()) && found) return false;
            if (i >= 2) {
                if (LcYieldAdapter(initialAdapters[i]).account() != address(accounts[i])) return false;
                if (LcYieldAdapter(initialAdapters[i]).baseToken() != address(usdc)) return false;
                if (initialAdapters[i] == initialAdapters[i == 2 ? 3 : 2]) return false;
            }
        }
        return true;
    }

    function property_principal_deficit_bounded() public view returns (bool) {
        for (uint256 i = 0; i < ACCOUNT_COUNT; i++) {
            if (accounts[i].closed()) {
                if (accounts[i].depositedAmount() != 0 || accounts[i].balance() != 0) return false;
                continue;
            }
            uint256 value = usdc.balanceOf(address(accounts[i]));
            if (accounts[i].yieldEnabled()) value += usdc.balanceOf(address(accounts[i].yieldAdapter()));
            uint256 principal = accounts[i].depositedAmount();
            uint256 deficit = principal > value ? principal - value : 0;
            uint256 roundingBudget = (successfulDeposits[i] + successfulYieldPulls[i])
                * YIELD_WITHDRAWAL_TOLERANCE;
            if (deficit > roundingBudget) return false;
            if (!accounts[i].yieldEnabled() && (accounts[i].balance() != value || deficit != 0)) return false;
            if (accounts[i].pendingWithdrawals(address(usdc)) != 0) return false;
        }
        return true;
    }

    function echidna_no_recorded_violation() external view returns (bool) {
        return property_no_recorded_violation();
    }

    function echidna_executor_retains_only_donations() external view returns (bool) {
        return property_executor_retains_only_donations();
    }

    function echidna_registry_and_clones_consistent() external view returns (bool) {
        return property_registry_and_clones_consistent();
    }

    function echidna_principal_deficit_bounded() external view returns (bool) {
        return property_principal_deficit_bounded();
    }
}
