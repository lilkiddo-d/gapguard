// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Shared role identifiers. DEFAULT_ADMIN_ROLE is always held by the 48h Timelock after deployment.
library Roles {
    bytes32 internal constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 internal constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 internal constant REGISTRY_ROLE = keccak256("REGISTRY_ROLE");
    bytes32 internal constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    bytes32 internal constant ATTESTATION_ROLE = keccak256("ATTESTATION_ROLE");
    bytes32 internal constant COMMITTEE_ROLE = keccak256("COMMITTEE_ROLE");
    bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 internal constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");

    bytes32 internal constant ACTION_BUY_COVER = keccak256("BUY_COVER");
    bytes32 internal constant ACTION_DEPOSIT = keccak256("DEPOSIT");
    bytes32 internal constant ACTION_TRANSFER_COVER = keccak256("TRANSFER_COVER");
    bytes32 internal constant ACTION_STAKE = keccak256("STAKE");
}
