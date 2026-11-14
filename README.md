# DCA Onchain contracts

Smart contracts for DCA Onchain, a self-custodial dollar-cost-averaging protocol. A user deposits
USDC once into a strategy account of their own, and automation buys a chosen asset for it on a fixed
schedule; a purchase that is missed stays in the account as USDC rather than being made up later.
As an option chosen at creation, idle USDC is supplied to Aave V3, where it accrues interest at
Aave's variable rate and carries Aave's own risks. Strategy parameters are fixed at creation.

Each strategy is its own contract account: only the wallet that created it can withdraw, and
scheduled purchases take only the amount fixed at creation, plus fees, on its schedule. Purchased
assets go to the owner's wallet after each purchase; any that cannot be delivered stay claimable.
Withdrawal has no pause switch: a protocol pause never stops it. A withdrawal returns the remaining
USDC and any yield position at once, so if Aave or a token transfer cannot complete at that moment,
nothing moves and it can be tried again. USDC reaches a strategy only through `deposit`: USDC sent
to it directly is not counted and cannot be withdrawn.

Governance chooses the swap route and the price check those purchases use, so it can replace a pool
or a price feed that stops working. These settings apply to the later purchases of every strategy,
existing ones included, so changes are meant to go through a time delay, with a timelock as the
contracts' owner, during which any user who disagrees with a change can withdraw.
Governance also decides which assets and yield venues strategies may use and where fees are paid,
and it can recover tokens sent to the batch executor by mistake, never the balances it holds for
users.

A guardian acts without the delay, but only to pause and resume new strategies and purchases, to
replace the automation that triggers purchases, or to pay retained fees to the treasury. A pause
never stops a withdrawal, and purchases stay bound to each strategy's amount and schedule and to the
price check.

Fees are protocol settings, not strategy parameters. An execution fee is taken in USDC from each
scheduled purchase, and a yield fee is taken from yield as it is realised; both go to the protocol
treasury. Governance sets them in the same way, never above the hard caps of 1% and 30% fixed in
the contracts. The rates in force are public on the factory, as `executionFeeBps` and
`yieldFeeBps`. The contracts pay no referral or revenue share: the `referralCommitment` argument to
`createStrategy` must be non-zero and is only emitted in an event; nothing on chain stores it or pays
on it.

## Contracts

| Path | Role |
|---|---|
| `src/DCAFactory.sol` | Deploys one `UserStrategyAccount` minimal proxy per strategy and holds the protocol parameters |
| `src/UserStrategyAccount.sol` | One user's strategy: their USDC, an optional yield position, and the schedule |
| `src/BatchExecutor.sol` | Pulls USDC from every due account, swaps once per asset, and distributes the output pro rata |
| `src/SwapRouter.sol` | Routes each swap to the adapter registered for the target asset |
| `src/adapters/swap/` | Uniswap V3 and Aerodrome swap adapters |
| `src/adapters/yield/` | Aave V3 yield adapter, cloned per strategy |
| `src/oracles/` | Price oracles that set the minimum acceptable swap output |
| `src/libraries/`, `src/interfaces/` | Shared helpers and interfaces |
| `test/` | Unit, invariant and Base mainnet fork tests |

The NatSpec in each file documents its access control, events and revert conditions.

## Build

Requires [Foundry](https://getfoundry.sh).

```sh
git clone https://github.com/dcaonchain/contracts.git
cd contracts
git submodule update --init
forge build
```

Compiler settings and remappings are in `foundry.toml`. Remappings are listed in full with
auto-detection off, so the output is the same whether or not the libraries' nested submodules are
initialised.

## Test

`test/unit` and `test/invariant` run offline:

```sh
forge test --no-match-path 'test/fork/*'
```

`test/fork` runs against a fork of Base mainnet. Point `BASE_RPC_URL` at any Base mainnet RPC that
serves historical state, since some cases fork at a fixed past block; `BASE_FORK_BLOCK` optionally
pins the rest:

```sh
BASE_RPC_URL=<rpc url> forge test --match-path 'test/fork/*' --threads 1
```

## Security

See [SECURITY.md](SECURITY.md). Please do not report vulnerabilities in public issues.

## License

[MIT](LICENSE).
