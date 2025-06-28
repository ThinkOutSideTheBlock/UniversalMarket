// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFractionToken {
    function initialize(
        string calldata name,
        string calldata symbol,
        address nftContract,
        uint256 tokenId,
        uint256 totalSupply,
        address owner,
        uint256 liquidityAmount,
        address liquidityRecipient
    ) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function proposeBuyout(uint256 pricePerFraction) external payable;
    function acceptBuyout(uint256 fractions) external;
    function executeBuyout() external;
    function redeemNFT() external;
    function getTimeWeightedBalance(
        address user
    ) external view returns (uint256);
    function getBuyoutInfo()
        external
        view
        returns (address, uint256, uint256, uint256, bool, bool);
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);
}
