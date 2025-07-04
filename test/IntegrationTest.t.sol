/*

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "../src/UniversalAssetFactory.sol";
import "../src/UniversalNFT.sol";
import "../src/FractionToken.sol";
import "../src/FRACToken.sol";
import "../src/HybridLiquidityEngine.sol";
import "../src/RoyaltyDistributor.sol";

contract IntegrationTest is Test, IERC721Receiver {
    UniversalNFT masterNFT;
    FractionToken masterFraction;
    FRACToken fracToken;
    HybridLiquidityEngine engine;
    UniversalAssetFactory factory;
    RoyaltyDistributor rd;

    address constant OWNER = address(0x1);
    address constant USER1 = address(0x2);

    function setUp() public {
        vm.startPrank(OWNER);
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
        rd = new RoyaltyDistributor();

        fracToken.mint(address(factory), 1_000_000 ether);
        fracToken.mint(OWNER, 1_000_000 ether);
        vm.stopPrank();

        vm.deal(USER1, 10 ether);
        vm.prank(OWNER);
        fracToken.transfer(USER1, 100_000 ether);
    }

    function testFullLifecycle_and_RoyaltyDeposit() public {
        vm.startPrank(USER1);
        fracToken.approve(address(factory), 5_000 ether);

        (, , address fracAddr) = factory.createAsset(
            "TestNFT",
            "TNFT",
            "https://test.uri",
            0,
            true,
            10_000,
            UniversalAssetFactory.LiquidityType.FRAC_ONLY,
            5_000 ether
        );

        // Verify user received correct tokens
        assertEq(FractionToken(fracAddr).balanceOf(USER1), 9_000);
        assertEq(FractionToken(fracAddr).balanceOf(address(engine)), 1_000);

        vm.stopPrank();

        bytes32 dummyRoot = keccak256("dummy");
        vm.deal(OWNER, 2 ether);
        vm.prank(OWNER);
        rd.depositRoyalties{value: 2 ether}(fracAddr, dummyRoot);

        uint256 totalDist = rd.getTotalDistributed(fracAddr);
        assertEq(totalDist, 2 ether);
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
*/