// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Fixture} from "../Fixture.sol";
import {SystemDeployer} from "../../script/SystemDeployer.sol";
import {CapitalPool} from "../../src/CapitalPool.sol";
import {ICoverRegistry} from "../../src/interfaces/ICoverRegistry.sol";
import {MockERC20, MockStockToken, MockAggregator} from "../mocks/Mocks.sol";

/// @notice Drives random sequences of deposits, purchases, outages/halts, claims, expiries and withdrawals.
contract Handler is Test {
    SystemDeployer.System internal s;
    MockERC20 internal usdg;
    MockStockToken[2] internal tokens;
    MockAggregator[3] internal feeds; // aaa, bbb, usdg
    address internal keeper;
    address[3] internal actors;

    uint256[] public coverIds;
    mapping(uint256 => uint256) public payCount;
    bytes32[] public events;
    uint256 public totalPaid;

    constructor(
        SystemDeployer.System memory s_,
        MockERC20 usdg_,
        MockStockToken a,
        MockStockToken b,
        MockAggregator fa,
        MockAggregator fb,
        MockAggregator fu,
        address keeper_
    ) {
        s = s_;
        usdg = usdg_;
        tokens = [a, b];
        feeds = [fa, fb, fu];
        keeper = keeper_;
        actors = [makeAddr("u1"), makeAddr("u2"), makeAddr("u3")];
    }

    function getS() external view returns (SystemDeployer.System memory) {
        return s;
    }

    function coverCount() external view returns (uint256) {
        return coverIds.length;
    }

    function deposit(uint256 actorSeed, uint256 product, uint256 amount) external {
        address a = actors[actorSeed % 3];
        CapitalPool pool = s.pools[product % 4];
        amount = bound(amount, 1e6, 2_000_000e6);
        usdg.mint(a, amount);
        vm.startPrank(a);
        usdg.approve(address(pool), amount);
        pool.deposit(amount, a);
        vm.stopPrank();
    }

    function buy(uint256 actorSeed, uint256 product, uint256 assetSeed, uint256 amount, uint256 duration) external {
        address a = actors[actorSeed % 3];
        uint8 p = uint8(product % 4);
        address asset = address(tokens[assetSeed % 2]);
        if (p == 1) asset = address(tokens[0]); // only AAA has depeg cover
        amount = bound(amount, 10e6, 300_000e6);
        duration = bound(duration, 7 days, 90 days);
        usdg.mint(a, 1_000_000e6);
        vm.startPrank(a);
        usdg.approve(address(s.registry), type(uint256).max);
        try s.registry.buyCover(p, asset, uint128(amount), uint64(duration), 0, type(uint256).max) returns (
            uint256 id
        ) {
            coverIds.push(id);
        } catch {}
        vm.stopPrank();
    }

    function passTime(uint256 secs, bool refresh) external {
        secs = bound(secs, 1 minutes, 5 days);
        vm.warp(block.timestamp + secs);
        if (refresh) {
            for (uint256 i; i < 3; ++i) {
                (, int256 ans,,,) = feeds[i].latestRoundData();
                feeds[i].pushNow(ans);
            }
        }
    }

    function reportOutage(uint256 assetSeed) external {
        try s.outageResolver.report(address(tokens[assetSeed % 2])) returns (bool trig) {
            if (trig) {
                bytes32 id = s.outageResolver.eventIdFor(
                    address(tokens[assetSeed % 2]), s.oracle.latestUpdatedAt(address(tokens[assetSeed % 2]))
                );
                events.push(id);
            }
        } catch {}
    }

    /// @dev Let one feed go silent for 4 days (>= 46h of open-market time) and report the outage.
    function forceOutage(uint256 assetSeed) external {
        MockStockToken t = tokens[assetSeed % 2];
        uint256 lastUpdate = s.oracle.latestUpdatedAt(address(t));
        vm.warp(block.timestamp + 4 days);
        for (uint256 i; i < 3; ++i) {
            if (i == assetSeed % 2) continue;
            (, int256 ans,,,) = feeds[i].latestRoundData();
            feeds[i].pushNow(ans);
        }
        try s.outageResolver.report(address(t)) returns (bool trig) {
            if (trig) events.push(s.outageResolver.eventIdFor(address(t), lastUpdate));
        } catch {}
        // feed recovers
        (, int256 a,,,) = feeds[assetSeed % 2].latestRoundData();
        feeds[assetSeed % 2].pushNow(a);
        try s.outageResolver.report(address(t)) {} catch {}
    }

    function eventCount() external view returns (uint256) {
        return events.length;
    }

    function haltCycle(uint256 assetSeed, bool pauseIt) external {
        MockStockToken t = tokens[assetSeed % 2];
        t.setPaused(pauseIt);
        try s.haltResolver.poke(address(t)) {} catch {}
        uint64 start = s.haltResolver.firstSeenPaused(address(t));
        if (start != 0 && block.timestamp - start >= 24 hours) {
            vm.prank(keeper);
            try s.haltResolver.proposeHalt(address(t), start) returns (bytes32 id) {
                events.push(id);
            } catch {}
        }
    }

    function settleHalts(uint256 idx) external {
        if (events.length == 0) return;
        bytes32 id = events[idx % events.length];
        (address asset,,, uint256 attId, bool settled) = s.haltResolver.claims(id);
        if (asset == address(0) || settled) return;
        try s.attestation.finalize(attId) {} catch {}
        try s.haltResolver.settle(id) {} catch {}
    }

    /// @dev Keeper-style auto-pay: tries every recorded event (twice, to prove double payment is impossible).
    function claim(uint256 coverSeed) external {
        if (coverIds.length == 0 || events.length == 0) return;
        for (uint256 k; k < coverIds.length && k < 40; ++k) {
            _claimAll(coverIds[(coverSeed + k) % coverIds.length]);
        }
    }

    function _claimAll(uint256 id) internal {
        for (uint256 round; round < 2; ++round) {
            for (uint256 e; e < events.length && e < 20; ++e) {
                uint256 lockedBefore = s.pools[s.registry.getCover(id).productId].lockedCapital();
                try s.registry.claim(id, events[e]) returns (uint256 amount) {
                    payCount[id] += 1;
                    totalPaid += amount;
                    assertEq(lockedBefore - amount, s.pools[s.registry.getCover(id).productId].lockedCapital());
                } catch {}
            }
        }
    }

    function expire(uint256 coverSeed) external {
        if (coverIds.length == 0) return;
        uint256[] memory ids = new uint256[](1);
        ids[0] = coverIds[coverSeed % coverIds.length];
        try s.registry.expireCovers(ids) {} catch {}
    }

    function requestWithdraw(uint256 actorSeed, uint256 product, uint256 frac) external {
        address a = actors[actorSeed % 3];
        CapitalPool pool = s.pools[product % 4];
        uint256 bal = pool.balanceOf(a);
        if (bal == 0) return;
        uint256 shares = bal * bound(frac, 1, 100) / 100;
        if (shares == 0) return;
        vm.prank(a);
        pool.requestWithdraw(shares);
    }

    function redeem(uint256 actorSeed, uint256 product) external {
        address a = actors[actorSeed % 3];
        CapitalPool pool = s.pools[product % 4];
        uint256 maxR = pool.maxRedeem(a);
        if (maxR == 0) return;
        vm.prank(a);
        pool.redeem(maxR, a, a);
    }
}

contract InvariantTest is Fixture {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        for (uint8 i; i < 4; ++i) {
            underwrite(i, bob, 3_000_000e6);
        }
        handler = new Handler(s, usdg, aaa, bbb, aaaFeed, bbbFeed, usdgFeed, keeper);
        targetContract(address(handler));
    }

    /// @dev Sanity: the handler can reach the payout path (so invariants are not vacuous).
    function test_handlerReachesPayout() public {
        handler.buy(0, 2, 0, 50_000e6, 30 days); // outage cover on AAA
        handler.passTime(2 hours, true);
        handler.forceOutage(0);
        handler.claim(0);
        assertGt(handler.totalPaid(), 0);
        invariant_poolCapitalCoversActiveCovers();
        invariant_exposureAccounting();
        invariant_eachCoverPaysOnce();
    }

    /// @notice Pool capital always covers the maximum payout of all active covers (within limits).
    function invariant_poolCapitalCoversActiveCovers() public view {
        for (uint8 i; i < 4; ++i) {
            CapitalPool pool = s.pools[i];
            assertGe(pool.totalAssets(), pool.lockedCapital(), "capital < max payout");
            assertEq(pool.lockedCapital(), s.registry.productExposure(i), "locked != exposure");
        }
    }

    /// @notice Locked capital equals the sum of active cover amounts, and asset exposures add up.
    function invariant_exposureAccounting() public view {
        uint256[4] memory active;
        uint256 n = handler.coverCount();
        for (uint256 k; k < n; ++k) {
            ICoverRegistry.Cover memory c = s.registry.getCover(handler.coverIds(k));
            if (c.status == ICoverRegistry.CoverStatus.Active) active[c.productId] += c.amount;
        }
        for (uint8 i; i < 4; ++i) {
            assertEq(active[i], s.registry.productExposure(i));
            assertEq(
                s.registry.assetExposure(i, address(aaa)) + s.registry.assetExposure(i, address(bbb)),
                s.registry.productExposure(i)
            );
        }
    }

    /// @notice Each cover is paid at most once.
    function invariant_eachCoverPaysOnce() public view {
        uint256 n = handler.coverCount();
        for (uint256 k; k < n; ++k) {
            assertLe(handler.payCount(handler.coverIds(k)), 1);
        }
    }

    function afterInvariant() external view {
        console.log("covers", handler.coverCount(), "paid", handler.totalPaid());
        console.log("events", handler.eventCount());
    }

    /// @notice Registry and resolvers never hold user funds.
    function invariant_registryHoldsNoFunds() public view {
        assertEq(usdg.balanceOf(address(s.registry)), 0);
    }
}
