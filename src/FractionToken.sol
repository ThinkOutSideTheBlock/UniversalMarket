// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

interface IEmergencyControls {
    function isContractPaused(
        address contractAddr
    ) external view returns (bool);
}

contract FractionToken is
    ERC20Upgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    IERC721Receiver
{
    // Constants
    uint256 private constant MIN_OWNERSHIP_PERCENT = 20;
    uint256 private constant EXECUTE_THRESHOLD_PERCENT = 51;
    uint256 private constant BUYOUT_DURATION = 7 days;
    uint256 private constant FLASH_LOAN_PROTECTION = 1 hours;
    uint256 private constant PERCENT_DENOMINATOR = 100;

    // State variables
    address public nftContract;
    uint256 public tokenId;
    uint256 public buyoutPrice;
    bool public redeemed;
    IEmergencyControls public emergencyControls;

    struct Buyout {
        address proposer;
        uint256 pricePerFraction;
        uint256 totalOffered;
        uint256 deadline;
        bool executed;
        bool cancelled;
        mapping(address => uint256) escrowedFractions;
        uint256 totalEscrowed;
    }

    Buyout public currentBuyout;

    mapping(address => uint256) public lastTransferTime;
    mapping(address => uint256) public timeWeightedBalance;

    // Events
    event BuyoutProposed(
        address indexed proposer,
        uint256 pricePerFraction,
        uint256 deadline
    );
    event BuyoutAccepted(
        address indexed acceptor,
        uint256 fractions,
        uint256 payment
    );
    event BuyoutExecuted(address indexed proposer, uint256 totalPrice);
    event BuyoutCancelled(address indexed proposer, string reason);
    event BuyoutRefunded(address indexed user, uint256 fractions);
    event NFTRedeemed(address indexed redeemer);
    event EmergencyControlsSet(address indexed controls);

    // Modifiers
    modifier notPaused() {
        if (address(emergencyControls) != address(0)) {
            require(
                !emergencyControls.isContractPaused(address(this)),
                "Contract is paused"
            );
        }
        require(!paused(), "Contract is paused");
        _;
    }

    modifier onlyValidBuyout() {
        require(currentBuyout.deadline > block.timestamp, "No active buyout");
        require(!currentBuyout.executed, "Buyout already executed");
        require(!currentBuyout.cancelled, "Buyout cancelled");
        _;
    }

    function initialize(
        string memory name,
        string memory symbol,
        address _nftContract,
        uint256 _tokenId,
        uint256 _totalSupply,
        address _owner,
        uint256 _liquidityAmount,
        address _liquidityRecipient
    ) external initializer {
        __ERC20_init(name, symbol);
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();

        require(_nftContract != address(0), "Invalid NFT contract");
        require(_totalSupply > 0, "Invalid total supply");

        nftContract = _nftContract;
        tokenId = _tokenId;

        // Mint liquidity tokens to recipient
        if (_liquidityAmount > 0 && _liquidityRecipient != address(0)) {
            _mint(_liquidityRecipient, _liquidityAmount);
        }

        // Mint remaining tokens to owner
        uint256 userTokens = _totalSupply - _liquidityAmount;
        if (userTokens > 0) {
            _mint(_owner, userTokens);
        }

        _transferOwnership(_owner);
    }

    function setEmergencyControls(address _controls) external onlyOwner {
        require(_controls != address(0), "Invalid controls");
        emergencyControls = IEmergencyControls(_controls);
        emit EmergencyControlsSet(_controls);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function proposeBuyout(
        uint256 pricePerFraction
    ) external payable nonReentrant notPaused {
        require(
            balanceOf(msg.sender) >=
                (totalSupply() * MIN_OWNERSHIP_PERCENT) / PERCENT_DENOMINATOR,
            "Need 20% ownership"
        );
        require(
            currentBuyout.deadline == 0 ||
                block.timestamp > currentBuyout.deadline,
            "Active buyout exists"
        );
        require(
            msg.value >= pricePerFraction * totalSupply(),
            "Insufficient payment"
        );
        require(
            block.timestamp >
                lastTransferTime[msg.sender] + FLASH_LOAN_PROTECTION,
            "Flash loan protection"
        );

        // Cancel previous buyout if exists and not executed
        if (currentBuyout.deadline > 0 && !currentBuyout.executed) {
            _cancelBuyout("New buyout proposed");
        }

        // Initialize new buyout
        Buyout storage newBuyout = currentBuyout;
        newBuyout.proposer = msg.sender;
        newBuyout.pricePerFraction = pricePerFraction;
        newBuyout.totalOffered = msg.value;
        newBuyout.deadline = block.timestamp + BUYOUT_DURATION;
        newBuyout.executed = false;
        newBuyout.cancelled = false;
        newBuyout.totalEscrowed = balanceOf(msg.sender);

        // Escrow proposer's fractions
        newBuyout.escrowedFractions[msg.sender] = balanceOf(msg.sender);

        emit BuyoutProposed(msg.sender, pricePerFraction, newBuyout.deadline);
    }

    function acceptBuyout(
        uint256 fractions
    ) external nonReentrant onlyValidBuyout notPaused {
        require(fractions > 0, "Invalid fraction amount");
        require(fractions <= balanceOf(msg.sender), "Insufficient balance");

        Buyout storage buyout = currentBuyout;
        require(msg.sender != buyout.proposer, "Proposer cannot accept");

        // Escrow fractions
        buyout.escrowedFractions[msg.sender] += fractions;
        buyout.totalEscrowed += fractions;

        // Calculate payment
        uint256 payment = fractions * buyout.pricePerFraction;

        // Transfer payment to acceptor
        (bool success, ) = payable(msg.sender).call{value: payment}("");
        require(success, "Payment failed");

        emit BuyoutAccepted(msg.sender, fractions, payment);

        // Auto-execute if threshold reached
        if (
            buyout.totalEscrowed >=
            (totalSupply() * EXECUTE_THRESHOLD_PERCENT) / PERCENT_DENOMINATOR
        ) {
            _executeBuyout();
        }
    }

    function executeBuyout() external nonReentrant notPaused {
        require(currentBuyout.deadline > 0, "No buyout to execute");
        require(!currentBuyout.executed, "Already executed");
        require(!currentBuyout.cancelled, "Buyout cancelled");

        if (block.timestamp <= currentBuyout.deadline) {
            require(
                currentBuyout.totalEscrowed >=
                    (totalSupply() * EXECUTE_THRESHOLD_PERCENT) /
                        PERCENT_DENOMINATOR,
                "Threshold not reached"
            );
        }

        _executeBuyout();
    }

    function _executeBuyout() internal {
        Buyout storage buyout = currentBuyout;
        buyout.executed = true;

        if (
            buyout.totalEscrowed >=
            (totalSupply() * EXECUTE_THRESHOLD_PERCENT) / PERCENT_DENOMINATOR
        ) {
            // Transfer all escrowed fractions to proposer
            for (uint i = 0; i < totalSupply(); i++) {
                address holder = address(uint160(i)); // This is simplified, need proper tracking
                if (buyout.escrowedFractions[holder] > 0) {
                    _transfer(
                        holder,
                        buyout.proposer,
                        buyout.escrowedFractions[holder]
                    );
                }
            }

            // Transfer NFT to buyout proposer
            IERC721(nftContract).transferFrom(
                address(this),
                buyout.proposer,
                tokenId
            );

            emit BuyoutExecuted(buyout.proposer, buyout.totalOffered);
        } else {
            _cancelBuyout("Threshold not reached");
        }
    }

    function _cancelBuyout(string memory reason) internal {
        Buyout storage buyout = currentBuyout;
        buyout.cancelled = true;

        // Refund proposer
        if (buyout.totalOffered > 0) {
            (bool success, ) = payable(buyout.proposer).call{
                value: buyout.totalOffered
            }("");
            require(success, "Refund failed");
        }

        emit BuyoutCancelled(buyout.proposer, reason);
    }

    function claimRefund() external nonReentrant {
        require(currentBuyout.cancelled, "Buyout not cancelled");
        uint256 escrowed = currentBuyout.escrowedFractions[msg.sender];
        require(escrowed > 0, "No refund available");

        currentBuyout.escrowedFractions[msg.sender] = 0;
        emit BuyoutRefunded(msg.sender, escrowed);
    }

    function redeemNFT() external nonReentrant notPaused {
        require(
            balanceOf(msg.sender) == totalSupply(),
            "Must own all fractions"
        );
        require(!redeemed, "Already redeemed");

        redeemed = true;
        _burn(msg.sender, totalSupply());

        IERC721(nftContract).transferFrom(address(this), msg.sender, tokenId);
        emit NFTRedeemed(msg.sender);
    }

    function getTimeWeightedBalance(
        address user
    ) external view returns (uint256) {
        uint256 timePassed = block.timestamp - lastTransferTime[user];
        return timeWeightedBalance[user] + (balanceOf(user) * timePassed);
    }

    function getBuyoutInfo()
        external
        view
        returns (
            address proposer,
            uint256 pricePerFraction,
            uint256 totalOffered,
            uint256 totalEscrowed,
            bool executed,
            bool active
        )
    {
        Buyout storage buyout = currentBuyout;
        return (
            buyout.proposer,
            buyout.pricePerFraction,
            buyout.totalOffered,
            buyout.totalEscrowed,
            buyout.executed,
            buyout.deadline > block.timestamp &&
                !buyout.executed &&
                !buyout.cancelled
        );
    }

    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        // Update time-weighted balances before transfer
        if (from != address(0)) {
            uint256 timePassed = block.timestamp - lastTransferTime[from];
            timeWeightedBalance[from] += balanceOf(from) * timePassed;
            lastTransferTime[from] = block.timestamp;
        }

        if (to != address(0)) {
            uint256 timePassed = block.timestamp - lastTransferTime[to];
            timeWeightedBalance[to] += balanceOf(to) * timePassed;
            lastTransferTime[to] = block.timestamp;
        }

        super._update(from, to, amount);
    }

    // Override transfer functions to check pause status
    function transfer(
        address to,
        uint256 amount
    ) public override notPaused returns (bool) {
        return super.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override notPaused returns (bool) {
        return super.transferFrom(from, to, amount);
    }
}
