// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICompliance {
    function isAllowed(address account, bytes32 action) external view returns (bool);
}
