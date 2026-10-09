// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IProjectTokenHooks {
    function tokenEnabled() external view returns (bool);
    function canReceiveRewards() external view returns (bool);
    function notifyReward(uint256 amount) external;
    function availableToBond(address staker) external view returns (uint256);
    function lockBond(address staker, uint256 amount) external;
    function releaseBond(address staker, uint256 amount) external;
    function slashBond(address staker, uint256 amount, address to) external;
}
