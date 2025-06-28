// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract RoyaltyDistributor is Ownable, ReentrancyGuard, Pausable {
    // Constants
    uint256 public constant CLAIM_PERIOD = 30 days;
    uint256 public constant WEEK = 7 days;
    uint256 private constant MAX_BATCH_SIZE = 50;

    struct RoyaltyPeriod {
        uint256 totalRevenue;
        uint256 totalClaimed;
        bytes32 merkleRoot;
        uint256 timestamp;
        uint256 claimDeadline;
        bool compounded;
        mapping(address => bool) claimed;
        mapping(address => uint256) claimedAmounts;
    }

    mapping(address => mapping(uint256 => RoyaltyPeriod)) public royaltyPeriods;
    mapping(address => uint256) public currentPeriod;
    mapping(address => uint256) public totalDistributed;
    mapping(address => uint256) public totalCompounded;

    // Events
    event RoyaltiesDeposited(
        address indexed fractionToken,
        uint256 indexed period,
        uint256 amount,
        bytes32 merkleRoot
    );
    event RoyaltiesClaimed(
        address indexed fractionToken,
        uint256 indexed period,
        address indexed user,
        uint256 amount
    );
    event UnclaimedRoyaltiesCompounded(
        address indexed fractionToken,
        uint256 indexed period,
        uint256 amount
    );
    event BatchClaimCompleted(
        address indexed user,
        address indexed fractionToken,
        uint256 totalAmount,
        uint256 periodsCount
    );

    constructor() Ownable(msg.sender) {}

    modifier validPeriod(address fractionToken, uint256 periodId) {
        require(
            royaltyPeriods[fractionToken][periodId].merkleRoot != bytes32(0),
            "Period does not exist"
        );
        _;
    }

    function depositRoyalties(
        address fractionToken,
        bytes32 merkleRoot
    ) external payable nonReentrant whenNotPaused {
        require(msg.value > 0, "No ETH sent");
        require(merkleRoot != bytes32(0), "Invalid merkle root");
        require(fractionToken != address(0), "Invalid fraction token");

        uint256 periodId = block.timestamp / WEEK;
        RoyaltyPeriod storage period = royaltyPeriods[fractionToken][periodId];

        period.totalRevenue += msg.value;
        period.merkleRoot = merkleRoot;
        period.timestamp = block.timestamp;
        period.claimDeadline = block.timestamp + CLAIM_PERIOD;

        if (currentPeriod[fractionToken] < periodId) {
            currentPeriod[fractionToken] = periodId;
        }

        totalDistributed[fractionToken] += msg.value;

        emit RoyaltiesDeposited(fractionToken, periodId, msg.value, merkleRoot);
    }

    function claimRoyalties(
        address fractionToken,
        uint256 periodId,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) external nonReentrant whenNotPaused validPeriod(fractionToken, periodId) {
        RoyaltyPeriod storage period = royaltyPeriods[fractionToken][periodId];

        require(
            block.timestamp <= period.claimDeadline,
            "Claim period expired"
        );
        require(!period.claimed[msg.sender], "Already claimed");
        require(amount > 0, "Invalid amount");
        require(!period.compounded, "Period already compounded");

        // Verify merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount));
        require(
            MerkleProof.verify(merkleProof, period.merkleRoot, leaf),
            "Invalid proof"
        );

        // Check sufficient balance
        require(
            period.totalClaimed + amount <= period.totalRevenue,
            "Insufficient balance"
        );

        period.claimed[msg.sender] = true;
        period.claimedAmounts[msg.sender] = amount;
        period.totalClaimed += amount;

        // Transfer royalties
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");

        emit RoyaltiesClaimed(fractionToken, periodId, msg.sender, amount);
    }

    function batchClaimRoyalties(
        address fractionToken,
        uint256[] calldata periodIds,
        uint256[] calldata amounts,
        bytes32[][] calldata merkleProofs
    ) external nonReentrant whenNotPaused {
        require(
            periodIds.length == amounts.length &&
                amounts.length == merkleProofs.length,
            "Array length mismatch"
        );
        require(periodIds.length <= MAX_BATCH_SIZE, "Too many periods");

        uint256 totalAmount = 0;

        for (uint i = 0; i < periodIds.length; i++) {
            uint256 periodId = periodIds[i];
            uint256 amount = amounts[i];
            bytes32[] memory proof = merkleProofs[i];

            RoyaltyPeriod storage period = royaltyPeriods[fractionToken][
                periodId
            ];

            require(period.merkleRoot != bytes32(0), "Period does not exist");
            require(
                block.timestamp <= period.claimDeadline,
                "Claim period expired"
            );
            require(!period.claimed[msg.sender], "Already claimed");
            require(!period.compounded, "Period already compounded");

            // Verify merkle proof
            bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount));
            require(
                MerkleProof.verify(proof, period.merkleRoot, leaf),
                "Invalid proof"
            );

            // Check sufficient balance
            require(
                period.totalClaimed + amount <= period.totalRevenue,
                "Insufficient balance"
            );

            period.claimed[msg.sender] = true;
            period.claimedAmounts[msg.sender] = amount;
            period.totalClaimed += amount;
            totalAmount += amount;

            emit RoyaltiesClaimed(fractionToken, periodId, msg.sender, amount);
        }

        // Transfer total royalties
        (bool success, ) = payable(msg.sender).call{value: totalAmount}("");
        require(success, "Transfer failed");

        emit BatchClaimCompleted(
            msg.sender,
            fractionToken,
            totalAmount,
            periodIds.length
        );
    }

    function compoundUnclaimedRoyalties(
        address fractionToken,
        uint256 periodId
    ) external nonReentrant whenNotPaused validPeriod(fractionToken, periodId) {
        RoyaltyPeriod storage period = royaltyPeriods[fractionToken][periodId];

        require(
            block.timestamp > period.claimDeadline,
            "Claim period not expired"
        );
        require(!period.compounded, "Already compounded");

        uint256 unclaimedAmount = period.totalRevenue - period.totalClaimed;
        require(unclaimedAmount > 0, "No unclaimed royalties");

        period.compounded = true;
        totalCompounded[fractionToken] += unclaimedAmount;

        // In a production system, this would buy back fractions from the market
        // For now, we keep the funds in the contract for the token holders

        emit UnclaimedRoyaltiesCompounded(
            fractionToken,
            periodId,
            unclaimedAmount
        );
    }

    // Emergency functions for contract owner
    function emergencyWithdraw(uint256 amount) external onlyOwner whenPaused {
        require(amount > 0, "Invalid amount");
        require(amount <= address(this).balance, "Insufficient balance");

        (bool success, ) = payable(owner()).call{value: amount}("");
        require(success, "Transfer failed");
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // View functions
    function getPeriodInfo(
        address fractionToken,
        uint256 periodId
    )
        external
        view
        returns (
            uint256 totalRevenue,
            uint256 totalClaimed,
            bytes32 merkleRoot,
            uint256 timestamp,
            uint256 claimDeadline,
            bool compounded
        )
    {
        RoyaltyPeriod storage period = royaltyPeriods[fractionToken][periodId];
        return (
            period.totalRevenue,
            period.totalClaimed,
            period.merkleRoot,
            period.timestamp,
            period.claimDeadline,
            period.compounded
        );
    }

    function hasClaimed(
        address fractionToken,
        uint256 periodId,
        address user
    ) external view returns (bool) {
        return royaltyPeriods[fractionToken][periodId].claimed[user];
    }

    function getClaimedAmount(
        address fractionToken,
        uint256 periodId,
        address user
    ) external view returns (uint256) {
        return royaltyPeriods[fractionToken][periodId].claimedAmounts[user];
    }

    function getCurrentPeriod(
        address fractionToken
    ) external view returns (uint256) {
        return currentPeriod[fractionToken];
    }

    function getTotalDistributed(
        address fractionToken
    ) external view returns (uint256) {
        return totalDistributed[fractionToken];
    }

    function getTotalCompounded(
        address fractionToken
    ) external view returns (uint256) {
        return totalCompounded[fractionToken];
    }

    function getUnclaimedAmount(
        address fractionToken,
        uint256 periodId
    ) external view returns (uint256) {
        RoyaltyPeriod storage period = royaltyPeriods[fractionToken][periodId];
        if (period.totalRevenue > period.totalClaimed) {
            return period.totalRevenue - period.totalClaimed;
        }
        return 0;
    }

    function getCurrentPeriodId() external view returns (uint256) {
        return block.timestamp / WEEK;
    }
}
