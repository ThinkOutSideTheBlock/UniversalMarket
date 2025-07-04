// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IFractionToken.sol";

interface IHybridLiquidityEngine {
    function swapETHForTokens(
        address token,
        uint256 minTokensOut,
        uint256 deadline
    ) external payable returns (uint256);
    function hasETHPool(address token) external view returns (bool);
    function getETHPoolInfo(
        address token
    ) external view returns (uint256, uint256, uint256, uint256, uint256);
}

contract RoyaltyDistributor is
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // Constants
    uint256 public constant CLAIM_PERIOD = 30 days;
    uint256 public constant WEEK = 7 days;
    uint256 private constant MAX_BATCH_SIZE = 50;
    uint256 private constant COMPOUND_THRESHOLD = 0.1 ether; // Minimum ETH to trigger buyback

    // State variables
    address public fractionToken;
    IHybridLiquidityEngine public liquidityEngine;
    bool public autoCompoundEnabled;
    uint256 public compoundPercentage; // Percentage of unclaimed to use for buyback (default 100%)

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

    mapping(uint256 => RoyaltyPeriod) public royaltyPeriods;
    uint256 public currentPeriod;
    uint256 public totalDistributed;
    uint256 public totalCompounded;
    uint256 public totalBurned; // Fractions burned through compounding

    // Events
    event RoyaltiesDeposited(
        uint256 indexed period,
        uint256 amount,
        bytes32 merkleRoot
    );
    event RoyaltiesClaimed(
        uint256 indexed period,
        address indexed user,
        uint256 amount
    );
    event UnclaimedRoyaltiesCompounded(
        uint256 indexed period,
        uint256 ethAmount,
        uint256 fractionsBurned
    );
    event BatchClaimCompleted(
        address indexed user,
        uint256 totalAmount,
        uint256 periodsCount
    );
    event AutoCompoundToggled(bool enabled);
    event LiquidityEngineSet(address indexed engine);
    event CompoundPercentageSet(uint256 percentage);

    modifier validPeriod(uint256 periodId) {
        require(
            royaltyPeriods[periodId].merkleRoot != bytes32(0),
            "Period does not exist"
        );
        _;
    }

    function initialize() external initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __Pausable_init();

        autoCompoundEnabled = true;
        compoundPercentage = 10000; // 100%
    }

    function setFractionToken(address _fractionToken) external onlyOwner {
        require(_fractionToken != address(0), "Invalid fraction token");
        fractionToken = _fractionToken;
    }

    function setLiquidityEngine(address _liquidityEngine) external onlyOwner {
        require(_liquidityEngine != address(0), "Invalid liquidity engine");
        liquidityEngine = IHybridLiquidityEngine(_liquidityEngine);
        emit LiquidityEngineSet(_liquidityEngine);
    }

    function setAutoCompound(bool enabled) external onlyOwner {
        autoCompoundEnabled = enabled;
        emit AutoCompoundToggled(enabled);
    }

    function setCompoundPercentage(uint256 percentage) external onlyOwner {
        require(percentage <= 10000, "Invalid percentage");
        compoundPercentage = percentage;
        emit CompoundPercentageSet(percentage);
    }

    function depositRoyalties(
        bytes32 merkleRoot
    ) external payable nonReentrant whenNotPaused {
        require(msg.value > 0, "No ETH sent");
        require(merkleRoot != bytes32(0), "Invalid merkle root");

        uint256 periodId = block.timestamp / WEEK;
        RoyaltyPeriod storage period = royaltyPeriods[periodId];

        period.totalRevenue += msg.value;
        period.merkleRoot = merkleRoot;
        period.timestamp = block.timestamp;
        period.claimDeadline = block.timestamp + CLAIM_PERIOD;

        if (currentPeriod < periodId) {
            currentPeriod = periodId;
        }

        totalDistributed += msg.value;

        emit RoyaltiesDeposited(periodId, msg.value, merkleRoot);
    }

    function claimRoyalties(
        uint256 periodId,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) external nonReentrant whenNotPaused validPeriod(periodId) {
        RoyaltyPeriod storage period = royaltyPeriods[periodId];

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

        emit RoyaltiesClaimed(periodId, msg.sender, amount);
    }

    function batchClaimRoyalties(
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

            RoyaltyPeriod storage period = royaltyPeriods[periodId];

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

            emit RoyaltiesClaimed(periodId, msg.sender, amount);
        }

        // Transfer total royalties
        (bool success, ) = payable(msg.sender).call{value: totalAmount}("");
        require(success, "Transfer failed");

        emit BatchClaimCompleted(msg.sender, totalAmount, periodIds.length);
    }

    function compoundUnclaimedRoyalties(
        uint256 periodId
    ) external nonReentrant whenNotPaused validPeriod(periodId) {
        RoyaltyPeriod storage period = royaltyPeriods[periodId];

        require(
            block.timestamp > period.claimDeadline,
            "Claim period not expired"
        );
        require(!period.compounded, "Already compounded");

        uint256 unclaimedAmount = period.totalRevenue - period.totalClaimed;
        require(unclaimedAmount > 0, "No unclaimed royalties");

        period.compounded = true;

        uint256 compoundAmount = (unclaimedAmount * compoundPercentage) / 10000;
        totalCompounded += compoundAmount;

        uint256 fractionsBurned = 0;

        if (
            autoCompoundEnabled &&
            compoundAmount >= COMPOUND_THRESHOLD &&
            address(liquidityEngine) != address(0)
        ) {
            fractionsBurned = _buybackAndBurn(compoundAmount);
        }

        emit UnclaimedRoyaltiesCompounded(
            periodId,
            compoundAmount,
            fractionsBurned
        );
    }

    function _buybackAndBurn(uint256 ethAmount) internal returns (uint256) {
        if (!liquidityEngine.hasETHPool(fractionToken)) {
            return 0;
        }

        try
            liquidityEngine.swapETHForTokens{value: ethAmount}(
                fractionToken,
                0, // Accept any amount of tokens
                block.timestamp + 300 // 5 minute deadline
            )
        returns (uint256 tokensReceived) {
            // Burn the received fraction tokens
            IFractionToken(fractionToken).burn(tokensReceived);
            totalBurned += tokensReceived;
            return tokensReceived;
        } catch {
            // If buyback fails, keep ETH in contract for token holders
            return 0;
        }
    }

    // Batch compound multiple periods
    function batchCompoundRoyalties(
        uint256[] calldata periodIds
    ) external nonReentrant whenNotPaused {
        require(periodIds.length <= MAX_BATCH_SIZE, "Too many periods");

        uint256 totalCompoundAmount = 0;
        uint256 totalFractionsBurned = 0;

        for (uint i = 0; i < periodIds.length; i++) {
            uint256 periodId = periodIds[i];
            RoyaltyPeriod storage period = royaltyPeriods[periodId];

            if (
                period.merkleRoot == bytes32(0) ||
                period.compounded ||
                block.timestamp <= period.claimDeadline
            ) {
                continue;
            }

            uint256 unclaimedAmount = period.totalRevenue - period.totalClaimed;
            if (unclaimedAmount == 0) continue;

            period.compounded = true;
            uint256 compoundAmount = (unclaimedAmount * compoundPercentage) /
                10000;
            totalCompoundAmount += compoundAmount;

            emit UnclaimedRoyaltiesCompounded(periodId, compoundAmount, 0);
        }

        if (totalCompoundAmount > 0) {
            totalCompounded += totalCompoundAmount;

            if (
                autoCompoundEnabled &&
                totalCompoundAmount >= COMPOUND_THRESHOLD &&
                address(liquidityEngine) != address(0)
            ) {
                totalFractionsBurned = _buybackAndBurn(totalCompoundAmount);
            }
        }
    }

    // Emergency functions
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
        RoyaltyPeriod storage period = royaltyPeriods[periodId];
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
        uint256 periodId,
        address user
    ) external view returns (bool) {
        return royaltyPeriods[periodId].claimed[user];
    }

    function getClaimedAmount(
        uint256 periodId,
        address user
    ) external view returns (uint256) {
        return royaltyPeriods[periodId].claimedAmounts[user];
    }

    function getCurrentPeriod() external view returns (uint256) {
        return currentPeriod;
    }

    function getTotalDistributed() external view returns (uint256) {
        return totalDistributed;
    }

    function getTotalCompounded() external view returns (uint256) {
        return totalCompounded;
    }

    function getTotalBurned() external view returns (uint256) {
        return totalBurned;
    }

    function getUnclaimedAmount(
        uint256 periodId
    ) external view returns (uint256) {
        RoyaltyPeriod storage period = royaltyPeriods[periodId];
        if (period.totalRevenue > period.totalClaimed) {
            return period.totalRevenue - period.totalClaimed;
        }
        return 0;
    }

    function getCurrentPeriodId() external view returns (uint256) {
        return block.timestamp / WEEK;
    }

    function getStats()
        external
        view
        returns (
            uint256 _totalDistributed,
            uint256 _totalCompounded,
            uint256 _totalBurned,
            uint256 _currentPeriod,
            bool _autoCompoundEnabled
        )
    {
        return (
            totalDistributed,
            totalCompounded,
            totalBurned,
            currentPeriod,
            autoCompoundEnabled
        );
    }

    receive() external payable {
        // Allow contract to receive ETH for royalty deposits
    }
}
