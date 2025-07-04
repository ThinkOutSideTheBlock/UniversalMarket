/*

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "../src/RoyaltyDistributor.sol";

contract RoyaltyDistributorTest is Test {
    RoyaltyDistributor rd;
    address owner = address(0x1);
    address user1 = address(0x2);
    address user2 = address(0x3);

    function setUp() public {
        rd = new RoyaltyDistributor();
        // fund the owner so depositRoyalties{value:...} works
        vm.deal(owner, 100 ether);
    }

    /// @dev Build a 2-leaf Merkle root sorted exactly as OZ does internally.
    function _buildTree(
        address a,
        uint256 aAmt,
        address b,
        uint256 bAmt
    ) internal pure returns (bytes32 root, bytes32 leafA, bytes32 leafB) {
        leafA = keccak256(abi.encodePacked(a, aAmt));
        leafB = keccak256(abi.encodePacked(b, bAmt));
        // sort the two leaves
        if (leafA < leafB) {
            root = keccak256(abi.encodePacked(leafA, leafB));
        } else {
            root = keccak256(abi.encodePacked(leafB, leafA));
        }
    }

    function testSinglePeriodClaims() public {
        address ft = address(0x11);
        uint256 amt1 = 3 ether;
        uint256 amt2 = 7 ether;

        // build tree and proof
        (bytes32 root, bytes32 leaf1, bytes32 leaf2) = _buildTree(
            user1,
            amt1,
            user2,
            amt2
        );

        // deposit under period 0
        vm.prank(owner);
        rd.depositRoyalties{value: amt1 + amt2}(ft, root);
        uint256 period0 = rd.getCurrentPeriod(ft);
        assertEq(period0, 0);

        // user1 claims with proof [leaf2]
        bytes32[] memory proof1 = new bytes32[](1);
        proof1[0] = leaf2;
        vm.deal(user1, 0);
        vm.prank(user1);
        rd.claimRoyalties(ft, period0, amt1, proof1);
        assertEq(user1.balance, amt1);

        // user2 claims with proof [leaf1]
        bytes32[] memory proof2 = new bytes32[](1);
        proof2[0] = leaf1;
        vm.deal(user2, 0);
        vm.prank(user2);
        rd.claimRoyalties(ft, period0, amt2, proof2);
        assertEq(user2.balance, amt2);
    }

    function testDoubleClaimReverts() public {
        address ft = address(0x22);
        uint256 amt1 = 1 ether;

        (bytes32 root, bytes32 leaf1, bytes32 leaf2) = _buildTree(
            user1,
            amt1,
            user2,
            0
        );

        vm.prank(owner);
        rd.depositRoyalties{value: amt1}(ft, root);
        uint256 p = rd.getCurrentPeriod(ft);

        // first claim ok
        bytes32[] memory proof1 = new bytes32[](1);
        proof1[0] = leaf2;
        vm.prank(user1);
        rd.claimRoyalties(ft, p, amt1, proof1);

        // second must revert
        vm.prank(user1);
        vm.expectRevert("Already claimed");
        rd.claimRoyalties(ft, p, amt1, proof1);
    }

    function testBatchClaimAcrossPeriods() public {
        address ft = address(0x33);

        // PERIOD 0
        vm.warp(0);
        uint256 a1p0 = 2 ether;
        uint256 a2p0 = 4 ether;
        (bytes32 root0, bytes32 l10, bytes32 l20) = _buildTree(
            user1,
            a1p0,
            user2,
            a2p0
        );
        vm.prank(owner);
        rd.depositRoyalties{value: a1p0 + a2p0}(ft, root0);
        uint256 p0 = rd.getCurrentPeriod(ft);
        assertEq(p0, 0);

        // PERIOD 1 (warp > WEEK)
        vm.warp(block.timestamp + rd.WEEK() + 1);
        uint256 a1p1 = 1 ether;
        uint256 a2p1 = 3 ether;
        (bytes32 root1, bytes32 l11, bytes32 l21) = _buildTree(
            user1,
            a1p1,
            user2,
            a2p1
        );
        vm.prank(owner);
        rd.depositRoyalties{value: a1p1 + a2p1}(ft, root1);
        uint256 p1 = rd.getCurrentPeriod(ft);
        assertEq(p1, 1);

        // user1 batch‐claims both periods
        vm.deal(user1, 0);
        uint256 before = user1.balance;

        uint256[] memory periods = new uint256[](2);
        periods[0] = p0;
        periods[1] = p1;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = a1p0;
        amounts[1] = a1p1;

        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = l20;
        proofs[1] = new bytes32[](1);
        proofs[1][0] = l21;

        vm.prank(user1);
        rd.batchClaimRoyalties(ft, periods, amounts, proofs);

        assertEq(user1.balance - before, a1p0 + a1p1);
    }

    function testClaimAfterDeadlineReverts() public {
        address ft = address(0x44);
        uint256 a1 = 1 ether;
        uint256 a2 = 1 ether;
        (bytes32 root, bytes32 l1, bytes32 l2) = _buildTree(
            user1,
            a1,
            user2,
            a2
        );
        vm.prank(owner);
        rd.depositRoyalties{value: a1 + a2}(ft, root);
        uint256 p = rd.getCurrentPeriod(ft);

        // warp past deadline
        vm.warp(block.timestamp + rd.CLAIM_PERIOD() + 1);

        bytes32[] memory proof1 = new bytes32[](1);
        proof1[0] = l2;
        vm.prank(user1);
        vm.expectRevert("Claim period expired");
        rd.claimRoyalties(ft, p, a1, proof1);
    }
}
*/