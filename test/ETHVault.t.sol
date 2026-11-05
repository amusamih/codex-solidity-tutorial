// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ETHVault} from "../src/ETHVault.sol";

/// @dev A real recipient whose payment rejection can be disabled for a retry.
contract PaymentReceiver {
    ETHVault public immutable vault;
    bool public rejectPayment = true;

    error PaymentRejected();

    constructor(ETHVault vault_) {
        vault = vault_;
    }

    function deposit(uint256 amount) external {
        vault.deposit{value: amount}();
    }

    function withdraw(uint256 amount) external {
        vault.withdraw(amount);
    }

    function acceptPayments() external {
        rejectPayment = false;
    }

    receive() external payable {
        if (rejectPayment) revert PaymentRejected();
    }
}

/// @dev Makes one actual nested call during payment, recording the guard error.
contract ReentrantReceiver {
    enum Attack {
        Withdraw,
        Deposit
    }

    ETHVault public immutable vault;
    Attack public attack;
    bool public armed;
    bool public bubbleFailure;
    bool public attempted;
    bool public reentrySucceeded;
    bytes public reentryResult;
    uint256 public callbackCount;
    uint256 public received;
    uint256 public reentryAmount;

    constructor(ETHVault vault_) {
        vault = vault_;
    }

    function deposit(uint256 amount) external {
        vault.deposit{value: amount}();
    }

    function withdraw(uint256 amount) external {
        vault.withdraw(amount);
    }

    function arm(Attack attack_, uint256 amount, bool bubbleFailure_) external {
        attack = attack_;
        reentryAmount = amount;
        bubbleFailure = bubbleFailure_;
        armed = true;
    }

    function disarm() external {
        armed = false;
    }

    receive() external payable {
        callbackCount++;
        received += msg.value;
        if (!armed) return;

        // Stop recursive attempts even if the vault's protection is broken.
        armed = false;
        attempted = true;
        if (attack == Attack.Withdraw) {
            (reentrySucceeded, reentryResult) = address(vault).call(abi.encodeCall(ETHVault.withdraw, (reentryAmount)));
        } else {
            (reentrySucceeded, reentryResult) =
                address(vault).call{value: reentryAmount}(abi.encodeCall(ETHVault.deposit, ()));
        }

        if (bubbleFailure && !reentrySucceeded) {
            bytes memory reason = reentryResult;
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
    }
}

contract ETHVaultTest is Test {
    ETHVault internal vault;
    address internal alice;
    address internal bob;

    event Deposited(address indexed depositor, uint256 amount);
    event Withdrawn(address indexed depositor, uint256 amount);

    function setUp() public {
        vault = new ETHVault();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function test_InitialBalancesAreZero() public view {
        _assertEOAState(0, 0);
        assertEq(vault.balances(address(this)), 0);
    }

    function test_PositiveDepositCreditsCallerAndEmitsEvent() public {
        _deposit(alice, 2 ether);
        _assertEOAState(2 ether, 0);
    }

    function test_OneWeiDepositIsAccepted() public {
        _deposit(alice, 1 wei);
        _assertEOAState(1 wei, 0);
    }

    function test_RepeatedDepositsAccumulate() public {
        _deposit(alice, 2 ether);
        _assertEOAState(2 ether, 0);
        _deposit(alice, 3 ether);
        _assertEOAState(5 ether, 0);
    }

    function test_PartialWithdrawalPaysCallerAndEmitsEvent() public {
        _deposit(alice, 4 ether);
        _withdraw(alice, 1 ether);
        _assertEOAState(3 ether, 0);
    }

    function test_FullWithdrawalPaysCallerAndEmitsEvent() public {
        _deposit(alice, 4 ether);
        _withdraw(alice, 4 ether);
        _assertEOAState(0, 0);
    }

    function test_WithdrawExactlyRemainingBalance() public {
        _deposit(alice, 4 ether);
        _withdraw(alice, 1 ether);
        _assertEOAState(3 ether, 0);
        _withdraw(alice, 3 ether);
        _assertEOAState(0, 0);
    }

    function test_WithdrawOneWeiAboveRemainingBalanceReverts() public {
        _deposit(alice, 4 ether);
        _withdraw(alice, 1 ether);
        _withdrawReverts(
            alice,
            3 ether + 1 wei,
            abi.encodeWithSelector(ETHVault.InsufficientBalance.selector, 3 ether, 3 ether + 1 wei)
        );
        _assertEOAState(3 ether, 0);
    }

    function test_ZeroDepositRevertsWithoutChangingExistingBalance() public {
        _deposit(alice, 2 ether);
        vm.recordLogs();
        vm.expectRevert(ETHVault.ZeroDeposit.selector);
        vm.prank(alice);
        vault.deposit{value: 0}();
        assertEq(vm.getRecordedLogs().length, 0);
        _assertEOAState(2 ether, 0);
    }

    function test_ZeroWithdrawalRevertsWithoutChangingExistingBalance() public {
        _deposit(alice, 2 ether);
        _withdrawReverts(alice, 0, abi.encodeWithSelector(ETHVault.ZeroWithdrawal.selector));
        _assertEOAState(2 ether, 0);
    }

    function test_InsufficientBalanceReverts() public {
        _deposit(alice, 2 ether);
        _withdrawReverts(
            alice, 3 ether, abi.encodeWithSelector(ETHVault.InsufficientBalance.selector, 2 ether, 3 ether)
        );
        _assertEOAState(2 ether, 0);
    }

    function test_NondepositorCannotWithdrawOtherUsersFunds() public {
        _deposit(bob, 5 ether);
        // The vault can afford this payment, but Alice has no claim to it.
        _withdrawReverts(alice, 1 ether, abi.encodeWithSelector(ETHVault.InsufficientBalance.selector, 0, 1 ether));
        _assertEOAState(0, 5 ether);
    }

    function test_DepositorCannotSpendAnotherUsersBalance() public {
        _deposit(alice, 1 ether);
        _deposit(bob, 5 ether);
        // There is 6 ETH in the vault; Alice is still limited to her own 1 ETH.
        _withdrawReverts(
            alice, 2 ether, abi.encodeWithSelector(ETHVault.InsufficientBalance.selector, 1 ether, 2 ether)
        );
        _assertEOAState(1 ether, 5 ether);
    }

    function test_IndependentUsersWithdrawOnlyTheirOwnDeposits() public {
        _deposit(alice, 3 ether);
        _deposit(bob, 4 ether);
        _assertEOAState(3 ether, 4 ether);
        _withdraw(alice, 1 ether);
        _assertEOAState(2 ether, 4 ether);
        _withdraw(bob, 4 ether);
        _assertEOAState(2 ether, 0);
        _withdraw(alice, 2 ether);
        _assertEOAState(0, 0);
    }

    function test_FailedPartialPaymentRollsBackAndCanBeRetried() public {
        PaymentReceiver receiver = _fundPaymentReceiver();
        _expectFailedPayment(receiver, 1 ether);
        _assertReceiverState(address(receiver), 3 ether, 4 ether);

        // The same payment succeeds when the receiver accepts it, proving
        // that the failed attempt reached the payment and left no lock behind.
        receiver.acceptPayments();
        vm.expectEmit(true, false, false, true, address(vault));
        emit Withdrawn(address(receiver), 1 ether);
        receiver.withdraw(1 ether);
        _assertReceiverState(address(receiver), 2 ether, 4 ether);
    }

    function test_FailedFullPaymentRollsBackAndCanBeRetried() public {
        PaymentReceiver receiver = _fundPaymentReceiver();
        _expectFailedPayment(receiver, 3 ether);
        _assertReceiverState(address(receiver), 3 ether, 4 ether);

        receiver.acceptPayments();
        vm.expectEmit(true, false, false, true, address(vault));
        emit Withdrawn(address(receiver), 3 ether);
        receiver.withdraw(3 ether);
        _assertReceiverState(address(receiver), 0, 4 ether);
        _withdraw(bob, 4 ether);
        _assertReceiverState(address(receiver), 0, 0);
    }

    function test_ReentrantWithdrawalIsBlockedButOuterPaymentSucceeds() public {
        ReentrantReceiver receiver = _fundReentrantReceiver();
        receiver.arm(ReentrantReceiver.Attack.Withdraw, 1 ether, false);
        // Both the outer call and the real nested withdrawal must execute.
        vm.expectCall(address(vault), abi.encodeCall(ETHVault.withdraw, (1 ether)), uint64(2));
        vm.expectCall(address(receiver), 1 ether, bytes(""));
        vm.expectEmit(true, false, false, true, address(vault));
        emit Withdrawn(address(receiver), 1 ether);
        vm.recordLogs();
        receiver.withdraw(1 ether);

        _assertBlockedReentry(receiver);
        assertEq(vm.getRecordedLogs().length, 1);
        _assertReceiverState(address(receiver), 2 ether, 5 ether);
    }

    function test_ReentrantDepositIsBlockedButOuterPaymentSucceeds() public {
        ReentrantReceiver receiver = _fundReentrantReceiver();
        receiver.arm(ReentrantReceiver.Attack.Deposit, 1 ether, false);
        vm.expectCall(address(vault), 1 ether, abi.encodeCall(ETHVault.deposit, ()));
        vm.expectCall(address(receiver), 1 ether, bytes(""));
        vm.expectEmit(true, false, false, true, address(vault));
        emit Withdrawn(address(receiver), 1 ether);
        vm.recordLogs();
        receiver.withdraw(1 ether);

        _assertBlockedReentry(receiver);
        assertEq(vm.getRecordedLogs().length, 1);
        _assertReceiverState(address(receiver), 2 ether, 5 ether);
    }

    function test_BubbledReentryFailureRollsBackEntireWithdrawal() public {
        ReentrantReceiver receiver = _fundReentrantReceiver();
        receiver.arm(ReentrantReceiver.Attack.Withdraw, 1 ether, true);
        // Storage counters roll back too, so expected calls establish that
        // the callback and nested withdrawal really ran before the revert.
        vm.expectCall(address(vault), abi.encodeCall(ETHVault.withdraw, (1 ether)), uint64(2));
        vm.expectCall(address(receiver), 1 ether, bytes(""));
        vm.recordLogs();
        vm.expectRevert(ETHVault.WithdrawalFailed.selector);
        receiver.withdraw(1 ether);

        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(receiver.callbackCount(), 0);
        assertEq(receiver.received(), 0);
        assertFalse(receiver.attempted());
        assertTrue(receiver.armed());
        _assertReceiverState(address(receiver), 3 ether, 5 ether);

        receiver.disarm();
        vm.expectEmit(true, false, false, true, address(vault));
        emit Withdrawn(address(receiver), 3 ether);
        receiver.withdraw(3 ether);
        assertEq(receiver.callbackCount(), 1);
        assertEq(receiver.received(), 3 ether);
        _assertReceiverState(address(receiver), 0, 5 ether);
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

    function _withdrawReverts(address depositor, uint256 amount, bytes memory reason) internal {
        vm.recordLogs();
        vm.expectRevert(reason);
        vm.prank(depositor);
        vault.withdraw(amount);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function _fundPaymentReceiver() internal returns (PaymentReceiver receiver) {
        receiver = new PaymentReceiver(vault);
        vm.deal(address(receiver), 10 ether);
        receiver.deposit(3 ether);
        _deposit(bob, 4 ether);
        _assertReceiverState(address(receiver), 3 ether, 4 ether);
    }

    function _expectFailedPayment(PaymentReceiver receiver, uint256 amount) internal {
        assertTrue(receiver.rejectPayment());
        vm.expectCall(address(receiver), amount, bytes(""));
        vm.recordLogs();
        vm.expectRevert(ETHVault.WithdrawalFailed.selector);
        receiver.withdraw(amount);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function _fundReentrantReceiver() internal returns (ReentrantReceiver receiver) {
        receiver = new ReentrantReceiver(vault);
        vm.deal(address(receiver), 10 ether);
        receiver.deposit(3 ether);
        _deposit(bob, 5 ether);
        _assertReceiverState(address(receiver), 3 ether, 5 ether);
    }

    function _assertBlockedReentry(ReentrantReceiver receiver) internal view {
        assertTrue(receiver.attempted());
        assertFalse(receiver.reentrySucceeded());
        assertEq(
            receiver.reentryResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(receiver.callbackCount(), 1);
        assertEq(receiver.received(), 1 ether);
    }

    /// @dev Only Alice and Bob have deposited in the fixed EOA examples.
    function _assertEOAState(uint256 aliceOwed, uint256 bobOwed) internal view {
        assertEq(vault.balances(alice), aliceOwed);
        assertEq(vault.balances(bob), bobOwed);
        assertEq(vault.totalDeposits(), aliceOwed + bobOwed);
        assertEq(address(vault).balance, aliceOwed + bobOwed);
        assertEq(alice.balance, 10 ether - aliceOwed);
        assertEq(bob.balance, 10 ether - bobOwed);
    }

    /// @dev Each receiver starts with 10 ETH, just like the independent EOAs.
    function _assertReceiverState(address receiver, uint256 receiverOwed, uint256 bobOwed) internal view {
        assertEq(vault.balances(receiver), receiverOwed);
        assertEq(vault.balances(alice), 0);
        assertEq(vault.balances(bob), bobOwed);
        assertEq(vault.totalDeposits(), receiverOwed + bobOwed);
        assertEq(address(vault).balance, receiverOwed + bobOwed);
        assertEq(receiver.balance, 10 ether - receiverOwed);
        assertEq(alice.balance, 10 ether);
        assertEq(bob.balance, 10 ether - bobOwed);
    }
}
