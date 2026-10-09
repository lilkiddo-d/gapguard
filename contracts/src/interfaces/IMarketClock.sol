// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMarketClock {
    function weekIdOf(uint256 timestamp) external view returns (uint256);
    function weeklyWindow(uint256 weekId) external view returns (uint64 closeTime, uint64 openTime);
    function isMarketOpen(uint256 timestamp) external view returns (bool);
    function openSecondsBetween(uint256 from, uint256 to) external view returns (uint256);
}
