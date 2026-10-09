// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title PricingCurve
/// @notice Per-product kinked utilization curve (annualised rate in bps):
///           rate(u) = base + slope1 * min(u, kink) / kink                                  for u <= kink
///                   + slope2 * (u - kink) / (10000 - kink)                                 for u >  kink
///         premium = amount * rate(u_after) * duration / (10000 * 365 days), rounded up, where u_after is the pool
///         utilization *after* the new cover is added (so large buyers pay for the capacity they consume).
contract PricingCurve is AccessControl {
    uint256 public constant BPS = 10_000;
    uint256 public constant YEAR = 365 days;
    uint256 public constant MAX_RATE_BPS = 50_000; // 500% APR hard ceiling

    struct Curve {
        uint32 baseRateBps;
        uint32 slope1Bps;
        uint32 slope2Bps;
        uint32 kinkBps;
        bool set;
    }

    mapping(uint8 productId => Curve) internal _curves;

    event CurveSet(uint8 indexed productId, uint32 baseRateBps, uint32 slope1Bps, uint32 slope2Bps, uint32 kinkBps);

    error InvalidCurve();
    error CurveNotSet(uint8 productId);

    constructor(address admin) {
        if (admin == address(0)) revert InvalidCurve();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setCurve(uint8 productId, uint32 baseRateBps, uint32 slope1Bps, uint32 slope2Bps, uint32 kinkBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (kinkBps == 0 || kinkBps >= BPS) revert InvalidCurve();
        if (uint256(baseRateBps) + slope1Bps + slope2Bps > MAX_RATE_BPS) revert InvalidCurve();
        _curves[productId] = Curve(baseRateBps, slope1Bps, slope2Bps, kinkBps, true);
        emit CurveSet(productId, baseRateBps, slope1Bps, slope2Bps, kinkBps);
    }

    function curveOf(uint8 productId) external view returns (Curve memory) {
        return _curves[productId];
    }

    /// @notice Annualised premium rate in bps at utilization `utilBps` (capped at 100%).
    function annualRateBps(uint8 productId, uint256 utilBps) public view returns (uint256) {
        Curve memory c = _curves[productId];
        if (!c.set) revert CurveNotSet(productId);
        if (utilBps > BPS) utilBps = BPS;
        if (utilBps <= c.kinkBps) {
            return c.baseRateBps + uint256(c.slope1Bps) * utilBps / c.kinkBps;
        }
        return c.baseRateBps + c.slope1Bps + uint256(c.slope2Bps) * (utilBps - c.kinkBps) / (BPS - c.kinkBps);
    }

    /// @notice Premium for `amount` of cover over `duration` seconds given pool state after the purchase.
    function quote(uint8 productId, uint256 amount, uint256 duration, uint256 lockedAfter, uint256 capital)
        external
        view
        returns (uint256 premium, uint256 rateBps)
    {
        uint256 utilBps = capital == 0 ? BPS : Math.mulDiv(lockedAfter, BPS, capital, Math.Rounding.Ceil);
        rateBps = annualRateBps(productId, utilBps);
        premium = Math.mulDiv(amount, rateBps * duration, BPS * YEAR, Math.Rounding.Ceil);
    }
}
