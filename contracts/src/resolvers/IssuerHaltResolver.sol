// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BaseResolver} from "./BaseResolver.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {IAttestationModule} from "../interfaces/IAttestationModule.sol";
import {IStockToken} from "../interfaces/IStockToken.sol";
import {Roles} from "../libraries/Roles.sol";

/// @title IssuerHaltResolver (product 3)
/// @notice Pays if a token's issuer pauses transfers (`paused() == true`) for at least `haltThreshold`.
///         The current pause state is verified on-chain; the halt *start* time comes from a keeper attestation
///         (read from the issuer's Paused event) and is bounded on-chain by permissionless `poke` checkpoints:
///         it can never precede the last time anyone observed the token unpaused. The attestation then goes
///         through the AttestationModule dispute window (bonded $GAPG stakers or the committee) before paying.
contract IssuerHaltResolver is BaseResolver, ReentrancyGuard {
    struct HaltClaim {
        address asset;
        uint64 start;
        uint64 observedUntil;
        uint256 attestationId;
        bool settled;
    }

    IAttestationModule public immutable attestations;
    uint32 public haltThreshold = 24 hours;

    mapping(address asset => uint64) public lastSeenUnpaused;
    mapping(address asset => uint64) public firstSeenPaused;
    mapping(address asset => bytes32) public pendingClaim;
    mapping(bytes32 eventId => HaltClaim) public claims;
    uint256 public pendingCount;
    uint256 public pausedSeenCount;

    event Poked(address indexed asset, bool paused);
    event HaltProposed(bytes32 indexed eventId, address indexed asset, uint64 start, uint64 observedUntil, uint256 attestationId);
    event HaltSettled(bytes32 indexed eventId, bool accepted);
    event ThresholdSet(uint32 haltThreshold);

    error NotPaused();
    error ClaimPending();
    error InvalidStart();
    error TooShort();
    error NotFinal();
    error UnknownClaim();

    constructor(address admin, IOracleAdapter oracle_, IAttestationModule attestations_)
        BaseResolver(3, admin, oracle_)
    {
        if (address(attestations_) == address(0)) revert ZeroAddress();
        attestations = attestations_;
    }

    function eventIdFor(address asset, uint64 start) public pure returns (bytes32) {
        return keccak256(abi.encode(uint8(3), asset, start));
    }

    /// @notice Permissionless checkpoint of the issuer pause flag.
    // zero = not observed paused
    // slither-disable-next-line incorrect-equality
    function poke(address asset) public returns (bool isPaused) {
        _requireEnabled(asset);
        isPaused = IStockToken(asset).paused();
        if (!isPaused) {
            lastSeenUnpaused[asset] = uint64(block.timestamp);
            if (firstSeenPaused[asset] != 0) {
                firstSeenPaused[asset] = 0;
                --pausedSeenCount;
            }
        } else if (firstSeenPaused[asset] == 0) {
            firstSeenPaused[asset] = uint64(block.timestamp);
            ++pausedSeenCount;
        }
        emit Poked(asset, isPaused);
    }

    /// @notice Keeper (or committee) attests that `asset` has been paused since `start` (from the Paused event).
    // nonReentrant; the only external call is the trusted AttestationModule, all other effects precede it
    // slither-disable-next-line reentrancy-no-eth
    function proposeHalt(address asset, uint64 start) external nonReentrant whenNotPaused returns (bytes32 eventId) {
        if (!hasRole(Roles.KEEPER_ROLE, msg.sender) && !hasRole(Roles.COMMITTEE_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, Roles.KEEPER_ROLE);
        }
        if (!poke(asset)) revert NotPaused();
        if (pendingClaim[asset] != bytes32(0)) revert ClaimPending();
        if (start <= lastSeenUnpaused[asset] || start > firstSeenPaused[asset]) revert InvalidStart();
        if (block.timestamp - start < haltThreshold) revert TooShort();
        eventId = eventIdFor(asset, start);
        if (_events[eventId].resolvedAt != 0 || claims[eventId].asset != address(0)) revert EventExists(eventId);
        // effects first; the attestation id returned by the trusted AttestationModule is recorded afterwards
        claims[eventId] = HaltClaim(asset, start, uint64(block.timestamp), 0, false);
        pendingClaim[asset] = eventId;
        ++pendingCount;
        uint256 attId = attestations.propose(eventId, msg.sender);
        claims[eventId].attestationId = attId;
        emit HaltProposed(eventId, asset, start, uint64(block.timestamp), attId);
    }

    /// @notice Permissionless: settle a claim once its attestation is final (Accepted pays, Rejected discards).
    function settle(bytes32 eventId) external nonReentrant returns (bool accepted) {
        HaltClaim storage c = claims[eventId];
        if (c.asset == address(0)) revert UnknownClaim();
        if (c.settled) revert EventExists(eventId);
        IAttestationModule.Status s = attestations.statusOf(c.attestationId);
        if (s != IAttestationModule.Status.Accepted && s != IAttestationModule.Status.Rejected) revert NotFinal();
        accepted = s == IAttestationModule.Status.Accepted;
        c.settled = true;
        pendingClaim[c.asset] = bytes32(0);
        --pendingCount;
        emit HaltSettled(eventId, accepted);
        if (accepted) _record(eventId, c.asset, c.start, true, c.observedUntil - c.start);
    }

    function canPurchase(address asset, uint64, uint64) external view returns (bool) {
        if (!assetEnabled[asset] || paused()) return false;
        if (pendingClaim[asset] != bytes32(0) || firstSeenPaused[asset] != 0) return false;
        return !IStockToken(asset).paused();
    }

    function withdrawalsBlocked() public view override returns (bool) {
        return pendingCount > 0 || pausedSeenCount > 0 || super.withdrawalsBlocked();
    }

    // call only proves paused() exists
    // slither-disable-next-line unused-return
    function setAssetEnabled(address asset, bool enabled) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        // must expose paused(); the value itself is irrelevant here
        if (enabled) IStockToken(asset).paused();
        if (!enabled && firstSeenPaused[asset] != 0) {
            firstSeenPaused[asset] = 0;
            --pausedSeenCount;
        }
        assetEnabled[asset] = enabled;
        emit AssetEnabled(asset, enabled);
    }

    function setHaltThreshold(uint32 threshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (threshold < 1 hours || threshold > 14 days) revert InvalidParam();
        haltThreshold = threshold;
        emit ThresholdSet(threshold);
    }
}
