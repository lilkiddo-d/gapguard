// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICapitalPool {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function lockedCapital() external view returns (uint256);
    function lockCapital(uint256 amount) external;
    function unlockCapital(uint256 amount) external;
    function payout(address to, uint256 amount) external;
    function addPremium(uint256 amount) external;
}
