// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ETHVault
/// @notice Holds ETH that depositors can withdraw only to themselves.
contract ETHVault is ReentrancyGuard {
    /// @notice ETH currently owed to each depositor, in wei.
    mapping(address depositor => uint256 amount) public balances;

    /// @notice Total ETH currently owed to depositors, in wei.
    /// @dev Excludes any ETH forcibly sent outside deposit().
    uint256 public totalDeposits;

    error ZeroDeposit();
    error ZeroWithdrawal();
    error InsufficientBalance(uint256 available, uint256 requested);
    error WithdrawalFailed();

    event Deposited(address indexed depositor, uint256 amount);
    event Withdrawn(address indexed depositor, uint256 amount);

    /// @notice Deposit a positive amount of ETH into your own balance.
    function deposit() external payable nonReentrant {
        if (msg.value == 0) revert ZeroDeposit();

        balances[msg.sender] += msg.value;
        totalDeposits += msg.value;

        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Withdraw a positive amount of your balance to yourself.
    /// @param amount Amount of ETH to withdraw, in wei.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroWithdrawal();

        uint256 balance = balances[msg.sender];
        if (amount > balance) revert InsufficientBalance(balance, amount);

        // Apply accounting changes before calling the recipient.
        balances[msg.sender] = balance - amount;
        totalDeposits -= amount;
        emit Withdrawn(msg.sender, amount);

        (bool success,) = payable(msg.sender).call{value: amount}("");
        if (!success) revert WithdrawalFailed();
    }
}
