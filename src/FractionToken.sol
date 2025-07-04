// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

interface IEmergencyControls {
    function isContractPaused(
        address contractAddr
    ) external view returns (bool);
}

interface IRoyaltyDistributor {
    function initialize(address fractionToken) external;
    function depositRoyalties(
        address fractionToken,
        bytes32 merkleRoot
    ) external payable;
}

contract FractionToken is
    ERC20Upgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    IERC721Receiver
{
    using EnumerableSet for EnumerableSet.AddressSet;

    // Constants
    uint256 private constant MIN_OWNERSHIP_PERCENT = 20;
    uint256 private constant EXECUTE_THRESHOLD_PERCENT = 51;
    uint256 private constant BUYOUT_DURATION = 7 days;
    uint256 private constant FLASH_LOAN_PROTECTION = 1 hours;
    uint256 private constant PERCENT_DENOMINATOR = 100;
    uint256 private constant MAX_SLIPPAGE = 1000; // 10%

    // State variables
    address public nftContract;
    uint256 public tokenId;
    uint256 public buyoutPrice;
    bool public redeemed;
    IEmergencyControls public emergencyControls;
    IRoyaltyDistributor public royaltyDistributor;

    // Asset metadata
    uint8 public assetCategory;
    string public metadataURI;
    mapping(string => string) public assetAttributes;
    string[] public attributeKeys;

    // Holder tracking - FIXED
    EnumerableSet.AddressSet private holders;

    struct Buyout {
        address proposer;
        uint256 pricePerFraction;
        uint256 totalOffered;
        uint256 deadline;
        bool executed;
        bool cancelled;
        mapping(address => uint256) escrowedFractions;
        uint256 totalEscrowed;
        mapping(address => uint256) refundAmounts;
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
    event BuyoutRefunded(
        address indexed user,
        uint256 fractions,
        uint256 ethAmount
    );
    event NFTRedeemed(address indexed redeemer);
    event EmergencyControlsSet(address indexed controls);
    event RoyaltyDistributorSet(address indexed distributor);
    event AssetAttributeSet(string key, string value);
    event RoyaltyDeposited(uint256 amount, bytes32 merkleRoot);

    // Modifiers
    modifier notPaused() {
        if (address(emergencyControls) != address(0)) {
            require(
                !emergencyControls.isContractPaused(address(this)),
                "Emergency paused"
            );
        }
        require(!paused(), "Contract paused");
        _;
    }

    modifier onlyValidBuyout() {
        require(currentBuyout.deadline > block.timestamp, "No active buyout");
        require(!currentBuyout.executed, "Buyout already executed");
        require(!currentBuyout.cancelled, "Buyout cancelled");
        _;
    }

    modifier validSlippage(uint256 slippage) {
        require(slippage <= MAX_SLIPPAGE, "Slippage too high");
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
        address _liquidityRecipient,
        uint8 _assetCategory,
        string memory _metadataURI
    ) external initializer {
        __ERC20_init(name, symbol);
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();

        require(_nftContract != address(0), "Invalid NFT contract");
        require(_totalSupply > 0, "Invalid total supply");
        require(_owner != address(0), "Invalid owner");

        nftContract = _nftContract;
        tokenId = _tokenId;
        assetCategory = _assetCategory;
        metadataURI = _metadataURI;

        // Mint liquidity tokens to recipient
        if (_liquidityAmount > 0 && _liquidityRecipient != address(0)) {
            _mint(_liquidityRecipient, _liquidityAmount);
            holders.add(_liquidityRecipient);
        }

        // Mint remaining tokens to owner
        uint256 userTokens = _totalSupply - _liquidityAmount;
        if (userTokens > 0) {
            _mint(_owner, userTokens);
            holders.add(_owner);
        }

        _transferOwnership(_owner);
    }

    function setEmergencyControls(address _controls) external onlyOwner {
        require(_controls != address(0), "Invalid controls");
        emergencyControls = IEmergencyControls(_controls);
        emit EmergencyControlsSet(_controls);
    }

    function setRoyaltyDistributor(address _distributor) external onlyOwner {
        require(_distributor != address(0), "Invalid distributor");
        royaltyDistributor = IRoyaltyDistributor(_distributor);
        emit RoyaltyDistributorSet(_distributor);
    }

    function setAssetAttribute(
        string calldata key,
        string calldata value
    ) external onlyOwner {
        if (bytes(assetAttributes[key]).length == 0) {
            attributeKeys.push(key);
        }
        assetAttributes[key] = value;
        emit AssetAttributeSet(key, value);
    }

    function depositRoyalties(
        bytes32 merkleRoot
    ) external payable nonReentrant {
        require(msg.value > 0, "No ETH sent");
        require(
            address(royaltyDistributor) != address(0),
            "No royalty distributor"
        );

        royaltyDistributor.depositRoyalties{value: msg.value}(
            address(this),
            merkleRoot
        );
        emit RoyaltyDeposited(msg.value, merkleRoot);
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
        uint256 pricePerFraction,
        uint256 maxSlippage
    ) external payable nonReentrant notPaused validSlippage(maxSlippage) {
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
        _resetBuyoutState();

        currentBuyout.proposer = msg.sender;
        currentBuyout.pricePerFraction = pricePerFraction;
        currentBuyout.totalOffered = msg.value;
        currentBuyout.deadline = block.timestamp + BUYOUT_DURATION;
        currentBuyout.executed = false;
        currentBuyout.cancelled = false;

        uint256 proposerBalance = balanceOf(msg.sender);
        currentBuyout.totalEscrowed = proposerBalance;
        currentBuyout.escrowedFractions[msg.sender] = proposerBalance;

        emit BuyoutProposed(
            msg.sender,
            pricePerFraction,
            currentBuyout.deadline
        );
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
        buyout.refundAmounts[msg.sender] += payment;

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
            // Transfer all escrowed fractions to proposer - FIXED LOGIC
            uint256 holderCount = holders.length();
            for (uint256 i = 0; i < holderCount; i++) {
                address holder = holders.at(i);
                uint256 escrowedAmount = buyout.escrowedFractions[holder];
                if (escrowedAmount > 0 && holder != buyout.proposer) {
                    _transfer(holder, buyout.proposer, escrowedAmount);
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
        uint256 refundAmount = currentBuyout.refundAmounts[msg.sender];
        require(escrowed > 0 || refundAmount > 0, "No refund available");

        currentBuyout.escrowedFractions[msg.sender] = 0;
        currentBuyout.refundAmounts[msg.sender] = 0;

        if (refundAmount > 0) {
            (bool success, ) = payable(msg.sender).call{value: refundAmount}(
                ""
            );
            require(success, "Refund transfer failed");
        }

        emit BuyoutRefunded(msg.sender, escrowed, refundAmount);
    }

    function redeemNFT() external nonReentrant notPaused {
        require(
            balanceOf(msg.sender) == totalSupply(),
            "Must own all fractions"
        );
        require(!redeemed, "Already redeemed");

        redeemed = true;
        _burn(msg.sender, totalSupply());
        holders.remove(msg.sender);

        IERC721(nftContract).transferFrom(address(this), msg.sender, tokenId);
        emit NFTRedeemed(msg.sender);
    }

    function _resetBuyoutState() internal {
        // Clear previous buyout mappings
        uint256 holderCount = holders.length();
        for (uint256 i = 0; i < holderCount; i++) {
            address holder = holders.at(i);
            currentBuyout.escrowedFractions[holder] = 0;
            currentBuyout.refundAmounts[holder] = 0;
        }
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

    function getHolders() external view returns (address[] memory) {
        uint256 length = holders.length();
        address[] memory holderList = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            holderList[i] = holders.at(i);
        }
        return holderList;
    }

    function getAssetAttributes()
        external
        view
        returns (string[] memory keys, string[] memory values)
    {
        keys = attributeKeys;
        values = new string[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            values[i] = assetAttributes[keys[i]];
        }
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

            // Remove from holders if balance becomes zero
            if (balanceOf(from) == amount) {
                holders.remove(from);
            }
        }

        if (to != address(0)) {
            uint256 timePassed = block.timestamp - lastTransferTime[to];
            timeWeightedBalance[to] += balanceOf(to) * timePassed;
            lastTransferTime[to] = block.timestamp;

            // Add to holders if new holder
            if (balanceOf(to) == 0) {
                holders.add(to);
            }
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

    // Emergency functions
    function emergencyWithdraw() external onlyOwner whenPaused {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success, ) = payable(owner()).call{value: balance}("");
            require(success, "Emergency withdraw failed");
        }
    }

    receive() external payable {
        // Allow contract to receive ETH for royalty deposits
    }
}
