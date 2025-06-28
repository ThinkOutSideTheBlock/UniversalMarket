// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract FRACToken is
    ERC20,
    ERC20Burnable,
    ERC20Permit,
    Ownable,
    ReentrancyGuard,
    Pausable
{
    // Constants
    uint256 public constant MAX_SUPPLY = 100_000_000 * 10 ** 18;
    uint256 public constant INITIAL_SUPPLY = 10_000_000 * 10 ** 18;
    uint256 public constant DAILY_MINT_CAP = 100_000 * 10 ** 18;
    uint256 public constant MONTHLY_MINT_CAP = 2_000_000 * 10 ** 18;
    uint256 private constant DAY_IN_SECONDS = 86400;
    uint256 private constant MONTH_IN_SECONDS = 2592000;

    // Minting tracking
    struct MintingPeriod {
        uint256 daily;
        uint256 monthly;
        uint256 lastDailyReset;
        uint256 lastMonthlyReset;
    }

    mapping(address => bool) public minters;
    mapping(address => bool) public burners;
    mapping(address => MintingPeriod) public mintingLimits;

    uint256 public globalDailyMinted;
    uint256 public globalMonthlyMinted;
    uint256 public lastGlobalDailyReset;
    uint256 public lastGlobalMonthlyReset;

    // Events
    event MinterAdded(address indexed minter);
    event MinterRemoved(address indexed minter);
    event BurnerAdded(address indexed burner);
    event BurnerRemoved(address indexed burner);
    event MintingCapExceeded(
        address indexed minter,
        uint256 requested,
        uint256 available
    );

    constructor()
        ERC20("Fraction Base Token", "FRAC")
        ERC20Permit("Fraction Base Token")
        Ownable(msg.sender)
    {
        _mint(msg.sender, INITIAL_SUPPLY);
        lastGlobalDailyReset = block.timestamp;
        lastGlobalMonthlyReset = block.timestamp;
    }

    modifier onlyMinter() {
        require(
            minters[msg.sender] || msg.sender == owner(),
            "Not authorized to mint"
        );
        _;
    }

    modifier onlyBurner() {
        require(
            burners[msg.sender] || msg.sender == owner(),
            "Not authorized to burn"
        );
        _;
    }

    function mint(
        address to,
        uint256 amount
    ) external onlyMinter nonReentrant whenNotPaused {
        require(totalSupply() + amount <= MAX_SUPPLY, "Max supply exceeded");
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Invalid amount");

        // Check and update minting caps
        _updateMintingPeriods();

        // Check daily cap
        require(
            globalDailyMinted + amount <= DAILY_MINT_CAP,
            "Daily mint cap exceeded"
        );

        // Check monthly cap
        require(
            globalMonthlyMinted + amount <= MONTHLY_MINT_CAP,
            "Monthly mint cap exceeded"
        );

        // Check individual minter caps (50% of global caps)
        MintingPeriod storage minterLimits = mintingLimits[msg.sender];
        _updateMinterPeriods(minterLimits);

        uint256 minterDailyCap = DAILY_MINT_CAP / 2;
        uint256 minterMonthlyCap = MONTHLY_MINT_CAP / 2;

        require(
            minterLimits.daily + amount <= minterDailyCap,
            "Minter daily cap exceeded"
        );
        require(
            minterLimits.monthly + amount <= minterMonthlyCap,
            "Minter monthly cap exceeded"
        );

        // Update minting totals
        globalDailyMinted += amount;
        globalMonthlyMinted += amount;
        minterLimits.daily += amount;
        minterLimits.monthly += amount;

        _mint(to, amount);
    }

    function _updateMintingPeriods() internal {
        // Reset daily counter if needed
        if (block.timestamp >= lastGlobalDailyReset + DAY_IN_SECONDS) {
            globalDailyMinted = 0;
            lastGlobalDailyReset = block.timestamp;
        }

        // Reset monthly counter if needed
        if (block.timestamp >= lastGlobalMonthlyReset + MONTH_IN_SECONDS) {
            globalMonthlyMinted = 0;
            lastGlobalMonthlyReset = block.timestamp;
        }
    }

    function _updateMinterPeriods(MintingPeriod storage period) internal {
        // Reset daily counter if needed
        if (block.timestamp >= period.lastDailyReset + DAY_IN_SECONDS) {
            period.daily = 0;
            period.lastDailyReset = block.timestamp;
        }

        // Reset monthly counter if needed
        if (block.timestamp >= period.lastMonthlyReset + MONTH_IN_SECONDS) {
            period.monthly = 0;
            period.lastMonthlyReset = block.timestamp;
        }
    }

    function burnFrom(
        address account,
        uint256 amount
    ) public override onlyBurner whenNotPaused {
        require(account != address(0), "Invalid account");
        require(amount > 0, "Invalid amount");

        uint256 currentAllowance = allowance(account, msg.sender);
        require(currentAllowance >= amount, "Burn amount exceeds allowance");

        _approve(account, msg.sender, currentAllowance - amount);
        _burn(account, amount);
    }

    function addMinter(address minter) external onlyOwner {
        require(minter != address(0), "Invalid minter");
        require(!minters[minter], "Already a minter");

        minters[minter] = true;
        mintingLimits[minter] = MintingPeriod({
            daily: 0,
            monthly: 0,
            lastDailyReset: block.timestamp,
            lastMonthlyReset: block.timestamp
        });

        emit MinterAdded(minter);
    }

    function removeMinter(address minter) external onlyOwner {
        require(minters[minter], "Not a minter");

        minters[minter] = false;
        delete mintingLimits[minter];

        emit MinterRemoved(minter);
    }

    function addBurner(address burner) external onlyOwner {
        require(burner != address(0), "Invalid burner");
        require(!burners[burner], "Already a burner");

        burners[burner] = true;
        emit BurnerAdded(burner);
    }

    function removeBurner(address burner) external onlyOwner {
        require(burners[burner], "Not a burner");

        burners[burner] = false;
        emit BurnerRemoved(burner);
    }

    // View functions
    function isMinter(address account) external view returns (bool) {
        return minters[account];
    }

    function isBurner(address account) external view returns (bool) {
        return burners[account];
    }

    function getRemainingDailyMint() external view returns (uint256) {
        if (block.timestamp >= lastGlobalDailyReset + DAY_IN_SECONDS) {
            return DAILY_MINT_CAP;
        }
        return
            DAILY_MINT_CAP > globalDailyMinted
                ? DAILY_MINT_CAP - globalDailyMinted
                : 0;
    }

    function getRemainingMonthlyMint() external view returns (uint256) {
        if (block.timestamp >= lastGlobalMonthlyReset + MONTH_IN_SECONDS) {
            return MONTHLY_MINT_CAP;
        }
        return
            MONTHLY_MINT_CAP > globalMonthlyMinted
                ? MONTHLY_MINT_CAP - globalMonthlyMinted
                : 0;
    }

    function getMinterLimits(
        address minter
    )
        external
        view
        returns (
            uint256 dailyUsed,
            uint256 monthlyUsed,
            uint256 dailyRemaining,
            uint256 monthlyRemaining
        )
    {
        MintingPeriod memory limits = mintingLimits[minter];
        uint256 minterDailyCap = DAILY_MINT_CAP / 2;
        uint256 minterMonthlyCap = MONTHLY_MINT_CAP / 2;

        // Check if periods need reset
        if (block.timestamp >= limits.lastDailyReset + DAY_IN_SECONDS) {
            dailyUsed = 0;
            dailyRemaining = minterDailyCap;
        } else {
            dailyUsed = limits.daily;
            dailyRemaining = minterDailyCap > limits.daily
                ? minterDailyCap - limits.daily
                : 0;
        }

        if (block.timestamp >= limits.lastMonthlyReset + MONTH_IN_SECONDS) {
            monthlyUsed = 0;
            monthlyRemaining = minterMonthlyCap;
        } else {
            monthlyUsed = limits.monthly;
            monthlyRemaining = minterMonthlyCap > limits.monthly
                ? minterMonthlyCap - limits.monthly
                : 0;
        }
    }

    // Emergency functions
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function recoverERC20(
        address tokenAddress,
        uint256 tokenAmount
    ) external onlyOwner {
        require(tokenAddress != address(this), "Cannot recover FRAC tokens");
        IERC20(tokenAddress).transfer(owner(), tokenAmount);
    }
}
