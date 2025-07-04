// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUniversalNFT {
    function initialize(
        string memory name,
        string memory symbol,
        address owner,
        string memory baseURI,
        uint8 assetCategory
    ) external;

    function mint(address to) external returns (uint256);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function transferOwnership(address newOwner) external;
}
