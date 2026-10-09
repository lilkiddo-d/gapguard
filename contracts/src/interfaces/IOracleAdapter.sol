// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Swappable price source. All prices are USD with 18 decimals.
interface IOracleAdapter {
    /// @notice Latest validated price. Reverts if stale, non-positive, sequencer down, or issuer oracle paused.
    function getPrice(address asset) external view returns (uint256 price, uint256 updatedAt);

    /// @notice Price of the last round with updatedAt <= timestamp. `roundHint` must be exactly that round.
    function getPriceAtOrBefore(address asset, uint256 timestamp, uint80 roundHint)
        external
        view
        returns (uint256 price, uint256 updatedAt);

    /// @notice Price of the first round with timestamp <= updatedAt <= timestamp + maxDelay. `roundHint` must be that round.
    function getPriceAtOrAfter(address asset, uint256 timestamp, uint256 maxDelay, uint80 roundHint)
        external
        view
        returns (uint256 price, uint256 updatedAt);

    /// @notice Raw timestamp of the latest feed update, without staleness validation (used by outage cover).
    function latestUpdatedAt(address asset) external view returns (uint256);

    function isSupported(address asset) external view returns (bool);

    function maxStaleness(address asset) external view returns (uint256);
}
