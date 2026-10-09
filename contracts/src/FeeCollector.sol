// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title FeeCollector
/// @notice Receives protocol fees (stablecoin) and slashed dispute bonds (project token). Withdrawals only via Timelock.
contract FeeCollector is AccessControl {
    using SafeERC20 for IERC20;

    event FeesWithdrawn(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function withdraw(IERC20 token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        emit FeesWithdrawn(address(token), to, amount);
        token.safeTransfer(to, amount);
    }
}
