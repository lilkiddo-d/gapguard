// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {SystemDeployer} from "../../script/SystemDeployer.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {ICoverRegistry} from "../../src/interfaces/ICoverRegistry.sol";
import {CapitalPool} from "../../src/CapitalPool.sol";
import {TickMath} from "../../src/libraries/TickMath.sol";

interface IPoolSlot0 {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

/// @notice Fork tests against Robinhood Chain mainnet (chain 4663) with the real USDG, stock tokens,
///         Chainlink feeds and Uniswap v3 pools listed in config/chains.ts. Uses the production Deploy wiring.
///         RPC: $ROBINHOOD_RPC_URL (default: the official public endpoint).
contract RobinhoodForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address constant QQQ = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;
    address constant QQQ_POOL = 0xD60A5d14dB690B7Afad71F76B108071D7175597d;

    Deploy internal deployer;
    SystemDeployer.System internal s;
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 4663, "not Robinhood Chain mainnet");
        // Make the AAPL feed "fresh" relative to block time regardless of when the suite runs (weekends).
        (,,, uint256 updatedAt,) = AggregatorV3Interface(AAPL_FEED).latestRoundData();
        if (block.timestamp - updatedAt > 20 hours) vm.warp(updatedAt + 1 hours);

        vm.setEnv("GAPGUARD_ADMIN", vm.toString(admin));
        deployer = new Deploy();
        SystemDeployer.Params memory p = deployer.loadParams(4663, address(this));
        s = Harness(address(new Harness())).deploy(p);
    }

    function _usdg(address to, uint256 amount) internal {
        deal(USDG, to, amount);
        assertEq(IERC20(USDG).balanceOf(to), amount, "deal USDG failed");
    }

    function test_fork_realTokensAndFeedsAreWired() public view {
        assertTrue(s.oracle.isSupported(AAPL));
        assertTrue(s.registry.assetAllowed(0, AAPL));
        assertTrue(s.registry.assetAllowed(1, QQQ));
        assertFalse(s.registry.assetAllowed(1, AAPL)); // no deep DEX pool -> no depeg cover
        (uint256 price,) = s.oracle.getPrice(AAPL);
        console.log("AAPL oracle price (1e18):", price);
        assertGt(price, 10e18);
        assertLt(price, 10_000e18);
        (uint256 usdgPrice,) = s.oracle.getPrice(USDG);
        assertApproxEqRel(usdgPrice, 1e18, 0.02e18);
        assertEq(s.timelock.getMinDelay(), 48 hours);
        assertTrue(s.registry.hasRole(0x00, address(s.timelock)));
        assertFalse(s.hooks.tokenEnabled());
    }

    function test_fork_underwriteAndBuyWithRealUsdg() public {
        _usdg(bob, 500_000e6);
        CapitalPool pool = s.pools[0];
        vm.startPrank(bob);
        IERC20(USDG).approve(address(pool), type(uint256).max);
        pool.deposit(500_000e6, bob);
        vm.stopPrank();

        _usdg(alice, 10_000e6);
        vm.startPrank(alice);
        IERC20(USDG).approve(address(s.registry), type(uint256).max);
        (uint256 q,) = s.registry.quote(0, AAPL, 50_000e6, 28 days);
        uint256 id = s.registry.buyCover(0, AAPL, 50_000e6, 28 days, 0, q);
        vm.stopPrank();
        assertEq(s.coverNFT.ownerOf(id), alice);
        assertEq(pool.lockedCapital(), 50_000e6);
        assertEq(uint8(s.registry.getCover(id).status), uint8(ICoverRegistry.CoverStatus.Active));
        console.log("premium for 50k AAPL weekend-gap cover, 28d:", q);
    }

    struct GapCase {
        uint256 week;
        uint64 close;
        uint80 closeRound;
        uint80 openRound;
        int256 closePrice;
        int256 openPrice;
    }

    function _lastWeekendCase() internal view returns (GapCase memory g) {
        g.week = s.clock.weekIdOf(block.timestamp);
        (uint64 close, uint64 open) = s.clock.weeklyWindow(g.week);
        if (block.timestamp < uint256(open) + 6 hours) {
            g.week -= 1;
            (close, open) = s.clock.weeklyWindow(g.week);
        }
        g.close = close;
        AggregatorV3Interface feed = AggregatorV3Interface(AAPL_FEED);
        (uint80 latest,,,,) = feed.latestRoundData();
        g.closeRound = _lastRoundAtOrBefore(feed, latest, close);
        g.openRound = _firstRoundAtOrAfter(feed, latest, open);
        (, g.closePrice,,,) = feed.getRoundData(g.closeRound);
        (, g.openPrice,,,) = feed.getRoundData(g.openRound);
    }

    /// @dev Resolves the most recent completed weekend for AAPL using real Chainlink rounds.
    function test_fork_resolveLastWeekendGapWithRealRounds() public {
        GapCase memory g = _lastWeekendCase();
        console.log("week", g.week, "close price", uint256(g.closePrice));
        console.log("open price", uint256(g.openPrice));
        (bytes32 eventId, bool triggered) = s.gapResolver.resolve(AAPL, g.week, g.closeRound, g.openRound);
        (address asset, uint64 t,) = s.gapResolver.getEvent(eventId);
        assertEq(asset, AAPL);
        assertEq(t, g.close);
        uint256 gapBps =
            g.openPrice < g.closePrice ? uint256(g.closePrice - g.openPrice) * 10_000 / uint256(g.closePrice) : 0;
        assertEq(triggered, gapBps >= 1_000);
    }

    function test_fork_wrongRoundHintsRejected() public {
        GapCase memory g = _lastWeekendCase();
        vm.expectRevert();
        s.gapResolver.resolve(AAPL, g.week, g.closeRound - 1, g.openRound);
        vm.expectRevert();
        s.gapResolver.resolve(AAPL, g.week, g.closeRound, g.openRound + 1);
    }

    function test_fork_depegTwapAgainstRealQqqPool() public view {
        (uint256 dexP, uint256 oracleP, uint256 devBps) = s.depegResolver.deviationBps(QQQ);
        console.log("QQQ dex TWAP / oracle / deviation bps", dexP, oracleP, devBps);
        assertGt(dexP, 0);
        assertLt(devBps, 5_000);
    }

    function test_fork_tickMathMatchesRealPool() public view {
        (uint160 sqrtP, int24 tick,,,,,) = IPoolSlot0(QQQ_POOL).slot0();
        assertLe(TickMath.getSqrtRatioAtTick(tick), sqrtP);
        assertGt(TickMath.getSqrtRatioAtTick(tick + 1), sqrtP);
    }

    function test_fork_haltAndOutageOnRealToken() public {
        assertFalse(s.haltResolver.poke(AAPL)); // AAPL transfers not paused
        assertTrue(s.haltResolver.canPurchase(AAPL, 0, 0));
        assertFalse(s.outageResolver.report(AAPL));
        (, uint256 staleOpen) = s.outageResolver.staleOpenSeconds(AAPL);
        assertLt(staleOpen, 26 hours);
    }

    // ---------------------------------------------------------------- round search helpers

    function _aggIndex(uint80 r) internal pure returns (uint64) {
        return uint64(r);
    }

    function _phase(uint80 r) internal pure returns (uint80) {
        return uint80((uint256(r) >> 64) << 64);
    }

    function _updatedAt(AggregatorV3Interface feed, uint80 r) internal view returns (uint256) {
        (,,, uint256 u,) = feed.getRoundData(r);
        return u;
    }

    /// binary search within the latest phase for the last round with updatedAt <= ts
    function _lastRoundAtOrBefore(AggregatorV3Interface feed, uint80 latest, uint256 ts) internal view returns (uint80) {
        uint80 ph = _phase(latest);
        uint64 lo = 1;
        uint64 hi = _aggIndex(latest);
        require(_updatedAt(feed, ph | lo) <= ts, "phase too new");
        while (lo < hi) {
            uint64 mid = lo + (hi - lo + 1) / 2;
            if (_updatedAt(feed, ph | mid) <= ts) lo = mid;
            else hi = mid - 1;
        }
        return ph | lo;
    }

    function _firstRoundAtOrAfter(AggregatorV3Interface feed, uint80 latest, uint256 ts) internal view returns (uint80) {
        uint80 ph = _phase(latest);
        uint64 lo = 1;
        uint64 hi = _aggIndex(latest);
        while (lo < hi) {
            uint64 mid = lo + (hi - lo) / 2;
            if (_updatedAt(feed, ph | mid) >= ts) hi = mid;
            else lo = mid + 1;
        }
        return ph | lo;
    }
}

/// @dev Deploys from a contract so the system's temporary admin is this harness (mirrors the script broadcaster).
contract Harness is SystemDeployer {
    function deploy(Params memory p) external returns (System memory s) {
        s = _deploySystem(p, address(this));
        _assertHandover(s, address(this));
    }
}
