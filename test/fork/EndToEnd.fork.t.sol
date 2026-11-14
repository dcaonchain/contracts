// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/DCAFactory.sol";
import "../../src/BatchExecutor.sol";
import "../../src/UserStrategyAccount.sol";
import "../../src/SwapRouter.sol";
import "../../src/adapters/swap/UniswapV3Adapter.sol";
import "../../src/adapters/swap/AerodromeAdapter.sol";
import "../../src/adapters/yield/AaveV3YieldAdapter.sol";
import "../../src/oracles/ManualPriceOracle.sol";
import "../../src/oracles/ChainlinkPriceOracle.sol";
import "../../src/oracles/ComposedPriceOracle.sol";
import "../../src/oracles/OracleDispatcher.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Non-zero `referralCommitment` for tests that do not care what it is. The factory rejects zero
// and ignores everything else, so any constant does here; a real client must not reuse one.
bytes32 constant TEST_COMMITMENT = keccak256("dca-test-referral-commitment");


// ─────────────────────────────────────────────────────────────────────────────
// Base mainnet addresses - injected into contracts, never hardcoded in logic
// ─────────────────────────────────────────────────────────────────────────────

address constant BASE_USDC           = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
address constant BASE_WETH           = 0x4200000000000000000000000000000000000006;
address constant BASE_WSTETH         = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
address constant BASE_CBBTC          = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
address constant BASE_CBETH          = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;

address constant BASE_AAVE_POOL      = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
address constant BASE_A_USDC         = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
address constant BASE_UNI_ROUTER     = 0x2626664c2603336E57B271c5C0b26F421741e481;
address constant BASE_AERO_ROUTER    = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
address constant BASE_AERO_FACTORY   = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;


// ─────────────────────────────────────────────────────────────────────────────
// Full protocol stack deployed on Base mainnet fork
// ─────────────────────────────────────────────────────────────────────────────

/// cbBTC is a Circle-style FiatToken: its blacklister can freeze any address.
interface IBlacklistable {
    function blacklister() external view returns (address);
    function blacklist(address account) external;
}

contract EndToEndForkTest is Test {

    // Protocol contracts
    DCAFactory          internal factory;
    BatchExecutor       internal batchExecutor;
    SwapRouter          internal swapRouter;
    UniswapV3Adapter    internal uniAdapter;
    AerodromeAdapter    internal aeroAdapter;
    AaveV3YieldAdapter  internal yieldAdapterImpl; // reviewed implementation; cloned per strategy
    UserStrategyAccount internal stratImpl;

    // Roles
    address internal owner     = makeAddr("owner");
    address internal executor  = makeAddr("executor");
    address internal treasury  = makeAddr("treasury");

    uint256 constant AMOUNT   = 50e6;   // 50 USDC per execution
    uint256 constant DEPOSIT  = 400e6;  // 8 × 50 USDC (weekly minimum)

    function setUp() public virtual {
        // Pinned block for determinism. Set BASE_FORK_BLOCK to pin; 0 => latest.
        uint256 forkBlock = vm.envOr("BASE_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        } else {
            vm.createSelectFork(vm.envString("BASE_RPC_URL"), forkBlock);
        }
        emit log_named_uint("fork block", block.number);

        vm.startPrank(owner);

        // 1. Deploy strategy implementation (logic contract for clones)
        stratImpl = new UserStrategyAccount();

        // 2. Deploy BatchExecutor placeholder (address needed for factory)
        //    We'll set it after factory is deployed
        address batchExecPlaceholder = makeAddr("placeholder");

        // 3. Deploy DCAFactory
        factory = new DCAFactory(address(stratImpl), batchExecPlaceholder, BASE_USDC, owner, owner, owner);

        // 4. Deploy SwapRouter
        swapRouter = new SwapRouter(batchExecPlaceholder, owner);

        // 5. Deploy swap adapters
        uniAdapter  = new UniswapV3Adapter(BASE_UNI_ROUTER, BASE_USDC, address(swapRouter));
        aeroAdapter = new AerodromeAdapter(BASE_AERO_ROUTER, BASE_USDC, address(swapRouter));

        // 6. Register adapters, then configure routes via SwapRouter passthrough
        // Routes are a realistic topology rather than a plausible-looking substitute. cbETH is
        // Uniswap V3 two-hop USDC->WETH(500)->cbETH(500): the direct Aerodrome USDC/cbETH volatile
        // pool quoted ~23% off fair value and the oracle floor rejected it, so the Aerodrome adapter
        // is constructed here but routes nothing.
        swapRouter.setAssetAdapter(BASE_WETH,   address(uniAdapter));
        swapRouter.setAssetAdapter(BASE_WSTETH, address(uniAdapter));
        swapRouter.setAssetAdapter(BASE_CBBTC,  address(uniAdapter));
        swapRouter.setAssetAdapter(BASE_CBETH,  address(uniAdapter));

        swapRouter.configureUniswapRoute(BASE_WETH,   address(uniAdapter), 500,  address(0), 0);
        swapRouter.configureUniswapRoute(BASE_WSTETH, address(uniAdapter), 100,  BASE_WETH,  500);
        swapRouter.configureUniswapRoute(BASE_CBBTC,  address(uniAdapter), 3000, address(0), 0);
        swapRouter.configureUniswapRoute(BASE_CBETH,  address(uniAdapter), 500,  BASE_WETH,  500);

        // 7. Deploy real BatchExecutor
        batchExecutor = new BatchExecutor(
            address(factory), BASE_USDC, address(swapRouter), executor, owner, owner
        );

        // 8. Wire everything together
        factory.setBatchExecutor(address(batchExecutor));
        swapRouter.setBatchExecutor(address(batchExecutor));
        batchExecutor.setWhitelistedAsset(BASE_WETH,   true);
        batchExecutor.setWhitelistedAsset(BASE_WSTETH, true);
        batchExecutor.setWhitelistedAsset(BASE_CBBTC,  true);
        batchExecutor.setWhitelistedAsset(BASE_CBETH,  true);

        // Price floor. These integration tests use a ManualPriceOracle with conservative
        // rates (~0.1% of rough market) so real Uniswap/Aerodrome output clears the floor with wide
        // headroom while dust is rejected - this keeps fork runs deterministic and independent of
        // live Chainlink feed availability. ChainlinkPriceOracle is unit-tested with mocks.
        ManualPriceOracle oracle = new ManualPriceOracle(owner);
        oracle.setRate(BASE_WETH,   3.3e23); // 18 dec, ~$3k
        oracle.setRate(BASE_WSTETH, 2.8e23); // 18 dec, ~$3.5k
        oracle.setRate(BASE_CBETH,  3.1e23); // 18 dec, ~$3.2k
        oracle.setRate(BASE_CBBTC,  1.0e12); // 8 dec,  ~$95k
        batchExecutor.setPriceOracle(address(oracle));

        // 9. Deploy the Aave yield-adapter implementation once and approve it. Strategies that opt
        //    into yield name this address, and the factory clones it per account.
        yieldAdapterImpl = new AaveV3YieldAdapter(BASE_AAVE_POOL, BASE_USDC, BASE_A_USDC);
        factory.setApprovedYieldAdapterImplementation(address(yieldAdapterImpl), true);

        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _fundUser(address user, uint256 amount) internal {
        deal(BASE_USDC, user, amount);
    }

    function _createStrategy(address user, address asset)
        internal returns (UserStrategyAccount acct)
    {
        return _createStrategy(user, asset, address(0));
    }

    function _createStrategy(address user, address asset, address yieldImplementation)
        internal returns (UserStrategyAccount acct)
    {
        return _createStrategy(user, asset, yieldImplementation, DCAFactory.Tier.Weekly);
    }

    function _createStrategy(
        address user,
        address asset,
        address yieldImplementation,
        DCAFactory.Tier tier
    ) internal returns (UserStrategyAccount acct) {
        DCAFactory.StrategyParams memory p = DCAFactory.StrategyParams({
            targetAsset: asset,
            amountPerExecution: AMOUNT,
            tier: tier,
            yieldAdapterImplementation: yieldImplementation
        });
        vm.prank(user);
        address addr = factory.createStrategy(p, TEST_COMMITMENT);
        acct = UserStrategyAccount(addr);
    }

    function _deposit(address user, UserStrategyAccount acct, uint256 amount) internal {
        vm.startPrank(user);
        IERC20(BASE_USDC).approve(address(acct), amount);
        acct.deposit(amount);
        vm.stopPrank();
    }

    function _executeBatch(address[] memory accounts, address asset) internal returns (uint256) {
        uint256[] memory amounts = new uint256[](accounts.length);
        uint256 total = 0;
        for (uint i = 0; i < accounts.length; i++) {
            amounts[i] = AMOUNT;
            total += AMOUNT;
        }

        // A minimal executor bound: this helper checks execution and non-zero output, and the
        // harness oracle supplies the price floor.
        uint256 minOut = 1;

        vm.prank(executor);
        return batchExecutor.executeBatch(accounts, amounts, asset, minOut, _nextNonce());
    }

    uint256 private _nonceCounter = 1;
    function _nextNonce() internal returns (uint256) { return _nonceCounter++; }

    // ─────────────────────────────────────────────────────────────────────────
    // Batch size against a per-transaction gas budget, measured on live Aave
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Builds `n` yield-enabled strategies on the real Aave adapter, lets real yield accrue so
    ///      the fee path is actually exercised, and returns the gas one `executeBatch` costs.
    ///
    ///      A mock venue cannot stand in for this. The yield-fee path adds, per account,
    ///      `yieldAdapter.balanceOf`, and on real aUSDC that is a scaled-balance read plus a reserve
    ///      index read plus a rayMul - several times what a mock's single SLOAD costs. Measuring it
    ///      against a mock would understate exactly the thing being measured.
    function _measureYieldBatchGas(uint256 n) internal returns (uint256 gasUsed) {
        address[] memory accounts = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            address u = address(uint160(uint256(0xBEEF0000) + i));
            _fundUser(u, DEPOSIT);
            UserStrategyAccount a = _createStrategy(u, BASE_WETH, address(yieldAdapterImpl));
            _deposit(u, a, DEPOSIT);
            accounts[i] = address(a);
        }

        // Real accrual, so `untaxed` is non-zero and every account takes the fee-charging branch.
        // Without this the benchmark measures the cheap path and flatters the result.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        uint256[] memory amounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) amounts[i] = AMOUNT;

        vm.prank(executor);
        uint256 before = gasleft();
        batchExecutor.executeBatch(accounts, amounts, BASE_WETH, 1, _nextNonce());
        gasUsed = before - gasleft();
    }

    /// Per-account cost of the yield-fee path, measured at the block below with forge 1.8.4. A
    /// regression ceiling, not a target: it catches the fee path getting materially dearer.
    uint256 private constant MEASURED_MARGINAL_GAS = 253_891;

    /// The block the figures below were measured at. Comparisons are only meaningful there: `setUp`
    /// falls back to latest when `BASE_FORK_BLOCK` is unset, a derived suite may pin a block of its
    /// own, and Aave's reserve state moves.
    uint256 private constant PUBLISHED_FIGURES_BLOCK = 47971162;

    /// A batch of MAX_BATCH_ACCOUNTS accounts is sized from a measured per-account cost against a
    /// per-transaction gas budget of 10,000,000, well under Base's 16,777,216 per-transaction limit.
    /// This test owns both claims: a full batch fits the budget with a 10% reserve, and the yield-fee
    /// path does not grow materially dearer per account.
    ///
    /// @dev Measured here with forge 1.8.4 at block 47971162:
    ///
    ///        32 accounts  8,679,623 gas   marginal 253,891
    ///
    ///      The figures can move by tens of percent between Foundry versions, so a limit sized under
    ///      one toolchain can exceed the budget under another. A Foundry upgrade therefore means
    ///      re-running this at the pinned block.
    ///
    ///      This benchmark is the WORST case by construction. Every account has accrued yield, so
    ///      every one takes the fee-charging branch. A real batch rarely looks like that.
    ///
    ///      Two details matter for a correct measurement:
    ///
    ///      - Each measurement takes a fresh snapshot. Whether one snapshot id survives several
    ///        reverts depends on the toolchain version, and where it does not, each measurement runs
    ///        on the state the last one left.
    ///      - The headroom is asserted as an inequality, not a bare subtraction, so a batch that does
    ///        not fit fails with a message rather than `panic: arithmetic underflow`.
    function test_fork_gasPerYieldEnabledAccountFitsTheBatchGasBudget() public {
        uint256 BATCH_GAS_BUDGET   = 10_000_000; // per-transaction gas budget for one batch
        uint256 MAX_BATCH_ACCOUNTS = 32;

        // ONLY MEASURE WHERE THE MEASUREMENT MEANS SOMETHING, and skip loudly elsewhere.
        //
        // This is by far the heaviest fork test in the repository: it creates 33 strategy accounts
        // and runs two batches, which is thousands of RPC reads, enough to strain an RPC provider.
        //
        // Comparisons across blocks are meaningless (Aave's reserve state moves), so running
        // anywhere but the pinned block would spend the RPC budget for nothing.
        if (block.number != PUBLISHED_FIGURES_BLOCK) {
            emit log_named_uint("gas benchmark SKIPPED, not the pinned block", block.number);
            emit log_named_uint("set BASE_FORK_BLOCK to measure", PUBLISHED_FIGURES_BLOCK);
            return;
        }

        emit log_named_uint("fork block these figures were measured at", block.number);

        uint256 snap = vm.snapshotState();
        uint256 gasOne = _measureYieldBatchGas(1);
        require(vm.revertToState(snap), "snapshot revert failed");
        snap = vm.snapshotState();
        uint256 gasFull = _measureYieldBatchGas(MAX_BATCH_ACCOUNTS);

        emit log_named_uint("executeBatch gas, 1 yield account", gasOne);
        emit log_named_uint("executeBatch gas, 32 yield accounts", gasFull);
        emit log_named_uint("batch gas budget", BATCH_GAS_BUDGET);

        assertGt(gasFull, gasOne, "a bigger batch must cost more, or the measurement is not one");
        uint256 marginal = (gasFull - gasOne) / (MAX_BATCH_ACCOUNTS - 1);
        emit log_named_uint("marginal gas per extra yield account", marginal);

        // The batch must fit with room to spare: a caller that validates its gas limit under the
        // budget and retries a failing batch unchanged would leave every account in it missing
        // every window.
        assertLe(
            gasFull + gasFull / 10,
            BATCH_GAS_BUDGET,
            "a full batch no longer fits the gas budget with a 10% reserve"
        );

        // A ceiling on the per-account cost of the yield-fee path, pinned to the measurement so a
        // future change that makes an execution materially dearer fails here.
        assertLe(
            marginal,
            MEASURED_MARGINAL_GAS + MEASURED_MARGINAL_GAS / 20,
            "the yield-fee path got materially dearer per account than when it was measured"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tests
    // ─────────────────────────────────────────────────────────────────────────

    /// Full E2E: create strategy  to  deposit  to  execute batch  to  asset in wallet (WETH)
    function test_fork_e2e_WETH() public {
        address user = makeAddr("wethUser");
        _fundUser(user, DEPOSIT);

        UserStrategyAccount acct = _createStrategy(user, BASE_WETH);
        _deposit(user, acct, DEPOSIT);

        vm.warp(acct.nextExecutionTime());

        address[] memory accounts = new address[](1);
        accounts[0] = address(acct);
        uint256 amountOut = _executeBatch(accounts, BASE_WETH);

        assertGt(amountOut, 0, "E2E WETH: swap must produce output");
        assertGt(IERC20(BASE_WETH).balanceOf(user), 0, "E2E WETH: user must receive WETH");
        assertEq(IERC20(BASE_USDC).balanceOf(address(batchExecutor)), 0, "zero USDC in executor");
        assertEq(IERC20(BASE_WETH).balanceOf(address(batchExecutor)), 0, "zero WETH in executor");
    }

    /// Full E2E: wstETH (two-hop swap via Uniswap V3)
    function test_fork_e2e_wstETH_twoHop() public {
        address user = makeAddr("wstEthUser");
        _fundUser(user, DEPOSIT);

        UserStrategyAccount acct = _createStrategy(user, BASE_WSTETH);
        _deposit(user, acct, DEPOSIT);

        vm.warp(acct.nextExecutionTime());

        address[] memory accounts = new address[](1);
        accounts[0] = address(acct);
        uint256 amountOut = _executeBatch(accounts, BASE_WSTETH);

        assertGt(amountOut, 0, "E2E wstETH: two-hop must produce output");
        assertGt(IERC20(BASE_WSTETH).balanceOf(user), 0, "E2E wstETH: user must receive wstETH");
        assertEq(IERC20(BASE_WSTETH).balanceOf(address(batchExecutor)), 0, "zero balance in executor");
    }

    /// Full E2E: cbBTC
    function test_fork_e2e_cbBTC() public {
        address user = makeAddr("cbbtcUser");
        _fundUser(user, DEPOSIT);

        UserStrategyAccount acct = _createStrategy(user, BASE_CBBTC);
        _deposit(user, acct, DEPOSIT);

        vm.warp(acct.nextExecutionTime());

        address[] memory accounts = new address[](1);
        accounts[0] = address(acct);
        uint256 amountOut = _executeBatch(accounts, BASE_CBBTC);

        assertGt(amountOut, 0, "E2E cbBTC: swap must produce output");
        assertGt(IERC20(BASE_CBBTC).balanceOf(user), 0, "E2E cbBTC: user must receive cbBTC");
    }

    /// Against the real token: cbBTC's own blacklister freezes the middle clone of three. The batch
    /// executes, the other two owners receive cbBTC, and the frozen
    /// share is held in the executor until its owner claims it to an address cbBTC accepts.
    function test_fork_e2e_frozenCbBtcAccountIsHeldNotReverted() public {
        address[3] memory users = [makeAddr("cbbtcA"), makeAddr("cbbtcFrozen"), makeAddr("cbbtcC")];
        address[] memory accounts = new address[](3);
        for (uint256 i; i < 3; i++) {
            _fundUser(users[i], DEPOSIT);
            UserStrategyAccount acct = _createStrategy(users[i], BASE_CBBTC);
            _deposit(users[i], acct, DEPOSIT);
            accounts[i] = address(acct);
        }
        vm.warp(UserStrategyAccount(accounts[0]).nextExecutionTime());

        vm.prank(IBlacklistable(BASE_CBBTC).blacklister());
        IBlacklistable(BASE_CBBTC).blacklist(accounts[1]);

        uint256 amountOut = _executeBatch(accounts, BASE_CBBTC);

        uint256 held = batchExecutor.heldOutput(accounts[1], BASE_CBBTC);
        assertGt(IERC20(BASE_CBBTC).balanceOf(users[0]), 0, "first owner received cbBTC");
        assertGt(IERC20(BASE_CBBTC).balanceOf(users[2]), 0, "third owner received cbBTC");
        assertEq(IERC20(BASE_CBBTC).balanceOf(users[1]), 0, "frozen owner received nothing yet");
        assertEq(held, amountOut / 3, "equal contributions: the frozen share is a third of the output");
        assertEq(IERC20(BASE_CBBTC).balanceOf(address(batchExecutor)), held, "the share is in the executor");
        assertEq(IERC20(BASE_USDC).balanceOf(accounts[1]), DEPOSIT - AMOUNT, "the frozen account still paid");

        address to = makeAddr("cbbtcFrozenNewWallet");
        vm.prank(users[1]);
        batchExecutor.claimHeldOutput(accounts[1], BASE_CBBTC, to);

        assertEq(IERC20(BASE_CBBTC).balanceOf(to), held, "owner claimed the whole share");
        assertEq(IERC20(BASE_CBBTC).balanceOf(address(batchExecutor)), 0, "nothing left in the executor");
    }

    /// Full E2E of the cbETH two-hop capability: the complete Factory -> Account -> BatchExecutor ->
    /// SwapRouter path for cbETH, through Uniswap V3 via WETH rather than through Aerodrome.
    ///
    /// Scope: this proves the wiring executes end to end and delivers the asset. It does NOT judge
    /// execution price - the harness oracle sits at ~0.1% of market for determinism, so any route
    /// returning more than dust clears the floor, even one quoting ~23% off fair value. Route
    /// quality against real feeds is checked by the oracle fork suites.
    function test_fork_e2e_cbETH_uniswapTwoHop() public {
        // Guard the wiring itself: the Aerodrome adapter is constructed here too, so this asserts
        // cbETH is not silently routed back to it.
        assertEq(address(swapRouter.adapters(BASE_CBETH)), address(uniAdapter),
            "cbETH must route through Uniswap, not the unused Aerodrome adapter");
        assertTrue(address(aeroAdapter) != address(uniAdapter), "adapters must be distinct for that guard to mean anything");

        address user = makeAddr("cbethUser");
        _fundUser(user, DEPOSIT);

        UserStrategyAccount acct = _createStrategy(user, BASE_CBETH);
        _deposit(user, acct, DEPOSIT);

        vm.warp(acct.nextExecutionTime());

        address[] memory accounts = new address[](1);
        accounts[0] = address(acct);
        uint256 amountOut = _executeBatch(accounts, BASE_CBETH);

        assertGt(amountOut, 0, "E2E cbETH: two-hop Uniswap swap must produce output");
        assertGt(IERC20(BASE_CBETH).balanceOf(user), 0, "E2E cbETH: user must receive cbETH");
    }

    /// Multi-account batch: 10 users, all accumulating WETH in one batch.
    function test_fork_e2e_multiAccount_10users() public {
        uint256 N = 10;
        address[] memory accounts = new address[](N);

        for (uint i = 0; i < N; i++) {
            address user = address(uint160(uint(keccak256(abi.encodePacked("user", i)))));
            _fundUser(user, DEPOSIT);
            UserStrategyAccount acct = _createStrategy(user, BASE_WETH);
            _deposit(user, acct, DEPOSIT);
            accounts[i] = address(acct);
        }

        vm.warp(UserStrategyAccount(accounts[0]).nextExecutionTime());

        uint256 amountOut = _executeBatch(accounts, BASE_WETH);

        assertGt(amountOut, 0, "multi-account: pooled swap must produce output");
        assertEq(IERC20(BASE_USDC).balanceOf(address(batchExecutor)), 0, "zero USDC after multi batch");
        assertEq(IERC20(BASE_WETH).balanceOf(address(batchExecutor)), 0, "zero WETH after multi batch");

        // All users received WETH
        for (uint i = 0; i < N; i++) {
            address user = address(uint160(uint(keccak256(abi.encodePacked("user", i)))));
            assertGt(IERC20(BASE_WETH).balanceOf(user), 0,
                string.concat("user ", vm.toString(i), " must receive WETH"));
        }
    }

    /// Skip account: one account with insufficient balance - rest of batch proceeds.
    function test_fork_e2e_skipInsufficientAccount() public {
        address rich = makeAddr("rich");
        address poor = makeAddr("poor");

        _fundUser(rich, DEPOSIT);
        _fundUser(poor, DEPOSIT);

        UserStrategyAccount richAcct = _createStrategy(rich, BASE_WETH);
        UserStrategyAccount poorAcct = _createStrategy(poor, BASE_WETH);
        _deposit(rich, richAcct, DEPOSIT);
        _deposit(poor, poorAcct, DEPOSIT);

        // Drain poor account to below amountPerExecution
        vm.prank(poor);
        poorAcct.withdraw();
        // Now poorAcct has no USDC - its authorisedPull will return 0

        vm.warp(richAcct.nextExecutionTime());

        address[] memory accounts = new address[](2);
        accounts[0] = address(poorAcct);
        accounts[1] = address(richAcct);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = AMOUNT;
        amounts[1] = AMOUNT;

        // Executor min-out of 1; the oracle floor provides the real protection and the skipped
        // account neither dilutes it nor blocks the batch.
        vm.prank(executor);
        uint256 amountOut = batchExecutor.executeBatch(
            accounts, amounts, BASE_WETH, 1, _nextNonce()
        );

        assertGt(amountOut, 0, "batch must succeed despite skipped account");
        assertGt(IERC20(BASE_WETH).balanceOf(rich), 0, "rich user must receive WETH");
        assertEq(IERC20(BASE_WETH).balanceOf(poor), 0, "poor user should not receive WETH (no deposit)");
        assertEq(IERC20(BASE_WETH).balanceOf(address(batchExecutor)), 0, "zero balance");
    }

    /// Slippage protection: batch reverts if swap output below minAmountOut.
    function test_fork_e2e_slippageReverts() public {
        address user = makeAddr("slipUser");
        _fundUser(user, DEPOSIT);

        UserStrategyAccount acct = _createStrategy(user, BASE_WETH);
        _deposit(user, acct, DEPOSIT);
        vm.warp(acct.nextExecutionTime());

        address[] memory accounts = new address[](1);
        accounts[0] = address(acct);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = AMOUNT;

        // Set minAmountOut impossibly high - should revert
        uint256 impossibleMinOut = 1000e18; // 1000 ETH for 50 USDC - impossible

        vm.prank(executor);
        vm.expectRevert(); // swap reverts due to slippage
        batchExecutor.executeBatch(accounts, amounts, BASE_WETH, impossibleMinOut, _nextNonce());
    }

    /// Full yield-enabled lifecycle against the real Aave pool, driven entirely through the factory:
    /// creation clones the approved implementation, deposit supplies the venue, a batch pull draws
    /// from it, and withdrawAll returns principal + yield with the yield fee taken. Nothing here
    /// names Aave beyond the implementation the factory was told to clone, so the batch and fee paths
    /// are exercised venue-agnostically through IYieldAdapter.
    /// The deposit postcondition holds through the WHOLE real stack against real
    /// Aave - factory-minted clone, real UserStrategyAccount, real pool. Both checks are live on
    /// this path, so if Aave's mint rounding breached the tolerance in either contract, this
    /// deposit would revert rather than merely under-report. That is the proof the rule is a lower
    /// bound because it has to be, and not because the number was chosen to make a mock pass.
    function test_fork_e2e_depositBoundAcceptsRealAaveMintRounding() public {
        address user = makeAddr("depositBoundUser");
        _fundUser(user, DEPOSIT * 2);

        UserStrategyAccount acct = _createStrategy(user, BASE_WETH, address(yieldAdapterImpl));
        AaveV3YieldAdapter adapter = AaveV3YieldAdapter(address(acct.yieldAdapter()));

        _deposit(user, acct, DEPOSIT);

        uint256 credited = adapter.balanceOf(address(acct));
        assertGe(credited + YIELD_WITHDRAWAL_TOLERANCE, DEPOSIT, "first deposit within tolerance");
        // Only the lower bound is load-bearing. The absolute band is retained as a fork diagnostic.
        assertApproxEqAbs(credited, DEPOSIT, YIELD_WITHDRAWAL_TOLERANCE, "rounding stays within tolerance");
        assertEq(acct.depositedAmount(), DEPOSIT, "principal recorded in full");
        assertEq(IERC20(BASE_USDC).balanceOf(address(acct)), 0, "no base token left untracked");

        // A top-up on an accruing position takes the same path and the same bound.
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 100);
        uint256 positionBefore = adapter.balanceOf(address(acct));

        _deposit(user, acct, DEPOSIT);

        assertGe(
            adapter.balanceOf(address(acct)) + YIELD_WITHDRAWAL_TOLERANCE,
            positionBefore + DEPOSIT,
            "top-up credited within tolerance on top of accrued interest"
        );
        assertEq(acct.depositedAmount(), DEPOSIT * 2, "both deposits recorded");
        assertEq(IERC20(BASE_USDC).balanceOf(address(acct)), 0, "still nothing untracked");
    }

    function test_fork_e2e_yieldStrategyThroughClone() public {
        address user = makeAddr("cloneYieldUser");
        _fundUser(user, DEPOSIT);

        UserStrategyAccount acct = _createStrategy(user, BASE_WETH, address(yieldAdapterImpl));

        // The factory gave this strategy its own clone, bound to it and to no one else.
        AaveV3YieldAdapter adapter = AaveV3YieldAdapter(address(acct.yieldAdapter()));
        assertTrue(acct.yieldEnabled(), "strategy must have yield on");
        assertTrue(address(adapter) != address(yieldAdapterImpl), "adapter must be a clone");
        assertEq(adapter.account(), address(acct), "clone is bound to its own account");
        assertEq(adapter.baseToken(), BASE_USDC);

        _deposit(user, acct, DEPOSIT);

        // Deposit went to the venue, not idle in the account.
        assertApproxEqAbs(adapter.balanceOf(address(acct)), DEPOSIT, 1, "deposit supplied to Aave");
        assertEq(acct.balance(), 0, "nothing left idle in the account");

        // Partial pull: the batch draws one execution's worth out of the venue.
        vm.warp(acct.nextExecutionTime());
        address[] memory accounts = new address[](1);
        accounts[0] = address(acct);
        uint256 amountOut = _executeBatch(accounts, BASE_WETH);

        assertGt(amountOut, 0, "yield-funded batch must produce output");
        assertGt(IERC20(BASE_WETH).balanceOf(user), 0, "user receives the DCA output");
        assertFalse(acct.paused(), "a routine venue withdrawal must not stall the strategy");
        // Warping to the execution window lets real Aave interest accrue, so bound the remaining
        // position rather than pinning it: at least principal-minus-pull, and strictly below the
        // full deposit so the pull provably came out of the venue.
        uint256 remaining = adapter.balanceOf(address(acct));
        assertGe(remaining, DEPOSIT - AMOUNT, "remaining position stays in the venue");
        assertLt(remaining, DEPOSIT, "the pull actually drew down the venue position");

        // Let yield accrue, then close: principal + yield back to the user, fee to the treasury.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 100);
        assertGt(adapter.balanceOf(address(acct)), DEPOSIT - AMOUNT, "yield must accrue on the clone");

        _assertWithdrawSplitsRealYieldExactly(acct, adapter, user);

        assertEq(adapter.balanceOf(address(acct)), 0, "clone position fully closed");
        assertTrue(acct.closed());
    }

    /// @dev Closes a yield strategy and asserts the **exact** split of a real Aave position, rather
    ///      than that the treasury received something. Split into a helper because inlining it in the
    ///      caller exceeds the stack limit, and because the arithmetic is the point of the check.
    ///
    ///      `depositedAmount` is the principal that SURVIVED the partial pull (it is reduced inside
    ///      `authorisedPull`), and it is the base the fee must use. Charging against the original
    ///      deposit would under-collect; charging against the whole position would tax principal. Both
    ///      of those satisfy an `assertGt(treasury, before)` check, which is why this one is exact.
    function _assertWithdrawSplitsRealYieldExactly(
        UserStrategyAccount acct,
        AaveV3YieldAdapter adapter,
        address user
    ) internal {
        address feeRecipient = factory.treasury();
        uint256 position    = adapter.balanceOf(address(acct));
        uint256 principal   = acct.depositedAmount();
        // The book is reduced by the PRINCIPAL part of the draw, not by the contribution. Real Aave
        // yield had accrued before the pull, so some of the draw came out of that yield and the book
        // is correspondingly HIGHER than `DEPOSIT - AMOUNT`. This is the live-venue witness for the
        // yield-first ordering: the yield that funds a draw is realised, and charged, at that draw.
        assertGt(principal, DEPOSIT - AMOUNT,
            "yield funded part of the draw, so principal fell by less than the contribution");
        assertLe(principal, DEPOSIT, "but the book never rises above what was deposited");

        uint256 expectedFee = (position - principal) * factory.yieldFeeBps() / 10000;
        assertGt(expectedFee, 0, "30 days of real Aave yield must produce a non-zero fee to check");

        uint256 treasuryBefore = IERC20(BASE_USDC).balanceOf(feeRecipient);
        uint256 userBefore     = IERC20(BASE_USDC).balanceOf(user);

        vm.prank(user);
        acct.withdraw();

        // Aave index scaling may differ from the aToken balance read a moment earlier by the shared
        // YIELD_WITHDRAWAL_TOLERANCE.
        assertApproxEqAbs(
            IERC20(BASE_USDC).balanceOf(feeRecipient) - treasuryBefore,
            expectedFee,
            YIELD_WITHDRAWAL_TOLERANCE,
            "treasury receives exactly the yield fee, on positive yield only"
        );
        assertApproxEqAbs(
            IERC20(BASE_USDC).balanceOf(user) - userBefore,
            position - expectedFee,
            YIELD_WITHDRAWAL_TOLERANCE,
            "owner receives the whole position minus that fee"
        );
    }

    /// Aave idle yield: deposit  to  warp 30 days  to  withdraw shows principal + yield.
    function test_fork_e2e_aaveYield() public {
        // Deploy a yield adapter for this test
        address user = makeAddr("yieldUser");
        _fundUser(user, DEPOSIT);

        AaveV3YieldAdapter adapterInstance =
            AaveV3YieldAdapter(Clones.clone(address(yieldAdapterImpl)));
        adapterInstance.initialize(user);

        // User deposits to Aave directly via adapter
        vm.startPrank(user);
        IERC20(BASE_USDC).approve(address(adapterInstance), DEPOSIT);
        adapterInstance.deposit(DEPOSIT);
        vm.stopPrank();

        assertGt(adapterInstance.balanceOf(user), 0, "aToken balance must increase");

        // Wait 30 days for yield to accrue
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 100);

        uint256 aBalance = adapterInstance.balanceOf(user);
        assertGt(aBalance, DEPOSIT, "yield must accrue over 30 days");

        // Withdraw all
        vm.prank(user);
        uint256 received = adapterInstance.withdrawAll();

        assertEq(adapterInstance.balanceOf(user), 0, "aToken balance must be zero after withdrawAll");
        assertGt(received, DEPOSIT, "must receive principal + yield");
        assertGt(IERC20(BASE_USDC).balanceOf(user), DEPOSIT, "user USDC must exceed deposit");
    }

    /// The escape hatch has to work against the real venue, not just a mock.
    ///
    /// While BatchExecutor and DCAFactory are both paused, a YIELD-ENABLED account must still be able
    /// to withdraw - which means unwinding a live Aave position and paying the yield fee - and no
    /// batch may pull anything. Pause-independence on a plain account is covered in the fast suite;
    /// this is the version where withdraw() actually has to reach an external protocol.
    function test_fork_e2e_pausedStillAllowsYieldWithdrawal() public {
        address user = makeAddr("pausedYieldUser");
        _fundUser(user, DEPOSIT);

        UserStrategyAccount acct = _createStrategy(user, BASE_WETH, address(yieldAdapterImpl));
        _deposit(user, acct, DEPOSIT);
        assertTrue(acct.yieldEnabled(), "precondition: funds are in Aave, not idle in the account");

        // Let real yield accrue so withdraw() takes the fee branch as well as the unwind.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 100);

        // Guardian stops everything. owner == guardian in this harness.
        vm.startPrank(owner);
        batchExecutor.pause();
        factory.pause();
        vm.stopPrank();

        // No batch can move a thing.
        address[] memory accounts = new address[](1);
        accounts[0] = address(acct);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = AMOUNT;
        vm.prank(executor);
        vm.expectRevert(); // EnforcedPause
        batchExecutor.executeBatch(accounts, amounts, BASE_WETH, 1, 991);
        assertFalse(acct.usedNonces(991), "authorisedPull was never reached while paused");

        // The user still leaves, with principal plus their share of real Aave yield.
        uint256 before = IERC20(BASE_USDC).balanceOf(user);
        vm.prank(user);
        acct.withdraw();

        uint256 recovered = IERC20(BASE_USDC).balanceOf(user) - before;
        assertGt(recovered, DEPOSIT, "recovered principal plus yield from a live Aave position");
        assertTrue(acct.closed(), "withdrawal completed while both contracts were paused");
        assertEq(acct.balance(), 0, "nothing stranded in the account");
    }

    /// Empty batch: all accounts already paused  to  emits BatchEmpty, marks nonce.
    function test_fork_e2e_emptyBatch() public {
        address user = makeAddr("emptyUser");
        _fundUser(user, DEPOSIT);

        UserStrategyAccount acct = _createStrategy(user, BASE_WETH);
        _deposit(user, acct, DEPOSIT);

        // Pause the account
        vm.prank(user);
        acct.pause();

        vm.warp(acct.nextExecutionTime());

        address[] memory accounts = new address[](1);
        accounts[0] = address(acct);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = AMOUNT;

        uint256 n = _nextNonce();
        vm.prank(executor);
        vm.expectEmit(true, true, false, false);
        emit BatchExecutor.BatchEmpty(BASE_WETH, n);
        batchExecutor.executeBatch(accounts, amounts, BASE_WETH, 1, n);

        assertTrue(batchExecutor.usedNonces(n), "nonce must be marked used on empty batch");
    }

    /// @dev Four weekly WETH strategies in one registry: idle-funded, idle-thin, Aave-funded,
    ///      Aave-thin. Bundled into a struct so the test below stays inside the stack limit.
    struct SelectorFixture {
        address idleUser;
        address yieldUser;
        UserStrategyAccount idleAcct;
        UserStrategyAccount thinAcct;
        UserStrategyAccount yieldAcct;
        UserStrategyAccount thinYAcct;
    }

    function _selectorFixture() internal returns (SelectorFixture memory f) {
        // One full execution is the smallest valid first deposit. The thin strategies activate with
        // that amount, execute once, then receive a sub-execution top-up. Top-ups are deliberately
        // outside the first-deposit minimum, so this reaches the same active, under-funded selector
        // state without a vacuous tier configuration.
        vm.prank(owner);
        factory.setMinExecutions(DCAFactory.Tier.Weekly, 1);

        uint256 thin = AMOUNT / 2;
        f.idleUser = makeAddr("selectorIdle");
        f.yieldUser = makeAddr("selectorYield");
        address thinUser = makeAddr("selectorThinIdle");
        address thinYUser = makeAddr("selectorThinYield");

        _fundUser(f.idleUser, DEPOSIT);
        _fundUser(thinUser, AMOUNT + thin);
        _fundUser(f.yieldUser, DEPOSIT);
        _fundUser(thinYUser, AMOUNT + thin);

        f.idleAcct = _createStrategy(f.idleUser, BASE_WETH);
        f.thinAcct = _createStrategy(thinUser, BASE_WETH);
        f.yieldAcct = _createStrategy(f.yieldUser, BASE_WETH, address(yieldAdapterImpl));
        f.thinYAcct = _createStrategy(thinYUser, BASE_WETH, address(yieldAdapterImpl));

        // Deposit order is registry order, and it interleaves funded with under-funded so a page
        // boundary lands between two strategies of different kinds.
        _deposit(f.idleUser, f.idleAcct, DEPOSIT);
        _deposit(thinUser, f.thinAcct, AMOUNT);
        _deposit(f.yieldUser, f.yieldAcct, DEPOSIT);
        _deposit(thinYUser, f.thinYAcct, AMOUNT);

        vm.warp(f.thinAcct.nextExecutionTime());
        address[] memory drained = new address[](2);
        drained[0] = address(f.thinAcct);
        drained[1] = address(f.thinYAcct);
        _executeBatch(drained, BASE_WETH);

        _deposit(thinUser, f.thinAcct, thin);
        _deposit(thinYUser, f.thinYAcct, thin);
    }

    /// The bounded funding-aware selector against the real registry, with a real Aave position on
    /// one side and idle USDC on the other.
    ///
    /// The two under-funded strategies are ACTIVE and DUE throughout, which is what makes this a
    /// test of the funding decision rather than of registry membership.
    function test_fork_e2e_dueFundedSelectorAcrossIdleAndYield() public {
        SelectorFixture memory f = _selectorFixture();

        assertEq(factory.activeStrategyCount(), 4, "all four are in the registry");
        assertTrue(factory.isActiveStrategy(address(f.thinAcct)), "the thin ones are active, not removed");
        assertTrue(factory.isActiveStrategy(address(f.thinYAcct)));

        // The venue read is a real aToken balance, not a mock: below one execution but not zero.
        {
            uint256 pos = IYieldAdapter(address(f.thinYAcct.yieldAdapter())).balanceOf(address(f.thinYAcct));
            assertGt(pos, 0, "the thin yield strategy really did supply Aave");
            assertLt(pos, AMOUNT, "and its position cannot cover one execution");
        }

        vm.warp(f.thinAcct.nextExecutionTime());

        address[] memory selected = new address[](2);

        // Page two at a time, so the selector is exercised as a bounded query rather than a full
        // scan that happens to fit.
        {
            (address[] memory page1, uint256 next1) =
                factory.getDueFundedAccounts(DCAFactory.Tier.Weekly, block.timestamp, 0, 2);
            assertEq(page1.length, 1, "page 1 holds the idle strategy only");
            assertEq(page1[0], address(f.idleAcct));
            assertEq(next1, 2, "and there is more registry behind it");

            (address[] memory page2, uint256 next2) =
                factory.getDueFundedAccounts(DCAFactory.Tier.Weekly, block.timestamp, next1, 2);
            assertEq(page2.length, 1, "page 2 holds the Aave-backed strategy only");
            assertEq(page2[0], address(f.yieldAcct));
            assertEq(next2, 0, "registry end");

            selected[0] = page1[0];
            selected[1] = page2[0];
        }

        // Monitoring is unaffected: the raw query still shows every due strategy, including the two
        // the selector dropped.
        assertEq(
            factory.getDueAccounts(DCAFactory.Tier.Weekly, block.timestamp).length,
            4,
            "the raw due query still surfaces the under-funded strategies"
        );

        // The selected page executes end to end.
        assertGt(_executeBatch(selected, BASE_WETH), 0, "the selected batch produces output");
        assertGt(IERC20(BASE_WETH).balanceOf(f.idleUser), 0, "idle-funded user receives WETH");
        assertGt(IERC20(BASE_WETH).balanceOf(f.yieldUser), 0, "Aave-funded user receives WETH");
        assertEq(IERC20(BASE_USDC).balanceOf(address(batchExecutor)), 0, "zero USDC in executor");
        assertEq(IERC20(BASE_WETH).balanceOf(address(batchExecutor)), 0, "zero WETH in executor");

        // Neither dropped strategy was touched, and both stay visible for a top-up.
        assertFalse(f.thinAcct.paused(), "an excluded strategy is not paused by being excluded");
        assertFalse(f.thinYAcct.paused());
        assertTrue(factory.isActiveStrategy(address(f.thinAcct)), "and it is still in the registry");
        assertTrue(factory.isActiveStrategy(address(f.thinYAcct)));
    }

    /// On live Aave, as an off-chain caller would run it: the selector drops the two under-funded strategies,
    /// so no batch ever reaches their insufficient-balance pause. Reconciling them is what ends
    /// them: both pause, leave the registry and stop reporting due, no token moves, and each owner
    /// can still take the residual.
    function test_fork_e2e_reconcileEndsTheStrategiesTheSelectorDrops() public {
        SelectorFixture memory f = _selectorFixture();
        vm.warp(f.thinAcct.nextExecutionTime());
        assertFalse(f.thinYAcct.isDueAndFunded(uint8(DCAFactory.Tier.Weekly), block.timestamp));
        uint256 position = IYieldAdapter(address(f.thinYAcct.yieldAdapter())).balanceOf(address(f.thinYAcct));

        vm.startPrank(executor);
        assertTrue(f.thinAcct.reconcileFunding(), "the thin idle strategy is reconciled into a pause");
        assertTrue(f.thinYAcct.reconcileFunding(), "and so is the thin Aave strategy");
        assertFalse(f.yieldAcct.reconcileFunding(), "a funded Aave strategy is left alone");
        vm.stopPrank();

        assertTrue(f.thinAcct.paused() && f.thinYAcct.paused(), "both paused");
        assertFalse(factory.isActiveStrategy(address(f.thinAcct)), "and out of the registry");
        assertFalse(factory.isActiveStrategy(address(f.thinYAcct)));
        assertEq(factory.getDueAccounts(DCAFactory.Tier.Weekly, block.timestamp).length, 2,
            "the raw due query now shows only the two funded strategies");
        assertEq(
            IYieldAdapter(address(f.thinYAcct.yieldAdapter())).balanceOf(address(f.thinYAcct)),
            position,
            "the Aave position was not touched"
        );

        address thinYOwner = f.thinYAcct.owner();
        vm.prank(thinYOwner);
        f.thinYAcct.withdraw();
        assertGt(IERC20(BASE_USDC).balanceOf(thinYOwner), 0, "the residual is still the owner's");
    }

    /// A yield strategy whose Aave position has fallen below one execution is submitted anyway (a
    /// race between selection and execution, or an executor that does not filter). It pauses and
    /// leaves the registry on its first empty window, exactly like its yield-off twin, with no
    /// YieldFailure.
    function test_fork_e2e_emptiedYieldStrategyPausesLikeItsYieldOffTwin() public {
        address yieldUser = makeAddr("emptiedYieldUser");
        address idleUser  = makeAddr("emptiedIdleUser");
        uint256 deposit = DEPOSIT + AMOUNT / 2; // eight executions and half a ninth
        _fundUser(yieldUser, deposit);
        _fundUser(idleUser, deposit);
        UserStrategyAccount y = _createStrategy(yieldUser, BASE_WETH, address(yieldAdapterImpl));
        UserStrategyAccount p = _createStrategy(idleUser, BASE_WETH);
        _deposit(yieldUser, y, deposit);
        _deposit(idleUser, p, deposit);

        address[] memory both = new address[](2);
        both[0] = address(y);
        both[1] = address(p);
        for (uint256 i = 0; i < 8; i++) {
            vm.warp(y.nextExecutionTime());
            _executeBatch(both, BASE_WETH);
        }
        assertFalse(y.paused() || p.paused(), "eight funded windows ran");

        vm.warp(y.nextExecutionTime());
        // Read after the warp: Aave keeps accruing, and the claim below is that the empty window
        // itself moved nothing.
        uint256 position = IYieldAdapter(address(y.yieldAdapter())).balanceOf(address(y));
        assertGt(position, 0, "a real residual remains in Aave");
        assertLt(position, AMOUNT, "below one execution");
        vm.recordLogs();
        _executeBatch(both, BASE_WETH);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != UserStrategyAccount.YieldFailure.selector,
                "depletion raises no YieldFailure");
        }

        assertTrue(p.paused(), "the yield-off twin auto-pauses");
        assertTrue(y.paused(), "and so does the yield strategy");
        assertFalse(factory.isActiveStrategy(address(y)), "both leave the registry");
        assertFalse(factory.isActiveStrategy(address(p)));
        assertEq(IYieldAdapter(address(y.yieldAdapter())).balanceOf(address(y)), position,
            "the venue was not asked for a withdrawal it could not make");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // The FULL oracle topology, end to end
    //
    // Everything above prices through a ManualPriceOracle at a fraction of market, deliberately, so
    // those runs stay deterministic and independent of feed availability. The consequence is that
    // none of it exercises the shape a real configuration uses:
    //
    //     BatchExecutor.priceOracle -> OracleDispatcher -> {ChainlinkPriceOracle, ComposedPriceOracle}
    //
    // The per-oracle fork suites quote and swap as two separate calls, so they establish that live
    // feeds and live pools agree, and nothing about routing or enforcement. Without this section, a
    // dispatcher that routed cbBTC to the wrong oracle, or a BatchExecutor that quoted the wrong
    // asset or amount, would pass every other test.
    // ─────────────────────────────────────────────────────────────────────────

    // Chainlink's Base mainnet feeds and realistic oracle settings.
    address constant WETH_USD_FEED       = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant CBBTC_USD_FEED      = 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D;
    address constant WSTETH_ETH_MARKET   = 0x43a5C292A453A3bF3606fa856197f09D7B74251a;
    address constant CBETH_ETH_MARKET    = 0x806b4Ac04501c29769051e42783cF04dCE41440b;
    address constant SEQUENCER_FEED      = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    uint16  constant ORACLE_SLIPPAGE_BPS  = 200;

    /// Staleness uses the enforced seven-day ceiling rather than a heartbeat-sized setting.
    ///
    /// Executing a batch requires reaching a strategy's window, so the test has to `vm.warp` forward,
    /// The fork's feed data does not advance after `vm.warp`: `updatedAt` stays at the pinned block.
    /// These topology tests therefore use Daily strategies, keeping their one-day warp inside the
    /// contract ceiling while the dedicated oracle fork suites retain heartbeat-sized values.
    ///
    /// This keeps routing and enforcement through the full topology without bypassing the
    /// contract's operating envelope.
    ///
    /// Where heartbeat-sized staleness IS held: `ChainlinkPriceOracle.fork.t.sol` at 3600 s for both
    /// direct feeds, and `ComposedPriceOracle.fork.t.sol` at 90000 s base and 3600 s quote. Neither
    /// warps. Those suites take these values as given rather than measuring heartbeats.
    ///
    /// Slippage stays at a realistic 200 bps, because that is what "clears the floor" depends on.
    uint32  constant WARP_TOLERANT_STALENESS = 7 days;

    /// @dev Replaces the harness ManualPriceOracle with the full **topology**: a dispatcher routing
    ///      the two direct-feed assets to a `ChainlinkPriceOracle` and the two LSTs to a
    ///      `ComposedPriceOracle`. Slippage is a realistic 200 bps; staleness deliberately is not,
    ///      for the reason above.
    function _installChainlinkOracleStack() internal returns (OracleDispatcher dispatcher) {
        vm.startPrank(owner);

        ChainlinkPriceOracle direct = new ChainlinkPriceOracle(BASE_USDC, owner);
        direct.setSequencerUptimeFeed(SEQUENCER_FEED, 3600);
        direct.setAssetFeed(BASE_WETH,  WETH_USD_FEED,  18, WARP_TOLERANT_STALENESS, ORACLE_SLIPPAGE_BPS);
        direct.setAssetFeed(BASE_CBBTC, CBBTC_USD_FEED, 8,  WARP_TOLERANT_STALENESS, ORACLE_SLIPPAGE_BPS);

        ComposedPriceOracle composed = new ComposedPriceOracle(BASE_USDC, owner);
        composed.setSequencerUptimeFeed(SEQUENCER_FEED, 3600);
        composed.setComposedFeed(
            BASE_WSTETH, WSTETH_ETH_MARKET, WETH_USD_FEED, 18,
            WARP_TOLERANT_STALENESS, WARP_TOLERANT_STALENESS, ORACLE_SLIPPAGE_BPS
        );
        composed.setComposedFeed(
            BASE_CBETH, CBETH_ETH_MARKET, WETH_USD_FEED, 18,
            WARP_TOLERANT_STALENESS, WARP_TOLERANT_STALENESS, ORACLE_SLIPPAGE_BPS
        );

        dispatcher = new OracleDispatcher(owner);
        dispatcher.setAssetOracle(BASE_WETH,   address(direct));
        dispatcher.setAssetOracle(BASE_CBBTC,  address(direct));
        dispatcher.setAssetOracle(BASE_WSTETH, address(composed));
        dispatcher.setAssetOracle(BASE_CBETH,  address(composed));

        batchExecutor.setPriceOracle(address(dispatcher));
        vm.stopPrank();

        // The routing itself, asserted rather than assumed: a swapped pair here would still let every
        // batch below succeed, because both oracle implementations price their configured assets in
        // the same USD terms.
        assertEq(address(dispatcher.oracles(BASE_WETH)),   address(direct),   "WETH routes direct");
        assertEq(address(dispatcher.oracles(BASE_CBBTC)),  address(direct),   "cbBTC routes direct");
        assertEq(address(dispatcher.oracles(BASE_WSTETH)), address(composed), "wstETH routes composed");
        assertEq(address(dispatcher.oracles(BASE_CBETH)),  address(composed), "cbETH routes composed");
    }

    /// Executes a real batch per asset with `minAmountOut = 1`, so the executor's own bound is inert
    /// and the **only** thing that can reject the swap is the floor the dispatcher returns. Output is
    /// then checked against that same floor, read through the dispatcher exactly as `executeBatch`
    /// reads it.
    function test_fork_e2e_chainlinkOracleFloorClearsForEveryAsset() public {
        OracleDispatcher dispatcher = _installChainlinkOracleStack();

        address[4] memory assets = [BASE_WETH, BASE_WSTETH, BASE_CBBTC, BASE_CBETH];
        string[4] memory labels  = ["WETH", "wstETH", "cbBTC", "cbETH"];

        // All four are created before any warp, so they share one daily anchor and the whole test
        // advances time ONCE. Warping per asset inside the loop compounds a day each iteration, which
        // pushed the LST feeds past any sane staleness bound by the third asset.
        UserStrategyAccount[4] memory accts;
        address[4] memory users;
        for (uint256 i = 0; i < assets.length; i++) {
            users[i] = makeAddr(string.concat("prodOracleUser-", labels[i]));
            _fundUser(users[i], AMOUNT * 10);
            accts[i] = _createStrategy(users[i], assets[i], address(0), DCAFactory.Tier.Daily);
            _deposit(users[i], accts[i], AMOUNT * 10);
        }
        vm.warp(accts[0].nextExecutionTime());

        for (uint256 i = 0; i < assets.length; i++) {
            address user = users[i];
            UserStrategyAccount acct = accts[i];
            assertLe(acct.nextExecutionTime(), block.timestamp, "every account must be due at one warp");

            // The floor as the executor will compute it: on the amount net of the execution fee.
            uint256 fee   = AMOUNT * factory.executionFeeBps() / 10000;
            uint256 floor = dispatcher.quoteMinOut(assets[i], AMOUNT - fee);
            assertGt(floor, 0, "the dispatcher floor must be non-zero");

            address[] memory accounts = new address[](1);
            accounts[0] = address(acct);
            uint256 out = _executeBatch(accounts, assets[i]);

            emit log_named_string("asset", labels[i]);
            emit log_named_uint("prod floor", floor);
            emit log_named_uint("realised  ", out);
            assertGe(out, floor, "a real swap must clear the oracle floor, through the dispatcher");
            assertEq(IERC20(assets[i]).balanceOf(user), out, "the whole output reached the owner");
        }
    }

    /// The floor has to be able to say no through the same path, or clearing it proves nothing. A
    /// missing dispatcher route must revert the batch rather than price the asset at zero: per the
    /// `IPriceOracle` contract, absent coverage is an error, never "no protection".
    function test_fork_e2e_chainlinkOracleMissingRouteRevertsTheBatch() public {
        OracleDispatcher dispatcher = _installChainlinkOracleStack();

        address user = makeAddr("unroutedUser");
        _fundUser(user, AMOUNT * 10);
        UserStrategyAccount acct = _createStrategy(user, BASE_CBBTC, address(0), DCAFactory.Tier.Daily);
        _deposit(user, acct, AMOUNT * 10);
        vm.warp(acct.nextExecutionTime());

        vm.prank(owner);
        dispatcher.removeAssetOracle(BASE_CBBTC);

        address[] memory accounts = new address[](1);
        accounts[0] = address(acct);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = AMOUNT;

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(OracleDispatcher.UnsupportedAsset.selector, BASE_CBBTC));
        batchExecutor.executeBatch(accounts, amounts, BASE_CBBTC, 1, _nextNonce());

        // The account kept its funds and its window: a batch that cannot be priced does not consume
        // anything, because the whole call reverted.
        assertEq(acct.balance(), AMOUNT * 10, "no USDC left the account");
        assertFalse(acct.paused(), "an unpriceable asset does not pause the strategy");
    }
}
