// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseResolver} from "./BaseResolver.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {IMarketClock} from "../interfaces/IMarketClock.sol";

/// @title OracleOutageResolver (product 2)
/// @notice Pays if a supported feed receives no update for at least `outageThreshold` seconds of *open-market* time
///         (weekend closures and flagged holidays are excluded via the MarketClock, so a normal 24/5 weekend pause
///         is never an outage). The event time is the feed's last update: only covers active when the outage began
///         can claim, and purchases are refused while a feed is already late.
contract OracleOutageResolver is BaseResolver {
    IMarketClock public immutable clock;
    uint32 public outageThreshold = 30 hours; // open-market seconds without an update

    mapping(address asset => bool) public suspected;
    uint256 public suspectedCount;

    event SuspectUpdated(address indexed asset, bool suspected, uint256 staleOpenSeconds);
    event ThresholdSet(uint32 outageThreshold);

    constructor(address admin, IOracleAdapter oracle_, IMarketClock clock_) BaseResolver(2, admin, oracle_) {
        if (address(clock_) == address(0)) revert ZeroAddress();
        clock = clock_;
    }

    function eventIdFor(address asset, uint256 lastUpdate) public pure returns (bytes32) {
        return keccak256(abi.encode(uint8(2), asset, lastUpdate));
    }

    function staleOpenSeconds(address asset) public view returns (uint256 lastUpdate, uint256 staleSecs) {
        lastUpdate = oracle.latestUpdatedAt(asset);
        staleSecs = clock.openSecondsBetween(lastUpdate, block.timestamp);
    }

    /// @notice Permissionless: report the current feed state; records an outage event once the threshold is crossed.
    function report(address asset) external whenNotPaused returns (bool triggered) {
        _requireEnabled(asset);
        (uint256 lastUpdate, uint256 staleSecs) = staleOpenSeconds(asset);
        bool late = staleSecs >= oracle.maxStaleness(asset);
        if (late != suspected[asset]) {
            suspected[asset] = late;
            if (late) ++suspectedCount;
            else --suspectedCount;
            emit SuspectUpdated(asset, late, staleSecs);
        }
        if (staleSecs >= outageThreshold) {
            bytes32 id = eventIdFor(asset, lastUpdate);
            if (_events[id].resolvedAt == 0) {
                _record(id, asset, uint64(lastUpdate), true, staleSecs);
                triggered = true;
            }
        }
    }

    function canPurchase(address asset, uint64, uint64) external view returns (bool) {
        if (!assetEnabled[asset] || paused() || suspected[asset]) return false;
        (, uint256 staleSecs) = staleOpenSeconds(asset);
        return staleSecs < oracle.maxStaleness(asset);
    }

    function withdrawalsBlocked() public view override returns (bool) {
        return suspectedCount > 0 || super.withdrawalsBlocked();
    }

    function setAssetEnabled(address asset, bool enabled) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (enabled && !oracle.isSupported(asset)) revert AssetNotEnabled(asset);
        if (!enabled && suspected[asset]) {
            suspected[asset] = false;
            --suspectedCount;
        }
        assetEnabled[asset] = enabled;
        emit AssetEnabled(asset, enabled);
    }

    function setOutageThreshold(uint32 threshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (threshold < 1 hours || threshold > 7 days) revert InvalidParam();
        outageThreshold = threshold;
        emit ThresholdSet(threshold);
    }
}
