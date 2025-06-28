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

    function transferOwnership(address newOwner) external; // Add this

    function ownerOf(uint256 tokenId) external view returns (address);

    function approve(address to, uint256 tokenId) external;
}
