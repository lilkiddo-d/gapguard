// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title GapguardTimelock
/// @notice Holds DEFAULT_ADMIN_ROLE on every Gapguard contract. Enforces a minimum delay of 48 hours that
///         cannot be lowered, even by a timelocked `updateDelay` call.
contract GapguardTimelock is TimelockController {
    uint256 public constant MIN_DELAY_FLOOR = 48 hours;

    error DelayTooShort();

    /// @param minDelay  Initial delay (>= 48h).
    /// @param proposers Addresses allowed to schedule and cancel operations (ops multisig).
    /// @param executors Addresses allowed to execute ready operations (address(0) = anyone).
    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors)
        TimelockController(minDelay, proposers, executors, address(0))
    {
        if (minDelay < MIN_DELAY_FLOOR) revert DelayTooShort();
    }

    /// @dev Effective delay is never below the 48h floor.
    function getMinDelay() public view override returns (uint256) {
        uint256 d = super.getMinDelay();
        return d < MIN_DELAY_FLOOR ? MIN_DELAY_FLOOR : d;
    }
}
