// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IOracleAdapter} from "./interfaces/IOracleAdapter.sol";
import {IStockToken} from "./interfaces/IStockToken.sol";

/// @title ChainlinkOracleAdapter
/// @notice Swappable OracleAdapter backed by Chainlink AggregatorV3 proxies (the official oracle of Robinhood Chain).
///         Validates staleness, positivity, optional L2 sequencer uptime, issuer `oraclePaused()` flag and an optional
///         secondary-feed deviation bound. Exposes historical round lookups with on-chain verified round hints so
///         resolvers can read the price at a fixed timestamp without trusting the caller.
contract ChainlinkOracleAdapter is IOracleAdapter, AccessControl {
    uint256 public constant MAX_DEVIATION_BPS = 2_000;

    struct FeedConfig {
        AggregatorV3Interface feed;
        uint32 maxStaleness;
        uint8 decimals;
        bool checkIssuerPause; // call IStockToken(asset).oraclePaused()
        AggregatorV3Interface secondary;
        uint16 maxDeviationBps;
    }

    mapping(address asset => FeedConfig) internal _feeds;

    AggregatorV3Interface public sequencerUptimeFeed; // optional (none published for Robinhood Chain yet)
    uint32 public sequencerGracePeriod;

    event FeedSet(address indexed asset, address indexed feed, uint32 maxStaleness, bool checkIssuerPause);
    event SecondaryFeedSet(address indexed asset, address indexed feed, uint16 maxDeviationBps);
    event SequencerFeedSet(address indexed feed, uint32 gracePeriod);

    error UnsupportedAsset(address asset);
    error StalePrice(address asset, uint256 updatedAt);
    error InvalidPrice(address asset);
    error IssuerOraclePaused(address asset);
    error SequencerDown();
    error PriceDeviation(address asset, uint256 primary, uint256 secondary);
    error BadRoundHint();
    error InvalidConfig();

    constructor(address admin) {
        if (admin == address(0)) revert InvalidConfig();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ---------------------------------------------------------------- admin

    function setFeed(address asset, AggregatorV3Interface feed, uint32 maxStaleness_, bool checkIssuerPause)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (asset == address(0) || address(feed) == address(0) || maxStaleness_ == 0 || maxStaleness_ > 7 days) {
            revert InvalidConfig();
        }
        uint8 dec = feed.decimals();
        if (dec > 18) revert InvalidConfig();
        FeedConfig storage c = _feeds[asset];
        c.feed = feed;
        c.maxStaleness = maxStaleness_;
        c.decimals = dec;
        c.checkIssuerPause = checkIssuerPause;
        emit FeedSet(asset, address(feed), maxStaleness_, checkIssuerPause);
    }

    function setSecondaryFeed(address asset, AggregatorV3Interface feed, uint16 maxDeviationBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (address(_feeds[asset].feed) == address(0)) revert UnsupportedAsset(asset);
        if (address(feed) != address(0) && (maxDeviationBps == 0 || maxDeviationBps > MAX_DEVIATION_BPS)) {
            revert InvalidConfig();
        }
        if (address(feed) != address(0) && feed.decimals() > 18) revert InvalidConfig();
        _feeds[asset].secondary = feed;
        _feeds[asset].maxDeviationBps = maxDeviationBps;
        emit SecondaryFeedSet(asset, address(feed), maxDeviationBps);
    }

    function setSequencerUptimeFeed(AggregatorV3Interface feed, uint32 gracePeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (gracePeriod > 1 days) revert InvalidConfig();
        sequencerUptimeFeed = feed;
        sequencerGracePeriod = gracePeriod;
        emit SequencerFeedSet(address(feed), gracePeriod);
    }

    // ---------------------------------------------------------------- views

    function feedConfig(address asset) external view returns (FeedConfig memory) {
        return _feeds[asset];
    }

    function isSupported(address asset) external view returns (bool) {
        return address(_feeds[asset].feed) != address(0);
    }

    function maxStaleness(address asset) external view returns (uint256) {
        return _config(asset).maxStaleness;
    }

    // startedAt is irrelevant; updatedAt is checked
    // slither-disable-next-line unused-return
    function getPrice(address asset) external view returns (uint256 price, uint256 updatedAt) {
        FeedConfig memory c = _config(asset);
        _checkSequencer();
        if (c.checkIssuerPause && IStockToken(asset).oraclePaused()) revert IssuerOraclePaused(asset);
        (uint80 roundId, int256 answer,, uint256 updated, uint80 answeredInRound) = c.feed.latestRoundData();
        updatedAt = updated;
        if (answer <= 0 || answeredInRound < roundId) revert InvalidPrice(asset);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > c.maxStaleness) {
            revert StalePrice(asset, updatedAt);
        }
        price = _scale(uint256(answer), c.decimals);
        if (address(c.secondary) != address(0)) {
            (, int256 a2,, uint256 u2,) = c.secondary.latestRoundData();
            if (a2 <= 0 || u2 == 0 || block.timestamp - u2 > c.maxStaleness) revert InvalidPrice(asset);
            uint256 p2 = _scale(uint256(a2), c.secondary.decimals());
            uint256 diff = p2 > price ? p2 - price : price - p2;
            if (diff * 10_000 > price * c.maxDeviationBps) revert PriceDeviation(asset, price, p2);
        }
    }

    // only the timestamp is requested
    // slither-disable-next-line unused-return
    function latestUpdatedAt(address asset) external view returns (uint256 updatedAt) {
        (,,, updatedAt,) = _config(asset).feed.latestRoundData();
    }

    /// @inheritdoc IOracleAdapter
    function getPriceAtOrBefore(address asset, uint256 timestamp, uint80 roundHint)
        external
        view
        returns (uint256 price, uint256 updatedAt)
    {
        FeedConfig memory c = _config(asset);
        int256 answer;
        (answer, updatedAt) = _round(c.feed, roundHint);
        if (updatedAt == 0 || updatedAt > timestamp) revert BadRoundHint();
        if (timestamp - updatedAt > c.maxStaleness) revert StalePrice(asset, updatedAt);
        // The next round must not exist or must be strictly after `timestamp`.
        (bool exists, uint256 nextUpdated) = _tryRound(c.feed, roundHint + 1);
        if (!exists) {
            // Phase boundary: the first round of the next phase (if any) must be after `timestamp`.
            uint80 nextPhaseFirst = uint80(((uint256(roundHint) >> 64) + 1) << 64 | 1);
            (exists, nextUpdated) = _tryRound(c.feed, nextPhaseFirst);
        }
        if (exists && nextUpdated != 0 && nextUpdated <= timestamp) revert BadRoundHint();
        if (answer <= 0) revert InvalidPrice(asset);
        price = _scale(uint256(answer), c.decimals);
    }

    /// @inheritdoc IOracleAdapter
    function getPriceAtOrAfter(address asset, uint256 timestamp, uint256 maxDelay, uint80 roundHint)
        external
        view
        returns (uint256 price, uint256 updatedAt)
    {
        FeedConfig memory c = _config(asset);
        int256 answer;
        (answer, updatedAt) = _round(c.feed, roundHint);
        if (updatedAt < timestamp || updatedAt > timestamp + maxDelay) revert BadRoundHint();
        // The previous round in the same phase must be strictly before `timestamp`.
        if (uint64(roundHint) > 1) {
            (bool exists, uint256 prevUpdated) = _tryRound(c.feed, roundHint - 1);
            if (exists && prevUpdated >= timestamp) revert BadRoundHint();
        }
        if (answer <= 0) revert InvalidPrice(asset);
        price = _scale(uint256(answer), c.decimals);
    }

    // ---------------------------------------------------------------- internal

    function _config(address asset) internal view returns (FeedConfig memory c) {
        c = _feeds[asset];
        if (address(c.feed) == address(0)) revert UnsupportedAsset(asset);
    }

    // uptime feeds only expose answer/startedAt
    // slither-disable-next-line unused-return
    function _checkSequencer() internal view {
        AggregatorV3Interface s = sequencerUptimeFeed;
        if (address(s) == address(0)) return;
        (, int256 answer, uint256 startedAt,,) = s.latestRoundData();
        // answer == 0: sequencer up; startedAt == 0 means the feed is not initialised.
        if (answer != 0 || startedAt == 0 || block.timestamp - startedAt <= sequencerGracePeriod) revert SequencerDown();
    }

    // callers validate answer/updatedAt
    // slither-disable-next-line unused-return
    function _round(AggregatorV3Interface feed, uint80 roundId) internal view returns (int256 answer, uint256 updatedAt) {
        (, answer,, updatedAt,) = feed.getRoundData(roundId);
    }

    // try/catch decode: only updatedAt is needed to detect existence and ordering
    // slither-disable-next-line unused-return
    function _tryRound(AggregatorV3Interface feed, uint80 roundId) internal view returns (bool, uint256) {
        try feed.getRoundData(roundId) returns (uint80, int256, uint256, uint256 updatedAt, uint80) {
            return (updatedAt != 0, updatedAt);
        } catch {
            return (false, 0);
        }
    }

    function _scale(uint256 value, uint8 decimals) internal pure returns (uint256) {
        return value * 10 ** (18 - decimals);
    }
}
