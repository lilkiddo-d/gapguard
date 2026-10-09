// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {GuardedAccess} from "./governance/GuardedAccess.sol";
import {ICapitalPool} from "./interfaces/ICapitalPool.sol";
import {ITriggerResolver} from "./interfaces/ITriggerResolver.sol";
import {ICompliance} from "./interfaces/ICompliance.sol";
import {ICoverRegistry} from "./interfaces/ICoverRegistry.sol";
import {IProjectTokenHooks} from "./interfaces/IProjectTokenHooks.sol";
import {CoverNFT} from "./CoverNFT.sol";
import {PricingCurve} from "./PricingCurve.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title CoverRegistry
/// @notice Entry point: sells parametric cover, mints the CoverNFT, routes premiums, enforces exposure limits and
///         pays claims once the product's resolver reports a triggered event.
///
///         Core safety properties:
///           - capital: every pool always holds >= the sum of its active cover amounts (lockCapital enforces it,
///             payouts reduce both sides equally, withdrawals only touch free capital);
///           - no retroactive cover: a cover's start is >= purchase time + product lead time, and an event is only
///             claimable if eventTime is within [start, end]; resolvers also refuse sales while an event is pending;
///           - one payout per cover (status Active -> Claimed), one record per event id (resolver side).
contract CoverRegistry is ICoverRegistry, GuardedAccess, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint64 public constant MIN_DURATION = 7 days;
    uint64 public constant MAX_DURATION = 90 days;
    uint64 public constant MAX_START_DELAY = 30 days;
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 2_000;
    uint256 public constant MAX_STAKER_SHARE_BPS = 3_000;
    uint256 public constant MAX_EXPIRE_BATCH = 100;

    struct Product {
        ICapitalPool pool;
        ITriggerResolver resolver;
        uint16 maxUtilizationBps; // cap on pool locked / total assets
        uint16 maxAssetExposureBps; // cap on a single asset's active cover / total assets
        uint32 minLead; // seconds between purchase and earliest cover start
        bool active;
    }

    IERC20 public immutable stablecoin;
    CoverNFT public immutable coverNFT;
    PricingCurve public pricing;
    ICompliance public compliance;
    IProjectTokenHooks public hooks;
    address public feeCollector;

    uint16 public protocolFeeBps = 1_000; // 10%
    uint16 public stakerShareBps = 1_000; // 10% (only when $GAPG staking is live; otherwise goes to the pool)
    uint64 public claimGracePeriod = 14 days; // covers can still claim events inside their period until end + grace
    uint128 public minCoverAmount;

    uint256 public nextCoverId = 1;
    mapping(uint8 productId => Product) internal _products;
    mapping(uint8 productId => mapping(address asset => bool)) public assetAllowed;
    mapping(uint8 productId => mapping(address asset => uint256)) public assetExposure;
    mapping(uint8 productId => uint256) public productExposure;
    mapping(uint256 coverId => Cover) internal _covers;
    mapping(uint256 coverId => bytes32) public claimedEvent;

    event ProductSet(
        uint8 indexed productId,
        address pool,
        address resolver,
        uint16 maxUtilizationBps,
        uint16 maxAssetExposureBps,
        uint32 minLead,
        bool active
    );
    event AssetAllowed(uint8 indexed productId, address indexed asset, bool allowed);
    event CoverPurchased(
        uint256 indexed coverId,
        address indexed buyer,
        uint8 indexed productId,
        address asset,
        uint256 amount,
        uint256 premium,
        uint64 start,
        uint64 end
    );
    event PremiumDistributed(uint256 indexed coverId, uint256 toPool, uint256 toProtocol, uint256 toStakers);
    event CoverClaimed(uint256 indexed coverId, bytes32 indexed eventId, address indexed holder, uint256 amount);
    event CoverExpired(uint256 indexed coverId);
    event FeesSet(uint16 protocolFeeBps, uint16 stakerShareBps);
    event ModulesSet(address pricing, address compliance, address hooks, address feeCollector);
    event ClaimGraceSet(uint64 claimGracePeriod);
    event MinCoverAmountSet(uint128 minCoverAmount);

    error ProductInactive(uint8 productId);
    error AssetNotAllowed(uint8 productId, address asset);
    error InvalidDuration();
    error InvalidStart();
    error InvalidAmount();
    error PurchaseBlocked();
    error CapacityExceeded(uint256 available);
    error AssetExposureExceeded(uint256 available);
    error PremiumTooHigh(uint256 premium);
    error NotActive(uint256 coverId);
    error EventMismatch();
    error NotTriggered();
    error NotExpired();
    error NotAllowed();
    error InvalidParam();
    error BatchTooLarge();

    constructor(address admin, IERC20 stablecoin_, CoverNFT coverNFT_, PricingCurve pricing_, address feeCollector_)
        GuardedAccess(admin)
    {
        if (address(stablecoin_) == address(0) || address(coverNFT_) == address(0)) revert ZeroAddress();
        if (address(pricing_) == address(0) || feeCollector_ == address(0)) revert ZeroAddress();
        stablecoin = stablecoin_;
        coverNFT = coverNFT_;
        pricing = pricing_;
        feeCollector = feeCollector_;
    }

    // ================================================================ views

    function getProduct(uint8 productId) external view returns (Product memory) {
        return _products[productId];
    }

    function getCover(uint256 coverId) external view returns (Cover memory) {
        return _covers[coverId];
    }

    /// @notice Capacity left for `asset` in `productId` (the min of product and asset limits).
    function availableCapacity(uint8 productId, address asset) public view returns (uint256) {
        Product memory p = _products[productId];
        if (address(p.pool) == address(0)) return 0;
        uint256 capital = p.pool.totalAssets();
        uint256 locked = p.pool.lockedCapital();
        uint256 productCap = capital * p.maxUtilizationBps / BPS;
        uint256 assetCap = capital * p.maxAssetExposureBps / BPS;
        uint256 a = productCap > locked ? productCap - locked : 0;
        uint256 exp = assetExposure[productId][asset];
        uint256 b = assetCap > exp ? assetCap - exp : 0;
        return a < b ? a : b;
    }

    function quote(uint8 productId, address asset, uint256 amount, uint64 duration)
        public
        view
        returns (uint256 premium, uint256 rateBps)
    {
        Product memory p = _products[productId];
        if (!p.active) revert ProductInactive(productId);
        if (!assetAllowed[productId][asset]) revert AssetNotAllowed(productId, asset);
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert InvalidDuration();
        uint256 capital = p.pool.totalAssets();
        uint256 lockedAfter = p.pool.lockedCapital() + amount;
        return pricing.quote(productId, amount, duration, lockedAfter, capital);
    }

    function isClaimable(uint256 coverId, bytes32 eventId) public view returns (bool) {
        Cover memory c = _covers[coverId];
        if (c.status != CoverStatus.Active) return false;
        (address asset, uint64 eventTime, bool triggered) = _products[c.productId].resolver.getEvent(eventId);
        return triggered && asset == c.asset && eventTime >= c.start && eventTime <= c.end;
    }

    // ================================================================ buy

    /// @param startTime 0 = earliest possible start (now + product lead time); otherwise must be >= that and
    ///                  <= now + MAX_START_DELAY. Cover can never start in the past or "now".
    function buyCover(
        uint8 productId,
        address asset,
        uint128 amount,
        uint64 duration,
        uint64 startTime,
        uint256 maxPremium
    ) external nonReentrant whenNotPaused returns (uint256 coverId) {
        Product memory p = _products[productId];
        uint64 end;
        (startTime, end) = _validatePurchase(p, productId, asset, amount, duration, startTime);
        (uint256 premium,) = quote(productId, asset, amount, duration);
        if (premium == 0 || premium > maxPremium) revert PremiumTooHigh(premium);

        // ---- effects
        coverId = nextCoverId++;
        _covers[coverId] = Cover({
            productId: productId,
            status: CoverStatus.Active,
            asset: asset,
            start: startTime,
            end: end,
            amount: amount,
            premium: uint128(premium)
        });
        assetExposure[productId][asset] += amount;
        productExposure[productId] += amount;
        emit CoverPurchased(coverId, msg.sender, productId, asset, amount, premium, startTime, end);

        // ---- interactions (trusted protocol contracts and the stablecoin only)
        _collectAndDistribute(coverId, p.pool, premium);
        p.pool.lockCapital(amount);
        coverNFT.mint(msg.sender, coverId);
    }

    function _validatePurchase(
        Product memory p,
        uint8 productId,
        address asset,
        uint128 amount,
        uint64 duration,
        uint64 startTime
    ) internal view returns (uint64 start, uint64 end) {
        if (!p.active) revert ProductInactive(productId);
        if (!assetAllowed[productId][asset]) revert AssetNotAllowed(productId, asset);
        if (amount == 0 || amount < minCoverAmount) revert InvalidAmount();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert InvalidDuration();
        ICompliance comp = compliance;
        if (address(comp) != address(0) && !comp.isAllowed(msg.sender, Roles.ACTION_BUY_COVER)) revert NotAllowed();

        uint64 earliest = uint64(block.timestamp) + p.minLead;
        start = startTime == 0 ? earliest : startTime;
        if (start < earliest || start > block.timestamp + MAX_START_DELAY) revert InvalidStart();
        end = start + duration;
        if (!p.resolver.canPurchase(asset, start, end)) revert PurchaseBlocked();

        uint256 capital = p.pool.totalAssets();
        uint256 exp = assetExposure[productId][asset] + amount;
        if (exp > capital * p.maxAssetExposureBps / BPS) revert AssetExposureExceeded(availableCapacity(productId, asset));
        if (p.pool.lockedCapital() + amount > capital * p.maxUtilizationBps / BPS) {
            revert CapacityExceeded(availableCapacity(productId, asset));
        }
    }

    function _collectAndDistribute(uint256 coverId, ICapitalPool pool, uint256 premium) internal {
        uint256 toProtocol = premium * protocolFeeBps / BPS;
        IProjectTokenHooks h = hooks;
        bool stakersLive = address(h) != address(0) && h.canReceiveRewards();
        uint256 toStakers = stakersLive ? premium * stakerShareBps / BPS : 0;
        uint256 toPool = premium - toProtocol - toStakers;

        IERC20 token = stablecoin;
        token.safeTransferFrom(msg.sender, address(pool), toPool);
        pool.addPremium(toPool);
        if (toProtocol > 0) token.safeTransferFrom(msg.sender, feeCollector, toProtocol);
        if (toStakers > 0) {
            token.safeTransferFrom(msg.sender, address(h), toStakers);
            h.notifyReward(toStakers);
        }
        emit PremiumDistributed(coverId, toPool, toProtocol, toStakers);
    }

    // ================================================================ claims

    /// @notice Permissionless (keepers auto-pay). Pays the current NFT holder; each cover pays at most once.
    function claim(uint256 coverId, bytes32 eventId) public nonReentrant whenNotPaused returns (uint256 amount) {
        Cover storage c = _covers[coverId];
        if (c.status != CoverStatus.Active) revert NotActive(coverId);
        Product memory p = _products[c.productId];
        (address asset, uint64 eventTime, bool triggered) = p.resolver.getEvent(eventId);
        if (!triggered) revert NotTriggered();
        if (asset != c.asset || eventTime < c.start || eventTime > c.end) revert EventMismatch();

        amount = c.amount;
        c.status = CoverStatus.Claimed;
        claimedEvent[coverId] = eventId;
        assetExposure[c.productId][asset] -= amount;
        productExposure[c.productId] -= amount;
        address holder = coverNFT.ownerOf(coverId);
        emit CoverClaimed(coverId, eventId, holder, amount);
        p.pool.payout(holder, amount);
    }

    /// @notice Releases capital of covers past end + grace. Permissionless, bounded batch.
    function expireCovers(uint256[] calldata coverIds) external nonReentrant {
        if (coverIds.length > MAX_EXPIRE_BATCH) revert BatchTooLarge();
        for (uint256 i; i < coverIds.length; ++i) {
            _expire(coverIds[i]);
        }
    }

    function _expire(uint256 coverId) internal {
        Cover storage c = _covers[coverId];
        if (c.status != CoverStatus.Active) revert NotActive(coverId);
        if (block.timestamp <= uint256(c.end) + claimGracePeriod) revert NotExpired();
        c.status = CoverStatus.Expired;
        uint256 amount = c.amount;
        assetExposure[c.productId][c.asset] -= amount;
        productExposure[c.productId] -= amount;
        emit CoverExpired(coverId);
        _products[c.productId].pool.unlockCapital(amount);
    }

    // ================================================================ admin (Timelock)

    function setProduct(
        uint8 productId,
        ICapitalPool pool,
        ITriggerResolver resolver,
        uint16 maxUtilizationBps,
        uint16 maxAssetExposureBps,
        uint32 minLead,
        bool active
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(pool) == address(0) || address(resolver) == address(0)) revert ZeroAddress();
        if (pool.asset() != address(stablecoin) || resolver.productId() != productId) revert InvalidParam();
        if (maxUtilizationBps == 0 || maxUtilizationBps > BPS) revert InvalidParam();
        if (maxAssetExposureBps == 0 || maxAssetExposureBps > maxUtilizationBps) revert InvalidParam();
        if (minLead < 1 hours || minLead > 7 days) revert InvalidParam();
        Product storage existing = _products[productId];
        if (address(existing.pool) != address(0) && existing.pool != pool && productExposure[productId] != 0) {
            revert InvalidParam(); // cannot swap a pool with live exposure
        }
        _products[productId] = Product(pool, resolver, maxUtilizationBps, maxAssetExposureBps, minLead, active);
        emit ProductSet(productId, address(pool), address(resolver), maxUtilizationBps, maxAssetExposureBps, minLead, active);
    }

    function setAssetAllowed(uint8 productId, address asset, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == address(0)) revert ZeroAddress();
        assetAllowed[productId][asset] = allowed;
        emit AssetAllowed(productId, asset, allowed);
    }

    function setFees(uint16 protocolFeeBps_, uint16 stakerShareBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (protocolFeeBps_ > MAX_PROTOCOL_FEE_BPS || stakerShareBps_ > MAX_STAKER_SHARE_BPS) revert InvalidParam();
        protocolFeeBps = protocolFeeBps_;
        stakerShareBps = stakerShareBps_;
        emit FeesSet(protocolFeeBps_, stakerShareBps_);
    }

    function setModules(PricingCurve pricing_, ICompliance compliance_, IProjectTokenHooks hooks_, address feeCollector_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (address(pricing_) == address(0) || feeCollector_ == address(0)) revert ZeroAddress();
        pricing = pricing_;
        compliance = compliance_;
        hooks = hooks_;
        feeCollector = feeCollector_;
        emit ModulesSet(address(pricing_), address(compliance_), address(hooks_), feeCollector_);
    }

    function setClaimGracePeriod(uint64 grace) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (grace < 3 days || grace > 60 days) revert InvalidParam();
        claimGracePeriod = grace;
        emit ClaimGraceSet(grace);
    }

    function setMinCoverAmount(uint128 minAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minCoverAmount = minAmount;
        emit MinCoverAmountSet(minAmount);
    }
}
