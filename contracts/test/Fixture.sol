// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SystemDeployer} from "../script/SystemDeployer.sol";
import {MockERC20, MockStockToken, MockAggregator, MockUniswapV3Pool} from "./mocks/Mocks.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {CapitalPool} from "../src/CapitalPool.sol";
import {ICoverRegistry} from "../src/interfaces/ICoverRegistry.sol";

/// @notice Full-system fixture with mocks, using the exact production wiring from SystemDeployer.
abstract contract Fixture is Test, SystemDeployer {
    // Wed 2026-10-07 12:00 UTC (market open). Week 2962's Friday close = Sat 2026-10-10 00:00 UTC (EDT).
    uint256 internal constant T0 = 1791374400;
    uint256 internal constant WEEK_ID = 2962;
    uint256 internal constant CLOSE = 1791590400;
    uint256 internal constant OPEN = 1791763200;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal keeper = makeAddr("keeper");
    address internal committee = makeAddr("committee");
    address internal alice = makeAddr("alice"); // buyer
    address internal bob = makeAddr("bob"); // underwriter
    address internal carol = makeAddr("carol"); // underwriter / staker

    MockERC20 internal usdg;
    MockAggregator internal usdgFeed;
    MockStockToken internal aaa;
    MockStockToken internal bbb;
    MockAggregator internal aaaFeed;
    MockAggregator internal bbbFeed;
    MockUniswapV3Pool internal aaaPool;

    System internal s;

    function setUp() public virtual {
        vm.warp(T0);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        usdgFeed = new MockAggregator(8);
        usdgFeed.pushNow(1e8);
        aaa = new MockStockToken("AAA");
        bbb = new MockStockToken("BBB");
        aaaFeed = new MockAggregator(8);
        bbbFeed = new MockAggregator(8);
        aaaFeed.pushNow(200e8);
        bbbFeed.pushNow(50e8);
        aaaPool = new MockUniswapV3Pool(address(aaa), address(usdg));
        aaaPool.setTick(tickForPrice(address(aaa), address(usdg), 200e6));

        AssetParams[] memory assets = new AssetParams[](2);
        assets[0] = AssetParams("AAA", address(aaa), address(aaaFeed), address(aaaPool), true, true, true, true);
        assets[1] = AssetParams("BBB", address(bbb), address(bbbFeed), address(0), true, false, true, true);

        Params memory p = Params({
            stablecoin: address(usdg),
            stablecoinFeed: address(usdgFeed),
            sequencerUptimeFeed: address(0),
            admin: admin,
            guardian: guardian,
            keeper: keeper,
            committee: committee,
            timelockDelay: 48 hours,
            feedMaxStaleness: 26 hours,
            depegTwapWindow: 30 minutes,
            depegMinLiquidity: 1e6,
            assets: assets
        });
        s = _deploySystem(p, address(this));
        _assertHandover(s, address(this));

        vm.label(address(s.registry), "CoverRegistry");
        vm.label(address(usdg), "USDG");
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Binary search for the tick at which 1 base token (18 dec) quotes `quoteAmount` of quote.
    function tickForPrice(address base, address quote, uint256 quoteAmount) internal pure returns (int24) {
        int24 lo = -887000;
        int24 hi = 887000;
        bool baseIs0 = base < quote;
        while (hi - lo > 1) {
            int24 mid = int24((int256(lo) + int256(hi)) / 2);
            uint256 q = TickMath.getQuoteAtTick(mid, 1e18, base, quote);
            // quote amount increases with tick when base is token0, decreases otherwise
            if ((q < quoteAmount) == baseIs0) lo = mid;
            else hi = mid;
        }
        return baseIs0 ? hi : lo;
    }

    function fund(address who, uint256 amount) internal {
        usdg.mint(who, amount);
        vm.prank(who);
        usdg.approve(address(s.registry), type(uint256).max);
    }

    function underwrite(uint8 productId, address who, uint256 amount) internal returns (uint256 shares) {
        usdg.mint(who, amount);
        CapitalPool pool = s.pools[productId];
        vm.startPrank(who);
        usdg.approve(address(pool), amount);
        shares = pool.deposit(amount, who);
        vm.stopPrank();
    }

    function buy(address who, uint8 productId, address asset, uint128 amount, uint64 duration)
        internal
        returns (uint256 id)
    {
        fund(who, 1_000_000e6);
        vm.prank(who);
        id = s.registry.buyCover(productId, asset, amount, duration, 0, type(uint256).max);
    }

    function asTimelock() internal {
        vm.prank(address(s.timelock));
    }

    function cover(uint256 id) internal view returns (ICoverRegistry.Cover memory) {
        return s.registry.getCover(id);
    }

    /// @dev Advance time and keep feeds fresh.
    function warpAndRefresh(uint256 ts) internal {
        vm.warp(ts);
        (, int256 a,,,) = aaaFeed.latestRoundData();
        (, int256 b,,,) = bbbFeed.latestRoundData();
        aaaFeed.pushNow(a);
        bbbFeed.pushNow(b);
        usdgFeed.pushNow(1e8);
    }
}
