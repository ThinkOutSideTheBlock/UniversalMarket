// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract UniversalNFT is
    ERC721Upgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    IERC2981
{
    // Constants
    uint256 private constant MAX_ROYALTY = 1000; // 10%
    uint256 private constant MAX_BATCH_SIZE = 50;

    // State variables
    uint256 private _tokenIdCounter;
    string private _baseTokenURI;
    uint8 public assetCategory;

    struct RoyaltyInfo {
        address recipient;
        uint96 royaltyFraction; // Out of 10000 (2.5% = 250)
    }

    RoyaltyInfo private _defaultRoyalty;
    mapping(uint256 => RoyaltyInfo) private _tokenRoyalties;
    mapping(uint256 => string) private _tokenURIs;

    // Events
    event TokenMinted(
        uint256 indexed tokenId,
        address indexed to,
        string tokenURI
    );
    event RoyaltySet(
        uint256 indexed tokenId,
        address recipient,
        uint96 royaltyFraction
    );
    event DefaultRoyaltySet(address recipient, uint96 royaltyFraction);
    event BaseURIUpdated(string oldURI, string newURI);

    function initialize(
        string memory name,
        string memory symbol,
        address owner,
        string memory baseURI,
        uint8 _assetCategory
    ) external initializer {
        require(owner != address(0), "Invalid owner");
        require(bytes(name).length > 0, "Empty name");
        require(bytes(symbol).length > 0, "Empty symbol");

        __ERC721_init(name, symbol);
        __Ownable_init(owner);
        __ReentrancyGuard_init();
        __Pausable_init();

        _transferOwnership(owner);
        _baseTokenURI = baseURI;
        assetCategory = _assetCategory;
        _tokenIdCounter = 1;

        // Set default royalty to 2.5%
        _setDefaultRoyalty(owner, 250);
    }

    function mint(
        address to
    ) external onlyOwner whenNotPaused returns (uint256) {
        require(to != address(0), "Invalid recipient");

        uint256 tokenId = _tokenIdCounter;
        _tokenIdCounter++;

        _safeMint(to, tokenId);

        emit TokenMinted(tokenId, to, tokenURI(tokenId));
        return tokenId;
    }

    function mintWithURI(
        address to,
        string calldata tokenURI_
    ) external onlyOwner whenNotPaused returns (uint256) {
        require(to != address(0), "Invalid recipient");
        require(bytes(tokenURI_).length > 0, "Empty URI");

        uint256 tokenId = _tokenIdCounter;
        _tokenIdCounter++;

        _safeMint(to, tokenId);
        _setTokenURI(tokenId, tokenURI_);

        emit TokenMinted(tokenId, to, tokenURI_);
        return tokenId;
    }

    function batchMint(
        address[] calldata recipients
    ) external onlyOwner whenNotPaused returns (uint256[] memory) {
        require(recipients.length > 0, "Empty recipients");
        require(recipients.length <= MAX_BATCH_SIZE, "Too many recipients");

        uint256[] memory tokenIds = new uint256[](recipients.length);

        for (uint i = 0; i < recipients.length; i++) {
            require(recipients[i] != address(0), "Invalid recipient");

            uint256 tokenId = _tokenIdCounter;
            _tokenIdCounter++;

            _safeMint(recipients[i], tokenId);
            tokenIds[i] = tokenId;

            emit TokenMinted(tokenId, recipients[i], tokenURI(tokenId));
        }

        return tokenIds;
    }

    function burn(uint256 tokenId) external {
        require(
            _isAuthorized(ownerOf(tokenId), msg.sender, tokenId),
            "Not authorized to burn"
        );

        // Clear token URI if exists
        if (bytes(_tokenURIs[tokenId]).length > 0) {
            delete _tokenURIs[tokenId];
        }

        // Clear token royalty if exists
        if (_tokenRoyalties[tokenId].recipient != address(0)) {
            delete _tokenRoyalties[tokenId];
        }

        _burn(tokenId);
    }

    function _setTokenURI(uint256 tokenId, string memory tokenURI_) internal {
        _requireOwned(tokenId);
        _tokenURIs[tokenId] = tokenURI_;
    }

    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        _requireOwned(tokenId);

        string memory _tokenURI = _tokenURIs[tokenId];

        // If token-specific URI exists, return it
        if (bytes(_tokenURI).length > 0) {
            return _tokenURI;
        }

        // Otherwise return base URI + token ID
        return
            bytes(_baseTokenURI).length > 0
                ? string(
                    abi.encodePacked(_baseTokenURI, Strings.toString(tokenId))
                )
                : "";
    }

    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        string memory oldURI = _baseTokenURI;
        _baseTokenURI = newBaseURI;
        emit BaseURIUpdated(oldURI, newBaseURI);
    }

    function setTokenURI(
        uint256 tokenId,
        string calldata tokenURI_
    ) external onlyOwner {
        require(bytes(tokenURI_).length > 0, "Empty URI");
        _setTokenURI(tokenId, tokenURI_);
    }

    // Royalty functions (EIP-2981)
    function setDefaultRoyalty(
        address recipient,
        uint96 royaltyFraction
    ) external onlyOwner {
        _setDefaultRoyalty(recipient, royaltyFraction);
    }

    function setTokenRoyalty(
        uint256 tokenId,
        address recipient,
        uint96 royaltyFraction
    ) external onlyOwner {
        _requireOwned(tokenId);
        _setTokenRoyalty(tokenId, recipient, royaltyFraction);
    }

    function removeDefaultRoyalty() external onlyOwner {
        delete _defaultRoyalty;
    }

    function resetTokenRoyalty(uint256 tokenId) external onlyOwner {
        _requireOwned(tokenId);
        delete _tokenRoyalties[tokenId];
    }

    function _setDefaultRoyalty(
        address recipient,
        uint96 royaltyFraction
    ) internal {
        require(royaltyFraction <= MAX_ROYALTY, "Royalty too high");
        require(recipient != address(0), "Invalid recipient");

        _defaultRoyalty = RoyaltyInfo(recipient, royaltyFraction);
        emit DefaultRoyaltySet(recipient, royaltyFraction);
    }

    function _setTokenRoyalty(
        uint256 tokenId,
        address recipient,
        uint96 royaltyFraction
    ) internal {
        require(royaltyFraction <= MAX_ROYALTY, "Royalty too high");
        require(recipient != address(0), "Invalid recipient");

        _tokenRoyalties[tokenId] = RoyaltyInfo(recipient, royaltyFraction);
        emit RoyaltySet(tokenId, recipient, royaltyFraction);
    }

    function royaltyInfo(
        uint256 tokenId,
        uint256 salePrice
    ) external view override returns (address, uint256) {
        _requireOwned(tokenId);

        RoyaltyInfo memory royalty = _tokenRoyalties[tokenId];

        if (royalty.recipient == address(0)) {
            royalty = _defaultRoyalty;
        }

        uint256 royaltyAmount = (salePrice * royalty.royaltyFraction) / 10000;
        return (royalty.recipient, royaltyAmount);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC721Upgradeable, IERC165) returns (bool) {
        return
            interfaceId == type(IERC2981).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function totalSupply() external view returns (uint256) {
        return _tokenIdCounter - 1;
    }

    function exists(uint256 tokenId) external view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    // Pausable functionality
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override whenNotPaused returns (address) {
        return super._update(to, tokenId, auth);
    }

    // View functions for royalty info
    function getDefaultRoyalty() external view returns (address, uint96) {
        return (_defaultRoyalty.recipient, _defaultRoyalty.royaltyFraction);
    }

    function getTokenRoyalty(
        uint256 tokenId
    ) external view returns (address, uint96) {
        _requireOwned(tokenId);
        RoyaltyInfo memory royalty = _tokenRoyalties[tokenId];
        return (royalty.recipient, royalty.royaltyFraction);
    }
}
