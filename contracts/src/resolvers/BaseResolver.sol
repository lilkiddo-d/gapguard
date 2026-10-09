// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GuardedAccess} from "../governance/GuardedAccess.sol";
import {ITriggerResolver} from "../interfaces/ITriggerResolver.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";

/// @title BaseResolver
/// @notice Shared event bookkeeping for trigger resolvers. Every event id can be recorded exactly once
///         (each trigger resolves once). Triggered events keep the product's pool in a settlement freeze for
///         `settlementPeriod` so underwriters cannot exit at pre-loss share prices while payouts are processed.
abstract contract BaseResolver is ITriggerResolver, GuardedAccess {
    struct TriggerEvent {
        address asset;
        uint64 eventTime;
        uint64 resolvedAt;
        bool triggered;
        uint256 metric; // product-specific measurement (gap bps, deviation bps, stale seconds, halt seconds)
    }

    uint8 public immutable productId;
    IOracleAdapter public oracle;
    uint64 public settlementPeriod = 3 days;
    uint64 public lastTriggerAt;

    mapping(address asset => bool) public assetEnabled;
    mapping(bytes32 eventId => TriggerEvent) internal _events;
    bytes32[] internal _eventIds;

    event EventRecorded(
        bytes32 indexed eventId, address indexed asset, uint64 eventTime, bool triggered, uint256 metric
    );
    event AssetEnabled(address indexed asset, bool enabled);
    event OracleSet(address oracle);
    event SettlementPeriodSet(uint64 period);

    error EventExists(bytes32 eventId);
    error AssetNotEnabled(address asset);
    error InvalidParam();

    constructor(uint8 productId_, address admin, IOracleAdapter oracle_) GuardedAccess(admin) {
        if (address(oracle_) == address(0)) revert ZeroAddress();
        productId = productId_;
        oracle = oracle_;
    }

    // ---------------------------------------------------------------- views

    function getEvent(bytes32 eventId) external view returns (address asset, uint64 eventTime, bool triggered) {
        TriggerEvent memory e = _events[eventId];
        return (e.asset, e.eventTime, e.triggered);
    }

    function eventDetails(bytes32 eventId) external view returns (TriggerEvent memory) {
        return _events[eventId];
    }

    function eventCount() external view returns (uint256) {
        return _eventIds.length;
    }

    /// @notice Paginated history (newest last). Bounded by `limit`.
    function eventIdsPage(uint256 offset, uint256 limit) external view returns (bytes32[] memory ids) {
        uint256 n = _eventIds.length;
        if (offset >= n) return ids;
        uint256 end = offset + limit > n ? n : offset + limit;
        ids = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            ids[i - offset] = _eventIds[i];
        }
    }

    function withdrawalsBlocked() public view virtual returns (bool) {
        return lastTriggerAt != 0 && block.timestamp < uint256(lastTriggerAt) + settlementPeriod;
    }

    // ---------------------------------------------------------------- admin

    function setAssetEnabled(address asset, bool enabled) external virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        if (enabled && !oracle.isSupported(asset)) revert AssetNotEnabled(asset);
        assetEnabled[asset] = enabled;
        emit AssetEnabled(asset, enabled);
    }

    function setOracle(IOracleAdapter oracle_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(oracle_) == address(0)) revert ZeroAddress();
        oracle = oracle_;
        emit OracleSet(address(oracle_));
    }

    function setSettlementPeriod(uint64 period) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (period < 1 days || period > 14 days) revert InvalidParam();
        settlementPeriod = period;
        emit SettlementPeriodSet(period);
    }

    // ---------------------------------------------------------------- internal

    function _requireEnabled(address asset) internal view {
        if (!assetEnabled[asset]) revert AssetNotEnabled(asset);
    }

    function _record(bytes32 eventId, address asset, uint64 eventTime, bool triggered, uint256 metric) internal {
        if (_events[eventId].resolvedAt != 0) revert EventExists(eventId);
        _events[eventId] = TriggerEvent(asset, eventTime, uint64(block.timestamp), triggered, metric);
        _eventIds.push(eventId);
        if (triggered) lastTriggerAt = uint64(block.timestamp);
        emit EventRecorded(eventId, asset, eventTime, triggered, metric);
    }
}
