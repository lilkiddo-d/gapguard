// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GuardedAccess} from "./governance/GuardedAccess.sol";
import {IProjectTokenHooks} from "./interfaces/IProjectTokenHooks.sol";
import {ICompliance} from "./interfaces/ICompliance.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title ProjectTokenHooks
/// @notice Optional $GAPG integration. The project token is NOT deployed by Gapguard: its address is set exactly once
///         through `setProjectToken` (DEFAULT_ADMIN_ROLE = Timelock). Until then every token feature is disabled and
///         the protocol runs without it (disputes fall back to the Timelock-controlled committee).
///         When enabled, stakers:
///           - earn a share of every cover premium (paid in the stablecoin, O(1) reward-per-share accounting);
///           - form the dispute layer for attestation-based triggers by bonding stake, which is slashable.
contract ProjectTokenHooks is IProjectTokenHooks, GuardedAccess, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant ACC = 1e36;
    uint256 public constant UNSTAKE_COOLDOWN = 7 days;

    IERC20 public immutable rewardToken;
    IERC20 public projectToken;
    ICompliance public compliance;

    uint256 public totalStaked;
    uint256 public accRewardPerShare;
    uint256 public undistributedRewards;

    struct StakerInfo {
        uint256 staked;
        uint256 bonded;
        uint256 rewardDebt;
        uint256 pendingRewards;
        uint256 unstakeAmount;
        uint64 unstakeAt;
    }

    mapping(address staker => StakerInfo) public stakers;

    event ProjectTokenSet(address indexed token);
    event Staked(address indexed staker, uint256 amount);
    event UnstakeRequested(address indexed staker, uint256 amount, uint64 unlockAt);
    event Unstaked(address indexed staker, uint256 amount);
    event RewardNotified(uint256 amount, uint256 accRewardPerShare);
    event RewardClaimed(address indexed staker, uint256 amount);
    event BondLocked(address indexed staker, uint256 amount);
    event BondReleased(address indexed staker, uint256 amount);
    event BondSlashed(address indexed staker, uint256 amount, address indexed to);
    event ComplianceSet(address compliance);

    error TokenAlreadySet();
    error TokenNotSet();
    error InvalidToken();
    error InvalidAmount();
    error InsufficientUnbonded();
    error CooldownActive();
    error NotAllowed();

    constructor(IERC20 rewardToken_, address admin) GuardedAccess(admin) {
        if (address(rewardToken_) == address(0)) revert ZeroAddress();
        rewardToken = rewardToken_;
    }

    // ---------------------------------------------------------------- token wiring

    /// @notice One-shot: wire the externally launched project token. Callable only by the Timelock.
    function setProjectToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(projectToken) != address(0)) revert TokenAlreadySet();
        if (token == address(0) || token.code.length == 0 || token == address(rewardToken)) revert InvalidToken();
        projectToken = IERC20(token);
        emit ProjectTokenSet(token);
    }

    function tokenEnabled() public view returns (bool) {
        return address(projectToken) != address(0);
    }

    function canReceiveRewards() external view returns (bool) {
        return tokenEnabled() && totalStaked > 0 && !paused();
    }

    function setCompliance(ICompliance compliance_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compliance = compliance_;
        emit ComplianceSet(address(compliance_));
    }

    // ---------------------------------------------------------------- staking

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (!tokenEnabled()) revert TokenNotSet();
        if (amount == 0) revert InvalidAmount();
        ICompliance c = compliance;
        if (address(c) != address(0) && !c.isAllowed(msg.sender, Roles.ACTION_STAKE)) revert NotAllowed();
        StakerInfo storage s = stakers[msg.sender];
        _accrue(s);
        uint256 before = projectToken.balanceOf(address(this));
        projectToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = projectToken.balanceOf(address(this)) - before; // fee-on-transfer safe
        s.staked += received;
        totalStaked += received;
        s.rewardDebt = Math.mulDiv(s.staked, accRewardPerShare, ACC);
        emit Staked(msg.sender, received);
    }

    /// @notice Starts the unstake cooldown. Unstaking stake stops earning immediately but remains slashable
    ///         only while bonded; bonded stake cannot be unstaked.
    function requestUnstake(uint256 amount) external nonReentrant {
        StakerInfo storage s = stakers[msg.sender];
        if (amount == 0 || amount > s.staked - s.bonded) revert InsufficientUnbonded();
        _accrue(s);
        s.staked -= amount;
        totalStaked -= amount;
        s.unstakeAmount += amount;
        s.unstakeAt = uint64(block.timestamp + UNSTAKE_COOLDOWN);
        s.rewardDebt = Math.mulDiv(s.staked, accRewardPerShare, ACC);
        emit UnstakeRequested(msg.sender, amount, s.unstakeAt);
    }

    function withdrawUnstaked() external nonReentrant {
        StakerInfo storage s = stakers[msg.sender];
        uint256 amount = s.unstakeAmount;
        if (amount == 0) revert InvalidAmount();
        if (block.timestamp < s.unstakeAt) revert CooldownActive();
        s.unstakeAmount = 0;
        emit Unstaked(msg.sender, amount);
        projectToken.safeTransfer(msg.sender, amount);
    }

    function claimRewards() external nonReentrant returns (uint256 amount) {
        StakerInfo storage s = stakers[msg.sender];
        _accrue(s);
        s.rewardDebt = Math.mulDiv(s.staked, accRewardPerShare, ACC);
        amount = s.pendingRewards;
        s.pendingRewards = 0;
        if (amount > 0) {
            emit RewardClaimed(msg.sender, amount);
            rewardToken.safeTransfer(msg.sender, amount);
        }
    }

    function pendingRewards(address staker) external view returns (uint256) {
        StakerInfo memory s = stakers[staker];
        return s.pendingRewards + Math.mulDiv(s.staked, accRewardPerShare, ACC) - s.rewardDebt;
    }

    // ---------------------------------------------------------------- registry hook

    /// @dev Registry transfers `amount` of rewardToken here before calling.
    function notifyReward(uint256 amount) external onlyRole(Roles.REGISTRY_ROLE) {
        uint256 total = totalStaked;
        uint256 distributable = amount + undistributedRewards;
        if (total == 0) {
            undistributedRewards = distributable;
            return;
        }
        undistributedRewards = 0;
        accRewardPerShare += Math.mulDiv(distributable, ACC, total);
        emit RewardNotified(distributable, accRewardPerShare);
    }

    // ---------------------------------------------------------------- dispute bonds

    function availableToBond(address staker) external view returns (uint256) {
        StakerInfo memory s = stakers[staker];
        return s.staked - s.bonded;
    }

    function lockBond(address staker, uint256 amount) external onlyRole(Roles.ATTESTATION_ROLE) {
        StakerInfo storage s = stakers[staker];
        if (amount > s.staked - s.bonded) revert InsufficientUnbonded();
        s.bonded += amount;
        emit BondLocked(staker, amount);
    }

    function releaseBond(address staker, uint256 amount) external onlyRole(Roles.ATTESTATION_ROLE) {
        stakers[staker].bonded -= amount;
        emit BondReleased(staker, amount);
    }

    function slashBond(address staker, uint256 amount, address to) external onlyRole(Roles.ATTESTATION_ROLE) {
        StakerInfo storage s = stakers[staker];
        _accrue(s);
        s.bonded -= amount;
        s.staked -= amount;
        totalStaked -= amount;
        s.rewardDebt = Math.mulDiv(s.staked, accRewardPerShare, ACC);
        emit BondSlashed(staker, amount, to);
        projectToken.safeTransfer(to, amount);
    }

    function _accrue(StakerInfo storage s) internal {
        uint256 accumulated = Math.mulDiv(s.staked, accRewardPerShare, ACC);
        if (accumulated > s.rewardDebt) s.pendingRewards += accumulated - s.rewardDebt;
    }
}
