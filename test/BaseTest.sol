// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/FRACToken.sol";
import "../src/HybridLiquidityEngine.sol";
import "../src/UniversalAssetFactory.sol";
import "../src/UniversalNFT.sol";
import "../src/FractionToken.sol";
import "../src/RoyaltyDistributor.sol";
import "../src/EmergencyControls.sol";

contract BaseTest is Test {
    // Core contracts
    FRACToken public fracToken;
    HybridLiquidityEngine public liquidityEngine;
    UniversalAssetFactory public assetFactory;
    RoyaltyDistributor public royaltyDistributor;
    EmergencyControls public emergencyControls;

    // Master implementations
    UniversalNFT public masterNFT;
    FractionToken public masterFraction;

    // Test users
    address public owner;
    address public user1;
    address public user2;
    address public user3;
    address public liquidityProvider;
    address public trader;

    // Test constants
    uint256 public constant INITIAL_FRAC_SUPPLY = 10_000_000 * 1e18;
    uint256 public constant FRACTION_SUPPLY = 10_000;
    uint256 public constant INITIAL_ETH_LIQUIDITY = 10 ether;
    uint256 public constant INITIAL_FRAC_LIQUIDITY = 100_000 * 1e18;

    function setUp() public virtual {
        // Setup users
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        liquidityProvider = makeAddr("liquidityProvider");
        trader = makeAddr("trader");

        // Deploy core contracts
        fracToken = new FRACToken();
        liquidityEngine = new HybridLiquidityEngine(address(fracToken));

        // Deploy master implementations
        masterNFT = new UniversalNFT();
        masterFraction = new FractionToken();

        // Deploy factory
        assetFactory = new UniversalAssetFactory(
            address(masterNFT),
            address(masterFraction),
            address(liquidityEngine),
            address(fracToken)
        );

        // Deploy auxiliary contracts
        royaltyDistributor = new RoyaltyDistributor();
        emergencyControls = new EmergencyControls();

        // Setup permissions
        fracToken.addMinter(address(liquidityEngine));
        fracToken.addMinter(address(assetFactory));

        // Fund test users
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(user3, 100 ether);
        vm.deal(liquidityProvider, 1000 ether);
        vm.deal(trader, 50 ether);

        // Distribute FRAC tokens
        fracToken.transfer(user1, 1_000_000 * 1e18);
        fracToken.transfer(user2, 1_000_000 * 1e18);
        fracToken.transfer(user3, 1_000_000 * 1e18);
        fracToken.transfer(liquidityProvider, 2_000_000 * 1e18);
        fracToken.transfer(trader, 500_000 * 1e18);
    }
}
