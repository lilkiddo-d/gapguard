// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "../Fixture.sol";
import {BaseResolver} from "../../src/resolvers/BaseResolver.sol";
import {WeekendGapResolver} from "../../src/resolvers/WeekendGapResolver.sol";
import {DepegResolver} from "../../src/resolvers/DepegResolver.sol";
import {OracleOutageResolver} from "../../src/resolvers/OracleOutageResolver.sol";
import {IssuerHaltResolver} from "../../src/resolvers/IssuerHaltResolver.sol";
import {AttestationModule} from "../../src/AttestationModule.sol";
import {IAttestationModule} from "../../src/interfaces/IAttestationModule.sol";
import {IUniswapV3Pool} from "../../src/interfaces/IUniswapV3Pool.sol";
import {IOracleAdapter} from "../../src/interfaces/IOracleAdapter.sol";
import {IMarketClock} from "../../src/interfaces/IMarketClock.sol";
import {ICoverRegistry} from "../../src/interfaces/ICoverRegistry.sol";
import {GuardedAccess} from "../../src/governance/GuardedAccess.sol";
import {MockUniswapV3Pool, MockERC20} from "../mocks/Mocks.sol";

contract WeekendGapResolverTest is Fixture {
    function _rounds(int256 closeP, int256 openP) internal returns (uint80 c, uint80 o) {
        vm.warp(CLOSE - 10 minutes);
        c = aaaFeed.pushNow(closeP);
        vm.warp(OPEN + 5 minutes);
        o = aaaFeed.pushNow(openP);
    }

    function test_resolve_triggersAboveThreshold() public {
        (uint80 c, uint80 o) = _rounds(200e8, 170e8);
        (bytes32 id, bool trig) = s.gapResolver.resolve(address(aaa), WEEK_ID, c, o);
        assertTrue(trig);
        assertEq(id, s.gapResolver.eventIdFor(address(aaa), WEEK_ID));
        BaseResolver.TriggerEvent memory e = s.gapResolver.eventDetails(id);
        assertEq(e.metric, 1_500);
        assertEq(e.eventTime, CLOSE);
        (address a, uint64 t, bool tr) = s.gapResolver.getEvent(id);
        assertEq(a, address(aaa));
        assertEq(t, CLOSE);
        assertTrue(tr);
        assertEq(s.gapResolver.eventCount(), 1);
        assertEq(s.gapResolver.eventIdsPage(0, 10)[0], id);
        assertEq(s.gapResolver.eventIdsPage(5, 10).length, 0);
        assertEq(s.gapResolver.lastTriggerAt(), block.timestamp);
        // each trigger resolves once
        vm.expectRevert(abi.encodeWithSelector(BaseResolver.EventExists.selector, id));
        s.gapResolver.resolve(address(aaa), WEEK_ID, c, o);
    }

    function test_resolve_upGapDoesNotTrigger() public {
        (uint80 c, uint80 o) = _rounds(200e8, 260e8);
        (, bool trig) = s.gapResolver.resolve(address(aaa), WEEK_ID, c, o);
        assertFalse(trig);
    }

    function test_revert_beforeReopenAndDisabledAsset() public {
        vm.warp(OPEN - 1);
        vm.expectRevert(WeekendGapResolver.MarketNotReopened.selector);
        s.gapResolver.resolve(address(aaa), WEEK_ID, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(BaseResolver.AssetNotEnabled.selector, address(0xdead)));
        s.gapResolver.resolve(address(0xdead), WEEK_ID, 0, 0);
    }

    function test_withdrawalsBlockedOverWeekend() public {
        assertFalse(s.gapResolver.withdrawalsBlocked());
        vm.warp(CLOSE - 30 minutes);
        assertTrue(s.gapResolver.withdrawalsBlocked());
        vm.warp(OPEN + 23 hours);
        assertTrue(s.gapResolver.withdrawalsBlocked());
        vm.warp(OPEN + 25 hours);
        assertFalse(s.gapResolver.withdrawalsBlocked());
        assertTrue(s.gapResolver.canPurchase(address(aaa), 0, 0));
    }

    function test_settlementFreezeAfterTrigger() public {
        (uint80 c, uint80 o) = _rounds(200e8, 100e8);
        s.gapResolver.resolve(address(aaa), WEEK_ID, c, o);
        vm.warp(OPEN + 2 days);
        assertTrue(s.gapResolver.withdrawalsBlocked());
        vm.warp(OPEN + 5 minutes + 3 days);
        assertFalse(s.gapResolver.withdrawalsBlocked());
    }

    function test_params() public {
        vm.startPrank(address(s.timelock));
        vm.expectRevert(BaseResolver.InvalidParam.selector);
        s.gapResolver.setParams(50, 1 hours, 1 hours, 1 days);
        vm.expectRevert(BaseResolver.InvalidParam.selector);
        s.gapResolver.setParams(500, 0, 1 hours, 1 days);
        vm.expectRevert(BaseResolver.InvalidParam.selector);
        s.gapResolver.setParams(500, 1 hours, 2 days, 1 days);
        s.gapResolver.setParams(500, 2 hours, 2 hours, 2 days);
        assertEq(s.gapResolver.thresholdBps(), 500);
        vm.expectRevert(BaseResolver.InvalidParam.selector);
        s.gapResolver.setSettlementPeriod(1 hours);
        s.gapResolver.setSettlementPeriod(5 days);
        vm.expectRevert(GuardedAccess.ZeroAddress.selector);
        s.gapResolver.setOracle(IOracleAdapter(address(0)));
        s.gapResolver.setOracle(IOracleAdapter(address(s.oracle)));
        vm.expectRevert(abi.encodeWithSelector(BaseResolver.AssetNotEnabled.selector, address(0xdead)));
        s.gapResolver.setAssetEnabled(address(0xdead), true);
        s.gapResolver.setAssetEnabled(address(aaa), false);
        vm.stopPrank();
        vm.expectRevert(GuardedAccess.ZeroAddress.selector);
        new WeekendGapResolver(address(this), IOracleAdapter(address(s.oracle)), IMarketClock(address(0)));
    }

    function test_pausedResolverRejects() public {
        vm.prank(guardian);
        s.gapResolver.pause();
        assertFalse(s.gapResolver.canPurchase(address(aaa), 0, 0));
    }
}

contract DepegResolverTest is Fixture {
    function setUp() public override {
        super.setUp();
        underwrite(DEPEG, bob, 1_000_000e6);
    }

    function _setDexPrice(uint256 usdg6) internal {
        aaaPool.setTick(tickForPrice(address(aaa), address(usdg), usdg6));
    }

    function test_dexPriceMatchesOracle() public view {
        uint256 p = s.depegResolver.dexPrice(address(aaa));
        assertApproxEqRel(p, 200e18, 0.001e18);
        (,, uint256 dev) = s.depegResolver.deviationBps(address(aaa));
        assertLt(dev, 10);
    }

    function test_noDepegNoEpisode() public {
        assertFalse(s.depegResolver.poke(address(aaa)));
        (uint64 start,,) = s.depegResolver.episodes(address(aaa));
        assertEq(start, 0);
    }

    function test_sustainedDepegTriggersAndPays() public {
        uint256 id = buy(alice, DEPEG, address(aaa), 50_000e6, 30 days);
        warpAndRefresh(block.timestamp + 2 hours); // cover active
        _setDexPrice(180e6); // 10% below oracle
        uint256 t0 = block.timestamp;
        assertFalse(s.depegResolver.poke(address(aaa)));
        assertFalse(s.depegResolver.canPurchase(address(aaa), 0, 0));
        assertTrue(s.depegResolver.withdrawalsBlocked());
        bool trig;
        for (uint256 i = 1; i <= 8; ++i) {
            warpAndRefresh(t0 + i * 30 minutes);
            trig = s.depegResolver.poke(address(aaa));
            if (trig) break;
        }
        assertTrue(trig);
        assertEq(block.timestamp, t0 + 4 hours);
        bytes32 eventId = s.depegResolver.eventIdFor(address(aaa), uint64(t0));
        (address a, uint64 t,) = s.depegResolver.getEvent(eventId);
        assertEq(a, address(aaa));
        assertEq(t, t0);
        assertEq(s.depegResolver.openEpisodes(), 0);
        uint256 before = usdg.balanceOf(alice);
        s.registry.claim(id, eventId);
        assertEq(usdg.balanceOf(alice) - before, 50_000e6);
    }

    function test_observationGapRestartsEpisode() public {
        _setDexPrice(150e6);
        s.depegResolver.poke(address(aaa));
        uint256 first = block.timestamp;
        warpAndRefresh(block.timestamp + 2 hours); // > maxPokeGap
        s.depegResolver.poke(address(aaa));
        (uint64 start,, uint32 pokes) = s.depegResolver.episodes(address(aaa));
        assertGt(start, first);
        assertEq(pokes, 1);
        assertEq(s.depegResolver.openEpisodes(), 1);
    }

    function test_recoveryAndLowLiquidityCloseEpisode() public {
        _setDexPrice(150e6);
        s.depegResolver.poke(address(aaa));
        _setDexPrice(200e6);
        warpAndRefresh(block.timestamp + 10 minutes);
        s.depegResolver.poke(address(aaa));
        assertEq(s.depegResolver.openEpisodes(), 0);
        _setDexPrice(150e6);
        s.depegResolver.poke(address(aaa));
        aaaPool.setLiquidity(1);
        warpAndRefresh(block.timestamp + 10 minutes);
        s.depegResolver.poke(address(aaa));
        assertEq(s.depegResolver.openEpisodes(), 0);
    }

    function test_expireEpisode() public {
        _setDexPrice(150e6);
        s.depegResolver.poke(address(aaa));
        vm.expectRevert(BaseResolver.InvalidParam.selector);
        s.depegResolver.expireEpisode(address(aaa));
        vm.warp(block.timestamp + 2 hours);
        s.depegResolver.expireEpisode(address(aaa));
        assertEq(s.depegResolver.openEpisodes(), 0);
    }

    function test_manipulationSpikeDoesNotTrigger() public {
        // a single-block spike that reverts next poke never satisfies minDuration/minPokes
        _setDexPrice(100e6);
        s.depegResolver.poke(address(aaa));
        _setDexPrice(200e6);
        for (uint256 i = 1; i <= 10; ++i) {
            warpAndRefresh(block.timestamp + 30 minutes);
            assertFalse(s.depegResolver.poke(address(aaa)));
        }
        assertEq(s.depegResolver.eventCount(), 0);
    }

    function test_staleOracleBlocksMeasurement() public {
        vm.warp(block.timestamp + 27 hours);
        vm.expectRevert();
        s.depegResolver.poke(address(aaa));
    }

    function test_admin() public {
        vm.startPrank(address(s.timelock));
        MockUniswapV3Pool wrong = new MockUniswapV3Pool(address(bbb), address(usdg));
        vm.expectRevert(BaseResolver.InvalidParam.selector);
        s.depegResolver.setDexConfig(address(aaa), IUniswapV3Pool(address(wrong)), address(usdg), 30 minutes, 0);
        vm.expectRevert(BaseResolver.InvalidParam.selector);
        s.depegResolver.setDexConfig(address(aaa), IUniswapV3Pool(address(aaaPool)), address(usdg), 1 minutes, 0);
        address unknown = address(new MockERC20("Q", "Q", 6));
        MockUniswapV3Pool odd = new MockUniswapV3Pool(address(aaa), unknown);
        vm.expectRevert(abi.encodeWithSelector(BaseResolver.AssetNotEnabled.selector, unknown));
        s.depegResolver.setDexConfig(address(aaa), IUniswapV3Pool(address(odd)), unknown, 30 minutes, 0);
        vm.expectRevert(abi.encodeWithSelector(DepegResolver.NoDexConfig.selector, address(bbb)));
        s.depegResolver.setAssetEnabled(address(bbb), true);
        vm.expectRevert(BaseResolver.InvalidParam.selector);
        s.depegResolver.setParams(50, 4 hours, 1 hours, 4);
        vm.expectRevert(BaseResolver.InvalidParam.selector);
        s.depegResolver.setParams(500, 30 minutes, 10 minutes, 4);
        vm.expectRevert(BaseResolver.InvalidParam.selector);
        s.depegResolver.setParams(500, 4 hours, 5 hours, 4);
        s.depegResolver.setParams(300, 2 hours, 30 minutes, 3);
        vm.stopPrank();
        // disabling with an open episode closes it
        _setDexPrice(150e6);
        s.depegResolver.poke(address(aaa));
        vm.prank(address(s.timelock));
        s.depegResolver.setAssetEnabled(address(aaa), false);
        assertEq(s.depegResolver.openEpisodes(), 0);
        vm.expectRevert(abi.encodeWithSelector(DepegResolver.NoDexConfig.selector, address(bbb)));
        s.depegResolver.dexPrice(address(bbb));
    }
}

contract OracleOutageResolverTest is Fixture {
    function setUp() public override {
        super.setUp();
        underwrite(OUTAGE, bob, 1_000_000e6);
    }

    function test_weekendIsNotAnOutage() public {
        vm.warp(CLOSE - 1 hours);
        aaaFeed.pushNow(200e8);
        vm.warp(OPEN + 1 hours);
        s.outageResolver.report(address(aaa));
        assertFalse(s.outageResolver.suspected(address(aaa)));
        (, uint256 stale) = s.outageResolver.staleOpenSeconds(address(aaa));
        assertEq(stale, 2 hours);
    }

    function test_outageTriggersAndPays() public {
        uint256 id = buy(alice, OUTAGE, address(aaa), 10_000e6, 30 days);
        warpAndRefresh(T0 + 2 hours); // last AAA update after cover start
        uint256 lastUpdate = block.timestamp;
        // Wed 14:00 -> Fri close is ~58h of open time, so 27h later is still within the week
        vm.warp(lastUpdate + 27 hours);
        assertFalse(s.outageResolver.report(address(aaa)));
        assertTrue(s.outageResolver.suspected(address(aaa)));
        assertTrue(s.outageResolver.withdrawalsBlocked());
        assertFalse(s.outageResolver.canPurchase(address(aaa), 0, 0));
        vm.warp(lastUpdate + 30 hours);
        assertTrue(s.outageResolver.report(address(aaa)));
        bytes32 eventId = s.outageResolver.eventIdFor(address(aaa), lastUpdate);
        (, uint64 t, bool trig) = s.outageResolver.getEvent(eventId);
        assertTrue(trig);
        assertEq(t, lastUpdate);
        // reporting again does not duplicate
        assertFalse(s.outageResolver.report(address(aaa)));
        s.registry.claim(id, eventId);
        assertEq(uint8(cover(id).status), uint8(ICoverRegistry.CoverStatus.Claimed));
        // feed recovers -> suspicion cleared
        aaaFeed.pushNow(200e8);
        s.outageResolver.report(address(aaa));
        assertFalse(s.outageResolver.suspected(address(aaa)));
        assertEq(s.outageResolver.suspectedCount(), 0);
    }

    function test_canPurchaseFreshFeed() public view {
        assertTrue(s.outageResolver.canPurchase(address(aaa), 0, 0));
    }

    function test_admin() public {
        vm.warp(T0 + 27 hours);
        s.outageResolver.report(address(aaa));
        vm.startPrank(address(s.timelock));
        s.outageResolver.setAssetEnabled(address(aaa), false);
        assertEq(s.outageResolver.suspectedCount(), 0);
        vm.expectRevert(abi.encodeWithSelector(BaseResolver.AssetNotEnabled.selector, address(0xdead)));
        s.outageResolver.setAssetEnabled(address(0xdead), true);
        s.outageResolver.setAssetEnabled(address(aaa), true);
        vm.expectRevert(BaseResolver.InvalidParam.selector);
        s.outageResolver.setOutageThreshold(1 minutes);
        s.outageResolver.setOutageThreshold(48 hours);
        vm.stopPrank();
        vm.expectRevert(GuardedAccess.ZeroAddress.selector);
        new OracleOutageResolver(address(this), IOracleAdapter(address(s.oracle)), IMarketClock(address(0)));
    }
}

contract IssuerHaltResolverTest is Fixture {
    function setUp() public override {
        super.setUp();
        underwrite(HALT, bob, 1_000_000e6);
    }

    function _haltFor(uint256 duration) internal returns (uint64 start) {
        s.haltResolver.poke(address(aaa)); // seen unpaused at T0
        vm.warp(block.timestamp + 2 hours);
        aaa.setPaused(true);
        start = uint64(block.timestamp);
        s.haltResolver.poke(address(aaa));
        vm.warp(block.timestamp + duration);
    }

    function test_haltFlow_undisputedPays() public {
        uint256 id = buy(alice, HALT, address(aaa), 10_000e6, 30 days);
        uint64 start = _haltFor(25 hours);
        assertTrue(s.haltResolver.withdrawalsBlocked());
        assertFalse(s.haltResolver.canPurchase(address(aaa), 0, 0));
        vm.prank(keeper);
        bytes32 eventId = s.haltResolver.proposeHalt(address(aaa), start);
        assertEq(s.haltResolver.pendingClaim(address(aaa)), eventId);
        vm.expectRevert(IssuerHaltResolver.NotFinal.selector);
        s.haltResolver.settle(eventId);
        (,,, uint256 attId,) = s.haltResolver.claims(eventId);
        vm.expectRevert(AttestationModule.WindowOpen.selector);
        s.attestation.finalize(attId);
        vm.warp(block.timestamp + 24 hours);
        s.attestation.finalize(attId);
        assertTrue(s.haltResolver.settle(eventId));
        vm.expectRevert(abi.encodeWithSelector(BaseResolver.EventExists.selector, eventId));
        s.haltResolver.settle(eventId);
        s.registry.claim(id, eventId);
        assertEq(uint8(cover(id).status), uint8(ICoverRegistry.CoverStatus.Claimed));
        // token unpaused -> purchases resume after poke
        aaa.setPaused(false);
        s.haltResolver.poke(address(aaa));
        assertEq(s.haltResolver.pausedSeenCount(), 0);
        assertTrue(s.haltResolver.canPurchase(address(aaa), 0, 0));
    }

    function test_haltFlow_committeeRejects() public {
        uint64 start = _haltFor(25 hours);
        vm.prank(keeper);
        bytes32 eventId = s.haltResolver.proposeHalt(address(aaa), start);
        (,,, uint256 attId,) = s.haltResolver.claims(eventId);
        // without $GAPG only the committee can dispute
        vm.prank(alice);
        vm.expectRevert(AttestationModule.NotAuthorizedDisputer.selector);
        s.attestation.dispute(attId);
        vm.prank(committee);
        s.attestation.dispute(attId);
        vm.prank(committee);
        s.attestation.resolveDispute(attId, false);
        assertFalse(s.haltResolver.settle(eventId));
        assertEq(s.haltResolver.pendingCount(), 0);
        assertEq(s.haltResolver.eventCount(), 0);
    }

    function test_revert_proposeValidation() public {
        vm.prank(alice);
        vm.expectRevert();
        s.haltResolver.proposeHalt(address(aaa), 1);
        vm.prank(keeper);
        vm.expectRevert(IssuerHaltResolver.NotPaused.selector);
        s.haltResolver.proposeHalt(address(aaa), 1);

        uint64 start = _haltFor(10 hours);
        vm.startPrank(keeper);
        vm.expectRevert(IssuerHaltResolver.TooShort.selector);
        s.haltResolver.proposeHalt(address(aaa), start);
        vm.warp(block.timestamp + 15 hours);
        // cannot claim the halt started before it was last observed unpaused
        vm.expectRevert(IssuerHaltResolver.InvalidStart.selector);
        s.haltResolver.proposeHalt(address(aaa), uint64(T0));
        // nor after it was first observed paused
        vm.expectRevert(IssuerHaltResolver.InvalidStart.selector);
        s.haltResolver.proposeHalt(address(aaa), start + 1);
        s.haltResolver.proposeHalt(address(aaa), start);
        vm.expectRevert(IssuerHaltResolver.ClaimPending.selector);
        s.haltResolver.proposeHalt(address(aaa), start);
        vm.stopPrank();
        vm.expectRevert(IssuerHaltResolver.UnknownClaim.selector);
        s.haltResolver.settle(bytes32(uint256(1)));
    }

    function test_admin() public {
        aaa.setPaused(true);
        s.haltResolver.poke(address(aaa));
        vm.startPrank(address(s.timelock));
        s.haltResolver.setAssetEnabled(address(aaa), false);
        assertEq(s.haltResolver.pausedSeenCount(), 0);
        vm.expectRevert(BaseResolver.InvalidParam.selector);
        s.haltResolver.setHaltThreshold(1);
        s.haltResolver.setHaltThreshold(48 hours);
        vm.stopPrank();
        vm.expectRevert(GuardedAccess.ZeroAddress.selector);
        new IssuerHaltResolver(address(this), IOracleAdapter(address(s.oracle)), IAttestationModule(address(0)));
    }
}
