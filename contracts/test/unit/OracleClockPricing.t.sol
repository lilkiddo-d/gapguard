// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChainlinkOracleAdapter} from "../../src/ChainlinkOracleAdapter.sol";
import {MarketClock} from "../../src/MarketClock.sol";
import {PricingCurve} from "../../src/PricingCurve.sol";
import {UsMarketTime} from "../../src/libraries/UsMarketTime.sol";
import {TickMath} from "../../src/libraries/TickMath.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {MockAggregator, MockStockToken, MockSequencerFeed} from "../mocks/Mocks.sol";

contract TimeHarness {
    function isDst(uint256 t) external pure returns (bool) {
        return UsMarketTime.isUsDst(t);
    }

    function year(uint256 t) external pure returns (uint256) {
        return UsMarketTime.yearOf(t);
    }

    function sqrtAt(int24 t) external pure returns (uint160) {
        return TickMath.getSqrtRatioAtTick(t);
    }
}

contract MarketClockTest is Test {
    MarketClock clock;
    TimeHarness h = new TimeHarness();
    address op = makeAddr("op");

    function setUp() public {
        clock = new MarketClock(address(this), 20 hours, 2, 20 hours);
        clock.grantRole(Roles.OPERATOR_ROLE, op);
        vm.warp(1791374400); // Wed 2026-10-07 12:00 UTC
    }

    function test_dstBoundaries() public view {
        assertFalse(h.isDst(1772953200 - 1)); // 2026-03-08 06:59:59 UTC
        assertTrue(h.isDst(1772953200)); // 2026-03-08 07:00 UTC (02:00 EST)
        assertTrue(h.isDst(1793512800 - 1)); // 2026-11-01 05:59:59 UTC
        assertFalse(h.isDst(1793512800)); // 2026-11-01 06:00 UTC
        assertEq(h.year(1791374400), 2026);
        assertEq(h.year(1767225600), 2026); // 2026-01-01
        assertEq(h.year(1767225599), 2025);
        assertEq(h.year(1772323200), 2026); // 2026-03-01 (leap-year logic path)
    }

    function test_weeklyWindow_summerAndWinter() public view {
        assertEq(clock.weekIdOf(1791374400), 2961);
        (uint64 c, uint64 o) = clock.weeklyWindow(2962);
        assertEq(c, 1791590400); // Sat 2026-10-10 00:00 UTC = Fri 20:00 EDT
        assertEq(o, 1791763200); // Mon 2026-10-12 00:00 UTC = Sun 20:00 EDT
        (c, o) = clock.weeklyWindow(2971);
        assertEq(c, 1797037200); // Sat 2026-12-12 01:00 UTC = Fri 20:00 EST
        assertEq(o, 1797210000);
        assertEq(clock.weekIdOf(0), 0);
    }

    function test_isMarketOpen() public {
        assertTrue(clock.isMarketOpen(1791374400));
        assertFalse(clock.isMarketOpen(1791590400));
        assertFalse(clock.isMarketOpen(1791763200 - 1));
        assertTrue(clock.isMarketOpen(1791763200));
        vm.prank(op);
        clock.setHoliday(uint256(1791374400) / 1 days + 3, true);
        assertFalse(clock.isMarketOpen(1791374400 + 3 days));
    }

    function test_openSecondsBetween() public {
        // Wed 12:00 -> next Wed 12:00 = 7 days minus a 48h weekend
        assertEq(clock.openSecondsBetween(1791374400, 1791374400 + 7 days), 5 days);
        assertEq(clock.openSecondsBetween(1791590400, 1791763200), 0);
        assertEq(clock.openSecondsBetween(10, 5), 0);
        // span clamped to MAX_SPAN
        assertLe(clock.openSecondsBetween(1791374400 - 60 days, 1791374400), 21 days);
        // a holiday removes a whole day
        vm.prank(op);
        clock.setHoliday(uint256(1791374400) / 1 days + 6, true); // Tuesday
        assertEq(clock.openSecondsBetween(1791374400, 1791374400 + 7 days), 4 days);
    }

    function test_overrides() public {
        (uint64 dc,) = clock.defaultWindow(2963);
        vm.prank(op);
        clock.setWeekOverride(2963, dc - 1 days, dc + 3 days, true);
        (uint64 c, uint64 o) = clock.weeklyWindow(2963);
        assertEq(c, dc - 1 days);
        assertEq(o, dc + 3 days);
        vm.startPrank(op);
        vm.expectRevert(MarketClock.InvalidWindow.selector);
        clock.setWeekOverride(2963, dc, dc, true);
        vm.expectRevert(MarketClock.InvalidWindow.selector);
        clock.setWeekOverride(2963, dc, dc + 6 days, true);
        vm.expectRevert(MarketClock.InvalidWindow.selector);
        clock.setWeekOverride(2963, dc + 14 days, dc + 15 days, true);
        // too late for the current week (close within MIN_NOTICE)
        vm.warp(1791374400 + 1 days);
        vm.expectRevert(MarketClock.TooLate.selector);
        clock.setWeekOverride(2962, 0, 0, false);
        vm.expectRevert(MarketClock.TooLate.selector);
        clock.setHoliday(uint256(1791374400) / 1 days, true);
        clock.setWeekOverride(2963, 0, 0, false);
        vm.stopPrank();
        (c,) = clock.weeklyWindow(2963);
        assertEq(c, dc);
    }

    function test_constructorValidation() public {
        vm.expectRevert(MarketClock.InvalidSchedule.selector);
        new MarketClock(address(0), 1, 2, 1);
        vm.expectRevert(MarketClock.InvalidSchedule.selector);
        new MarketClock(address(1), 1 days, 2, 1);
        vm.expectRevert(MarketClock.InvalidSchedule.selector);
        new MarketClock(address(1), 1, 0, 1);
        vm.expectRevert(MarketClock.InvalidSchedule.selector);
        new MarketClock(address(1), 1, 4, 1);
    }

    function test_tickMathKnownValues() public view {
        assertEq(h.sqrtAt(0), 79228162514264337593543950336);
        assertEq(h.sqrtAt(TickMath.MIN_TICK), 4295128739);
        assertEq(h.sqrtAt(TickMath.MAX_TICK), 1461446703485210103287273052203988822378723970342);
    }

    function test_tickMathOutOfRange() public {
        vm.expectRevert(TickMath.TickOutOfRange.selector);
        h.sqrtAt(TickMath.MAX_TICK + 1);
    }
}

contract OracleAdapterTest is Test {
    ChainlinkOracleAdapter oracle;
    MockAggregator feed;
    MockStockToken token;

    function setUp() public {
        vm.warp(1_800_000_000);
        oracle = new ChainlinkOracleAdapter(address(this));
        feed = new MockAggregator(8);
        token = new MockStockToken("AAA");
        oracle.setFeed(address(token), AggregatorV3Interface(address(feed)), 1 days, true);
    }

    function test_getPrice_scalesTo18() public {
        feed.pushNow(123_45000000);
        (uint256 p, uint256 u) = oracle.getPrice(address(token));
        assertEq(p, 123.45e18);
        assertEq(u, block.timestamp);
        assertTrue(oracle.isSupported(address(token)));
        assertEq(oracle.maxStaleness(address(token)), 1 days);
        assertEq(oracle.latestUpdatedAt(address(token)), block.timestamp);
        assertEq(address(oracle.feedConfig(address(token)).feed), address(feed));
    }

    function test_revert_staleNegativeUnsupportedPaused() public {
        feed.push(100e8, block.timestamp - 1 days - 1);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleAdapter.StalePrice.selector, address(token), block.timestamp - 1 days - 1));
        oracle.getPrice(address(token));
        feed.pushNow(-1);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleAdapter.InvalidPrice.selector, address(token)));
        oracle.getPrice(address(token));
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleAdapter.UnsupportedAsset.selector, address(1)));
        oracle.getPrice(address(1));
        feed.pushNow(100e8);
        token.setOraclePaused(true);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleAdapter.IssuerOraclePaused.selector, address(token)));
        oracle.getPrice(address(token));
    }

    function test_sequencerCheck() public {
        feed.pushNow(100e8);
        MockSequencerFeed seq = new MockSequencerFeed();
        oracle.setSequencerUptimeFeed(AggregatorV3Interface(address(seq)), 1 hours);
        seq.set(1, block.timestamp - 2 hours); // down
        vm.expectRevert(ChainlinkOracleAdapter.SequencerDown.selector);
        oracle.getPrice(address(token));
        seq.set(0, block.timestamp - 10 minutes); // up but within grace
        vm.expectRevert(ChainlinkOracleAdapter.SequencerDown.selector);
        oracle.getPrice(address(token));
        seq.set(0, block.timestamp - 2 hours);
        oracle.getPrice(address(token));
        vm.expectRevert(ChainlinkOracleAdapter.InvalidConfig.selector);
        oracle.setSequencerUptimeFeed(AggregatorV3Interface(address(seq)), 2 days);
    }

    function test_secondaryDeviation() public {
        feed.pushNow(100e8);
        MockAggregator f2 = new MockAggregator(18);
        f2.pushNow(103e18);
        oracle.setSecondaryFeed(address(token), AggregatorV3Interface(address(f2)), 200);
        vm.expectRevert();
        oracle.getPrice(address(token));
        f2.pushNow(101e18);
        (uint256 p,) = oracle.getPrice(address(token));
        assertEq(p, 100e18);
        f2.pushNow(0);
        vm.expectRevert();
        oracle.getPrice(address(token));
        vm.expectRevert(ChainlinkOracleAdapter.InvalidConfig.selector);
        oracle.setSecondaryFeed(address(token), AggregatorV3Interface(address(f2)), 0);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleAdapter.UnsupportedAsset.selector, address(9)));
        oracle.setSecondaryFeed(address(9), AggregatorV3Interface(address(f2)), 100);
        oracle.setSecondaryFeed(address(token), AggregatorV3Interface(address(0)), 0);
    }

    function test_historicalLookups() public {
        uint256 t = block.timestamp;
        uint80 r1 = feed.push(100e8, t - 3 hours);
        uint80 r2 = feed.push(110e8, t - 2 hours);
        uint80 r3 = feed.push(90e8, t - 1 hours);
        // at-or-before t-90min is r2
        (uint256 p,) = oracle.getPriceAtOrBefore(address(token), t - 90 minutes, r2);
        assertEq(p, 110e18);
        vm.expectRevert(ChainlinkOracleAdapter.BadRoundHint.selector);
        oracle.getPriceAtOrBefore(address(token), t - 90 minutes, r1); // not the last one
        vm.expectRevert(ChainlinkOracleAdapter.BadRoundHint.selector);
        oracle.getPriceAtOrBefore(address(token), t - 90 minutes, r3); // after timestamp
        // latest round as hint (no next round)
        (p,) = oracle.getPriceAtOrBefore(address(token), t, r3);
        assertEq(p, 90e18);
        // at-or-after t-150min is r2
        (p,) = oracle.getPriceAtOrAfter(address(token), t - 150 minutes, 1 hours, r2);
        assertEq(p, 110e18);
        vm.expectRevert(ChainlinkOracleAdapter.BadRoundHint.selector);
        oracle.getPriceAtOrAfter(address(token), t - 150 minutes, 1 hours, r3); // not first
        vm.expectRevert(ChainlinkOracleAdapter.BadRoundHint.selector);
        oracle.getPriceAtOrAfter(address(token), t - 150 minutes, 10 minutes, r2); // too late
        (p,) = oracle.getPriceAtOrAfter(address(token), t - 4 hours, 2 hours, r1); // first in phase
        assertEq(p, 100e18);
        // stale before-lookup
        vm.expectRevert();
        oracle.getPriceAtOrBefore(address(token), t + 2 days, r3);
    }

    function test_phaseBoundary() public {
        uint256 t = block.timestamp;
        uint80 r1 = feed.push(100e8, t - 3 hours);
        feed.newPhase();
        feed.push(120e8, t - 1 hours);
        // r1 is last of phase 1; the first round of phase 2 is after t-2h -> valid
        (uint256 p,) = oracle.getPriceAtOrBefore(address(token), t - 2 hours, r1);
        assertEq(p, 100e18);
        // but not valid for t (phase-2 round is at/before t)
        vm.expectRevert(ChainlinkOracleAdapter.BadRoundHint.selector);
        oracle.getPriceAtOrBefore(address(token), t, r1);
    }

    function test_negativeHistoricalPrice() public {
        uint80 r = feed.push(-5, block.timestamp - 1);
        vm.expectRevert();
        oracle.getPriceAtOrBefore(address(token), block.timestamp, r);
        vm.expectRevert();
        oracle.getPriceAtOrAfter(address(token), block.timestamp - 1, 1, r);
    }

    function test_setFeedValidation() public {
        vm.expectRevert(ChainlinkOracleAdapter.InvalidConfig.selector);
        oracle.setFeed(address(0), AggregatorV3Interface(address(feed)), 1 days, true);
        vm.expectRevert(ChainlinkOracleAdapter.InvalidConfig.selector);
        oracle.setFeed(address(token), AggregatorV3Interface(address(feed)), 8 days, true);
        MockAggregator bad = new MockAggregator(19);
        vm.expectRevert(ChainlinkOracleAdapter.InvalidConfig.selector);
        oracle.setFeed(address(token), AggregatorV3Interface(address(bad)), 1 days, true);
        vm.expectRevert(ChainlinkOracleAdapter.InvalidConfig.selector);
        new ChainlinkOracleAdapter(address(0));
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        oracle.setFeed(address(token), AggregatorV3Interface(address(feed)), 1 days, true);
    }
}

contract PricingCurveTest is Test {
    PricingCurve pricing;

    function setUp() public {
        pricing = new PricingCurve(address(this));
        pricing.setCurve(0, 300, 800, 4_000, 7_000);
    }

    function test_rates() public view {
        assertEq(pricing.annualRateBps(0, 0), 300);
        assertEq(pricing.annualRateBps(0, 7_000), 1_100);
        assertEq(pricing.annualRateBps(0, 8_500), 1_100 + 2_000);
        assertEq(pricing.annualRateBps(0, 10_000), 5_100);
        assertEq(pricing.annualRateBps(0, 50_000), 5_100); // capped
        assertTrue(pricing.curveOf(0).set);
    }

    function test_quote() public view {
        (uint256 premium, uint256 rate) = pricing.quote(0, 1_000_000e6, 365 days, 0, 1_000_000e6);
        assertEq(rate, 300);
        assertEq(premium, 30_000e6);
        (, rate) = pricing.quote(0, 1, 7 days, 1, 0); // zero capital => 100% util
        assertEq(rate, 5_100);
    }

    function test_revert_invalidCurves() public {
        vm.expectRevert(PricingCurve.InvalidCurve.selector);
        pricing.setCurve(1, 0, 0, 0, 0);
        vm.expectRevert(PricingCurve.InvalidCurve.selector);
        pricing.setCurve(1, 0, 0, 0, 10_000);
        vm.expectRevert(PricingCurve.InvalidCurve.selector);
        pricing.setCurve(1, 50_000, 1, 0, 5_000);
        vm.expectRevert(abi.encodeWithSelector(PricingCurve.CurveNotSet.selector, uint8(5)));
        pricing.annualRateBps(5, 0);
        vm.expectRevert(PricingCurve.InvalidCurve.selector);
        new PricingCurve(address(0));
    }
}
