// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "../src/UniversalAssetFactory.sol";
import "../src/UniversalNFT.sol";
import "../src/FractionToken.sol";
import "../src/FRACToken.sol";
import "../src/HybridLiquidityEngine.sol";

contract AssetCreationTest is Test, IERC721Receiver {
    UniversalNFT masterNFT;
    FractionToken masterFraction;
    FRACToken fracToken;
    HybridLiquidityEngine engine;
    UniversalAssetFactory factory;
    address constant CREATOR = address(0x2);

    function setUp() public {
        vm.startPrank(address(0x1));
        masterNFT = new UniversalNFT();
        masterFraction = new FractionToken();
        fracToken = new FRACToken();
        engine = new HybridLiquidityEngine(address(fracToken));
        factory = new UniversalAssetFactory(
            address(masterNFT),
            address(masterFraction),
            address(engine),
            address(fracToken)
        );
        fracToken.mint(address(factory), 1_000_000 ether);
        vm.stopPrank();

        vm.deal(CREATOR, 10 ether);
        vm.prank(address(0x1));
        fracToken.mint(CREATOR, 100_000 ether);
    }

    function testCreateAndFractionalizeWithETH() public {
        vm.startPrank(CREATOR);

        (bytes32 assetId, address nft, address frac) = factory.createAsset{
            value: 1 ether
        }(
            "TestNFT",
            "TNFT",
            "https://test.uri",
            0,
            true,
            10_000,
            UniversalAssetFactory.LiquidityType.ETH_ONLY,
            0
        );

        // Verify asset was created
        assertTrue(assetId != bytes32(0));
        assertTrue(nft != address(0));
        assertTrue(frac != address(0));

        // Verify user received 90% of tokens (9000 out of 10000)
        assertEq(FractionToken(frac).balanceOf(CREATOR), 9_000);

        // Verify liquidity engine received 10% (1000 tokens)
        assertEq(FractionToken(frac).balanceOf(address(engine)), 1_000);

        // Verify ETH pool was created
        assertTrue(engine.hasETHPool(frac));

        vm.stopPrank();
    }

    function testCreateAndFractionalizeWithFRAC() public {
        vm.startPrank(CREATOR);

        fracToken.approve(address(factory), 2_000 ether);

        (bytes32 assetId, address nft, address frac) = factory.createAsset(
            "TestNFT2",
            "TNFT2",
            "https://test2.uri",
            0,
            true,
            5_000,
            UniversalAssetFactory.LiquidityType.FRAC_ONLY,
            2_000 ether
        );

        // Verify user received 90% of tokens (4500 out of 5000)
        assertEq(FractionToken(frac).balanceOf(CREATOR), 4_500);

        // Verify liquidity engine received 10% (500 tokens)
        assertEq(FractionToken(frac).balanceOf(address(engine)), 500);

        // Verify FRAC pool was created
        assertTrue(engine.hasFRACPool(frac));

        vm.stopPrank();
    }

    function testFractionalizeExistingNFT() public {
        vm.startPrank(CREATOR);

        (bytes32 assetId, address nft, ) = factory.createAsset(
            "SoloNFT",
            "SNFT",
            "https://solo.uri",
            0,
            false,
            0,
            UniversalAssetFactory.LiquidityType.NONE,
            0
        );

        UniversalNFT(nft).approve(address(factory), 1);
        fracToken.approve(address(factory), 1_000 ether);

        address frac = factory.fractionalizeExisting(
            nft,
            1,
            10_000,
            "F-Name",
            "F-SYM",
            UniversalAssetFactory.LiquidityType.FRAC_ONLY,
            1_000 ether
        );

        // Verify user received 90% of tokens (9000 out of 10000)
        assertEq(FractionToken(frac).balanceOf(CREATOR), 9_000);

        // Verify liquidity engine received 10% (1000 tokens)
        assertEq(FractionToken(frac).balanceOf(address(engine)), 1_000);

        // Verify FRAC pool was created
        assertTrue(engine.hasFRACPool(frac));

        vm.stopPrank();
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
