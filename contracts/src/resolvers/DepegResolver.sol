// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {BaseResolver} from "./BaseResolver.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {IUniswapV3Pool} from "../interfaces/IUniswapV3Pool.sol";
import {TickMath} from "../libraries/TickMath.sol";

/// @title DepegResolver (product 1)
/// @notice Pays if a token's on-chain DEX price (Uniswap v3 TWAP) deviates from its oracle price by more than
///         `thresholdBps` continuously for at least `minDuration`.
///         Manipulation resistance:
///           - TWAP over `twapWindow` (not spot), so a one-block push has ~no effect;
///           - the deviation must persist across permissionless pokes spaced <= `maxPokeGap` for `minDuration`
///             (hours), i.e. an attacker must hold the pool off-peg against arbitrage for hours;
///           - pools below `minLiquidity` are ignored (episode reset), and the oracle side must be fresh
///             (no measurement while markets are closed);
///           - per-asset exposure caps in the CoverRegistry bound the profit from any single manipulation.
contract DepegResolver is BaseResolver {
    struct DexConfig {
        IUniswapV3Pool pool;
        address quoteAsset; // token paired in the pool; must be priced by the OracleAdapter (e.g. USDG, WETH)
        uint8 assetDecimals;
        uint8 quoteDecimals;
        uint32 twapWindow;
        uint128 minLiquidity;
    }

    struct Episode {
        uint64 start;
        uint64 lastPoke;
        uint32 pokes;
    }

    uint16 public thresholdBps = 500; // 5%
    uint32 public minDuration = 4 hours;
    uint32 public maxPokeGap = 1 hours;
    uint32 public minPokes = 4;

    mapping(address asset => DexConfig) public dexConfig;
    mapping(address asset => Episode) public episodes;
    uint256 public openEpisodes;

    event DexConfigSet(address indexed asset, address pool, address quoteAsset, uint32 twapWindow, uint128 minLiquidity);
    event Poked(address indexed asset, uint256 dexPrice, uint256 oraclePrice, uint256 deviationBps, bool depegged);
    event EpisodeOpened(address indexed asset, uint64 start);
    event EpisodeClosed(address indexed asset, uint64 start, bool triggered);
    event ParamsSet(uint16 thresholdBps, uint32 minDuration, uint32 maxPokeGap, uint32 minPokes);

    error NoDexConfig(address asset);

    constructor(address admin, IOracleAdapter oracle_) BaseResolver(1, admin, oracle_) {}

    function eventIdFor(address asset, uint64 start) public pure returns (bytes32) {
        return keccak256(abi.encode(uint8(1), asset, start));
    }

    /// @notice USD price (1e18) of one whole `asset` token from the pool TWAP.
    // only the tick cumulatives / price are needed
    // slither-disable-next-line unused-return
    function dexPrice(address asset) public view returns (uint256) {
        DexConfig memory d = dexConfig[asset];
        if (address(d.pool) == address(0)) revert NoDexConfig(asset);
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = d.twapWindow;
        (int56[] memory cumulatives,) = d.pool.observe(secondsAgos);
        int56 delta = cumulatives[1] - cumulatives[0];
        int56 window = int56(uint56(d.twapWindow));
        int24 avgTick = int24(delta / window);
        if (delta < 0 && (delta % window != 0)) avgTick--;
        uint256 quoteAmount =
            TickMath.getQuoteAtTick(avgTick, uint128(10 ** d.assetDecimals), asset, d.quoteAsset);
        (uint256 quoteUsd,) = oracle.getPrice(d.quoteAsset);
        return quoteAmount * quoteUsd / (10 ** d.quoteDecimals);
    }

    // updatedAt already validated by the adapter
    // slither-disable-next-line unused-return
    function deviationBps(address asset) public view returns (uint256 dexP, uint256 oracleP, uint256 devBps) {
        (oracleP,) = oracle.getPrice(asset);
        dexP = dexPrice(asset);
        uint256 diff = dexP > oracleP ? dexP - oracleP : oracleP - dexP;
        devBps = diff * 10_000 / oracleP;
    }

    /// @notice Permissionless measurement. Keepers call it every few minutes for each enabled asset.
    function poke(address asset) external whenNotPaused returns (bool triggered) {
        _requireEnabled(asset);
        DexConfig memory d = dexConfig[asset];
        Episode memory e = episodes[asset];
        bool liquid = d.pool.liquidity() >= d.minLiquidity;
        (uint256 dexP, uint256 oracleP, uint256 devBps) = deviationBps(asset);
        bool depegged = liquid && devBps >= thresholdBps;
        emit Poked(asset, dexP, oracleP, devBps, depegged);

        if (!depegged) {
            if (e.start != 0) _close(asset, e.start, false);
            return false;
        }
        if (e.start == 0 || block.timestamp - e.lastPoke > maxPokeGap) {
            if (e.start != 0) _close(asset, e.start, false); // gap in observations: restart conservatively
            e = Episode(uint64(block.timestamp), uint64(block.timestamp), 1);
            ++openEpisodes;
            emit EpisodeOpened(asset, e.start);
        } else {
            e.lastPoke = uint64(block.timestamp);
            e.pokes += 1;
        }
        episodes[asset] = e;

        if (block.timestamp - e.start >= minDuration && e.pokes >= minPokes) {
            _close(asset, e.start, true);
            _record(eventIdFor(asset, e.start), asset, e.start, true, devBps);
            return true;
        }
        return false;
    }

    /// @notice Permissionless cleanup of an episode whose observations lapsed (e.g. market closed / oracle stale).
    // zero = no open episode
    // slither-disable-next-line incorrect-equality
    function expireEpisode(address asset) external {
        Episode memory e = episodes[asset];
        if (e.start == 0 || block.timestamp - e.lastPoke <= maxPokeGap) revert InvalidParam();
        _close(asset, e.start, false);
    }

    function canPurchase(address asset, uint64, uint64) external view returns (bool) {
        return assetEnabled[asset] && !paused() && episodes[asset].start == 0;
    }

    function withdrawalsBlocked() public view override returns (bool) {
        return openEpisodes > 0 || super.withdrawalsBlocked();
    }

    // ---------------------------------------------------------------- admin

    function setDexConfig(address asset, IUniswapV3Pool pool, address quoteAsset, uint32 twapWindow, uint128 minLiquidity)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (twapWindow < 5 minutes || twapWindow > 1 days) revert InvalidParam();
        address t0 = pool.token0();
        address t1 = pool.token1();
        if (!((t0 == asset && t1 == quoteAsset) || (t1 == asset && t0 == quoteAsset))) revert InvalidParam();
        if (!oracle.isSupported(quoteAsset)) revert AssetNotEnabled(quoteAsset);
        dexConfig[asset] = DexConfig(
            pool, quoteAsset, _decimals(asset), _decimals(quoteAsset), twapWindow, minLiquidity
        );
        emit DexConfigSet(asset, address(pool), quoteAsset, twapWindow, minLiquidity);
    }

    function setAssetEnabled(address asset, bool enabled) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (enabled && (address(dexConfig[asset].pool) == address(0) || !oracle.isSupported(asset))) {
            revert NoDexConfig(asset);
        }
        if (!enabled && episodes[asset].start != 0) _close(asset, episodes[asset].start, false);
        assetEnabled[asset] = enabled;
        emit AssetEnabled(asset, enabled);
    }

    function setParams(uint16 thresholdBps_, uint32 minDuration_, uint32 maxPokeGap_, uint32 minPokes_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (thresholdBps_ < 100 || thresholdBps_ > 5_000) revert InvalidParam();
        if (minDuration_ < 1 hours || minDuration_ > 7 days) revert InvalidParam();
        if (maxPokeGap_ < 5 minutes || maxPokeGap_ > minDuration_ || minPokes_ < 2) revert InvalidParam();
        thresholdBps = thresholdBps_;
        minDuration = minDuration_;
        maxPokeGap = maxPokeGap_;
        minPokes = minPokes_;
        emit ParamsSet(thresholdBps_, minDuration_, maxPokeGap_, minPokes_);
    }

    function _close(address asset, uint64 start, bool triggered) internal {
        delete episodes[asset];
        --openEpisodes;
        emit EpisodeClosed(asset, start, triggered);
    }

    function _decimals(address token) internal view returns (uint8) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || data.length < 32) revert InvalidParam();
        uint256 dec = abi.decode(data, (uint256));
        if (dec > 30) revert InvalidParam();
        return uint8(dec);
    }
}
