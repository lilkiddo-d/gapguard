// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAttestationModule {
    enum Status {
        None,
        Pending,
        Disputed,
        Accepted,
        Rejected
    }

    function propose(bytes32 subject, address proposer) external returns (uint256 id);
    function statusOf(uint256 id) external view returns (Status);
}
