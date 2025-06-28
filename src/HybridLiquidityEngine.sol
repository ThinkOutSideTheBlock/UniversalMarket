// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./FRACToken.sol";

contract HybridLiquidityEngine is Ownable, ReentrancyGuard, Pausable {
    FRACToken public immutable FRAC_TOKEN;

    // Constants
    uint256 private constant PRECISION = 1e18;
    uint256 public constant FEE_RATE = 300; // 0.3%
    uint256 public constant FEE_DENOMINATOR = 100000;
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    uint256 private constant MAX_DEADLINE = 365 days;

    struct Pool {
        uint256 reserve0; // ETH or FRAC reserve
        uint256 reserve1; // Token reserve
        uint256 totalLiquidity;
        uint256 lastPrice;
        uint256 volume24h;
        uint256 lastVolumeUpdate;
        uint256 feeAccumulated;
        mapping(address => uint256) liquidity;
    }

    // Dual pool system
    mapping(address => Pool) public ethPools;
    mapping(address => Pool) public fracPools;

    address[] public ethPoolTokens;
    address[] public fracPoolTokens;

    // Events
    event ETHPoolCreated(
        address indexed token,
        uint256 ethAmount,
        uint256 tokenAmount
    );
    event FRACPoolCreated(
        address indexed token,
        uint256 fracAmount,
        uint256 tokenAmount
    );
    event ETHLiquidityAdded(
        address indexed token,
        address indexed provider,
        uint256 ethAmount,
        uint256 tokenAmount
    );
    event FRACLiquidityAdded(
        address indexed token,
        address indexed provider,
        uint256 fracAmount,
        uint256 tokenAmount
    );
    event ETHSwap(
        address indexed token,
        address indexed user,
        uint256 ethIn,
        uint256 tokenOut,
        bool ethToToken
    );
    event FRACSwap(
        address indexed token,
        address indexed user,
        uint256 fracIn,
        uint256 tokenOut,
        bool fracToToken
    );
    event CrossFractionSwap(
        address indexed fromToken,
        address indexed toToken,
        address indexed user,
        uint256 amountIn,
        uint256 amountOut
    );
    event SmartRouteExecuted(
        address indexed fromToken,
        address indexed toToken,
        address indexed user,
        bool usedFRACRoute,
        uint256 amountOut
    );

    constructor(address _fracToken) Ownable(msg.sender) {
        require(_fracToken != address(0), "Invalid FRAC token");
        FRAC_TOKEN = FRACToken(_fracToken);
    }

    modifier validETHPool(address token) {
        require(ethPools[token].totalLiquidity > 0, "ETH pool does not exist");
        _;
    }

    modifier validFRACPool(address token) {
        require(
            fracPools[token].totalLiquidity > 0,
            "FRAC pool does not exist"
        );
        _;
    }

    modifier validDeadline(uint256 deadline) {
        require(deadline > block.timestamp, "Deadline expired");
        require(deadline <= block.timestamp + MAX_DEADLINE, "Deadline too far");
        _;
    }

    // ============ ETH POOL FUNCTIONS ============

    function createETHPool(
        address token,
        uint256 tokenAmount
    ) external payable nonReentrant whenNotPaused {
        require(msg.value > 0, "Must send ETH");
        require(tokenAmount > 0, "Must send tokens");
        require(ethPools[token].totalLiquidity == 0, "ETH pool already exists");

        Pool storage pool = ethPools[token];

        IERC20(token).transferFrom(msg.sender, address(this), tokenAmount);

        uint256 liquidity = _sqrt((msg.value * tokenAmount) / PRECISION) *
            PRECISION;
        require(liquidity > MINIMUM_LIQUIDITY, "Insufficient liquidity");

        pool.reserve0 = msg.value;
        pool.reserve1 = tokenAmount;
        pool.totalLiquidity = liquidity;
        pool.liquidity[msg.sender] = liquidity;
        pool.lastPrice = (msg.value * PRECISION) / tokenAmount;

        ethPoolTokens.push(token);

        emit ETHPoolCreated(token, msg.value, tokenAmount);
        emit ETHLiquidityAdded(token, msg.sender, msg.value, tokenAmount);
    }

    function addETHLiquidity(
        address token,
        uint256 deadline
    )
        external
        payable
        validETHPool(token)
        validDeadline(deadline)
        nonReentrant
        whenNotPaused
    {
        require(msg.value > 0, "Must send ETH");

        Pool storage pool = ethPools[token];
        uint256 tokenAmount = (msg.value * pool.reserve1 * PRECISION) /
            (pool.reserve0 * PRECISION);
        require(tokenAmount > 0, "Insufficient token amount");

        IERC20(token).transferFrom(msg.sender, address(this), tokenAmount);

        uint256 liquidity = (msg.value * pool.totalLiquidity) / pool.reserve0;

        pool.reserve0 += msg.value;
        pool.reserve1 += tokenAmount;
        pool.totalLiquidity += liquidity;
        pool.liquidity[msg.sender] += liquidity;

        emit ETHLiquidityAdded(token, msg.sender, msg.value, tokenAmount);
    }

    function removeETHLiquidity(
        address token,
        uint256 liquidity,
        uint256 deadline
    )
        external
        validETHPool(token)
        validDeadline(deadline)
        nonReentrant
        whenNotPaused
    {
        Pool storage pool = ethPools[token];
        require(
            pool.liquidity[msg.sender] >= liquidity,
            "Insufficient liquidity"
        );
        require(liquidity > 0, "Invalid liquidity amount");

        uint256 ethAmount = (liquidity * pool.reserve0) / pool.totalLiquidity;
        uint256 tokenAmount = (liquidity * pool.reserve1) / pool.totalLiquidity;

        pool.liquidity[msg.sender] -= liquidity;
        pool.totalLiquidity -= liquidity;
        pool.reserve0 -= ethAmount;
        pool.reserve1 -= tokenAmount;

        IERC20(token).transfer(msg.sender, tokenAmount);
        (bool success, ) = payable(msg.sender).call{value: ethAmount}("");
        require(success, "ETH transfer failed");
    }

    function swapETHForTokens(
        address token,
        uint256 minTokensOut,
        uint256 deadline
    )
        external
        payable
        validETHPool(token)
        validDeadline(deadline)
        nonReentrant
        whenNotPaused
        returns (uint256 tokensOut)
    {
        require(msg.value > 0, "Must send ETH");

        Pool storage pool = ethPools[token];
        uint256 ethAfterFee = (msg.value * (FEE_DENOMINATOR - FEE_RATE)) /
            FEE_DENOMINATOR;
        tokensOut = _getAmountOut(ethAfterFee, pool.reserve0, pool.reserve1);

        require(tokensOut >= minTokensOut, "Insufficient output amount");
        require(tokensOut < pool.reserve1, "Insufficient liquidity");

        pool.reserve0 += msg.value;
        pool.reserve1 -= tokensOut;
        pool.lastPrice = (pool.reserve0 * PRECISION) / pool.reserve1;
        pool.feeAccumulated += msg.value - ethAfterFee;

        _updateVolume(token, msg.value, true);

        IERC20(token).transfer(msg.sender, tokensOut);

        emit ETHSwap(token, msg.sender, msg.value, tokensOut, true);
        return tokensOut;
    }

    function swapTokensForETH(
        address token,
        uint256 tokenAmount,
        uint256 minETHOut,
        uint256 deadline
    )
        external
        validETHPool(token)
        validDeadline(deadline)
        nonReentrant
        whenNotPaused
        returns (uint256 ethOut)
    {
        require(tokenAmount > 0, "Must send tokens");

        Pool storage pool = ethPools[token];

        IERC20(token).transferFrom(msg.sender, address(this), tokenAmount);

        uint256 tokensAfterFee = (tokenAmount * (FEE_DENOMINATOR - FEE_RATE)) /
            FEE_DENOMINATOR;
        ethOut = _getAmountOut(tokensAfterFee, pool.reserve1, pool.reserve0);

        require(ethOut >= minETHOut, "Insufficient output amount");
        require(ethOut < pool.reserve0, "Insufficient liquidity");

        pool.reserve1 += tokenAmount;
        pool.reserve0 -= ethOut;
        pool.lastPrice = (pool.reserve0 * PRECISION) / pool.reserve1;

        _updateVolume(token, ethOut, true);

        (bool success, ) = payable(msg.sender).call{value: ethOut}("");
        require(success, "ETH transfer failed");

        emit ETHSwap(token, msg.sender, ethOut, tokenAmount, false);
        return ethOut;
    }

    // ============ FRAC POOL FUNCTIONS ============

    function createFRACPool(
        address token,
        uint256 fracAmount,
        uint256 tokenAmount
    ) external nonReentrant whenNotPaused {
        require(fracAmount > 0, "Must send FRAC");
        require(tokenAmount > 0, "Must send tokens");
        require(
            fracPools[token].totalLiquidity == 0,
            "FRAC pool already exists"
        );

        Pool storage pool = fracPools[token];

        FRAC_TOKEN.transferFrom(msg.sender, address(this), fracAmount);
        IERC20(token).transferFrom(msg.sender, address(this), tokenAmount);

        uint256 liquidity = _sqrt((fracAmount * tokenAmount) / PRECISION) *
            PRECISION;
        require(liquidity > MINIMUM_LIQUIDITY, "Insufficient liquidity");

        pool.reserve0 = fracAmount;
        pool.reserve1 = tokenAmount;
        pool.totalLiquidity = liquidity;
        pool.liquidity[msg.sender] = liquidity;
        pool.lastPrice = (fracAmount * PRECISION) / tokenAmount;

        fracPoolTokens.push(token);

        emit FRACPoolCreated(token, fracAmount, tokenAmount);
        emit FRACLiquidityAdded(token, msg.sender, fracAmount, tokenAmount);
    }

    function addFRACLiquidity(
        address token,
        uint256 fracAmount,
        uint256 deadline
    )
        external
        validFRACPool(token)
        validDeadline(deadline)
        nonReentrant
        whenNotPaused
    {
        require(fracAmount > 0, "Must send FRAC");

        Pool storage pool = fracPools[token];
        uint256 tokenAmount = (fracAmount * pool.reserve1 * PRECISION) /
            (pool.reserve0 * PRECISION);
        require(tokenAmount > 0, "Insufficient token amount");

        FRAC_TOKEN.transferFrom(msg.sender, address(this), fracAmount);
        IERC20(token).transferFrom(msg.sender, address(this), tokenAmount);

        uint256 liquidity = (fracAmount * pool.totalLiquidity) / pool.reserve0;

        pool.reserve0 += fracAmount;
        pool.reserve1 += tokenAmount;
        pool.totalLiquidity += liquidity;
        pool.liquidity[msg.sender] += liquidity;

        emit FRACLiquidityAdded(token, msg.sender, fracAmount, tokenAmount);
    }

    function removeFRACLiquidity(
        address token,
        uint256 liquidity,
        uint256 deadline
    )
        external
        validFRACPool(token)
        validDeadline(deadline)
        nonReentrant
        whenNotPaused
    {
        Pool storage pool = fracPools[token];
        require(
            pool.liquidity[msg.sender] >= liquidity,
            "Insufficient liquidity"
        );
        require(liquidity > 0, "Invalid liquidity amount");

        uint256 fracAmount = (liquidity * pool.reserve0) / pool.totalLiquidity;
        uint256 tokenAmount = (liquidity * pool.reserve1) / pool.totalLiquidity;

        pool.liquidity[msg.sender] -= liquidity;
        pool.totalLiquidity -= liquidity;
        pool.reserve0 -= fracAmount;
        pool.reserve1 -= tokenAmount;

        FRAC_TOKEN.transfer(msg.sender, fracAmount);
        IERC20(token).transfer(msg.sender, tokenAmount);
    }

    function swapFRACForTokens(
        address token,
        uint256 fracAmount,
        uint256 minTokensOut,
        uint256 deadline
    )
        external
        validFRACPool(token)
        validDeadline(deadline)
        nonReentrant
        whenNotPaused
        returns (uint256 tokensOut)
    {
        require(fracAmount > 0, "Must send FRAC");

        Pool storage pool = fracPools[token];

        FRAC_TOKEN.transferFrom(msg.sender, address(this), fracAmount);

        uint256 fracAfterFee = (fracAmount * (FEE_DENOMINATOR - FEE_RATE)) /
            FEE_DENOMINATOR;
        tokensOut = _getAmountOut(fracAfterFee, pool.reserve0, pool.reserve1);

        require(tokensOut >= minTokensOut, "Insufficient output amount");
        require(tokensOut < pool.reserve1, "Insufficient liquidity");

        pool.reserve0 += fracAmount;
        pool.reserve1 -= tokensOut;
        pool.lastPrice = (pool.reserve0 * PRECISION) / pool.reserve1;

        _updateVolume(token, fracAmount, false);

        IERC20(token).transfer(msg.sender, tokensOut);

        emit FRACSwap(token, msg.sender, fracAmount, tokensOut, true);
        return tokensOut;
    }

    function swapTokensForFRAC(
        address token,
        uint256 tokenAmount,
        uint256 minFRACOut,
        uint256 deadline
    )
        external
        validFRACPool(token)
        validDeadline(deadline)
        nonReentrant
        whenNotPaused
        returns (uint256 fracOut)
    {
        require(tokenAmount > 0, "Must send tokens");

        Pool storage pool = fracPools[token];

        IERC20(token).transferFrom(msg.sender, address(this), tokenAmount);

        uint256 tokensAfterFee = (tokenAmount * (FEE_DENOMINATOR - FEE_RATE)) /
            FEE_DENOMINATOR;
        fracOut = _getAmountOut(tokensAfterFee, pool.reserve1, pool.reserve0);

        require(fracOut >= minFRACOut, "Insufficient output amount");
        require(fracOut < pool.reserve0, "Insufficient liquidity");

        pool.reserve1 += tokenAmount;
        pool.reserve0 -= fracOut;
        pool.lastPrice = (pool.reserve0 * PRECISION) / pool.reserve1;

        _updateVolume(token, fracOut, false);

        FRAC_TOKEN.transfer(msg.sender, fracOut);

        emit FRACSwap(token, msg.sender, fracOut, tokenAmount, false);
        return fracOut;
    }

    // ============ CROSS-FRACTION TRADING ============

    function _swapFractionToFraction(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        require(fromToken != toToken, "Same token");
        require(amountIn > 0, "Invalid amount");
        require(
            fracPools[fromToken].totalLiquidity > 0,
            "From pool not exists"
        );
        require(fracPools[toToken].totalLiquidity > 0, "To pool not exists");

        // Step 1: Swap fromToken → FRAC
        IERC20(fromToken).transferFrom(msg.sender, address(this), amountIn);

        Pool storage fromPool = fracPools[fromToken];
        uint256 tokensAfterFee = (amountIn * (FEE_DENOMINATOR - FEE_RATE)) /
            FEE_DENOMINATOR;
        uint256 fracAmount = _getAmountOut(
            tokensAfterFee,
            fromPool.reserve1,
            fromPool.reserve0
        );

        fromPool.reserve1 += amountIn;
        fromPool.reserve0 -= fracAmount;
        fromPool.lastPrice =
            (fromPool.reserve0 * PRECISION) /
            fromPool.reserve1;

        // Step 2: Swap FRAC → toToken
        Pool storage toPool = fracPools[toToken];
        uint256 fracAfterFee = (fracAmount * (FEE_DENOMINATOR - FEE_RATE)) /
            FEE_DENOMINATOR;
        amountOut = _getAmountOut(
            fracAfterFee,
            toPool.reserve0,
            toPool.reserve1
        );

        require(amountOut >= minAmountOut, "Insufficient output amount");
        require(amountOut < toPool.reserve1, "Insufficient liquidity");

        toPool.reserve0 += fracAmount;
        toPool.reserve1 -= amountOut;
        toPool.lastPrice = (toPool.reserve0 * PRECISION) / toPool.reserve1;

        IERC20(toToken).transfer(msg.sender, amountOut);

        emit CrossFractionSwap(
            fromToken,
            toToken,
            msg.sender,
            amountIn,
            amountOut
        );
        return amountOut;
    }

    function swapFractionToFraction(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        return
            _swapFractionToFraction(fromToken, toToken, amountIn, minAmountOut);
    }

    // ============ SMART ROUTING ============

    function getSmartRouteOutput(
        address fromToken,
        address toToken,
        uint256 amountIn
    )
        external
        view
        returns (
            uint256 ethRouteOutput,
            uint256 fracRouteOutput,
            bool preferFRAC
        )
    {
        // Calculate ETH route: fromToken → ETH → toToken
        if (
            ethPools[fromToken].totalLiquidity > 0 &&
            ethPools[toToken].totalLiquidity > 0
        ) {
            Pool storage fromETHPool = ethPools[fromToken];
            Pool storage toETHPool = ethPools[toToken];

            uint256 tokensAfterFee = (amountIn * (FEE_DENOMINATOR - FEE_RATE)) /
                FEE_DENOMINATOR;
            uint256 ethIntermediate = _getAmountOut(
                tokensAfterFee,
                fromETHPool.reserve1,
                fromETHPool.reserve0
            );

            uint256 ethAfterFee = (ethIntermediate *
                (FEE_DENOMINATOR - FEE_RATE)) / FEE_DENOMINATOR;
            ethRouteOutput = _getAmountOut(
                ethAfterFee,
                toETHPool.reserve0,
                toETHPool.reserve1
            );
        }

        // Calculate FRAC route: fromToken → FRAC → toToken
        if (
            fracPools[fromToken].totalLiquidity > 0 &&
            fracPools[toToken].totalLiquidity > 0
        ) {
            Pool storage fromFRACPool = fracPools[fromToken];
            Pool storage toFRACPool = fracPools[toToken];

            uint256 tokensAfterFee = (amountIn * (FEE_DENOMINATOR - FEE_RATE)) /
                FEE_DENOMINATOR;
            uint256 fracIntermediate = _getAmountOut(
                tokensAfterFee,
                fromFRACPool.reserve1,
                fromFRACPool.reserve0
            );

            uint256 fracAfterFee = (fracIntermediate *
                (FEE_DENOMINATOR - FEE_RATE)) / FEE_DENOMINATOR;
            fracRouteOutput = _getAmountOut(
                fracAfterFee,
                toFRACPool.reserve0,
                toFRACPool.reserve1
            );
        }

        preferFRAC = fracRouteOutput > ethRouteOutput;
        return (ethRouteOutput, fracRouteOutput, preferFRAC);
    }

    function smartSwapFractionToFraction(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    )
        external
        validDeadline(deadline)
        nonReentrant
        whenNotPaused
        returns (uint256 amountOut)
    {
        require(fromToken != toToken, "Same token");
        require(amountIn > 0, "Invalid amount");

        (, , bool preferFRAC) = this.getSmartRouteOutput(
            fromToken,
            toToken,
            amountIn
        );

        if (
            preferFRAC &&
            fracPools[fromToken].totalLiquidity > 0 &&
            fracPools[toToken].totalLiquidity > 0
        ) {
            // Use FRAC route - Fix: Use internal function
            amountOut = _swapFractionToFraction(
                fromToken,
                toToken,
                amountIn,
                minAmountOut
            );
            emit SmartRouteExecuted(
                fromToken,
                toToken,
                msg.sender,
                true,
                amountOut
            );
        } else if (
            ethPools[fromToken].totalLiquidity > 0 &&
            ethPools[toToken].totalLiquidity > 0
        ) {
            // Use ETH route
            amountOut = _swapViaETHRoute(
                fromToken,
                toToken,
                amountIn,
                minAmountOut
            );
            emit SmartRouteExecuted(
                fromToken,
                toToken,
                msg.sender,
                false,
                amountOut
            );
        } else {
            revert("No route available");
        }

        return amountOut;
    }

    function _swapViaETHRoute(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        // Step 1: Swap fromToken → ETH
        IERC20(fromToken).transferFrom(msg.sender, address(this), amountIn);

        Pool storage fromPool = ethPools[fromToken];
        uint256 tokensAfterFee = (amountIn * (FEE_DENOMINATOR - FEE_RATE)) /
            FEE_DENOMINATOR;
        uint256 ethAmount = _getAmountOut(
            tokensAfterFee,
            fromPool.reserve1,
            fromPool.reserve0
        );

        fromPool.reserve1 += amountIn;
        fromPool.reserve0 -= ethAmount;
        fromPool.lastPrice =
            (fromPool.reserve0 * PRECISION) /
            fromPool.reserve1;

        // Step 2: Swap ETH → toToken
        Pool storage toPool = ethPools[toToken];
        uint256 ethAfterFee = (ethAmount * (FEE_DENOMINATOR - FEE_RATE)) /
            FEE_DENOMINATOR;
        amountOut = _getAmountOut(
            ethAfterFee,
            toPool.reserve0,
            toPool.reserve1
        );

        require(amountOut >= minAmountOut, "Insufficient output amount");
        require(amountOut < toPool.reserve1, "Insufficient liquidity");

        toPool.reserve0 += ethAmount;
        toPool.reserve1 -= amountOut;
        toPool.lastPrice = (toPool.reserve0 * PRECISION) / toPool.reserve1;

        IERC20(toToken).transfer(msg.sender, amountOut);

        return amountOut;
    }

    // ============ HELPER FUNCTIONS ============

    function _updateVolume(
        address token,
        uint256 amount,
        bool isETHPool
    ) internal {
        Pool storage pool = isETHPool ? ethPools[token] : fracPools[token];

        if (block.timestamp > pool.lastVolumeUpdate + 24 hours) {
            pool.volume24h = amount;
        } else {
            pool.volume24h += amount;
        }

        pool.lastVolumeUpdate = block.timestamp;
    }

    function _getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "Insufficient input amount");
        require(reserveIn > 0 && reserveOut > 0, "Insufficient liquidity");

        // Use higher precision calculations
        uint256 numerator = (amountIn * reserveOut * PRECISION);
        uint256 denominator = ((reserveIn * PRECISION) +
            (amountIn * PRECISION));
        amountOut = numerator / denominator;
    }

    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    // ============ VIEW FUNCTIONS ============

    function getETHPoolInfo(
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
        Pool storage pool = ethPools[token];
        return (
            pool.reserve0,
            pool.reserve1,
            pool.totalLiquidity,
            pool.lastPrice,
            pool.volume24h
        );
    }

    function getFRACPoolInfo(
        address token
    )
        external
        view
        returns (
            uint256 fracReserve,
            uint256 tokenReserve,
            uint256 totalLiquidity,
            uint256 lastPrice,
            uint256 volume24h
        )
    {
        Pool storage pool = fracPools[token];
        return (
            pool.reserve0,
            pool.reserve1,
            pool.totalLiquidity,
            pool.lastPrice,
            pool.volume24h
        );
    }

    function getUserETHLiquidity(
        address token,
        address user
    ) external view returns (uint256) {
        return ethPools[token].liquidity[user];
    }

    function getUserFRACLiquidity(
        address token,
        address user
    ) external view returns (uint256) {
        return fracPools[token].liquidity[user];
    }

    function getAllETHPools() external view returns (address[] memory) {
        return ethPoolTokens;
    }

    function getAllFRACPools() external view returns (address[] memory) {
        return fracPoolTokens;
    }

    function hasETHPool(address token) external view returns (bool) {
        return ethPools[token].totalLiquidity > 0;
    }

    function hasFRACPool(address token) external view returns (bool) {
        return fracPools[token].totalLiquidity > 0;
    }

    // ============ ADMIN FUNCTIONS ============

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdrawETH() external onlyOwner {
        (bool success, ) = payable(owner()).call{value: address(this).balance}(
            ""
        );
        require(success, "ETH transfer failed");
    }

    function emergencyWithdrawToken(address token) external onlyOwner {
        IERC20(token).transfer(owner(), IERC20(token).balanceOf(address(this)));
    }

    function collectFees(address token) external onlyOwner {
        Pool storage pool = ethPools[token];
        require(pool.feeAccumulated > 0, "No fees to collect");

        uint256 fees = pool.feeAccumulated;
        pool.feeAccumulated = 0;

        (bool success, ) = payable(owner()).call{value: fees}("");
        require(success, "Fee transfer failed");
    }
}
