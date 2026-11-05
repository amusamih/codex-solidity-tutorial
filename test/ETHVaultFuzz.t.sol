// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {ETHVault} from "../src/ETHVault.sol";

contract ETHVaultFuzzTest is Test {
    // Keep generated values realistic and leave headroom for repeated deposits.
    uint256 internal constant MAX_DEPOSIT = 1_000 ether;
    uint256 internal constant STARTING_ETH = 2 * MAX_DEPOSIT;

    ETHVault internal vault;
    address internal alice;
    address internal bob;

    event Deposited(address indexed depositor, uint256 amount);
    event Withdrawn(address indexed depositor, uint256 amount);

    function setUp() public {
        vault = new ETHVault();
        alice = makeAddr("fuzz-alice");
        bob = makeAddr("fuzz-bob");
        vm.deal(alice, STARTING_ETH);
        vm.deal(bob, STARTING_ETH);
    }

    function testFuzz_RepeatedDepositsAccumulate(uint256 firstSeed, uint256 secondSeed) public {
        uint256 first = bound(firstSeed, 1 wei, MAX_DEPOSIT);
        uint256 second = bound(secondSeed, 1 wei, MAX_DEPOSIT);

        _assertState(0, 0);
        _deposit(alice, first);
        _assertState(first, 0);
        _deposit(alice, second);
        _assertState(first + second, 0);
    }

    function testFuzz_PartialWithdrawalThenWithdrawRemaining(uint256 depositSeed, uint256 withdrawalSeed) public {
        uint256 deposited = bound(depositSeed, 2 wei, MAX_DEPOSIT);
        // Always a strictly partial, positive withdrawal; no discarded cases.
        uint256 withdrawn = bound(withdrawalSeed, 1 wei, deposited - 1 wei);
        uint256 remaining = deposited - withdrawn;

        _deposit(alice, deposited);
        _assertState(deposited, 0);
        _withdraw(alice, withdrawn);
        _assertState(remaining, 0);
        _withdraw(alice, remaining);
        _assertState(0, 0);
    }

    function testFuzz_FullWithdrawalReturnsEntireDeposit(uint256 depositSeed) public {
        uint256 deposited = bound(depositSeed, 1 wei, MAX_DEPOSIT);

        _deposit(alice, deposited);
        _assertState(deposited, 0);
        _withdraw(alice, deposited);
        _assertState(0, 0);
    }

    function testFuzz_ExcessiveWithdrawalPreservesState(uint256 depositSeed, uint256 withdrawalSeed) public {
        uint256 deposited = bound(depositSeed, 1 wei, MAX_DEPOSIT);
        uint256 requested = bound(withdrawalSeed, deposited + 1 wei, 2 * MAX_DEPOSIT);

        _deposit(alice, deposited);
        _assertState(deposited, 0);
        _expectExcessiveWithdrawal(alice, deposited, requested);
        _assertState(deposited, 0);

        // A failed attempt must not prevent a later valid withdrawal.
        _withdraw(alice, deposited);
        _assertState(0, 0);
    }

    function testFuzz_OneWeiAboveRemainingPreservesState(uint256 depositSeed, uint256 withdrawalSeed) public {
        uint256 deposited = bound(depositSeed, 2 wei, MAX_DEPOSIT);
        uint256 withdrawn = bound(withdrawalSeed, 1 wei, deposited - 1 wei);
        uint256 remaining = deposited - withdrawn;

        _deposit(alice, deposited);
        _assertState(deposited, 0);
        _withdraw(alice, withdrawn);
        _assertState(remaining, 0);
        _expectExcessiveWithdrawal(alice, remaining, remaining + 1 wei);
        _assertState(remaining, 0);
        _withdraw(alice, remaining);
        _assertState(0, 0);
    }

    function testFuzz_IndependentDepositorsKeepSeparateBalances(
        uint256 aliceDepositSeed,
        uint256 bobDepositSeed,
        uint256 aliceWithdrawalSeed,
        uint256 bobWithdrawalSeed
    ) public {
        uint256 aliceDeposit = bound(aliceDepositSeed, 1 wei, MAX_DEPOSIT);
        uint256 bobDeposit = bound(bobDepositSeed, 1 wei, MAX_DEPOSIT);
        uint256 aliceWithdrawal = bound(aliceWithdrawalSeed, 1 wei, aliceDeposit);
        uint256 bobWithdrawal = bound(bobWithdrawalSeed, 1 wei, bobDeposit);
        uint256 aliceRemaining = aliceDeposit - aliceWithdrawal;
        uint256 bobRemaining = bobDeposit - bobWithdrawal;

        _deposit(alice, aliceDeposit);
        _assertState(aliceDeposit, 0);
        _deposit(bob, bobDeposit);
        _assertState(aliceDeposit, bobDeposit);
        _withdraw(alice, aliceWithdrawal);
        _assertState(aliceRemaining, bobDeposit);
        _withdraw(bob, bobWithdrawal);
        _assertState(aliceRemaining, bobRemaining);

        if (aliceRemaining > 0) {
            _withdraw(alice, aliceRemaining);
            _assertState(0, bobRemaining);
        }
        if (bobRemaining > 0) {
            _withdraw(bob, bobRemaining);
        }
        _assertState(0, 0);
    }

    function testFuzz_DepositorCannotSpendOtherDepositorsETH(
        uint256 aliceDepositSeed,
        uint256 bobDepositSeed,
        uint256 excessSeed
    ) public {
        uint256 aliceDeposit = bound(aliceDepositSeed, 1 wei, MAX_DEPOSIT);
        uint256 bobDeposit = bound(bobDepositSeed, 1 wei, MAX_DEPOSIT);
        // Always exceeds the caller's claim, while remaining affordable by
        // the vault. Rejection cannot be explained by a lack of actual ETH.
        uint256 requested = aliceDeposit + bound(excessSeed, 1 wei, bobDeposit);

        _deposit(alice, aliceDeposit);
        _assertState(aliceDeposit, 0);
        _deposit(bob, bobDeposit);
        _assertState(aliceDeposit, bobDeposit);
        assertLe(requested, address(vault).balance);
        _expectExcessiveWithdrawal(alice, aliceDeposit, requested);
        _assertState(aliceDeposit, bobDeposit);

        // Each depositor can still withdraw exactly their own funds.
        _withdraw(alice, aliceDeposit);
        _assertState(0, bobDeposit);
        _withdraw(bob, bobDeposit);
        _assertState(0, 0);
    }

    function testFuzz_NondepositorCannotSpendOtherDepositorsETH(uint256 depositSeed, uint256 withdrawalSeed) public {
        uint256 deposited = bound(depositSeed, 1 wei, MAX_DEPOSIT);
        uint256 requested = bound(withdrawalSeed, 1 wei, deposited);

        _deposit(bob, deposited);
        _assertState(0, deposited);
        assertLe(requested, address(vault).balance);
        _expectExcessiveWithdrawal(alice, 0, requested);
        _assertState(0, deposited);
    }

    function _deposit(address depositor, uint256 amount) internal {
        vm.expectEmit(true, false, false, true, address(vault));
        emit Deposited(depositor, amount);
        vm.prank(depositor);
        vault.deposit{value: amount}();
    }

    function _withdraw(address depositor, uint256 amount) internal {
        vm.expectEmit(true, false, false, true, address(vault));
        emit Withdrawn(depositor, amount);
        vm.prank(depositor);
        vault.withdraw(amount);
    }

    function _expectExcessiveWithdrawal(address depositor, uint256 available, uint256 requested) internal {
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(ETHVault.InsufficientBalance.selector, available, requested));
        vm.prank(depositor);
        vault.withdraw(requested);
        assertEq(vm.getRecordedLogs().length, 0, "Reverted withdrawal must not retain events");
    }

    /// @dev Check independent expected balances as well as ETH conservation.
    /// Only Alice and Bob deposit in these scenarios; no ETH is forced in.
    function _assertState(uint256 aliceOwed, uint256 bobOwed) internal view {
        assertEq(vault.balances(alice), aliceOwed, "Alice recorded balance");
        assertEq(vault.balances(bob), bobOwed, "Bob recorded balance");
        assertEq(vault.totalDeposits(), aliceOwed + bobOwed, "Total owed");
        assertEq(address(vault).balance, aliceOwed + bobOwed, "Vault ETH");
        assertEq(alice.balance, STARTING_ETH - aliceOwed, "Alice ETH");
        assertEq(bob.balance, STARTING_ETH - bobOwed, "Bob ETH");
    }
}
