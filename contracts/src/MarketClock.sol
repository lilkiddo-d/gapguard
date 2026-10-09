// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IMarketClock} from "./interfaces/IMarketClock.sol";
import {UsMarketTime} from "./libraries/UsMarketTime.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title MarketClock
/// @notice Deterministic weekly market schedule for tokenized US equities trading 24/5.
///         Week `w` starts Friday 00:00 UTC. Each week has one weekend closure [closeTime, openTime):
///         default close = Friday 20:00 New York time, default open = Sunday 20:00 New York time (= Monday 00:00/01:00 UTC),
///         matching the 24/5 session of the Chainlink stock feeds. DST is computed on-chain.
///         An operator may override a week's window or flag holidays, but only with >= MIN_NOTICE before it matters,
///         so schedule changes can never be used to re-shape an event that is already known.
contract MarketClock is IMarketClock, AccessControl {
    uint256 public constant WEEK = 1 weeks;
    uint256 public constant FRIDAY_ANCHOR = 1 days; // 1970-01-02 00:00 UTC was a Friday
    uint256 public constant MIN_NOTICE = 2 days;
    uint256 public constant MAX_SPAN = 21 days;
    uint256 public constant MAX_CLOSURE = 5 days;

    uint32 public immutable closeLocalSeconds; // seconds after local midnight on Friday
    uint8 public immutable openDayOffset; // days after Friday (2 = Sunday, 3 = Monday)
    uint32 public immutable openLocalSeconds; // seconds after local midnight on the open day

    struct WindowOverride {
        uint64 closeTime;
        uint64 openTime;
        bool set;
    }

    mapping(uint256 weekId => WindowOverride) public overrides;
    mapping(uint256 dayIndex => bool) public holidays;

    event WeekOverrideSet(uint256 indexed weekId, uint64 closeTime, uint64 openTime, bool set);
    event HolidaySet(uint256 indexed dayIndex, bool closed);

    error TooLate();
    error InvalidWindow();
    error InvalidSchedule();

    constructor(address admin, uint32 closeLocalSeconds_, uint8 openDayOffset_, uint32 openLocalSeconds_) {
        if (admin == address(0)) revert InvalidSchedule();
        if (closeLocalSeconds_ >= 1 days || openLocalSeconds_ >= 1 days || openDayOffset_ == 0 || openDayOffset_ > 3) {
            revert InvalidSchedule();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        closeLocalSeconds = closeLocalSeconds_;
        openDayOffset = openDayOffset_;
        openLocalSeconds = openLocalSeconds_;
    }

    // ---------------------------------------------------------------- views

    function weekIdOf(uint256 timestamp) public pure returns (uint256) {
        if (timestamp < FRIDAY_ANCHOR) return 0;
        return (timestamp - FRIDAY_ANCHOR) / WEEK;
    }

    function defaultWindow(uint256 weekId) public view returns (uint64 closeTime, uint64 openTime) {
        uint256 friday = FRIDAY_ANCHOR + weekId * WEEK;
        closeTime = uint64(UsMarketTime.easternToUtc(friday + closeLocalSeconds));
        openTime = uint64(UsMarketTime.easternToUtc(friday + uint256(openDayOffset) * 1 days + openLocalSeconds));
    }

    function weeklyWindow(uint256 weekId) public view returns (uint64 closeTime, uint64 openTime) {
        WindowOverride memory o = overrides[weekId];
        if (o.set) return (o.closeTime, o.openTime);
        return defaultWindow(weekId);
    }

    function isMarketOpen(uint256 timestamp) external view returns (bool) {
        if (holidays[timestamp / 1 days]) return false;
        uint256 w = weekIdOf(timestamp);
        (uint64 c, uint64 o) = weeklyWindow(w);
        if (timestamp >= c && timestamp < o) return false;
        if (w > 0) {
            (c, o) = weeklyWindow(w - 1);
            if (timestamp >= c && timestamp < o) return false;
        }
        return true;
    }

    /// @notice Seconds of open market time in [from, to). Spans longer than MAX_SPAN are clamped to the last
    ///         MAX_SPAN seconds (a lower bound, which is conservative for outage detection).
    function openSecondsBetween(uint256 from, uint256 to) external view returns (uint256) {
        if (to <= from) return 0;
        if (to - from > MAX_SPAN) from = to - MAX_SPAN;
        uint256 closed = 0;
        uint256 wFrom = weekIdOf(from);
        uint256 wTo = weekIdOf(to);
        for (uint256 w = wFrom > 0 ? wFrom - 1 : 0; w <= wTo; ++w) {
            (uint64 c, uint64 o) = weeklyWindow(w);
            closed += _overlap(from, to, c, o);
        }
        for (uint256 dayStart = from - (from % 1 days); dayStart <= to; dayStart += 1 days) {
            if (holidays[dayStart / 1 days]) closed += _overlap(from, to, dayStart, dayStart + 1 days);
        }
        uint256 total = to - from;
        return closed >= total ? 0 : total - closed;
    }

    // ---------------------------------------------------------------- admin

    /// @notice Override one week's closure (e.g. Good Friday, Thanksgiving week-end). Only before the window matters.
    function setWeekOverride(uint256 weekId, uint64 closeTime, uint64 openTime, bool set)
        external
        onlyRole(Roles.OPERATOR_ROLE)
    {
        (uint64 dc,) = defaultWindow(weekId);
        uint64 earliest = closeTime < dc && set ? closeTime : dc;
        if (block.timestamp + MIN_NOTICE > earliest) revert TooLate();
        if (set) {
            if (openTime <= closeTime || openTime - closeTime > MAX_CLOSURE) revert InvalidWindow();
            if (weekIdOf(closeTime) != weekId && weekIdOf(closeTime) + 1 != weekId) revert InvalidWindow();
        }
        overrides[weekId] = WindowOverride(closeTime, openTime, set);
        emit WeekOverrideSet(weekId, closeTime, openTime, set);
    }

    /// @notice Flag a UTC day as a market holiday (only affects outage-time accounting). Requires MIN_NOTICE.
    function setHoliday(uint256 dayIndex, bool closed) external onlyRole(Roles.OPERATOR_ROLE) {
        if (block.timestamp + MIN_NOTICE > dayIndex * 1 days) revert TooLate();
        holidays[dayIndex] = closed;
        emit HolidaySet(dayIndex, closed);
    }

    function _overlap(uint256 a, uint256 b, uint256 c, uint256 d) private pure returns (uint256) {
        uint256 lo = a > c ? a : c;
        uint256 hi = b < d ? b : d;
        return hi > lo ? hi - lo : 0;
    }
}
