# Smart contract development with Codex

Companion project for Ahmad Musamih's tutorial on using Codex inside Visual Studio Code to write, compile, test and locally deploy Solidity smart contracts. The ETH vault is the worked example.

**[Exact tutorial prompts](PROMPTS.md)** | [Contract](src/ETHVault.sol) | [Tests](test/) | [Local web interface](web/)

Ahmad Musamih | Management Science and Engineering Department | Khalifa University

## Get the project

Recorded tools: Foundry 1.9.0, Slither 0.11.6, Solidity 0.8.37, forge-std 1.17.0, and OpenZeppelin Contracts 5.7.0. The compiler and Solidity dependencies are pinned in the project. The local helper uses PowerShell; the interface uses Node.js 18 or later.

```powershell
git clone --recurse-submodules https://github.com/amusamih/codex-solidity-tutorial.git
cd codex-solidity-tutorial
forge build
forge test --fuzz-runs 1000 --fuzz-seed 0x4554485641554c54 -vv
```

If you already cloned without submodules, run `git submodule update --init --recursive` first. Installation prompts are in [PROMPTS.md](PROMPTS.md). After installation changes PATH, restart VS Code so new terminals can find the commands.

The following sections describe the finished local demonstration. No personal private key or public-network deployment is needed. Local Anvil accounts and test ETH are for development only. The production recordings, narration and local transaction logs are not included in this repository.

## ETH vault project

A simple Foundry project using Solidity **0.8.37** and OpenZeppelin Contracts
**v5.7.0**, pinned in `foundry.lock` and the Git submodule reference.

## Contract

`src/ETHVault.sol` provides:

- `deposit() payable`: credits positive ETH deposits to the caller.
- `withdraw(uint256 amount)`: sends a positive amount, up to the caller's balance,
  only to the caller. Failed payments revert the entire withdrawal.
- `balances(address)`: the ETH currently owed to a depositor, in wei.
- `totalDeposits()`: the total ETH currently owed to all depositors, in wei.
- `Deposited` and `Withdrawn` events with indexed depositor addresses.

Both entry points use OpenZeppelin's `ReentrancyGuard`. Withdrawals follow
checks-effects-interactions. There are no administrator privileges, fees, or
lockups.

Deposits must use `deposit()`; ordinary direct ETH transfers are rejected.
Forcibly sent ETH does not credit balances or increase `totalDeposits`.

## Build

```powershell
forge build
```

## Unit tests

```powershell
forge test -vv
```

`test/ETHVault.t.sol` uses fixed examples to cover deposits, withdrawals, boundary
amounts, independent users, event contents, actual ETH movements, failed-payment
rollback, and reentrancy attempts through both entry points. Receiver contracts
exercise real payment failures and callbacks, including successful retries.

## Fuzz tests

`test/ETHVaultFuzz.t.sol` covers repeated deposits, partial and full withdrawals,
excessive withdrawals with no state changes, and independence between depositors.
It checks recorded balances, total owed, actual ETH movements, and events after
each operation. Each generated deposit is bounded from 1 wei to 1,000 ETH
(at least 2 wei for strictly partial withdrawals). Each user starts with 2,000 ETH
to cover two maximum deposits without changing their ETH balance mid-scenario.
Withdrawal amounts are bounded to exercise the valid or invalid case directly,
without discarding generated inputs.

Run 1,000 cases per fuzz test, then the complete suite at the same run count:

```powershell
forge test --match-contract ETHVaultFuzzTest --fuzz-runs 1000 -vv
forge test --fuzz-runs 1000 -vv
```

## Stateful invariant tests

`test/ETHVaultInvariant.t.sol` uses five simulated depositors and a separate
input-driven model of their balances and total liabilities. After every vault
action, the handler checks all depositor balances, total owed, actual wallet
movements, and solvency. Forced ETH is sent by a test-only contract that calls
`selfdestruct` in its constructor; it must increase only the vault's surplus.
Ordinary direct transfers, zero withdrawals, and excessive withdrawals must
revert without changing accounting, ETH balances, or retained events.

The seven randomized handler actions include deposits and paired
deposit/withdraw operations. Paired actions ensure withdrawals always execute
instead of skipping empty accounts, and can spend previously accumulated credit.
Every deposit, including any inside a paired action, is bounded to 1 wei–10 ETH.
Each depositor and the separate force-send source start with 1,000,000 ETH, well
above the maximum required by a 128-action sequence, and are never refilled.

Settings in `foundry.toml`: 128 runs per campaign, 128 actions per run, fixed
depth, one worker, checks after every action, no call overrides, and failure on
any unexpected handler revert. No persistent corpus is enabled. The commands
below use seed `0x4554485641554c54` for reproducibility with Foundry 1.9.0, which
groups the three invariant properties into one campaign checking them together.
Each completed sequence must include successful deposits and withdrawals, a full
withdrawal, forced ETH, and each expected rejection; `afterInvariant()` rejects
vacuous sequences. Handler counters count only completed operations. Forge's
selector metrics count action invocations: deposits equal `deposit` calls plus
both paired-action call counts; withdrawals equal both paired-action call counts.
There are no skipped actions, so zero handler reverts/discards confirm these
counts represent completed operations.

```powershell
forge test --match-contract ETHVaultInvariantTest --fuzz-seed 0x4554485641554c54 -vv
forge test --fuzz-runs 1000 --fuzz-seed 0x4554485641554c54 -vv
```

## Repeat the local demonstration

From VS Code's PowerShell terminal in this project:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\script\local-demo.ps1
```

The execution-policy option applies only to that PowerShell process. The script
reuses Anvil at `http://127.0.0.1:8545` or starts a hidden loopback-only Anvil if
needed. It requires an Anvil endpoint with chain ID 31337, deploys a **fresh vault
on every run**, deposits **1 ETH**, and withdraws **0.4 ETH**. It does not reset
the chain or modify existing vaults. To use a different local port, append
`-Port 8546`.

The table shows the depositor's wallet, its recorded vault balance, the vault's
actual ETH, and total owed before and after each transaction. Wallet balances
include gas costs and are displayed to nine decimals. Exact wei balances,
transaction receipts, and the deployed address are saved under the ignored
`.logs/local-demo/` directory. The script checks successful receipts, events,
accounting, and wallet movements including gas, then leaves Anvil running.

`forge create --unlocked --broadcast` and `cast send --unlocked` use Anvil's
unlocked test accounts. Anvil signs transactions locally with its development
keys via `eth_sendTransaction`; no private key is supplied to the script or CLI.
The first account deploys; the second deposits and withdraws, keeping deployment
gas separate from the balance demonstration.

The starter Counter files have been removed. Public-network deployment remains
outside this local demonstration.

## Local web interface

With Anvil running, first [configure the interface for your deployment](#connect-the-web-interface-to-your-deployment), then start it from VS Code:

```powershell
node .\web\server.mjs
```

Open **http://127.0.0.1:3000**. Enter a positive ETH amount and use **Deposit** or
**Withdraw**. Balances refresh after confirmation and every five seconds; the
page shows your recorded balance, wallet ETH, actual vault ETH, and total owed.
Hover over a balance for its exact amount. Successful session transactions show
their hashes, with complete receipts saved in `.logs/web-demo/transactions.jsonl`.

`web/config.json` selects the existing deployment and depositor; starting the
interface does not deploy a new vault or reset Anvil. After a chain reset or a
different demonstration deployment, update the addresses there. The server
verifies Anvil, chain 31337, contract code, and the unlocked account before use.

The interface and its small Node server require no npm dependencies or wallet
extension. The server sends `eth_sendTransaction` to Anvil, which signs using its
unlocked local development account. Only the configured vault and depositor are
used. The web server binds to loopback and accepts transaction requests only from
its local browser origin. No private key is supplied to the page or server.

## Run the focused Slither summary

From the project root, this PowerShell command builds the production contract with its imports and reports findings involving the vault. Tests and scripts are excluded from compilation; dependency-only findings are outside this report's scope.

```powershell
$vaultPattern = '(?i)^' + [regex]::Escape((Join-Path (Get-Location).Path 'src/ETHVault.sol').Replace('\', '/')) + '$'
slither . --compile-force-framework foundry --include-paths $vaultPattern --disable-color --detect all --print human-summary
```

The recorded focused scan had two informational findings: compiler-version constraints and the low-level withdrawal payment call. The native summary showed one source contract and two required dependency contracts. Review diagnostics in context; passing tests and a small finding count do not establish that all possible problems have been found.

## Connect the web interface to your deployment

The checked-in addresses in `web/config.json` are local Anvil development addresses from the demonstration. Each helper run deploys a fresh vault. After running the helper, update the interface configuration from its newest local result before starting the server:

```powershell
$latest = Get-ChildItem .\.logs\local-demo -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$demo = Get-Content -LiteralPath (Join-Path $latest.FullName 'demo.json') -Raw | ConvertFrom-Json
$configJson = @{ rpcUrl = $demo.rpc; chainId = $demo.chainId; vault = $demo.vault; depositor = $demo.depositor } | ConvertTo-Json
[System.IO.File]::WriteAllText((Join-Path (Get-Location).Path 'web/config.json'), $configJson, [System.Text.UTF8Encoding]::new($false))
node .\web\server.mjs
```

Open `http://127.0.0.1:3000`. If Anvil is restarted, its in-memory chain is lost; deploy again and refresh the configuration. Reloading the web page refreshes the view and clears session activity, while the blockchain state stays in place.
