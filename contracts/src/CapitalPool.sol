// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GuardedAccess} from "./governance/GuardedAccess.sol";
import {ICapitalPool} from "./interfaces/ICapitalPool.sol";
import {ICompliance} from "./interfaces/ICompliance.sol";
import {ITriggerResolver} from "./interfaces/ITriggerResolver.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title CapitalPool
/// @notice ERC-4626 underwriting vault for one cover product. Underwriters deposit the stablecoin, earn premiums
///         (vested linearly over PREMIUM_VEST to defeat just-in-time deposits) and absorb payouts.
///         Exits are two-step: `requestWithdraw` escrows shares (still exposed to losses) for `cooldown`, after which
///         they can be redeemed within `withdrawWindow`, only from free (unlocked) capital, and only while the
///         product's resolver reports no pending event.
contract CapitalPool is ERC4626, GuardedAccess, ReentrancyGuard, ICapitalPool {
    using SafeERC20 for IERC20;

    uint256 public constant PREMIUM_VEST = 7 days;
    uint256 public constant MIN_COOLDOWN = 7 days;
    uint256 public constant MAX_COOLDOWN = 60 days;

    uint8 public immutable productId;

    uint256 public lockedCapital;
    uint256 public cooldown = 14 days;
    uint256 public withdrawWindow = 7 days;
    uint256 public depositCap; // 0 = unlimited

    uint256 public vestingAmount; // unvested premium at `vestStart`
    uint64 public vestStart;
    uint64 public vestEnd;

    ICompliance public compliance;
    ITriggerResolver public withdrawGuard;

    struct WithdrawRequest {
        uint256 shares;
        uint64 unlockAt;
    }

    mapping(address owner => WithdrawRequest) public withdrawRequests;
    uint256 public totalRequestedShares;

    event CapitalLocked(uint256 amount, uint256 lockedCapital);
    event CapitalUnlocked(uint256 amount, uint256 lockedCapital);
    event PayoutSent(address indexed to, uint256 amount);
    event PremiumAdded(uint256 amount, uint256 vestingAmount, uint64 vestEnd);
    event WithdrawRequested(address indexed owner, uint256 shares, uint64 unlockAt);
    event WithdrawCancelled(address indexed owner, uint256 shares);
    event CooldownSet(uint256 cooldown, uint256 window);
    event DepositCapSet(uint256 cap);
    event ComplianceSet(address compliance);
    event WithdrawGuardSet(address guard);

    error InsufficientFreeCapital(uint256 requested, uint256 available);
    error NotOwner();
    error NoMaturedRequest();
    error WithdrawalsBlocked();
    error ExceedsRequest();
    error NotAllowed();
    error InvalidParam();

    constructor(IERC20 asset_, string memory name_, string memory symbol_, uint8 productId_, address admin)
        ERC4626(asset_)
        ERC20(name_, symbol_)
        GuardedAccess(admin)
    {
        productId = productId_;
    }

    // ---------------------------------------------------------------- accounting

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6; // virtual-shares defence against first-depositor inflation attacks
    }

    function asset() public view override(ERC4626, ICapitalPool) returns (address) {
        return super.asset();
    }

    function unvestedPremium() public view returns (uint256) {
        if (block.timestamp >= vestEnd) return 0;
        return Math.mulDiv(vestingAmount, vestEnd - block.timestamp, vestEnd - vestStart);
    }

    function totalAssets() public view override(ERC4626, ICapitalPool) returns (uint256) {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        uint256 unvested = unvestedPremium();
        return bal > unvested ? bal - unvested : 0;
    }

    function freeCapital() public view returns (uint256) {
        uint256 ta = totalAssets();
        return ta > lockedCapital ? ta - lockedCapital : 0;
    }

    // division-by-zero guard
    // slither-disable-next-line incorrect-equality
    function utilizationBps() external view returns (uint256) {
        uint256 ta = totalAssets();
        return ta == 0 ? 0 : Math.mulDiv(lockedCapital, 10_000, ta);
    }

    // ---------------------------------------------------------------- registry hooks

    function lockCapital(uint256 amount) external onlyRole(Roles.REGISTRY_ROLE) {
        uint256 newLocked = lockedCapital + amount;
        uint256 ta = totalAssets();
        if (newLocked > ta) revert InsufficientFreeCapital(amount, freeCapital());
        lockedCapital = newLocked;
        emit CapitalLocked(amount, newLocked);
    }

    function unlockCapital(uint256 amount) external onlyRole(Roles.REGISTRY_ROLE) {
        lockedCapital -= amount;
        emit CapitalUnlocked(amount, lockedCapital);
    }

    function payout(address to, uint256 amount) external onlyRole(Roles.REGISTRY_ROLE) nonReentrant {
        lockedCapital -= amount;
        emit PayoutSent(to, amount);
        IERC20(asset()).safeTransfer(to, amount);
    }

    /// @dev The registry transfers `amount` to this contract before calling.
    function addPremium(uint256 amount) external onlyRole(Roles.REGISTRY_ROLE) {
        uint256 pending = unvestedPremium() + amount;
        vestingAmount = pending;
        vestStart = uint64(block.timestamp);
        vestEnd = uint64(block.timestamp + PREMIUM_VEST);
        emit PremiumAdded(amount, pending, vestEnd);
    }

    // ---------------------------------------------------------------- deposits

    function maxDeposit(address) public view override returns (uint256) {
        if (paused()) return 0;
        if (depositCap == 0) return type(uint256).max;
        uint256 ta = totalAssets();
        return ta >= depositCap ? 0 : depositCap - ta;
    }

    // sentinel comparison with type(uint256).max
    // slither-disable-next-line incorrect-equality
    function maxMint(address receiver) public view override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        return maxAssets == type(uint256).max ? type(uint256).max : convertToShares(maxAssets);
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant whenNotPaused returns (uint256) {
        _checkCompliance(receiver);
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant whenNotPaused returns (uint256) {
        _checkCompliance(receiver);
        return super.mint(shares, receiver);
    }

    // ---------------------------------------------------------------- withdrawals

    function requestWithdraw(uint256 shares) external nonReentrant {
        if (shares == 0) revert InvalidParam();
        WithdrawRequest storage r = withdrawRequests[msg.sender];
        r.shares += shares;
        r.unlockAt = uint64(block.timestamp + cooldown);
        totalRequestedShares += shares;
        emit WithdrawRequested(msg.sender, r.shares, r.unlockAt);
        _transfer(msg.sender, address(this), shares);
    }

    function cancelWithdraw(uint256 shares) external nonReentrant {
        WithdrawRequest storage r = withdrawRequests[msg.sender];
        if (shares == 0 || shares > r.shares) revert ExceedsRequest();
        r.shares -= shares;
        totalRequestedShares -= shares;
        emit WithdrawCancelled(msg.sender, shares);
        _transfer(address(this), msg.sender, shares);
    }

    // zero check on a request counter
    // slither-disable-next-line incorrect-equality
    function isWithdrawable(address owner) public view returns (bool) {
        WithdrawRequest memory r = withdrawRequests[owner];
        if (paused() || r.shares == 0) return false;
        if (block.timestamp < r.unlockAt || block.timestamp > uint256(r.unlockAt) + withdrawWindow) return false;
        if (address(withdrawGuard) != address(0) && withdrawGuard.withdrawalsBlocked()) return false;
        return true;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (!isWithdrawable(owner)) return 0;
        uint256 freeShares = _convertToShares(freeCapital(), Math.Rounding.Floor);
        uint256 s = withdrawRequests[owner].shares;
        return s < freeShares ? s : freeShares;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return _convertToAssets(maxRedeem(owner), Math.Rounding.Floor);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        assets = previewRedeem(shares);
        _exit(assets, shares, receiver, owner);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        shares = previewWithdraw(assets);
        _exit(assets, shares, receiver, owner);
    }

    // zero checks on share counts, not balances
    // slither-disable-next-line incorrect-equality
    function _exit(uint256 assets, uint256 shares, address receiver, address owner) internal {
        if (owner != msg.sender) revert NotOwner();
        if (!isWithdrawable(owner)) revert NoMaturedRequest();
        WithdrawRequest storage r = withdrawRequests[owner];
        if (shares == 0 || shares > r.shares) revert ExceedsRequest();
        uint256 free = freeCapital();
        if (assets > free) revert InsufficientFreeCapital(assets, free);
        r.shares -= shares;
        totalRequestedShares -= shares;
        _burn(address(this), shares);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        IERC20(asset()).safeTransfer(receiver, assets);
    }

    // ---------------------------------------------------------------- admin

    function setCooldown(uint256 cooldown_, uint256 window_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (cooldown_ < MIN_COOLDOWN || cooldown_ > MAX_COOLDOWN || window_ < 1 days || window_ > 30 days) {
            revert InvalidParam();
        }
        cooldown = cooldown_;
        withdrawWindow = window_;
        emit CooldownSet(cooldown_, window_);
    }

    function setDepositCap(uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        depositCap = cap;
        emit DepositCapSet(cap);
    }

    function setCompliance(ICompliance compliance_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compliance = compliance_;
        emit ComplianceSet(address(compliance_));
    }

    function setWithdrawGuard(ITriggerResolver guard) external onlyRole(DEFAULT_ADMIN_ROLE) {
        withdrawGuard = guard;
        emit WithdrawGuardSet(address(guard));
    }

    function _checkCompliance(address receiver) internal view {
        ICompliance c = compliance;
        if (address(c) == address(0)) return;
        if (!c.isAllowed(msg.sender, Roles.ACTION_DEPOSIT) || !c.isAllowed(receiver, Roles.ACTION_DEPOSIT)) {
            revert NotAllowed();
        }
    }
}
