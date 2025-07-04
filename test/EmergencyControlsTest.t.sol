/*
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/EmergencyControls.sol";
import "../src/UniversalAssetFactory.sol";
import "../src/FRACToken.sol";
import "../src/HybridLiquidityEngine.sol";
import "../src/UniversalNFT.sol";
import "../src/FractionToken.sol";

contract EmergencyControlsTest is Test {
    EmergencyControls public emergencyControls;
    UniversalAssetFactory public assetFactory;

    address public admin = makeAddr("admin");
    address public guardian = makeAddr("guardian");
    address public emergency = makeAddr("emergency");

    function setUp() public {
        vm.startPrank(admin);

        emergencyControls = new EmergencyControls();

        // Setup other contracts for testing
        FRACToken fracToken = new FRACToken();
        UniversalNFT masterNFT = new UniversalNFT();
        FractionToken masterFraction = new FractionToken();
        HybridLiquidityEngine liquidityEngine = new HybridLiquidityEngine(
            address(fracToken)
        );

        assetFactory = new UniversalAssetFactory(
            address(masterNFT),
            address(masterFraction),
            address(liquidityEngine),
            address(fracToken)
        );

        // Grant roles
        emergencyControls.grantRole(
            emergencyControls.GUARDIAN_ROLE(),
            guardian
        );
        emergencyControls.grantRole(
            emergencyControls.EMERGENCY_ROLE(),
            emergency
        );

        // Transfer factory ownership to admin (not emergency controls) for proper testing
        assetFactory.transferOwnership(admin);

        vm.stopPrank();
    }

    function testAccessControl() public {
        assertTrue(
            emergencyControls.hasRole(
                emergencyControls.DEFAULT_ADMIN_ROLE(),
                admin
            )
        );
        assertTrue(
            emergencyControls.hasRole(
                emergencyControls.GUARDIAN_ROLE(),
                guardian
            )
        );
        assertTrue(
            emergencyControls.hasRole(
                emergencyControls.EMERGENCY_ROLE(),
                emergency
            )
        );
    }

    function testPauseContract() public {
        vm.prank(guardian);
        emergencyControls.pauseContract(address(assetFactory));

        assertTrue(emergencyControls.isContractPaused(address(assetFactory)));
    }

    function testEmergencyPause() public {
        vm.prank(emergency);
        emergencyControls.emergencyPause();

        assertTrue(emergencyControls.paused());
    }

    function testScheduledTransaction() public {
        vm.prank(admin);
        bytes memory data = abi.encodeWithSelector(
            assetFactory.setPlatformFee.selector,
            500
        );

        bytes32 txHash = emergencyControls.scheduleTransaction(
            address(assetFactory),
            data
        );

        assertTrue(txHash != bytes32(0));

        (
            address target,
            ,
            uint256 executeTime,
            bool executed
        ) = emergencyControls.scheduledTx(txHash);
        assertEq(target, address(assetFactory));
        assertEq(executeTime, block.timestamp + 24 hours);
        assertFalse(executed);
    }

    function testExecuteScheduledTransaction() public {
        // First transfer factory ownership to emergency controls
        vm.prank(admin);
        assetFactory.transferOwnership(address(emergencyControls));

        vm.prank(admin);
        bytes memory data = abi.encodeWithSelector(
            assetFactory.setPlatformFee.selector,
            500
        );

        bytes32 txHash = emergencyControls.scheduleTransaction(
            address(assetFactory),
            data
        );

        // Fast forward past timelock
        vm.warp(block.timestamp + 24 hours + 1);

        vm.prank(admin);
        emergencyControls.executeScheduledTransaction(txHash);

        // Verify the transaction was executed
        (, , , bool executed) = emergencyControls.scheduledTx(txHash);
        assertTrue(executed);
    }

    function testCannotExecuteBeforeTimelock() public {
        vm.prank(admin);
        bytes memory data = abi.encodeWithSelector(
            assetFactory.setPlatformFee.selector,
            500
        );

        bytes32 txHash = emergencyControls.scheduleTransaction(
            address(assetFactory),
            data
        );

        vm.prank(admin);
        vm.expectRevert("Time lock not expired");
        emergencyControls.executeScheduledTransaction(txHash);
    }
}
*/