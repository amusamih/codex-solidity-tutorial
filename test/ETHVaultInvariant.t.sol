// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ETHVault} from "../src/ETHVault.sol";

/// @dev Test-only force-send: creation and destruction occur in the same call.
contract ForceETH {
    constructor(address payable recipient) payable {
        selfdestruct(recipient);
    }
}

contract ETHVaultHandler is Test {
    uint256 public constant ACTOR_COUNT = 5;
    uint256 public constant MAX_ACTION_ETH = 10 ether;
    uint256 public constant STARTING_ETH = 1_000_000 ether;

    ETHVault public immutable vault;
    address[5] public actors;

    // This model is updated from successful inputs, never from vault getters.
    mapping(address actor => uint256 amount) public expectedBalances;
    uint256 public expectedTotal;
    uint256 public forcedETH;

    // Count completed operations, not attempts or skipped calls.
    uint256 public successfulDeposits;
    uint256 public successfulWithdrawals;
    uint256 public successfulFullWithdrawals;
    uint256 public successfulForceSends;
    uint256 public rejectedDirectTransfers;
    uint256 public rejectedZeroWithdrawals;
    uint256 public rejectedExcessiveWithdrawals;

    constructor(ETHVault vault_) {
        vault = vault_;
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            address actor = makeAddr(string.concat("invariant-depositor-", vm.toString(i)));
            actors[i] = actor;
            vm.deal(actor, STARTING_ETH);
        }
        // Separate source for forced ETH; depositor wallets are never refilled.
        vm.deal(address(this), STARTING_ETH);
        assertAccounting();
    }

    function deposit(uint256 actorSeed, uint256 amountSeed) external {
        _deposit(_actor(actorSeed), _amount(amountSeed));
    }

    function depositAndWithdraw(uint256 actorSeed, uint256 depositSeed, uint256 withdrawalSeed) external {
        address actor = _actor(actorSeed);
        // A real deposit ensures the action always executes a valid withdrawal,
        // even if a previous randomized action emptied this actor's balance.
        _deposit(actor, _amount(depositSeed));
        uint256 amount = bound(withdrawalSeed, 1 wei, expectedBalances[actor]);
        _withdraw(actor, amount);
    }

    function depositAndWithdrawAll(uint256 actorSeed, uint256 depositSeed) external {
        address actor = _actor(actorSeed);
        _deposit(actor, _amount(depositSeed));
        _withdraw(actor, expectedBalances[actor]);
        successfulFullWithdrawals++;
    }

    function forceETH(uint256 amountSeed) external {
        uint256 amount = _amount(amountSeed);
        uint256 vaultBefore = address(vault).balance;
        uint256 donorBefore = address(this).balance;
        new ForceETH{value: amount}(payable(address(vault)));

        assertEq(address(vault).balance, vaultBefore + amount, "Force-send must transfer ETH");
        assertEq(address(this).balance, donorBefore - amount, "Force-send must debit its source");
        forcedETH += amount;
        successfulForceSends++;
        assertAccounting();
    }

    function rejectDirectTransfer(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _actor(actorSeed);
        uint256 amount = _amount(amountSeed);
        uint256 actorBefore = actor.balance;
        uint256 vaultBefore = address(vault).balance;

        vm.recordLogs();
        vm.prank(actor);
        (bool success,) = address(vault).call{value: amount}("");
        assertFalse(success, "Ordinary direct ETH transfer must revert");
        assertEq(vm.getRecordedLogs().length, 0, "Rejected transfer must not retain events");
        assertEq(actor.balance, actorBefore, "Rejected transfer must not debit sender");
        assertEq(address(vault).balance, vaultBefore, "Rejected transfer must not credit vault");
        rejectedDirectTransfers++;
        assertAccounting();
    }

    function rejectZeroWithdrawal(uint256 actorSeed) external {
        _rejectWithdrawal(_actor(actorSeed), 0, abi.encodeWithSelector(ETHVault.ZeroWithdrawal.selector));
        rejectedZeroWithdrawals++;
    }

    function rejectExcessiveWithdrawal(uint256 actorSeed, uint256 excessSeed) external {
        address actor = _actor(actorSeed);
        uint256 available = expectedBalances[actor];
        uint256 requested = available + _amount(excessSeed);
        _rejectWithdrawal(
            actor, requested, abi.encodeWithSelector(ETHVault.InsufficientBalance.selector, available, requested)
        );
        rejectedExcessiveWithdrawals++;
    }

    /// @dev Runs after every external vault action, including both operations
    /// in paired actions. Reverted calls must preserve the same ghost model.
    function assertAccounting() public view {
        uint256 sum;
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            address actor = actors[i];
            uint256 expected = expectedBalances[actor];
            assertEq(vault.balances(actor), expected, "Depositor balance must match independent model");
            assertEq(actor.balance, STARTING_ETH - expected, "Depositor ETH must match successful movements");
            sum += expected;
        }
        assertEq(sum, expectedTotal, "Independent balances must sum to model total");
        assertEq(vault.totalDeposits(), expectedTotal, "Total owed must match independent model");
        assertGe(address(vault).balance, expectedTotal, "Vault must cover all depositor liabilities");
        assertEq(address(vault).balance, expectedTotal + forcedETH, "Forced ETH must remain uncredited surplus");
        assertEq(address(this).balance, STARTING_ETH - forcedETH, "Force-send source ETH");
    }

    function _deposit(address actor, uint256 amount) internal {
        uint256 actorBefore = actor.balance;
        uint256 vaultBefore = address(vault).balance;
        vm.prank(actor);
        vault.deposit{value: amount}();

        assertEq(actor.balance, actorBefore - amount, "Valid deposit must debit depositor");
        assertEq(address(vault).balance, vaultBefore + amount, "Valid deposit must credit vault");
        expectedBalances[actor] += amount;
        expectedTotal += amount;
        successfulDeposits++;
        assertAccounting();
    }

    function _withdraw(address actor, uint256 amount) internal {
        uint256 actorBefore = actor.balance;
        uint256 vaultBefore = address(vault).balance;
        vm.prank(actor);
        vault.withdraw(amount);

        assertEq(actor.balance, actorBefore + amount, "Valid withdrawal must pay depositor");
        assertEq(address(vault).balance, vaultBefore - amount, "Valid withdrawal must debit vault");
        expectedBalances[actor] -= amount;
        expectedTotal -= amount;
        successfulWithdrawals++;
        assertAccounting();
    }

    function _rejectWithdrawal(address actor, uint256 amount, bytes memory expectedError) internal {
        uint256 actorBefore = actor.balance;
        uint256 vaultBefore = address(vault).balance;
        vm.recordLogs();
        vm.prank(actor);
        (bool success, bytes memory errorData) = address(vault).call(abi.encodeCall(ETHVault.withdraw, (amount)));

        assertFalse(success, "Invalid withdrawal must revert");
        assertEq(errorData, expectedError, "Invalid withdrawal must reject for the expected reason");
        assertEq(vm.getRecordedLogs().length, 0, "Rejected withdrawal must not retain events");
        assertEq(actor.balance, actorBefore, "Rejected withdrawal must not pay caller");
        assertEq(address(vault).balance, vaultBefore, "Rejected withdrawal must not debit vault");
        assertAccounting();
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % ACTOR_COUNT];
    }

    function _amount(uint256 seed) internal pure returns (uint256) {
        return bound(seed, 1 wei, MAX_ACTION_ETH);
    }
}

contract ETHVaultInvariantTest is StdInvariant, Test {
    ETHVault internal vault;
    ETHVaultHandler internal handler;

    function setUp() public {
        vault = new ETHVault();
        handler = new ETHVaultHandler(vault);

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = ETHVaultHandler.deposit.selector;
        selectors[1] = ETHVaultHandler.depositAndWithdraw.selector;
        selectors[2] = ETHVaultHandler.depositAndWithdrawAll.selector;
        selectors[3] = ETHVaultHandler.forceETH.selector;
        selectors[4] = ETHVaultHandler.rejectDirectTransfer.selector;
        selectors[5] = ETHVaultHandler.rejectZeroWithdrawal.selector;
        selectors[6] = ETHVaultHandler.rejectExcessiveWithdrawal.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_EachDepositorBalanceMatchesModel() public view {
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            address actor = handler.actors(i);
            assertEq(vault.balances(actor), handler.expectedBalances(actor));
        }
    }

    function invariant_TotalDepositsMatchesIndependentSum() public view {
        uint256 sum;
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            sum += handler.expectedBalances(handler.actors(i));
        }
        assertEq(vault.totalDeposits(), sum);
        assertEq(handler.expectedTotal(), sum);
    }

    function invariant_VaultIsSolventWithUncreditedForcedETH() public view {
        assertGe(address(vault).balance, handler.expectedTotal());
        assertEq(address(vault).balance, handler.expectedTotal() + handler.forcedETH());
        assertEq(vault.balances(address(handler)), 0);
    }

    /// @dev Fail vacuous runs: every sequence must actually exercise all seven
    /// actions. Handler calls never silently skip or swallow unexpected errors.
    function afterInvariant() public view {
        handler.assertAccounting();
        assertGt(handler.successfulDeposits(), 0, "Campaign must execute valid deposits");
        assertGt(handler.successfulWithdrawals(), 0, "Campaign must execute valid withdrawals");
        assertGt(handler.successfulFullWithdrawals(), 0, "Campaign must execute full withdrawals");
        assertGt(handler.successfulForceSends(), 0, "Campaign must execute forced ETH transfers");
        assertGt(handler.rejectedDirectTransfers(), 0, "Campaign must reject direct transfers");
        assertGt(handler.rejectedZeroWithdrawals(), 0, "Campaign must reject zero withdrawals");
        assertGt(handler.rejectedExcessiveWithdrawals(), 0, "Campaign must reject excessive withdrawals");
    }
}
