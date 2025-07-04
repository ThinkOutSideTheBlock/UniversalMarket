// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import "./HybridLiquidityEngine.sol";
import "./FRACToken.sol";
import "./RoyaltyDistributor.sol";
import "./EmergencyControls.sol";
import "./interfaces/IUniversalNFT.sol";
import "./interfaces/IFractionToken.sol";

contract UniversalAssetFactory is
    Ownable,
    ReentrancyGuard,
    Pausable,
    IERC721Receiver
{
    using ERC165Checker for address;

    // Immutable addresses - FIXED: Using address payable for contracts with receive() functions
    address public immutable MASTER_NFT;
    address public immutable MASTER_FRACTION;
    address public immutable MASTER_ROYALTY_DISTRIBUTOR;
    HybridLiquidityEngine public immutable LIQUIDITY_ENGINE;
    FRACToken public immutable FRAC_TOKEN;
    EmergencyControls public immutable EMERGENCY_CONTROLS;

    // Constants
    uint256 public constant MAX_FEE = 1000; // 10% max
    uint256 public constant MIN_FRACTION_SUPPLY = 1000;
    uint256 public constant MAX_FRACTION_SUPPLY = 10_000_000;
    uint256 private constant LIQUIDITY_PERCENTAGE = 10; // 10%
    uint256 private constant MAX_SLIPPAGE = 1000; // 10%

    // Asset Categories with different fee structures
    enum AssetCategory {
        DIGITAL_ART, // 1.0%
        MUSIC_RIGHTS, // 2.0%
        REAL_ESTATE, // 0.5%
        LUXURY_ITEMS, // 1.5%
        INTELLECTUAL_PROPERTY, // 2.5%
        COLLECTIBLES, // 1.2%
        GAMING_ASSETS, // 0.8%
        UTILITY_TOKENS // 0.3%
    }

    enum LiquidityType {
        NONE,
        ETH_ONLY,
        FRAC_ONLY,
        BOTH
    }

    struct CategoryConfig {
        uint256 platformFeeRate; // Out of 10000
        uint256 minFractionSupply;
        uint256 maxFractionSupply;
        bool requiresVerification;
        bool allowsRoyalties;
    }

    struct AssetMetadata {
        string primaryURI;
        string[] mediaURIs;
        mapping(string => string) attributes;
        string[] attributeKeys;
        bytes32 verificationHash;
        uint256 lastUpdated;
    }

    struct Asset {
        address nftContract;
        address fractionContract;
        address royaltyDistributor;
        address creator;
        uint256 tokenId;
        uint256 createdAt;
        bool isActive;
        AssetCategory category;
        LiquidityType liquidityType;
        uint256 totalValue; // Updated from AMM prices
        uint256 totalRoyalties;
    }

    // State variables
    mapping(AssetCategory => CategoryConfig) public categoryConfigs;
    mapping(address => bool) public whitelistedNFTs;
    mapping(address => bool) public verifiedCreators;
    bool public requireWhitelist = false;

    // Storage
    mapping(bytes32 => Asset) public assets;
    mapping(bytes32 => AssetMetadata) private assetMetadata;
    mapping(address => bytes32[]) public userAssets;
    mapping(AssetCategory => bytes32[]) public categoryAssets;
    bytes32[] public allAssets;

    // Treasury
    address public treasury;
    mapping(AssetCategory => uint256) public categoryRevenue;
    uint256 public totalRevenue;

    // Events
    event AssetCreated(
        bytes32 indexed assetId,
        address indexed creator,
        address nftContract,
        address fractionContract,
        address royaltyDistributor,
        uint256 tokenId,
        AssetCategory category,
        LiquidityType liquidityType
    );
    event AssetFractionalized(
        bytes32 indexed assetId,
        address fractionContract,
        uint256 totalSupply,
        uint256 ethLiquidity,
        uint256 fracLiquidity
    );
    event PlatformFeesCollected(AssetCategory category, uint256 amount);
    event CategoryConfigUpdated(
        AssetCategory category,
        uint256 feeRate,
        bool requiresVerification
    );
    event NFTWhitelisted(address indexed nftContract, bool whitelisted);
    event CreatorVerified(address indexed creator, bool verified);
    event TreasuryUpdated(
        address indexed oldTreasury,
        address indexed newTreasury
    );
    event AssetMetadataUpdated(
        bytes32 indexed assetId,
        string key,
        string value
    );

    // FIXED: Constructor parameters using address payable where needed
    constructor(
        address _masterNFT,
        address _masterFraction,
        address _masterRoyaltyDistributor,
        address payable _liquidityEngine, // FIXED: payable
        address _fracToken,
        address payable _emergencyControls, // FIXED: payable
        address _treasury
    ) Ownable(msg.sender) {
        require(_masterNFT != address(0), "Invalid master NFT");
        require(_masterFraction != address(0), "Invalid master fraction");
        require(
            _masterRoyaltyDistributor != address(0),
            "Invalid master royalty"
        );
        require(_liquidityEngine != address(0), "Invalid liquidity engine");
        require(_fracToken != address(0), "Invalid FRAC token");
        require(_emergencyControls != address(0), "Invalid emergency controls");
        require(_treasury != address(0), "Invalid treasury");

        MASTER_NFT = _masterNFT;
        MASTER_FRACTION = _masterFraction;
        MASTER_ROYALTY_DISTRIBUTOR = _masterRoyaltyDistributor;
        LIQUIDITY_ENGINE = HybridLiquidityEngine(_liquidityEngine); // FIXED: Now works with payable
        FRAC_TOKEN = FRACToken(_fracToken);
        EMERGENCY_CONTROLS = EmergencyControls(_emergencyControls); // FIXED: Now works with payable
        treasury = _treasury;

        _initializeCategoryConfigs();
    }

    function _initializeCategoryConfigs() internal {
        categoryConfigs[AssetCategory.DIGITAL_ART] = CategoryConfig(
            100,
            1000,
            1000000,
            false,
            true
        );
        categoryConfigs[AssetCategory.MUSIC_RIGHTS] = CategoryConfig(
            200,
            5000,
            5000000,
            true,
            true
        );
        categoryConfigs[AssetCategory.REAL_ESTATE] = CategoryConfig(
            50,
            10000,
            10000000,
            true,
            true
        );
        categoryConfigs[AssetCategory.LUXURY_ITEMS] = CategoryConfig(
            150,
            1000,
            1000000,
            true,
            true
        );
        categoryConfigs[AssetCategory.INTELLECTUAL_PROPERTY] = CategoryConfig(
            250,
            5000,
            5000000,
            true,
            true
        );
        categoryConfigs[AssetCategory.COLLECTIBLES] = CategoryConfig(
            120,
            1000,
            1000000,
            false,
            true
        );
        categoryConfigs[AssetCategory.GAMING_ASSETS] = CategoryConfig(
            80,
            1000,
            5000000,
            false,
            false
        );
        categoryConfigs[AssetCategory.UTILITY_TOKENS] = CategoryConfig(
            30,
            10000,
            10000000,
            false,
            false
        );
    }

    modifier validNFT(address nftContract) {
        require(_isValidNFT(nftContract), "Invalid or non-whitelisted NFT");
        _;
    }

    modifier validCategory(AssetCategory category) {
        require(
            uint8(category) <= uint8(AssetCategory.UTILITY_TOKENS),
            "Invalid category"
        );
        _;
    }

    modifier whenSystemNotPaused() {
        require(
            !EMERGENCY_CONTROLS.isContractPaused(address(this)),
            "System paused"
        );
        require(!paused(), "Factory paused");
        _;
    }

    modifier validSlippage(uint256 slippage) {
        require(slippage <= MAX_SLIPPAGE, "Slippage too high");
        _;
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function createAsset(
        string calldata name,
        string calldata symbol,
        string calldata metadataURI,
        AssetCategory assetCategory,
        bool shouldFractionalize,
        uint256 fractionSupply,
        LiquidityType liquidityType,
        uint256 fracAmount,
        uint256 maxSlippage,
        string[] calldata mediaURIs,
        string[] calldata attributeKeys,
        string[] calldata attributeValues
    )
        external
        payable
        nonReentrant
        whenSystemNotPaused
        validCategory(assetCategory)
        validSlippage(maxSlippage)
        returns (
            bytes32 assetId,
            address nft,
            address fraction,
            address payable royaltyDist // FIXED: address payable
        )
    {
        require(bytes(name).length > 0, "Empty name");
        require(bytes(symbol).length > 0, "Empty symbol");
        require(
            attributeKeys.length == attributeValues.length,
            "Attribute arrays mismatch"
        );

        CategoryConfig memory config = categoryConfigs[assetCategory];
        if (config.requiresVerification) {
            require(verifiedCreators[msg.sender], "Creator not verified");
        }

        assetId = keccak256(
            abi.encodePacked(
                msg.sender,
                block.timestamp,
                name,
                block.prevrandao
            )
        );

        // 1) Deploy & init NFT
        bytes32 nftSalt = keccak256(abi.encodePacked(assetId, "NFT"));
        nft = Clones.cloneDeterministic(MASTER_NFT, nftSalt);
        IUniversalNFT(nft).initialize(
            name,
            symbol,
            address(this),
            metadataURI,
            uint8(assetCategory)
        );
        uint256 tokenId = IUniversalNFT(nft).mint(address(this));

        // 2) Deploy royalty distributor if category allows
        if (config.allowsRoyalties) {
            bytes32 royaltySalt = keccak256(
                abi.encodePacked(assetId, "ROYALTY")
            );
            address royaltyDistAddr = Clones.cloneDeterministic(
                MASTER_ROYALTY_DISTRIBUTOR,
                royaltySalt
            );
            royaltyDist = payable(royaltyDistAddr); // FIXED: Explicit payable conversion
            RoyaltyDistributor(royaltyDist).initialize(); // FIXED: Now works with payable
        }

        if (!shouldFractionalize) {
            IUniversalNFT(nft).transferFrom(address(this), msg.sender, tokenId);
            IUniversalNFT(nft).transferOwnership(msg.sender);
        } else {
            require(
                fractionSupply >= config.minFractionSupply &&
                    fractionSupply <= config.maxFractionSupply,
                "Invalid supply range"
            );
            require(liquidityType != LiquidityType.NONE, "Specify liquidity");

            // 3) Deploy & init FractionToken clone
            bytes32 fracSalt = keccak256(abi.encodePacked(assetId, "FRAC"));
            fraction = Clones.cloneDeterministic(MASTER_FRACTION, fracSalt);

            string memory fracName = string(
                abi.encodePacked("Fractions of ", name)
            );
            string memory fracSymbol = string(abi.encodePacked("f", symbol));

            uint256 liquidityTokens = fractionSupply / LIQUIDITY_PERCENTAGE;

            IFractionToken(fraction).initialize(
                fracName,
                fracSymbol,
                nft,
                tokenId,
                fractionSupply,
                msg.sender,
                liquidityTokens,
                address(this),
                uint8(assetCategory),
                metadataURI
            );

            // Set emergency controls and royalty distributor
            IFractionToken(fraction).setEmergencyControls(
                address(EMERGENCY_CONTROLS)
            );
            if (royaltyDist != address(0)) {
                IFractionToken(fraction).setRoyaltyDistributor(
                    address(royaltyDist)
                );
            }

            // Set asset attributes
            for (uint i = 0; i < attributeKeys.length; i++) {
                IFractionToken(fraction).setAssetAttribute(
                    attributeKeys[i],
                    attributeValues[i]
                );
            }

            // Escrow NFT
            IUniversalNFT(nft).transferFrom(address(this), fraction, tokenId);

            // 4) Seed liquidity with platform fee collection
            _addInitialLiquidity(
                fraction,
                liquidityType,
                fracAmount,
                assetCategory
            );

            IUniversalNFT(nft).transferOwnership(msg.sender);

            emit AssetFractionalized(
                assetId,
                fraction,
                fractionSupply,
                msg.value,
                fracAmount
            );
        }

        // Store asset metadata
        _storeAssetMetadata(
            assetId,
            metadataURI,
            mediaURIs,
            attributeKeys,
            attributeValues
        );

        // Store asset info
        assets[assetId] = Asset({
            nftContract: nft,
            fractionContract: fraction,
            royaltyDistributor: address(royaltyDist),
            creator: msg.sender,
            tokenId: tokenId,
            createdAt: block.timestamp,
            isActive: true,
            category: assetCategory,
            liquidityType: liquidityType,
            totalValue: 0,
            totalRoyalties: 0
        });

        userAssets[msg.sender].push(assetId);
        categoryAssets[assetCategory].push(assetId);
        allAssets.push(assetId);

        emit AssetCreated(
            assetId,
            msg.sender,
            nft,
            fraction,
            address(royaltyDist),
            tokenId,
            assetCategory,
            liquidityType
        );
        return (assetId, nft, fraction, royaltyDist);
    }

    function _addInitialLiquidity(
        address fractionToken,
        LiquidityType liquidityType,
        uint256 fracAmount,
        AssetCategory category
    ) internal {
        uint256 liqBal = IERC20(fractionToken).balanceOf(address(this));
        IERC20(fractionToken).approve(address(LIQUIDITY_ENGINE), liqBal);

        CategoryConfig memory config = categoryConfigs[category];
        uint256 totalFees = 0;

        // Declare variables at the top
        uint256 totalPortion;
        uint256 ethPortion;
        uint256 tokenPortion;

        if (
            liquidityType == LiquidityType.ETH_ONLY ||
            liquidityType == LiquidityType.BOTH
        ) {
            require(msg.value > 0, "ETH required");

            // Calculate and collect platform fee
            uint256 ethFee = (msg.value * config.platformFeeRate) / 10000;
            uint256 ethForLiquidity = msg.value - ethFee;
            totalFees += ethFee;

            // Calculate portions properly
            totalPortion = liquidityType == LiquidityType.BOTH
                ? liqBal / 2
                : liqBal;
            ethPortion = ethForLiquidity;
            tokenPortion = totalPortion;

            LIQUIDITY_ENGINE.createETHPool{value: ethPortion}(
                fractionToken,
                tokenPortion
            );
        }

        if (
            liquidityType == LiquidityType.FRAC_ONLY ||
            liquidityType == LiquidityType.BOTH
        ) {
            require(fracAmount > 0, "FRAC required");

            // Calculate FRAC fee (in ETH equivalent if any ETH was sent)
            if (msg.value > 0 && liquidityType == LiquidityType.BOTH) {
                uint256 fracFee = (msg.value * config.platformFeeRate) / 20000; // Half the ETH fee rate
                totalFees += fracFee;
            }

            FRAC_TOKEN.transferFrom(msg.sender, address(this), fracAmount);
            FRAC_TOKEN.approve(address(LIQUIDITY_ENGINE), fracAmount);

            tokenPortion = liquidityType == LiquidityType.BOTH
                ? liqBal / 2
                : liqBal;

            LIQUIDITY_ENGINE.createFRACPool(
                fractionToken,
                fracAmount,
                tokenPortion
            );
        }

        // Transfer collected fees to treasury
        if (totalFees > 0) {
            (bool success, ) = payable(treasury).call{value: totalFees}("");
            require(success, "Fee transfer failed");

            categoryRevenue[category] += totalFees;
            totalRevenue += totalFees;

            emit PlatformFeesCollected(category, totalFees);
        }
    }

    function _storeAssetMetadata(
        bytes32 assetId,
        string calldata primaryURI,
        string[] calldata mediaURIs,
        string[] calldata keys,
        string[] calldata values
    ) internal {
        AssetMetadata storage metadata = assetMetadata[assetId];
        metadata.primaryURI = primaryURI;
        metadata.mediaURIs = mediaURIs;
        metadata.lastUpdated = block.timestamp;

        for (uint i = 0; i < keys.length; i++) {
            if (bytes(metadata.attributes[keys[i]]).length == 0) {
                metadata.attributeKeys.push(keys[i]);
            }
            metadata.attributes[keys[i]] = values[i];
        }
    }

    function fractionalizeExisting(
        address existingNFT,
        uint256 tokenId,
        uint256 fractionSupply,
        string calldata fractionName,
        string calldata fractionSymbol,
        AssetCategory category,
        LiquidityType liquidityType,
        uint256 fracAmount,
        uint256 maxSlippage,
        string[] calldata attributeKeys,
        string[] calldata attributeValues
    )
        external
        payable
        nonReentrant
        whenSystemNotPaused
        validNFT(existingNFT)
        validCategory(category)
        validSlippage(maxSlippage)
        returns (
            address fraction,
            address payable royaltyDist // FIXED: address payable
        )
    {
        require(
            IERC721(existingNFT).ownerOf(tokenId) == msg.sender,
            "Not owner"
        );

        CategoryConfig memory config = categoryConfigs[category];
        require(
            fractionSupply >= config.minFractionSupply &&
                fractionSupply <= config.maxFractionSupply,
            "Invalid supply range"
        );
        require(liquidityType != LiquidityType.NONE, "Specify liquidity");
        require(bytes(fractionName).length > 0, "Empty name");
        require(bytes(fractionSymbol).length > 0, "Empty symbol");
        require(
            attributeKeys.length == attributeValues.length,
            "Attribute arrays mismatch"
        );

        if (config.requiresVerification) {
            require(verifiedCreators[msg.sender], "Creator not verified");
        }

        bytes32 assetId = keccak256(
            abi.encodePacked(existingNFT, tokenId, block.timestamp, msg.sender)
        );

        // Deploy royalty distributor if category allows
        if (config.allowsRoyalties) {
            bytes32 royaltySalt = keccak256(
                abi.encodePacked(assetId, "ROYALTY")
            );
            address royaltyDistAddr = Clones.cloneDeterministic(
                MASTER_ROYALTY_DISTRIBUTOR,
                royaltySalt
            );
            royaltyDist = payable(royaltyDistAddr); // FIXED: Explicit payable conversion
            RoyaltyDistributor(royaltyDist).initialize(); // FIXED: Now works with payable
        }

        bytes32 fracSalt = keccak256(abi.encodePacked(assetId, "FRAC"));
        fraction = Clones.cloneDeterministic(MASTER_FRACTION, fracSalt);

        uint256 liquidityTokens = fractionSupply / LIQUIDITY_PERCENTAGE;
        IFractionToken(fraction).initialize(
            fractionName,
            fractionSymbol,
            existingNFT,
            tokenId,
            fractionSupply,
            msg.sender,
            liquidityTokens,
            address(this),
            uint8(category),
            ""
        );

        // Set emergency controls and royalty distributor
        IFractionToken(fraction).setEmergencyControls(
            address(EMERGENCY_CONTROLS)
        );
        if (royaltyDist != address(0)) {
            IFractionToken(fraction).setRoyaltyDistributor(
                address(royaltyDist)
            );
        }

        // Set asset attributes
        for (uint i = 0; i < attributeKeys.length; i++) {
            IFractionToken(fraction).setAssetAttribute(
                attributeKeys[i],
                attributeValues[i]
            );
        }

        IERC721(existingNFT).transferFrom(msg.sender, fraction, tokenId);
        _addInitialLiquidity(fraction, liquidityType, fracAmount, category);

        // Store asset info
        assets[assetId] = Asset({
            nftContract: existingNFT,
            fractionContract: fraction,
            royaltyDistributor: address(royaltyDist),
            creator: msg.sender,
            tokenId: tokenId,
            createdAt: block.timestamp,
            isActive: true,
            category: category,
            liquidityType: liquidityType,
            totalValue: 0,
            totalRoyalties: 0
        });

        userAssets[msg.sender].push(assetId);
        categoryAssets[category].push(assetId);
        allAssets.push(assetId);

        emit AssetFractionalized(
            assetId,
            fraction,
            fractionSupply,
            msg.value,
            fracAmount
        );
        return (fraction, royaltyDist);
    }

    // Category management
    function setCategoryConfig(
        AssetCategory category,
        uint256 feeRate,
        uint256 minSupply,
        uint256 maxSupply,
        bool requiresVerification,
        bool allowsRoyalties
    ) external onlyOwner validCategory(category) {
        require(feeRate <= MAX_FEE, "Fee too high");

        categoryConfigs[category] = CategoryConfig({
            platformFeeRate: feeRate,
            minFractionSupply: minSupply,
            maxFractionSupply: maxSupply,
            requiresVerification: requiresVerification,
            allowsRoyalties: allowsRoyalties
        });

        emit CategoryConfigUpdated(category, feeRate, requiresVerification);
    }

    function setCreatorVerification(
        address creator,
        bool verified
    ) external onlyOwner {
        verifiedCreators[creator] = verified;
        emit CreatorVerified(creator, verified);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Invalid treasury");
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    function updateAssetMetadata(
        bytes32 assetId,
        string calldata key,
        string calldata value
    ) external {
        Asset memory asset = assets[assetId];
        require(
            asset.creator == msg.sender || msg.sender == owner(),
            "Not authorized"
        );

        AssetMetadata storage metadata = assetMetadata[assetId];
        if (bytes(metadata.attributes[key]).length == 0) {
            metadata.attributeKeys.push(key);
        }
        metadata.attributes[key] = value;
        metadata.lastUpdated = block.timestamp;

        emit AssetMetadataUpdated(assetId, key, value);
    }

    function _isValidNFT(address nftContract) internal view returns (bool) {
        if (nftContract.code.length == 0) return false;
        if (!nftContract.supportsInterface(type(IERC721).interfaceId))
            return false;
        if (requireWhitelist && !whitelistedNFTs[nftContract]) return false;
        return true;
    }

    // Admin functions
    function setWhitelistMode(bool _requireWhitelist) external onlyOwner {
        requireWhitelist = _requireWhitelist;
    }

    function whitelistNFT(
        address nftContract,
        bool whitelisted
    ) external onlyOwner {
        require(_isValidNFTContract(nftContract), "Invalid NFT contract");
        whitelistedNFTs[nftContract] = whitelisted;
        emit NFTWhitelisted(nftContract, whitelisted);
    }

    function _isValidNFTContract(
        address nftContract
    ) internal view returns (bool) {
        return
            nftContract.code.length > 0 &&
            nftContract.supportsInterface(type(IERC721).interfaceId);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw() external onlyOwner whenPaused {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success, ) = payable(treasury).call{value: balance}("");
            require(success, "Emergency withdraw failed");
        }
    }

    // View functions
    function getAssetMetadata(
        bytes32 assetId
    )
        external
        view
        returns (
            string memory primaryURI,
            string[] memory mediaURIs,
            string[] memory attributeKeys,
            string[] memory attributeValues,
            uint256 lastUpdated
        )
    {
        AssetMetadata storage metadata = assetMetadata[assetId];
        attributeKeys = metadata.attributeKeys;
        attributeValues = new string[](attributeKeys.length);

        for (uint i = 0; i < attributeKeys.length; i++) {
            attributeValues[i] = metadata.attributes[attributeKeys[i]];
        }

        return (
            metadata.primaryURI,
            metadata.mediaURIs,
            attributeKeys,
            attributeValues,
            metadata.lastUpdated
        );
    }

    function getUserAssets(
        address user
    ) external view returns (bytes32[] memory) {
        return userAssets[user];
    }

    function getCategoryAssets(
        AssetCategory category
    ) external view returns (bytes32[] memory) {
        return categoryAssets[category];
    }

    function getAllAssets() external view returns (bytes32[] memory) {
        return allAssets;
    }

    function getAssetDetails(
        bytes32 assetId
    ) external view returns (Asset memory) {
        return assets[assetId];
    }

    function getCategoryRevenue(
        AssetCategory category
    ) external view returns (uint256) {
        return categoryRevenue[category];
    }

    function getTotalRevenue() external view returns (uint256) {
        return totalRevenue;
    }

    function isCreatorVerified(address creator) external view returns (bool) {
        return verifiedCreators[creator];
    }

    function getCategoryConfig(
        AssetCategory category
    ) external view returns (CategoryConfig memory) {
        return categoryConfigs[category];
    }

    receive() external payable {
        // Allow contract to receive ETH
    }
}
