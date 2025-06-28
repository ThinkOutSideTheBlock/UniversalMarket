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
import "./interfaces/IUniversalNFT.sol";
import "./interfaces/IFractionToken.sol";

contract UniversalAssetFactory is
    Ownable,
    ReentrancyGuard,
    Pausable,
    IERC721Receiver
{
    using ERC165Checker for address;

    // Immutable addresses
    address public immutable MASTER_NFT;
    address public immutable MASTER_FRACTION;
    HybridLiquidityEngine public immutable LIQUIDITY_ENGINE;
    FRACToken public immutable FRAC_TOKEN;

    // Constants
    uint256 public constant MAX_FEE = 1000; // 10% max
    uint256 public constant MIN_FRACTION_SUPPLY = 1000;
    uint256 public constant MAX_FRACTION_SUPPLY = 10_000_000;
    uint256 private constant LIQUIDITY_PERCENTAGE = 10; // 10%

    // State variables
    uint256 public platformFee = 250; // 2.5%
    mapping(address => bool) public whitelistedNFTs;
    bool public requireWhitelist = false;

    enum LiquidityType {
        NONE,
        ETH_ONLY,
        FRAC_ONLY,
        BOTH
    }

    struct Asset {
        address nftContract;
        address fractionContract;
        address creator;
        uint256 tokenId;
        uint256 createdAt;
        bool isActive;
        LiquidityType liquidityType;
    }

    // Storage
    mapping(bytes32 => Asset) public assets;
    mapping(address => bytes32[]) public userAssets;
    bytes32[] public allAssets;

    // Events
    event AssetCreated(
        bytes32 indexed assetId,
        address indexed creator,
        address nftContract,
        address fractionContract,
        uint256 tokenId,
        LiquidityType liquidityType
    );
    event AssetFractionalized(
        bytes32 indexed assetId,
        address fractionContract,
        uint256 totalSupply,
        uint256 ethLiquidity,
        uint256 fracLiquidity
    );
    event NFTWhitelisted(address indexed nftContract, bool whitelisted);
    event WhitelistModeChanged(bool requireWhitelist);
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);

    constructor(
        address _masterNFT,
        address _masterFraction,
        address _liquidityEngine,
        address _fracToken
    ) Ownable(msg.sender) {
        require(_masterNFT != address(0), "Invalid master NFT");
        require(_masterFraction != address(0), "Invalid master fraction");
        require(_liquidityEngine != address(0), "Invalid liquidity engine");
        require(_fracToken != address(0), "Invalid FRAC token");

        MASTER_NFT = _masterNFT;
        MASTER_FRACTION = _masterFraction;
        LIQUIDITY_ENGINE = HybridLiquidityEngine(_liquidityEngine);
        FRAC_TOKEN = FRACToken(_fracToken);
    }

    modifier validNFT(address nftContract) {
        require(_isValidNFT(nftContract), "Invalid or non-whitelisted NFT");
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

    function _isValidNFT(address nftContract) internal view returns (bool) {
        // Check if contract exists
        if (nftContract.code.length == 0) {
            return false;
        }

        // Check ERC721 interface support
        if (!nftContract.supportsInterface(type(IERC721).interfaceId)) {
            return false;
        }

        // Check whitelist if required
        if (requireWhitelist && !whitelistedNFTs[nftContract]) {
            return false;
        }

        return true;
    }

    function createAsset(
        string calldata name,
        string calldata symbol,
        string calldata metadataURI,
        uint8 assetCategory,
        bool shouldFractionalize,
        uint256 fractionSupply,
        LiquidityType liquidityType,
        uint256 fracAmount
    )
        external
        payable
        nonReentrant
        whenNotPaused
        returns (bytes32 assetId, address nft, address fraction)
    {
        require(bytes(name).length > 0, "Empty name");
        require(bytes(symbol).length > 0, "Empty symbol");

        assetId = keccak256(
            abi.encodePacked(msg.sender, block.timestamp, name)
        );

        // 1) Deploy & init NFT
        bytes32 nftSalt = keccak256(abi.encodePacked(assetId, "NFT"));
        nft = Clones.cloneDeterministic(MASTER_NFT, nftSalt);
        IUniversalNFT(nft).initialize(
            name,
            symbol,
            address(this),
            metadataURI,
            assetCategory
        );
        uint256 tokenId = IUniversalNFT(nft).mint(address(this));

        if (!shouldFractionalize) {
            IUniversalNFT(nft).transferFrom(address(this), msg.sender, tokenId);
            IUniversalNFT(nft).transferOwnership(msg.sender);
        } else {
            require(
                fractionSupply >= MIN_FRACTION_SUPPLY &&
                    fractionSupply <= MAX_FRACTION_SUPPLY,
                "Invalid supply range"
            );
            require(liquidityType != LiquidityType.NONE, "Specify liquidity");

            // 2) Deploy & init FractionToken clone
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
                address(this)
            );

            // escrow NFT
            IUniversalNFT(nft).transferFrom(address(this), fraction, tokenId);

            // 3) Seed liquidity
            _addInitialLiquidity(fraction, liquidityType, fracAmount);

            IUniversalNFT(nft).transferOwnership(msg.sender);

            emit AssetFractionalized(
                assetId,
                fraction,
                fractionSupply,
                msg.value,
                fracAmount
            );
        }

        assets[assetId] = Asset({
            nftContract: nft,
            fractionContract: fraction,
            creator: msg.sender,
            tokenId: tokenId,
            createdAt: block.timestamp,
            isActive: true,
            liquidityType: liquidityType
        });

        userAssets[msg.sender].push(assetId);
        allAssets.push(assetId);

        emit AssetCreated(
            assetId,
            msg.sender,
            nft,
            fraction,
            tokenId,
            liquidityType
        );
        return (assetId, nft, fraction);
    }

    function _addInitialLiquidity(
        address fractionToken,
        LiquidityType liquidityType,
        uint256 fracAmount
    ) internal {
        uint256 liqBal = IERC20(fractionToken).balanceOf(address(this));
        IERC20(fractionToken).approve(address(LIQUIDITY_ENGINE), liqBal);

        if (
            liquidityType == LiquidityType.ETH_ONLY ||
            liquidityType == LiquidityType.BOTH
        ) {
            require(msg.value > 0, "ETH required");
            uint256 ethPortion = liquidityType == LiquidityType.BOTH
                ? msg.value / 2
                : msg.value;
            uint256 tokenPortion = liquidityType == LiquidityType.BOTH
                ? liqBal / 2
                : liqBal;

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
            FRAC_TOKEN.transferFrom(msg.sender, address(this), fracAmount);
            FRAC_TOKEN.approve(address(LIQUIDITY_ENGINE), fracAmount);

            uint256 tokenPortion = liquidityType == LiquidityType.BOTH
                ? liqBal / 2
                : liqBal;

            LIQUIDITY_ENGINE.createFRACPool(
                fractionToken,
                fracAmount,
                tokenPortion
            );
        }
    }

    function fractionalizeExisting(
        address existingNFT,
        uint256 tokenId,
        uint256 fractionSupply,
        string calldata fractionName,
        string calldata fractionSymbol,
        LiquidityType liquidityType,
        uint256 fracAmount
    )
        external
        payable
        nonReentrant
        whenNotPaused
        validNFT(existingNFT)
        returns (address fraction)
    {
        require(
            IERC721(existingNFT).ownerOf(tokenId) == msg.sender,
            "Not owner"
        );
        require(
            fractionSupply >= MIN_FRACTION_SUPPLY &&
                fractionSupply <= MAX_FRACTION_SUPPLY,
            "Invalid supply range"
        );
        require(liquidityType != LiquidityType.NONE, "Specify liquidity");
        require(bytes(fractionName).length > 0, "Empty name");
        require(bytes(fractionSymbol).length > 0, "Empty symbol");

        bytes32 assetId = keccak256(
            abi.encodePacked(existingNFT, tokenId, block.timestamp)
        );
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
            address(this)
        );

        IERC721(existingNFT).transferFrom(msg.sender, fraction, tokenId);
        _addInitialLiquidity(fraction, liquidityType, fracAmount);

        assets[assetId] = Asset({
            nftContract: existingNFT,
            fractionContract: fraction,
            creator: msg.sender,
            tokenId: tokenId,
            createdAt: block.timestamp,
            isActive: true,
            liquidityType: liquidityType
        });
        userAssets[msg.sender].push(assetId);
        allAssets.push(assetId);

        emit AssetFractionalized(
            assetId,
            fraction,
            fractionSupply,
            msg.value,
            fracAmount
        );
        return fraction;
    }

    function batchCreateAssets(
        string[] calldata names,
        string[] calldata symbols,
        string[] calldata metadataURIs,
        uint8[] calldata categories
    ) external returns (bytes32[] memory assetIds) {
        require(
            names.length == symbols.length &&
                symbols.length == metadataURIs.length &&
                names.length <= 20,
            "Array mismatch or too many"
        );

        assetIds = new bytes32[](names.length);
        for (uint i; i < names.length; i++) {
            (bytes32 id, , ) = this.createAsset(
                names[i],
                symbols[i],
                metadataURIs[i],
                categories[i],
                false,
                0,
                LiquidityType.NONE,
                0
            );
            assetIds[i] = id;
        }
        return assetIds;
    }

    // Admin functions
    function setPlatformFee(uint256 newFee) external onlyOwner {
        require(newFee <= MAX_FEE, "Fee too high");
        uint256 oldFee = platformFee;
        platformFee = newFee;
        emit PlatformFeeUpdated(oldFee, newFee);
    }

    function setWhitelistMode(bool _requireWhitelist) external onlyOwner {
        requireWhitelist = _requireWhitelist;
        emit WhitelistModeChanged(_requireWhitelist);
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

    function withdrawFees() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No fees to withdraw");

        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "Transfer failed");
    }

    // View functions
    function getUserAssets(
        address user
    ) external view returns (bytes32[] memory) {
        return userAssets[user];
    }

    function getAllAssets() external view returns (bytes32[] memory) {
        return allAssets;
    }

    function getAssetDetails(
        bytes32 assetId
    ) external view returns (Asset memory) {
        return assets[assetId];
    }

    function getAssetLiquidityInfo(
        bytes32 assetId
    )
        external
        view
        returns (
            bool hasETHPool,
            bool hasFRACPool,
            uint256 ethReserve,
            uint256 fracReserve,
            uint256 tokenReserveETH,
            uint256 tokenReserveFRAC
        )
    {
        Asset memory a = assets[assetId];
        if (a.fractionContract == address(0)) {
            return (false, false, 0, 0, 0, 0);
        }

        hasETHPool = LIQUIDITY_ENGINE.hasETHPool(a.fractionContract);
        hasFRACPool = LIQUIDITY_ENGINE.hasFRACPool(a.fractionContract);

        if (hasETHPool) {
            (ethReserve, tokenReserveETH, , , ) = LIQUIDITY_ENGINE
                .getETHPoolInfo(a.fractionContract);
        }

        if (hasFRACPool) {
            (fracReserve, tokenReserveFRAC, , , ) = LIQUIDITY_ENGINE
                .getFRACPoolInfo(a.fractionContract);
        }
    }

    function isNFTWhitelisted(
        address nftContract
    ) external view returns (bool) {
        return whitelistedNFTs[nftContract];
    }

    function getTotalAssets() external view returns (uint256) {
        return allAssets.length;
    }

    function getUserAssetCount(address user) external view returns (uint256) {
        return userAssets[user].length;
    }
}
