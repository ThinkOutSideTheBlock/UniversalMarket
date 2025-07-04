// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFractionToken {
    function initialize(
        string memory name,
        string memory symbol,
        address nftContract,
        uint256 tokenId,
        uint256 totalSupply,
        address owner,
        uint256 liquidityAmount,
        address liquidityRecipient,
        uint8 assetCategory,
        string memory metadataURI
    ) external;

    function setEmergencyControls(address controls) external;
    function setRoyaltyDistributor(address distributor) external;
    function setAssetAttribute(
        string calldata key,
        string calldata value
    ) external;
    function burn(uint256 amount) external;
    function getHolders() external view returns (address[] memory);
}
