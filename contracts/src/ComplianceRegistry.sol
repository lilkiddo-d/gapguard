// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ICompliance} from "./interfaces/ICompliance.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title ComplianceRegistry
/// @notice Pluggable gate for key actions (buy cover, deposit, cover transfer, stake). OFF by default: while
///         `enabled == false` every account is allowed. When enabled, an account passes if it is on the allowlist or,
///         optionally, if an external provider (e.g. a KYC attestation contract) approves it.
contract ComplianceRegistry is ICompliance, AccessControl {
    bool public enabled;
    ICompliance public provider;
    mapping(address account => bool) public allowlisted;

    event EnabledSet(bool enabled);
    event ProviderSet(address provider);
    event AllowlistSet(address indexed account, bool allowed);

    error ZeroAddress();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function isAllowed(address account, bytes32 action) external view returns (bool) {
        if (!enabled) return true;
        if (allowlisted[account]) return true;
        ICompliance p = provider;
        if (address(p) != address(0)) return p.isAllowed(account, action);
        return false;
    }

    function setEnabled(bool enabled_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        enabled = enabled_;
        emit EnabledSet(enabled_);
    }

    function setProvider(ICompliance provider_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        provider = provider_;
        emit ProviderSet(address(provider_));
    }

    /// @dev Bounded by calldata length chosen by the caller.
    function setAllowlisted(address[] calldata accounts, bool allowed) external onlyRole(Roles.COMPLIANCE_ROLE) {
        for (uint256 i; i < accounts.length; ++i) {
            allowlisted[accounts[i]] = allowed;
            emit AllowlistSet(accounts[i], allowed);
        }
    }
}
