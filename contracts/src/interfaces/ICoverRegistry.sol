// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICoverRegistry {
    enum CoverStatus {
        None,
        Active,
        Claimed,
        Expired
    }

    struct Cover {
        uint8 productId;
        CoverStatus status;
        address asset;
        uint64 start;
        uint64 end;
        uint128 amount;
        uint128 premium;
    }

    function getCover(uint256 coverId) external view returns (Cover memory);
}
