// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title UsMarketTime
/// @notice Pure calendar helpers converting US Eastern wall-clock times to UTC using on-chain DST rules
///         (DST starts 2nd Sunday of March 02:00 local, ends 1st Sunday of November 02:00 local; US rule since 2007).
/// @dev Civil-date algorithms adapted from Howard Hinnant's public-domain days_from_civil / civil_from_days.
library UsMarketTime {
    uint256 internal constant DAY = 1 days;
    uint256 internal constant EST_OFFSET = 5 hours;
    uint256 internal constant EDT_OFFSET = 4 hours;

    // Integer calendar arithmetic: the floor divisions are the algorithm, not a precision loss.
    // slither-disable-start divide-before-multiply
    function daysFromCivil(uint256 y, uint256 m, uint256 d) internal pure returns (uint256) {
        if (m <= 2) y -= 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 mp = m > 2 ? m - 3 : m + 9;
        uint256 doy = (153 * mp + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146097 + doe - 719468;
    }

    function yearOf(uint256 timestamp) internal pure returns (uint256 y) {
        uint256 z = timestamp / DAY + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        if (mp >= 10) y += 1; // months Jan/Feb belong to the next civil year
    }

    // slither-disable-end divide-before-multiply

    /// @return 0 = Sunday ... 6 = Saturday
    function weekday(uint256 dayIndex) internal pure returns (uint256) {
        return (dayIndex + 4) % 7;
    }

    function firstSundayOnOrAfter(uint256 dayIndex) internal pure returns (uint256) {
        return dayIndex + (7 - weekday(dayIndex)) % 7;
    }

    /// @notice Whether US Eastern daylight time is in effect at UTC instant `timestamp`.
    function isUsDst(uint256 timestamp) internal pure returns (bool) {
        uint256 y = yearOf(timestamp);
        uint256 start = (firstSundayOnOrAfter(daysFromCivil(y, 3, 1)) + 7) * DAY + 7 hours; // 02:00 EST
        uint256 end = firstSundayOnOrAfter(daysFromCivil(y, 11, 1)) * DAY + 6 hours; // 02:00 EDT
        return timestamp >= start && timestamp < end;
    }

    /// @notice Converts a New York wall-clock time (seconds since epoch "as if UTC") into a UTC timestamp.
    function easternToUtc(uint256 localAsUtc) internal pure returns (uint256) {
        uint256 asEst = localAsUtc + EST_OFFSET;
        return isUsDst(asEst) ? localAsUtc + EDT_OFFSET : asEst;
    }
}
