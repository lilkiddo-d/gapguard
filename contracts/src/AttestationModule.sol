// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {GuardedAccess} from "./governance/GuardedAccess.sol";
import {IAttestationModule} from "./interfaces/IAttestationModule.sol";
import {IProjectTokenHooks} from "./interfaces/IProjectTokenHooks.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title AttestationModule
/// @notice Optimistic attestations with a dispute window, used by attestation-based triggers (Issuer Halt).
///         Lifecycle: Pending --(window passes)--> Accepted
///                    Pending --dispute--> Disputed --committee--> Accepted | Rejected
///                    Disputed --(arbitration timeout)--> Rejected (fail-safe for underwriters)
///         Who may dispute:
///           - $GAPG enabled: any staker bonding `disputeBond` of stake (slashed if the dispute is wrong),
///             plus the committee (no bond);
///           - $GAPG not set: only the Timelock-controlled committee (COMMITTEE_ROLE).
contract AttestationModule is IAttestationModule, GuardedAccess, ReentrancyGuard {
    struct Attestation {
        address resolver;
        bytes32 subject;
        address proposer;
        uint64 proposedAt;
        uint64 disputeDeadline;
        uint64 disputedAt;
        Status status;
        address disputer;
        uint256 bond;
    }

    IProjectTokenHooks public hooks;
    address public slashRecipient;
    uint64 public disputeWindow = 24 hours;
    uint64 public arbitrationWindow = 7 days;
    uint256 public disputeBond = 1_000e18;

    uint256 public attestationCount;
    mapping(uint256 id => Attestation) internal _attestations;

    event Proposed(uint256 indexed id, address indexed resolver, bytes32 indexed subject, address proposer, uint64 deadline);
    event Disputed(uint256 indexed id, address indexed disputer, uint256 bond);
    event Finalized(uint256 indexed id, Status status);
    event DisputeResolved(uint256 indexed id, bool attestationValid, address indexed disputer, uint256 bond);
    event ParamsSet(uint64 disputeWindow, uint64 arbitrationWindow, uint256 disputeBond);
    event HooksSet(address hooks, address slashRecipient);

    error WrongStatus(Status status);
    error WindowClosed();
    error WindowOpen();
    error NotAuthorizedDisputer();
    error InvalidParam();

    constructor(address admin, IProjectTokenHooks hooks_, address slashRecipient_) GuardedAccess(admin) {
        if (slashRecipient_ == address(0)) revert ZeroAddress();
        hooks = hooks_;
        slashRecipient = slashRecipient_;
    }

    function getAttestation(uint256 id) external view returns (Attestation memory) {
        return _attestations[id];
    }

    function statusOf(uint256 id) external view returns (Status) {
        return _attestations[id].status;
    }

    /// @notice Called by a resolver (RESOLVER_ROLE) on behalf of a keeper.
    function propose(bytes32 subject, address proposer)
        external
        onlyRole(Roles.RESOLVER_ROLE)
        whenNotPaused
        returns (uint256 id)
    {
        id = ++attestationCount;
        uint64 deadline = uint64(block.timestamp) + disputeWindow;
        _attestations[id] = Attestation({
            resolver: msg.sender,
            subject: subject,
            proposer: proposer,
            proposedAt: uint64(block.timestamp),
            disputeDeadline: deadline,
            disputedAt: 0,
            status: Status.Pending,
            disputer: address(0),
            bond: 0
        });
        emit Proposed(id, msg.sender, subject, proposer, deadline);
    }

    function canDispute(address account) public view returns (bool) {
        if (hasRole(Roles.COMMITTEE_ROLE, account)) return true;
        IProjectTokenHooks h = hooks;
        return address(h) != address(0) && h.tokenEnabled() && h.availableToBond(account) >= disputeBond;
    }

    function dispute(uint256 id) external nonReentrant whenNotPaused {
        Attestation storage a = _attestations[id];
        if (a.status != Status.Pending) revert WrongStatus(a.status);
        if (block.timestamp >= a.disputeDeadline) revert WindowClosed();
        bool bonded = !hasRole(Roles.COMMITTEE_ROLE, msg.sender);
        IProjectTokenHooks h = hooks;
        if (bonded && (address(h) == address(0) || !h.tokenEnabled())) revert NotAuthorizedDisputer();
        uint256 bond = bonded ? disputeBond : 0;
        // effects before the external bond lock (checks-effects-interactions)
        a.status = Status.Disputed;
        a.disputer = msg.sender;
        a.bond = bond;
        a.disputedAt = uint64(block.timestamp);
        emit Disputed(id, msg.sender, bond);
        if (bonded) h.lockBond(msg.sender, bond); // reverts (undoing the effects) if insufficient unbonded stake
    }

    /// @notice Anyone may finalize an undisputed attestation after its window.
    function finalize(uint256 id) external {
        Attestation storage a = _attestations[id];
        if (a.status == Status.Pending) {
            if (block.timestamp < a.disputeDeadline) revert WindowOpen();
            a.status = Status.Accepted;
            emit Finalized(id, Status.Accepted);
        } else if (a.status == Status.Disputed) {
            if (block.timestamp < uint256(a.disputedAt) + arbitrationWindow) revert WindowOpen();
            a.status = Status.Rejected;
            emit Finalized(id, Status.Rejected);
            _releaseBond(a);
        } else {
            revert WrongStatus(a.status);
        }
    }

    /// @notice Committee verdict on a disputed attestation.
    function resolveDispute(uint256 id, bool attestationValid) external onlyRole(Roles.COMMITTEE_ROLE) nonReentrant {
        Attestation storage a = _attestations[id];
        if (a.status != Status.Disputed) revert WrongStatus(a.status);
        a.status = attestationValid ? Status.Accepted : Status.Rejected;
        emit DisputeResolved(id, attestationValid, a.disputer, a.bond);
        emit Finalized(id, a.status);
        if (a.bond > 0) {
            uint256 bond = a.bond;
            a.bond = 0;
            if (attestationValid) hooks.slashBond(a.disputer, bond, slashRecipient);
            else hooks.releaseBond(a.disputer, bond);
        }
    }

    function setParams(uint64 disputeWindow_, uint64 arbitrationWindow_, uint256 disputeBond_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (disputeWindow_ < 1 hours || disputeWindow_ > 7 days) revert InvalidParam();
        if (arbitrationWindow_ < 1 days || arbitrationWindow_ > 30 days || disputeBond_ == 0) revert InvalidParam();
        disputeWindow = disputeWindow_;
        arbitrationWindow = arbitrationWindow_;
        disputeBond = disputeBond_;
        emit ParamsSet(disputeWindow_, arbitrationWindow_, disputeBond_);
    }

    function setHooks(IProjectTokenHooks hooks_, address slashRecipient_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (slashRecipient_ == address(0)) revert ZeroAddress();
        hooks = hooks_;
        slashRecipient = slashRecipient_;
        emit HooksSet(address(hooks_), slashRecipient_);
    }

    function _releaseBond(Attestation storage a) internal {
        if (a.bond > 0) {
            uint256 bond = a.bond;
            a.bond = 0;
            hooks.releaseBond(a.disputer, bond);
        }
    }
}
