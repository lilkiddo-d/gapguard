// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Subset of the Robinhood Chain stock token interface (ERC-20 + ERC-8056 scaled UI amount + pause flags).
/// @dev Verified on-chain against AAPL 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9: paused(), oraclePaused(), uiMultiplier().
interface IStockToken {
    function paused() external view returns (bool);
    function oraclePaused() external view returns (bool);
    function uiMultiplier() external view returns (uint256);
}
