/*

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/HybridLiquidityEngine.sol";
import "../src/FractionToken.sol";
import "../src/FRACToken.sol";
import "../src/UniversalNFT.sol";

contract LiquidityEngineTest is Test {
    HybridLiquidityEngine engine;
    FractionToken frac;
    FRACToken fracToken;
    address constant user = address(0x123);
    UniversalNFT nft;
    function setUp() public {
        vm.startPrank(user);
        fracToken = new FRACToken();
        engine = new HybridLiquidityEngine(address(fracToken));
        nft = new UniversalNFT();
        frac = new FractionToken();

        nft.initialize("N", "S", user, "uri", 0);
        uint256 id = nft.mint(address(frac));

        // CALL new 8-arg initialize
        frac.initialize(
            "Frac",
            "F",
            address(nft),
            id,
            10000,
            user,
            0,
            address(0)
        );
        vm.stopPrank();

        vm.deal(user, 2 ether);
    }

    function testCreateETHPool() public {
        vm.startPrank(user);
        frac.approve(address(engine), 1_000);
        engine.createETHPool{value: 1 ether}(address(frac), 1_000);
        assertEq(address(engine).balance, 1 ether);
        vm.stopPrank();
    }

    function testSwapETHForTokens() public {
        vm.startPrank(user);
        // First create pool
        frac.approve(address(engine), 1_000);
        engine.createETHPool{value: 1 ether}(address(frac), 1_000);

        uint256 before = frac.balanceOf(user);
        // Swap ETH for tokens with 0 as minTokensOut
        uint256 got = engine.swapETHForTokens{value: 0.1 ether}(
            address(frac),
            0 // minTokensOut
        );
        assertGt(got, 0);
        assertEq(frac.balanceOf(user), before + got);
        vm.stopPrank();
    }

    function testCreateFRACPool() public {
        vm.startPrank(user);
        // Approve both FRAC and fraction tokens
        fracToken.approve(address(engine), 500 ether);
        frac.approve(address(engine), 1_000);

        // Create FRAC pool
        engine.createFRACPool(address(frac), 500 ether, 1_000);

        // Check that engine received tokens
        assertGt(fracToken.balanceOf(address(engine)), 0);
        assertGt(frac.balanceOf(address(engine)), 0);
        vm.stopPrank();
    }
}
*/