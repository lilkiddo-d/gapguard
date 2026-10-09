// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Common interface implemented by every per-product trigger resolver.
interface ITriggerResolver {
    /// @return asset Asset the event concerns.
    /// @return eventTime Timestamp at which the insured event began (cover must be active at this time).
    /// @return triggered True once the event is final and pays out.
    function getEvent(bytes32 eventId) external view returns (address asset, uint64 eventTime, bool triggered);

    /// @notice Whether new cover for `asset` over [start, end] may be sold right now (no known/pending event).
    function canPurchase(address asset, uint64 start, uint64 end) external view returns (bool);

    /// @notice True while an event is pending/suspected for this product, freezing underwriter exits.
    function withdrawalsBlocked() external view returns (bool);

    function productId() external view returns (uint8);
}
