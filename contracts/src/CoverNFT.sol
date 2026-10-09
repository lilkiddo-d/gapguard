// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ICompliance} from "./interfaces/ICompliance.sol";
import {ICoverRegistry} from "./interfaces/ICoverRegistry.sol";
import {Roles} from "./libraries/Roles.sol";

/// @title CoverNFT
/// @notice Transferable ERC-721 cover position. The current owner receives the payout when the trigger resolves.
///         Minting is restricted to the CoverRegistry; transfers respect the optional ComplianceRegistry.
contract CoverNFT is ERC721Enumerable, AccessControl {
    using Strings for uint256;

    ICoverRegistry public registry;
    ICompliance public compliance;

    event RegistrySet(address registry);
    event ComplianceSet(address compliance);

    error NotAllowed();
    error ZeroAddress();

    constructor(address admin) ERC721("Gapguard Cover", "GGCOVER") {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setRegistry(ICoverRegistry registry_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        registry = registry_;
        emit RegistrySet(address(registry_));
    }

    function setCompliance(ICompliance compliance_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compliance = compliance_;
        emit ComplianceSet(address(compliance_));
    }

    function mint(address to, uint256 tokenId) external onlyRole(Roles.MINTER_ROLE) {
        _mint(to, tokenId); // no receiver callback: avoids re-entrancy during cover purchase
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        ICompliance c = compliance;
        if (from != address(0) && to != address(0) && address(c) != address(0)) {
            if (!c.isAllowed(to, Roles.ACTION_TRANSFER_COVER)) revert NotAllowed();
        }
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        ICoverRegistry.Cover memory c = registry.getCover(tokenId);
        string memory head = string.concat(
            '{"name":"Gapguard Cover #',
            tokenId.toString(),
            '","description":"Parametric ',
            _productName(c.productId),
            ' cover. Pays the holder automatically if the on-chain trigger resolves during the cover period.",'
        );
        string memory attrs = string.concat(
            '"attributes":[{"trait_type":"Product","value":"',
            _productName(c.productId),
            '"},{"trait_type":"Asset","value":"',
            Strings.toHexString(c.asset),
            '"},{"trait_type":"Amount","value":"',
            uint256(c.amount).toString(),
            '"},'
        );
        string memory tail = string.concat(
            '{"trait_type":"Start","display_type":"date","value":',
            uint256(c.start).toString(),
            '},{"trait_type":"End","display_type":"date","value":',
            uint256(c.end).toString(),
            '},{"trait_type":"Status","value":"',
            _statusName(uint8(c.status)),
            '"}]}'
        );
        bytes memory json = bytes(string.concat(head, attrs, tail));
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    function _productName(uint8 id) internal pure returns (string memory) {
        if (id == 0) return "Weekend Gap";
        if (id == 1) return "Depeg";
        if (id == 2) return "Oracle Outage";
        if (id == 3) return "Issuer Halt";
        return "Unknown";
    }

    function _statusName(uint8 s) internal pure returns (string memory) {
        if (s == 1) return "Active";
        if (s == 2) return "Claimed";
        if (s == 3) return "Expired";
        return "None";
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Enumerable, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
