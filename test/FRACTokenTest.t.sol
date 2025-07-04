/*
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/HybridLiquidityEngine.sol";
import "../src/FRACToken.sol";
import "../src/FractionToken.sol";
import "../src/UniversalNFT.sol";

contract LiquidityEngineTest is Test {
    HybridLiquidityEngine engine;
    FRACToken fracToken;
    FractionToken frac;
    UniversalNFT nft;

    address user1 = address(0x1);

    function setUp() public {
        vm.startPrank(user1);

        fracToken = new FRACToken();
        engine = new HybridLiquidityEngine(address(fracToken));
        frac = new FractionToken();
        nft = new UniversalNFT();

        nft.initialize("TestNFT", "TNFT", user1, "https://test.uri", 0);
        uint256 tokenId = nft.mint(address(frac));

        // FIX: Use new initialize signature with 8 parameters
        frac.initialize(
            "Fraction Token",
            "FRAC",
            address(nft),
            tokenId,
            10000,
            user1,
            0, // No liquidity amount
            address(0) // No liquidity recipient
        );

        fracToken.mint(user1, 100000 ether);
        vm.stopPrank();

        vm.deal(user1, 100 ether);
    }

    function testCreateETHPool() public {
        vm.startPrank(user1);

        frac.approve(address(engine), 1000);
        engine.createETHPool{value: 1 ether}(address(frac), 1000);

        assertTrue(engine.hasETHPool(address(frac)));

        (
            uint256 ethReserve,
            uint256 tokenReserve,
            uint256 totalLiquidity,
            ,

        ) = engine.getETHPoolInfo(address(frac));

        assertEq(ethReserve, 1 ether);
        assertEq(tokenReserve, 1000);
        assertGt(totalLiquidity, 0);

        vm.stopPrank();
    }

    function testCreateFRACPool() public {
        vm.startPrank(user1);

        frac.approve(address(engine), 1000);
        fracToken.approve(address(engine), 2000 ether);

        engine.createFRACPool(address(frac), 2000 ether, 1000);

        assertTrue(engine.hasFRACPool(address(frac)));

        (
            uint256 fracReserve,
            uint256 tokenReserve,
            uint256 totalLiquidity,
            ,

        ) = engine.getFRACPoolInfo(address(frac));

        assertEq(fracReserve, 2000 ether);
        assertEq(tokenReserve, 1000);
        assertGt(totalLiquidity, 0);

        vm.stopPrank();
    }

    function testSwapETHForTokens() public {
        vm.startPrank(user1);

        // Create pool first
        frac.approve(address(engine), 1000);
        engine.createETHPool{value: 1 ether}(address(frac), 1000);

        // Perform swap
        uint256 tokensBefore = frac.balanceOf(user1);
        engine.swapETHForTokens{value: 0.1 ether}(address(frac), 1);
        uint256 tokensAfter = frac.balanceOf(user1);

        assertGt(tokensAfter, tokensBefore);

        vm.stopPrank();
    }
}
*/