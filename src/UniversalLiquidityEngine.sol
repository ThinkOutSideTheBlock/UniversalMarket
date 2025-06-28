
/*
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IFractionToken.sol";


contract UniversalLiquidityEngine is Ownable, ReentrancyGuard {
    struct Pool {
        uint256 ethReserve;
        uint256 tokenReserve;
        uint256 totalLiquidity;
        uint256 lastPrice;
        uint256 volume24h;
        uint256 lastVolumeUpdate;
        mapping(address => uint256) liquidity;
    }

    mapping(address => Pool) public pools;
    address[] public allPools;

    uint256 public constant FEE_RATE = 300; // 0.3%
    uint256 public constant FEE_DENOMINATOR = 100000;

    event PoolCreated(
        address indexed token,
        uint256 ethAmount,
        uint256 tokenAmount
    );
    event LiquidityAdded(
        address indexed token,
        address indexed provider,
        uint256 ethAmount,
        uint256 tokenAmount
    );
    event LiquidityRemoved(
        address indexed token,
        address indexed provider,
        uint256 ethAmount,
        uint256 tokenAmount
    );
    event Swap(
        address indexed token,
        address indexed user,
        uint256 ethIn,
        uint256 tokenOut,
        bool ethToToken
    );

    modifier validPool(address token) {
        require(pools[token].totalLiquidity > 0, "Pool does not exist");
        _;
    }

    function addInitialLiquidity(
        address token,
        uint256 tokenAmount
    ) external payable nonReentrant {
        require(msg.value > 0, "Must send ETH");
        require(tokenAmount > 0, "Must send tokens");
        require(pools[token].totalLiquidity == 0, "Pool already exists");

        Pool storage pool = pools[token];

        // Transfer tokens to contract
        IERC20(token).transferFrom(msg.sender, address(this), tokenAmount);

        // Calculate initial liquidity (geometric mean)
        uint256 liquidity = sqrt(msg.value * tokenAmount);
        require(liquidity > 1000, "Insufficient liquidity"); // Minimum liquidity

        pool.ethReserve = msg.value;
        pool.tokenReserve = tokenAmount;
        pool.totalLiquidity = liquidity;
        pool.liquidity[msg.sender] = liquidity;
        pool.lastPrice = (msg.value * 1e18) / tokenAmount;

        allPools.push(token);

        emit PoolCreated(token, msg.value, tokenAmount);
        emit LiquidityAdded(token, msg.sender, msg.value, tokenAmount);
    }

    function addLiquidity(
        address token
    ) external payable validPool(token) nonReentrant {
        require(msg.value > 0, "Must send ETH");

        Pool storage pool = pools[token];

        // Calculate proportional token amount
        uint256 tokenAmount = (msg.value * pool.tokenReserve) / pool.ethReserve;
        require(tokenAmount > 0, "Insufficient token amount");

        // Transfer tokens
        IERC20(token).transferFrom(msg.sender, address(this), tokenAmount);

        // Calculate liquidity to mint
        uint256 liquidity = (msg.value * pool.totalLiquidity) / pool.ethReserve;

        // Update reserves
        pool.ethReserve += msg.value;
        pool.tokenReserve += tokenAmount;
        pool.totalLiquidity += liquidity;
        pool.liquidity[msg.sender] += liquidity;

        emit LiquidityAdded(token, msg.sender, msg.value, tokenAmount);
    }

    function removeLiquidity(
        address token,
        uint256 liquidity
    ) external validPool(token) nonReentrant {
        Pool storage pool = pools[token];
        require(
            pool.liquidity[msg.sender] >= liquidity,
            "Insufficient liquidity"
        );
        require(liquidity > 0, "Invalid liquidity amount");

        // Calculate proportional amounts
        uint256 ethAmount = (liquidity * pool.ethReserve) / pool.totalLiquidity;
        uint256 tokenAmount = (liquidity * pool.tokenReserve) /
            pool.totalLiquidity;

        // Update state
        pool.liquidity[msg.sender] -= liquidity;
        pool.totalLiquidity -= liquidity;
        pool.ethReserve -= ethAmount;
        pool.tokenReserve -= tokenAmount;

        // Transfer assets
        IERC20(token).transfer(msg.sender, tokenAmount);
        payable(msg.sender).transfer(ethAmount);

        emit LiquidityRemoved(token, msg.sender, ethAmount, tokenAmount);
    }

    function swapETHForTokens(
        address token,
        uint256 minTokensOut
    )
        external
        payable
        validPool(token)
        nonReentrant
        returns (uint256 tokensOut)
    {
        require(msg.value > 0, "Must send ETH");

        Pool storage pool = pools[token];

        // Calculate output with fee
        uint256 ethAfterFee = (msg.value * (FEE_DENOMINATOR - FEE_RATE)) /
            FEE_DENOMINATOR;
        tokensOut = getAmountOut(
            ethAfterFee,
            pool.ethReserve,
            pool.tokenReserve
        );

        require(tokensOut >= minTokensOut, "Insufficient output amount");
        require(tokensOut < pool.tokenReserve, "Insufficient liquidity");

        // Update reserves
        pool.ethReserve += msg.value;
        pool.tokenReserve -= tokensOut;

        // Update price and volume
        pool.lastPrice = (pool.ethReserve * 1e18) / pool.tokenReserve;
        _updateVolume(token, msg.value);

        // Transfer tokens
        IERC20(token).transfer(msg.sender, tokensOut);

        emit Swap(token, msg.sender, msg.value, tokensOut, true);

        return tokensOut;
    }

    function swapTokensForETH(
        address token,
        uint256 tokenAmount,
        uint256 minETHOut
    ) external validPool(token) nonReentrant returns (uint256 ethOut) {
        require(tokenAmount > 0, "Must send tokens");

        Pool storage pool = pools[token];

        // Transfer tokens first
        IERC20(token).transferFrom(msg.sender, address(this), tokenAmount);

        // Calculate output with fee
        uint256 tokensAfterFee = (tokenAmount * (FEE_DENOMINATOR - FEE_RATE)) /
            FEE_DENOMINATOR;
        ethOut = getAmountOut(
            tokensAfterFee,
            pool.tokenReserve,
            pool.ethReserve
        );

        require(ethOut >= minETHOut, "Insufficient output amount");
        require(ethOut < pool.ethReserve, "Insufficient liquidity");

        // Update reserves
        pool.tokenReserve += tokenAmount;
        pool.ethReserve -= ethOut;

        // Update price and volume
        pool.lastPrice = (pool.ethReserve * 1e18) / pool.tokenReserve;
        _updateVolume(token, ethOut);

        // Transfer ETH
        payable(msg.sender).transfer(ethOut);

        emit Swap(token, msg.sender, ethOut, tokenAmount, false);

        return ethOut;
    }

    function _updateVolume(address token, uint256 amount) internal {
        Pool storage pool = pools[token];

        // Reset volume if more than 24 hours passed
        if (block.timestamp > pool.lastVolumeUpdate + 24 hours) {
            pool.volume24h = amount;
        } else {
            pool.volume24h += amount;
        }

        pool.lastVolumeUpdate = block.timestamp;
    }

    // View functions
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure returns (uint256 amountOut) {
        require(amountIn > 0, "Insufficient input amount");
        require(reserveIn > 0 && reserveOut > 0, "Insufficient liquidity");

        uint256 numerator = amountIn * reserveOut;
        uint256 denominator = reserveIn + amountIn;
        amountOut = numerator / denominator;
    }

    function getPoolInfo(
        address token
    )
        external
        view
        returns (
            uint256 ethReserve,
            uint256 tokenReserve,
            uint256 totalLiquidity,
            uint256 lastPrice,
            uint256 volume24h
        )
    {
        Pool storage pool = pools[token];
        return (
            pool.ethReserve,
            pool.tokenReserve,
            pool.totalLiquidity,
            pool.lastPrice,
            pool.volume24h
        );
    }

    function getUserLiquidity(
        address token,
        address user
    ) external view returns (uint256) {
        return pools[token].liquidity[user];
    }

    function getAllPools() external view returns (address[] memory) {
        return allPools;
    }

    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    // Emergency functions
    function emergencyWithdraw(address token) external onlyOwner {
        IERC20(token).transfer(owner(), IERC20(token).balanceOf(address(this)));
    }

    function emergencyWithdrawETH() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
}
*/