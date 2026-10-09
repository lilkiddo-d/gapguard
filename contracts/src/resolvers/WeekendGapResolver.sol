// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseResolver} from "./BaseResolver.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {IMarketClock} from "../interfaces/IMarketClock.sol";

/// @title WeekendGapResolver (product 0)
/// @notice Pays if a token's first oracle price after the weekly reopen is more than `thresholdBps` below the last
///         oracle price at or before the Friday close. Both timestamps come from the MarketClock; prices come from
///         OracleAdapter rounds whose hints are verified on-chain, so resolution is permissionless and deterministic.
///         The event time is the Friday close: only covers that were already active at the close can claim, which
///         makes buying after the market has closed (when the gap may be predictable) worthless.
contract WeekendGapResolver is BaseResolver {
    IMarketClock public immutable clock;
    uint16 public thresholdBps = 1_000; // 10% gap
    uint32 public maxOpenDelay = 6 hours; // first post-open round must land within this delay
    uint64 public preCloseBlock = 1 hours; // withdrawals frozen from close - preCloseBlock until resolution grace ends
    uint64 public resolutionGrace = 1 days;

    event ParamsSet(uint16 thresholdBps, uint32 maxOpenDelay, uint64 preCloseBlock, uint64 resolutionGrace);

    error MarketNotReopened();

    constructor(address admin, IOracleAdapter oracle_, IMarketClock clock_) BaseResolver(0, admin, oracle_) {
        if (address(clock_) == address(0)) revert ZeroAddress();
        clock = clock_;
    }

    function eventIdFor(address asset, uint256 weekId) public pure returns (bytes32) {
        return keccak256(abi.encode(uint8(0), asset, weekId));
    }

    /// @notice Permissionless: resolve the weekend gap for `asset` in week `weekId` (week of the Friday close).
    /// @param closeRound Round id of the last feed round at/before the close.
    /// @param openRound  Round id of the first feed round at/after the reopen.
    // round timestamps are validated by the adapter
    // slither-disable-next-line unused-return
    function resolve(address asset, uint256 weekId, uint80 closeRound, uint80 openRound)
        external
        whenNotPaused
        returns (bytes32 eventId, bool triggered)
    {
        _requireEnabled(asset);
        (uint64 closeTime, uint64 openTime) = clock.weeklyWindow(weekId);
        if (block.timestamp < openTime) revert MarketNotReopened();
        eventId = eventIdFor(asset, weekId);
        (uint256 closePrice,) = oracle.getPriceAtOrBefore(asset, closeTime, closeRound);
        (uint256 openPrice,) = oracle.getPriceAtOrAfter(asset, openTime, maxOpenDelay, openRound);
        uint256 gapBps = openPrice < closePrice ? (closePrice - openPrice) * 10_000 / closePrice : 0;
        triggered = gapBps >= thresholdBps;
        _record(eventId, asset, closeTime, triggered, gapBps);
    }

    /// @dev Eligibility is enforced through eventTime (= Friday close) vs cover start, so purchases are always allowed.
    function canPurchase(address asset, uint64, uint64) external view returns (bool) {
        return assetEnabled[asset] && !paused();
    }

    /// @notice Underwriter exits are frozen over every weekend window (plus margins) and during settlement.
    function withdrawalsBlocked() public view override returns (bool) {
        if (super.withdrawalsBlocked()) return true;
        uint256 w = clock.weekIdOf(block.timestamp);
        for (uint256 i; i < 2; ++i) {
            if (w < i) break;
            (uint64 c, uint64 o) = clock.weeklyWindow(w - i);
            if (block.timestamp + preCloseBlock >= c && block.timestamp < uint256(o) + resolutionGrace) return true;
        }
        return false;
    }

    function setParams(uint16 thresholdBps_, uint32 maxOpenDelay_, uint64 preCloseBlock_, uint64 resolutionGrace_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (thresholdBps_ < 100 || thresholdBps_ > 5_000) revert InvalidParam();
        if (maxOpenDelay_ == 0 || maxOpenDelay_ > 1 days) revert InvalidParam();
        if (preCloseBlock_ > 1 days || resolutionGrace_ > 3 days) revert InvalidParam();
        thresholdBps = thresholdBps_;
        maxOpenDelay = maxOpenDelay_;
        preCloseBlock = preCloseBlock_;
        resolutionGrace = resolutionGrace_;
        emit ParamsSet(thresholdBps_, maxOpenDelay_, preCloseBlock_, resolutionGrace_);
    }
}
