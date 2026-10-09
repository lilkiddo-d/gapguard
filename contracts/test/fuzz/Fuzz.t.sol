// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "../Fixture.sol";
import {CoverRegistry} from "../../src/CoverRegistry.sol";
import {CapitalPool} from "../../src/CapitalPool.sol";
import {TickMath} from "../../src/libraries/TickMath.sol";

contract FuzzTest is Fixture {
    function setUp() public override {
        super.setUp();
        for (uint8 i; i < 4; ++i) {
            underwrite(i, bob, 1_000_000e6);
        }
    }

    function testFuzz_premiumMonotonic(uint256 amount, uint256 extra, uint64 duration) public view {
        amount = bound(amount, 10e6, 200_000e6);
        extra = bound(extra, 1e6, 40_000e6);
        duration = uint64(bound(duration, 7 days, 90 days));
        (uint256 p1, uint256 r1) = s.registry.quote(GAP, address(aaa), amount, duration);
        (uint256 p2, uint256 r2) = s.registry.quote(GAP, address(aaa), amount + extra, duration);
        assertGe(r2, r1);
        assertGt(p2, p1);
        (uint256 p3,) = s.registry.quote(GAP, address(aaa), amount, duration + 1 days > 90 days ? 90 days : duration + 1 days);
        assertGe(p3, p1);
        // premium never exceeds the cover amount for <= 90 day covers under the 500% APR ceiling
        assertLe(p2, amount + extra);
    }

    function testFuzz_cannotBuyForStartedPeriod(uint64 startTime) public {
        startTime = uint64(bound(startTime, 1, block.timestamp + 1 hours - 1));
        fund(alice, 1_000_000e6);
        vm.prank(alice);
        vm.expectRevert(CoverRegistry.InvalidStart.selector);
        s.registry.buyCover(GAP, address(aaa), 1_000e6, 7 days, startTime, type(uint256).max);
    }

    function testFuzz_buyKeepsCapitalInvariant(uint8 product, uint128 amount, uint64 duration, uint64 startDelay)
        public
    {
        product = uint8(bound(product, 0, 3));
        amount = uint128(bound(amount, 10e6, 400_000e6));
        duration = uint64(bound(duration, 7 days, 90 days));
        startDelay = uint64(bound(startDelay, 1 hours, 30 days));
        fund(alice, 10_000_000e6);
        vm.prank(alice);
        try s.registry.buyCover(product, address(aaa), amount, duration, uint64(block.timestamp) + startDelay, type(uint256).max)
        returns (uint256 id) {
            assertGe(cover(id).start, block.timestamp + 1 hours);
            assertEq(cover(id).end - cover(id).start, duration);
        } catch {}
        CapitalPool pool = s.pools[product];
        assertGe(pool.totalAssets(), pool.lockedCapital());
        assertEq(pool.lockedCapital(), s.registry.productExposure(product));
        assertLe(
            s.registry.assetExposure(product, address(aaa)),
            pool.totalAssets() * s.registry.getProduct(product).maxAssetExposureBps / 10_000
        );
    }

    function testFuzz_poolRoundTripNoProfit(uint256 amount) public {
        amount = bound(amount, 1e6, 10_000_000e6);
        CapitalPool pool = s.pools[OUTAGE];
        uint256 shares = underwrite(OUTAGE, carol, amount);
        vm.prank(carol);
        pool.requestWithdraw(shares);
        warpAndRefresh(block.timestamp + 14 days);
        vm.prank(carol);
        uint256 out = pool.redeem(shares, carol, carol);
        assertLe(out, amount);
        assertApproxEqAbs(out, amount, 1);
    }

    function testFuzz_gapTriggersIffAboveThreshold(uint256 closeP, uint256 openP) public {
        closeP = bound(closeP, 1e8, 1e13);
        openP = bound(openP, 1, 2e13);
        vm.warp(CLOSE - 10 minutes);
        uint80 c = aaaFeed.pushNow(int256(closeP));
        vm.warp(OPEN + 5 minutes);
        uint80 o = aaaFeed.pushNow(int256(openP));
        (, bool trig) = s.gapResolver.resolve(address(aaa), WEEK_ID, c, o);
        uint256 gapBps = openP < closeP ? (closeP - openP) * 10_000 / closeP : 0;
        assertEq(trig, gapBps >= 1_000);
    }

    function testFuzz_openSecondsBounded(uint256 a, uint256 len) public view {
        a = bound(a, 1_700_000_000, 2_000_000_000);
        len = bound(len, 0, 30 days);
        uint256 open = s.clock.openSecondsBetween(a, a + len);
        assertLe(open, len);
        // at most one weekend (~48-50h) per 7 days is excluded
        if (len >= 7 days && len <= 21 days) assertGe(open, len - (len / 7 days + 1) * 50 hours);
    }

    function testFuzz_tickMonotonic(int24 t) public pure {
        t = int24(bound(t, TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        assertLt(TickMath.getSqrtRatioAtTick(t), TickMath.getSqrtRatioAtTick(t + 1));
    }

    function testFuzz_claimOnlyOnce(uint128 amount) public {
        amount = uint128(bound(amount, 10e6, 200_000e6));
        uint256 id = buy(alice, GAP, address(aaa), amount, 14 days);
        vm.warp(CLOSE - 10 minutes);
        uint80 c = aaaFeed.pushNow(200e8);
        vm.warp(OPEN + 5 minutes);
        uint80 o = aaaFeed.pushNow(100e8);
        (bytes32 eventId,) = s.gapResolver.resolve(address(aaa), WEEK_ID, c, o);
        s.registry.claim(id, eventId);
        vm.expectRevert(abi.encodeWithSelector(CoverRegistry.NotActive.selector, id));
        s.registry.claim(id, eventId);
        assertEq(s.pools[GAP].lockedCapital(), 0);
    }
}
