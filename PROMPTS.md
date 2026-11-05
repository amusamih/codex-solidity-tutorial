# Tutorial prompts

These are the prompts submitted during the tutorial, in order. VS Code's automatically attached file-context headers are omitted; prompt wording is preserved. Paste these into Codex inside Visual Studio Code as you follow the corresponding stage. They are agent requests, not terminal commands.

The published project already contains the completed contract and tests. Use a separate empty project if you want to reproduce the generation process from the beginning. The deliberate-bug step is temporary: restore the working contract in the following step before continuing.

The main sequence omits two superseded Slither requests from discarded recordings: the broad project scan and the earlier native-summary request. The focused scan and corrected native summary shown in the tutorial are included below.

## 1. Install and verify Foundry

```text
I want to build a Solidity project on Windows. Please check whether
Foundry is already installed.

If it isn't, install a stable release from the official Foundry
sources for my user account and make it available in PowerShell.

Verify that Forge, Cast, and Anvil work, show their versions, and
tell me if VS Code needs restarting.

Leave the project files unchanged for now.
```

## 2. Install and verify Slither

```text
Foundry is installed and I've restarted VS Code. First, run
forge --version, cast --version, and anvil --version to confirm
they work from PowerShell.

Please install Slither for my Windows user account using its
official installation guidance. Keep its Python dependencies
isolated from other projects.

Make the slither command available in PowerShell, verify its
version, and tell me if another restart is needed.

Leave the project files unchanged for now.
```

## 3. Set up the Foundry project

```text
Set up this eth-vault folder as a standard Foundry project
with forge-std.

Keep the generated Counter example as a temporary setup check.
Pin a stable Solidity compiler version in foundry.toml.

Run forge build and forge test, and resolve any setup errors.
Finish with a short summary of the results.

Stop after project setup. We will implement the ETH vault next.
```

## 4. Build the ETH vault

```text
Build a simple ETH vault in this Foundry project, replacing
the starter Counter example.

Anyone can deposit a positive amount of ETH through a deposit
function. Users can withdraw part or all of their remaining
balance at any time, paid only to themselves.

Reject zero deposits, zero withdrawals, and withdrawals above
the caller's balance. Users must never withdraw another user's
funds. If an ETH payment fails, revert the entire withdrawal.

Make each user's recorded balance and the total currently
owed to depositors readable. Emit deposit and withdrawal events.

Use established security protections, including against
reentrancy. Keep the contract simple, with no administrator
access to users' funds, fees, or lockup period.

Preserve the existing compiler version and pin any added
dependencies.

Implement it and verify that the project builds successfully.
Leave tests and deployment for the following steps.
Finish with a short results summary.
```

## 5. Write and run unit tests

```text
Add and run unit tests for the ETH vault. Use our original
requirements to determine the expected behavior.

Use fixed examples covering:
- Initial zero balances.
- Positive and repeated deposits.
- Partial and full withdrawals.
- Zero deposits, zero withdrawals, and insufficient balances.
- Withdrawing exactly the remaining balance and one wei above it.
- Independent users: nobody can withdraw another user's funds,
  even when the vault holds enough ETH from other depositors.
- Failed ETH payments rolling back the entire withdrawal.
- Attempted reentrancy being blocked.

Check recorded balances, total owed, actual ETH movements,
and deposit/withdrawal events. Ensure the security tests
actually exercise failed payments and reentrancy attempts.

If a test exposes a contract bug, keep the regression test
and fix the bug according to the original requirements.

Run the tests and resolve any failures. Finish with the command
used and the actual pass/fail totals.

Leave fuzz tests, invariant tests, and deployment for later.
```

## 6. Introduce the deliberate accounting bug

```text
For a teaching demonstration, temporarily introduce one bug:
a withdrawal should still pay the caller and reduce their
personal balance, but fail to reduce the total owed to depositors.

Preserve the exact working contract in a backup that will not
affect compilation. Leave the tests unchanged.

Run the existing unit tests and report which fail.

The bug is intentional. Stop after demonstrating the failures;
we will restore the working version in the next step.
```

## 7. Restore the working contract

```text
Restore the exact working ETH vault from the backup you created.
Leave all tests unchanged.

Verify that the restored contract matches the backup exactly.
Run the full unit-test suite and report the pass/fail totals.
```

## 8. Write and run fuzz tests

```text
Add fuzz tests for the ETH vault using many different deposit
and withdrawal amounts.

Check individual balances, total accounting, partial and full
withdrawals, rejection of excessive withdrawals without changing
state, and independence between depositors.

Use sensible bounds for the generated amounts. Keep the working
contract and existing unit tests unchanged.

Run 1,000 cases per fuzz test, then run the complete test suite.
Report the commands used and the actual results.
```

## 9. Write and run stateful invariant tests

```text
Add stateful invariant tests for the ETH vault using several
simulated depositors and randomized sequences of actions.

Track expected balances independently and check after every action:
- Each depositor's recorded balance is correct.
- totalDeposits matches the total owed to depositors.
- The vault holds at least enough ETH to cover that total.

Include forced ETH without crediting depositors, rejection of
ordinary direct transfers, and invalid withdrawals without
changing state.

Use sensible input bounds and confirm valid deposits and
withdrawals actually execute.

Keep the production contract and existing tests unchanged.
Choose reproducible campaign settings, run the invariant tests,
then the complete suite with 1,000 cases per fuzz test.

Report the commands, campaign settings, successful action counts,
and actual results.
```

## 10. Run the focused Slither analysis

```text
Run Slither through Foundry and report findings involving only
src/ETHVault.sol, the contract generated by Codex.

Resolve imports normally. Exclude dependency-only, test-only, and
script-only findings from this report. Retain cross-file findings
involving ETHVault.sol. Keep default detectors and all severities.

Keep the contract, tests, and previous reports unchanged.
Save the new results in a separate folder.

Print a concise terminal summary with counts by severity, followed
by each finding's location, diagnostic, and your assessment.
Clearly state the report's scope and use actual scan results.

Provide one command to redisplay the summary and details in
VS Code's terminal.
```

## 11. Show the native Slither summary

```text
Show Slither’s built-in summary using a build of the vault and
its required imports only, excluding tests and scripts.

Keep our existing findings filter and leave the contract unchanged.
Run it and give me the command.
```

## 12. Deploy and interact on Anvil

```text
Deploy our vault to a local Anvil network, then demonstrate
a deposit and a withdrawal. Show the balances before and after.
```

## 13. Prepare the repeatable terminal demonstration

```text
Make this local demonstration easy to repeat from VS Code’s
terminal, using a fresh vault and a readable balance table.
Briefly state how the transactions are signed.
```

## 14. Build the local web interface

```text
Create and run a simple local web interface for our vault,
with an ETH amount field, Deposit and Withdraw buttons,
and readable balances.

Use our existing Anvil deployment and depositor account.
Keep the contract and tests unchanged, and verify the
interface works.
```
