/*
 SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/HybridLiquidityEngine.sol";
import "../src/FRACToken.sol";
import "../src/FractionToken.sol";
import "../src/UniversalNFT.sol";

contract LiquidityEngineTest is Test {
    HybridLiquidityEngine public engine;
    FRACToken public fracToken;
    UniversalNFT public nft;
    FractionToken public frac;

    address constant user = address(0x123);

    function setUp() public {
        // 1) deploy & fund
        vm.startPrank(user);

        // FRAC-token is mintable by deployer (user)
        fracToken = new FRACToken();
        fracToken.mint(user, 1_000 ether);

        // engine
        engine = new HybridLiquidityEngine(address(fracToken));

        // NFT + FractionToken
        nft = new UniversalNFT();
        frac = new FractionToken();

        nft.initialize("TestNFT", "TNFT", user, "uri", 0);
        uint256 id = nft.mint(address(frac));

        frac.initialize(
            "Test Fractions", // matches tests above
            "TFRAC",
            address(nft),
            id,
            10000,
            user,
            0,
            address(0)
        );
        vm.stopPrank();

        // give user 2 ETH so they can seed + swap
        vm.deal(user, 2 ether);
    }

    function testCreateETHPool() public {
        vm.startPrank(user);
        frac.approve(address(engine), 1000);

        engine.createETHPool{value: 1 ether}(address(frac), 1000);

        // reserves
        (uint256 eR, uint256 tR, , , ) = engine.getETHPoolInfo(address(frac));
        assertEq(eR, 1 ether);
        assertEq(tR, 1000);
        assertTrue(engine.hasETHPool(address(frac)));
        vm.stopPrank();
    }

    function testSwapETHForTokens() public {
        vm.startPrank(user);
        frac.approve(address(engine), 1000);

        engine.createETHPool{value: 1 ether}(address(frac), 1000);

        uint256 before = frac.balanceOf(user);
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

        // FRAC-token must be approved for engine
        fracToken.approve(address(engine), 500 ether);
        frac.approve(address(engine), 1000);

        engine.createFRACPool(address(frac), 500 ether, 1000);

        (uint256 fracRes, uint256 tokRes, , , ) = engine.getFRACPoolInfo(
            address(frac)
        );
        assertEq(fracRes, 500 ether);
        assertEq(tokRes, 1000);
        assertTrue(engine.hasFRACPool(address(frac)));
        vm.stopPrank();
    }
}
*/