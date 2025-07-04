// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./FRACToken.sol";

interface IEmergencyControls {
    function isContractPaused(
        address contractAddr
    ) external view returns (bool);
}

contract HybridLiquidityEngine is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    FRACToken public immutable FRAC_TOKEN;
    IEmergencyControls public emergencyControls;

    // Constants
    uint256 private constant PRECISION = 1e18;
    uint256 public constant FEE_RATE = 300; // 0.3%
    uint256 public constant FEE_DENOMINATOR = 100000;
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    uint256 private constant MAX_DEADLINE = 365 days;
    uint256 private constant MAX_SLIPPAGE = 5000; // 50% max slippage protection
    uint256 private constant CIRCUIT_BREAKER_THRESHOLD = 2000; // 20% price impact triggers circuit breaker

    // Circuit breaker
    bool public circuitBreakerActive;
    uint256 public lastCircuitBreakerReset;
    uint256 public constant CIRCUIT_BREAKER_COOLDOWN = 1 hours;

    struct Pool {
        uint256 reserve0; // ETH or FRAC reserve
        uint256 reserve1; // Token reserve
        uint256 totalLiquidity;
        uint256 lastPrice;
        uint256 volume24h;
        uint256 lastVolumeUpdate;
        uint256 feeAccumulated;
        uint256 cumulativePrice; // For TWAP oracle
        uint256 lastPriceUpdate;
        mapping(address => uint256) liquidity;
    }

    // Dual pool system
    mapping(address => Pool) public ethPools;
    mapping(address => Pool) public fracPools;

    address[] public ethPoolTokens;
    address[] public fracPoolTokens;

    // Fee collection
    address public feeRecipient;
    mapping(address => uint256) public protocolFees; // Per token protocol fees

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
    event CircuitBreakerTriggered(address indexed token, uint256 priceImpact);
    event CircuitBreakerReset();
    event FeeRecipientUpdated(
        address indexed oldRecipient,
        address indexed newRecipient
    );
    event ProtocolFeesCollected(address indexed token, uint256 amount);
    event EmergencyControlsSet(address indexed controls);

    constructor(address _fracToken) Ownable(msg.sender) {
        require(_fracToken != address(0), "Invalid FRAC token");
        FRAC_TOKEN = FRACToken(_fracToken);
        feeRecipient = msg.sender;
        lastCircuitBreakerReset = block.timestamp;
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

    modifier validSlippage(uint256 slippage) {
        require(slippage <= MAX_SLIPPAGE, "Slippage too high");
        _;
    }

    modifier whenSystemNotPaused() {
        if (address(emergencyControls) != address(0)) {
            require(
                !emergencyControls.isContractPaused(address(this)),
                "Emergency paused"
            );
        }
        require(!paused() && !circuitBreakerActive, "System paused");
        _;
    }

    function setEmergencyControls(address _controls) external onlyOwner {
        emergencyControls = IEmergencyControls(_controls);
        emit EmergencyControlsSet(_controls);
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        address oldRecipient = feeRecipient;
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(oldRecipient, _feeRecipient);
    }

    function resetCircuitBreaker() external {
        require(
            block.timestamp >=
                lastCircuitBreakerReset + CIRCUIT_BREAKER_COOLDOWN,
            "Cooldown not finished"
        );
        circuitBreakerActive = false;
        lastCircuitBreakerReset = block.timestamp;
        emit CircuitBreakerReset();
    }

    // ============ HELPER FUNCTIONS (MOVED UP FOR VISIBILITY) ============

    function _calculatePriceImpact(
        address token,
        uint256 amountIn,
        uint256 amountOut,
        bool isETHPool
    ) internal view returns (uint256) {
        Pool storage pool = isETHPool ? ethPools[token] : fracPools[token];
        uint256 reserveIn = pool.reserve0; // Both ETH and FRAC use reserve0

        // Calculate price impact as percentage (basis points)
        uint256 priceImpact = (amountIn * 10000) / reserveIn;
        return priceImpact;
    }

    function _updatePrice(
        Pool storage pool,
        address token,
        bool isETHPool
    ) internal {
        uint256 currentPrice = (pool.reserve0 * PRECISION) / pool.reserve1;
        uint256 timeElapsed = block.timestamp - pool.lastPriceUpdate;

        if (timeElapsed > 0) {
            pool.cumulativePrice += currentPrice * timeElapsed;
            pool.lastPrice = currentPrice;
            pool.lastPriceUpdate = block.timestamp;
        }
    }

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

    // ============ SMART ROUTING (MOVED UP FOR VISIBILITY) ============

    function getSmartRouteOutput(
        address fromToken,
        address toToken,
        uint256 amountIn
    )
        public
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

    // ============ ETH POOL FUNCTIONS ============

    function createETHPool(
        address token,
        uint256 tokenAmount
    ) external payable nonReentrant whenSystemNotPaused {
        require(msg.value > 0, "Must send ETH");
        require(tokenAmount > 0, "Must send tokens");
        require(ethPools[token].totalLiquidity == 0, "ETH pool already exists");

        Pool storage pool = ethPools[token];

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        uint256 liquidity = _sqrt((msg.value * tokenAmount) / PRECISION) *
            PRECISION;
        require(liquidity > MINIMUM_LIQUIDITY, "Insufficient liquidity");

        pool.reserve0 = msg.value;
        pool.reserve1 = tokenAmount;
        pool.totalLiquidity = liquidity;
        pool.liquidity[msg.sender] = liquidity;
        pool.lastPrice = (msg.value * PRECISION) / tokenAmount;
        pool.cumulativePrice = pool.lastPrice * block.timestamp;
        pool.lastPriceUpdate = block.timestamp;

        ethPoolTokens.push(token);

        emit ETHPoolCreated(token, msg.value, tokenAmount);
        emit ETHLiquidityAdded(token, msg.sender, msg.value, tokenAmount);
    }

    function addETHLiquidity(
        address token,
        uint256 deadline,
        uint256 maxSlippage
    )
        external
        payable
        validETHPool(token)
        validDeadline(deadline)
        validSlippage(maxSlippage)
        nonReentrant
        whenSystemNotPaused
    {
        require(msg.value > 0, "Must send ETH");

        Pool storage pool = ethPools[token];
        uint256 tokenAmount = (msg.value * pool.reserve1) / pool.reserve0;
        require(tokenAmount > 0, "Insufficient token amount");

        // Slippage protection
        uint256 slippage = (tokenAmount * 10000) / pool.reserve1;
        require(slippage <= maxSlippage, "Slippage exceeded");

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        uint256 liquidity = (msg.value * pool.totalLiquidity) / pool.reserve0;

        pool.reserve0 += msg.value;
        pool.reserve1 += tokenAmount;
        pool.totalLiquidity += liquidity;
        pool.liquidity[msg.sender] += liquidity;

        _updatePrice(pool, token, true);

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
        whenSystemNotPaused
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

        IERC20(token).safeTransfer(msg.sender, tokenAmount);
        (bool success, ) = payable(msg.sender).call{value: ethAmount}("");
        require(success, "ETH transfer failed");

        _updatePrice(pool, token, true);
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
        whenSystemNotPaused
        returns (uint256 tokensOut)
    {
        require(msg.value > 0, "Must send ETH");

        Pool storage pool = ethPools[token];
        uint256 ethAfterFee = (msg.value * (FEE_DENOMINATOR - FEE_RATE)) /
            FEE_DENOMINATOR;
        tokensOut = _getAmountOut(ethAfterFee, pool.reserve0, pool.reserve1);

        require(tokensOut >= minTokensOut, "Insufficient output amount");
        require(tokensOut < pool.reserve1, "Insufficient liquidity");

        // Circuit breaker check
        uint256 priceImpact = _calculatePriceImpact(
            token,
            msg.value,
            tokensOut,
            true
        );
        if (priceImpact > CIRCUIT_BREAKER_THRESHOLD) {
            circuitBreakerActive = true;
            emit CircuitBreakerTriggered(token, priceImpact);
            revert("Circuit breaker triggered");
        }

        uint256 protocolFee = (msg.value - ethAfterFee) / 2; // 50% of fees to protocol
        protocolFees[address(0)] += protocolFee; // ETH fees

        pool.reserve0 += msg.value - protocolFee;
        pool.reserve1 -= tokensOut;
        pool.feeAccumulated += (msg.value - ethAfterFee) - protocolFee;

        _updateVolume(token, msg.value, true);
        _updatePrice(pool, token, true);

        IERC20(token).safeTransfer(msg.sender, tokensOut);

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
        whenSystemNotPaused
        returns (uint256 ethOut)
    {
        require(tokenAmount > 0, "Must send tokens");

        Pool storage pool = ethPools[token];

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        uint256 tokensAfterFee = (tokenAmount * (FEE_DENOMINATOR - FEE_RATE)) /
            FEE_DENOMINATOR;
        ethOut = _getAmountOut(tokensAfterFee, pool.reserve1, pool.reserve0);

        require(ethOut >= minETHOut, "Insufficient output amount");
        require(ethOut < pool.reserve0, "Insufficient liquidity");

        // Circuit breaker check
        uint256 priceImpact = _calculatePriceImpact(
            token,
            tokenAmount,
            ethOut,
            true
        );
        if (priceImpact > CIRCUIT_BREAKER_THRESHOLD) {
            circuitBreakerActive = true;
            emit CircuitBreakerTriggered(token, priceImpact);
            revert("Circuit breaker triggered");
        }

        uint256 feeInETH = _getAmountOut(
            tokenAmount - tokensAfterFee,
            pool.reserve1,
            pool.reserve0
        );
        uint256 protocolFeeETH = feeInETH / 2;
        protocolFees[address(0)] += protocolFeeETH;

        pool.reserve1 += tokenAmount;
        pool.reserve0 -= (ethOut + protocolFeeETH);

        _updateVolume(token, ethOut, true);
        _updatePrice(pool, token, true);

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
    ) external nonReentrant whenSystemNotPaused {
        require(fracAmount > 0, "Must send FRAC");
        require(tokenAmount > 0, "Must send tokens");
        require(
            fracPools[token].totalLiquidity == 0,
            "FRAC pool already exists"
        );

        Pool storage pool = fracPools[token];

        FRAC_TOKEN.transferFrom(msg.sender, address(this), fracAmount);
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        uint256 liquidity = _sqrt((fracAmount * tokenAmount) / PRECISION) *
            PRECISION;
        require(liquidity > MINIMUM_LIQUIDITY, "Insufficient liquidity");

        pool.reserve0 = fracAmount;
        pool.reserve1 = tokenAmount;
        pool.totalLiquidity = liquidity;
        pool.liquidity[msg.sender] = liquidity;
        pool.lastPrice = (fracAmount * PRECISION) / tokenAmount;
        pool.cumulativePrice = pool.lastPrice * block.timestamp;
        pool.lastPriceUpdate = block.timestamp;

        fracPoolTokens.push(token);

        emit FRACPoolCreated(token, fracAmount, tokenAmount);
        emit FRACLiquidityAdded(token, msg.sender, fracAmount, tokenAmount);
    }

    function addFRACLiquidity(
        address token,
        uint256 fracAmount,
        uint256 deadline,
        uint256 maxSlippage
    )
        external
        validFRACPool(token)
        validDeadline(deadline)
        validSlippage(maxSlippage)
        nonReentrant
        whenSystemNotPaused
    {
        require(fracAmount > 0, "Must send FRAC");

        Pool storage pool = fracPools[token];
        uint256 tokenAmount = (fracAmount * pool.reserve1) / pool.reserve0;
        require(tokenAmount > 0, "Insufficient token amount");

        // Slippage protection
        uint256 slippage = (tokenAmount * 10000) / pool.reserve1;
        require(slippage <= maxSlippage, "Slippage exceeded");

        FRAC_TOKEN.transferFrom(msg.sender, address(this), fracAmount);
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        uint256 liquidity = (fracAmount * pool.totalLiquidity) / pool.reserve0;

        pool.reserve0 += fracAmount;
        pool.reserve1 += tokenAmount;
        pool.totalLiquidity += liquidity;
        pool.liquidity[msg.sender] += liquidity;

        _updatePrice(pool, token, false);

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
        whenSystemNotPaused
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
        IERC20(token).safeTransfer(msg.sender, tokenAmount);

        _updatePrice(pool, token, false);
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
        whenSystemNotPaused
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

        // Circuit breaker check
        uint256 priceImpact = _calculatePriceImpact(
            token,
            fracAmount,
            tokensOut,
            false
        );
        if (priceImpact > CIRCUIT_BREAKER_THRESHOLD) {
            circuitBreakerActive = true;
            emit CircuitBreakerTriggered(token, priceImpact);
            revert("Circuit breaker triggered");
        }

        uint256 protocolFee = (fracAmount - fracAfterFee) / 2;
        protocolFees[address(FRAC_TOKEN)] += protocolFee;

        pool.reserve0 += fracAmount - protocolFee;
        pool.reserve1 -= tokensOut;

        _updateVolume(token, fracAmount, false);
        _updatePrice(pool, token, false);

        IERC20(token).safeTransfer(msg.sender, tokensOut);

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
        whenSystemNotPaused
        returns (uint256 fracOut)
    {
        require(tokenAmount > 0, "Must send tokens");

        Pool storage pool = fracPools[token];

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        uint256 tokensAfterFee = (tokenAmount * (FEE_DENOMINATOR - FEE_RATE)) /
            FEE_DENOMINATOR;
        fracOut = _getAmountOut(tokensAfterFee, pool.reserve1, pool.reserve0);

        require(fracOut >= minFRACOut, "Insufficient output amount");
        require(fracOut < pool.reserve0, "Insufficient liquidity");

        // Circuit breaker check
        uint256 priceImpact = _calculatePriceImpact(
            token,
            tokenAmount,
            fracOut,
            false
        );
        if (priceImpact > CIRCUIT_BREAKER_THRESHOLD) {
            circuitBreakerActive = true;
            emit CircuitBreakerTriggered(token, priceImpact);
            revert("Circuit breaker triggered");
        }

        uint256 feeInFRAC = _getAmountOut(
            tokenAmount - tokensAfterFee,
            pool.reserve1,
            pool.reserve0
        );
        uint256 protocolFeeFRAC = feeInFRAC / 2;
        protocolFees[address(FRAC_TOKEN)] += protocolFeeFRAC;

        pool.reserve1 += tokenAmount;
        pool.reserve0 -= (fracOut + protocolFeeFRAC);

        _updateVolume(token, fracOut, false);
        _updatePrice(pool, token, false);

        FRAC_TOKEN.transfer(msg.sender, fracOut);

        emit FRACSwap(token, msg.sender, fracOut, tokenAmount, false);
        return fracOut;
    }

    // ============ CROSS-FACTION TRADING WITH ENHANCED ROUTING ============

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
        whenSystemNotPaused
        returns (uint256 amountOut)
    {
        require(fromToken != toToken, "Same token");
        require(amountIn > 0, "Invalid amount");

        (, , bool preferFRAC) = getSmartRouteOutput(
            fromToken,
            toToken,
            amountIn
        );

        if (
            preferFRAC &&
            fracPools[fromToken].totalLiquidity > 0 &&
            fracPools[toToken].totalLiquidity > 0
        ) {
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

    function _swapFractionToFraction(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amountIn);

        Pool storage fromPool = fracPools[fromToken];
        uint256 tokensAfterFee = (amountIn * (FEE_DENOMINATOR - FEE_RATE)) /
            FEE_DENOMINATOR;
        uint256 fracAmount = _getAmountOut(
            tokensAfterFee,
            fromPool.reserve1,
            fromPool.reserve0
        );

        // Circuit breaker check for first swap
        uint256 priceImpact1 = _calculatePriceImpact(
            fromToken,
            amountIn,
            fracAmount,
            false
        );
        if (priceImpact1 > CIRCUIT_BREAKER_THRESHOLD) {
            circuitBreakerActive = true;
            emit CircuitBreakerTriggered(fromToken, priceImpact1);
            revert("Circuit breaker triggered");
        }

        uint256 protocolFee1 = (amountIn - tokensAfterFee) / 2;
        protocolFees[address(FRAC_TOKEN)] += protocolFee1;

        fromPool.reserve1 += amountIn - protocolFee1;
        fromPool.reserve0 -= fracAmount;
        _updatePrice(fromPool, fromToken, false);

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

        // Circuit breaker check for second swap
        uint256 priceImpact2 = _calculatePriceImpact(
            toToken,
            fracAmount,
            amountOut,
            false
        );
        if (priceImpact2 > CIRCUIT_BREAKER_THRESHOLD) {
            circuitBreakerActive = true;
            emit CircuitBreakerTriggered(toToken, priceImpact2);
            revert("Circuit breaker triggered");
        }

        uint256 protocolFee2 = (fracAmount - fracAfterFee) / 2;
        protocolFees[address(FRAC_TOKEN)] += protocolFee2;

        toPool.reserve0 += fracAmount - protocolFee2;
        toPool.reserve1 -= amountOut;
        _updatePrice(toPool, toToken, false);

        IERC20(toToken).safeTransfer(msg.sender, amountOut);

        emit CrossFractionSwap(
            fromToken,
            toToken,
            msg.sender,
            amountIn,
            amountOut
        );
        return amountOut;
    }

    function _swapViaETHRoute(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amountIn);

        Pool storage fromPool = ethPools[fromToken];
        uint256 tokensAfterFee = (amountIn * (FEE_DENOMINATOR - FEE_RATE)) /
            FEE_DENOMINATOR;
        uint256 ethAmount = _getAmountOut(
            tokensAfterFee,
            fromPool.reserve1,
            fromPool.reserve0
        );

        // Circuit breaker check for first swap
        uint256 priceImpact1 = _calculatePriceImpact(
            fromToken,
            amountIn,
            ethAmount,
            true
        );
        if (priceImpact1 > CIRCUIT_BREAKER_THRESHOLD) {
            circuitBreakerActive = true;
            emit CircuitBreakerTriggered(fromToken, priceImpact1);
            revert("Circuit breaker triggered");
        }

        uint256 protocolFee1 = (amountIn - tokensAfterFee) / 2;
        protocolFees[address(0)] += protocolFee1;

        fromPool.reserve1 += amountIn - protocolFee1;
        fromPool.reserve0 -= ethAmount;
        _updatePrice(fromPool, fromToken, true);

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

        // Circuit breaker check for second swap
        uint256 priceImpact2 = _calculatePriceImpact(
            toToken,
            ethAmount,
            amountOut,
            true
        );
        if (priceImpact2 > CIRCUIT_BREAKER_THRESHOLD) {
            circuitBreakerActive = true;
            emit CircuitBreakerTriggered(toToken, priceImpact2);
            revert("Circuit breaker triggered");
        }

        uint256 protocolFee2 = (ethAmount - ethAfterFee) / 2;
        protocolFees[address(0)] += protocolFee2;

        toPool.reserve0 += ethAmount - protocolFee2;
        toPool.reserve1 -= amountOut;
        _updatePrice(toPool, toToken, true);

        IERC20(toToken).safeTransfer(msg.sender, amountOut);

        return amountOut;
    }

    // ============ PROTOCOL FEE COLLECTION ============

    function collectProtocolFees(address token) external {
        require(
            msg.sender == feeRecipient || msg.sender == owner(),
            "Not authorized"
        );
        uint256 fees = protocolFees[token];
        require(fees > 0, "No fees to collect");

        protocolFees[token] = 0;

        if (token == address(0)) {
            // ETH fees
            (bool success, ) = payable(feeRecipient).call{value: fees}("");
            require(success, "Fee transfer failed");
        } else {
            // Token fees
            IERC20(token).safeTransfer(feeRecipient, fees);
        }

        emit ProtocolFeesCollected(token, fees);
    }

    function batchCollectProtocolFees(address[] calldata tokens) external {
        require(
            msg.sender == feeRecipient || msg.sender == owner(),
            "Not authorized"
        );

        for (uint i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 fees = protocolFees[token];
            if (fees == 0) continue;

            protocolFees[token] = 0;

            if (token == address(0)) {
                (bool success, ) = payable(feeRecipient).call{value: fees}("");
                require(success, "Fee transfer failed");
            } else {
                IERC20(token).safeTransfer(feeRecipient, fees);
            }

            emit ProtocolFeesCollected(token, fees);
        }
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

    function getTWAP(
        address token,
        bool isETHPool,
        uint256 timeWindow
    ) external view returns (uint256) {
        Pool storage pool = isETHPool ? ethPools[token] : fracPools[token];
        uint256 timeElapsed = block.timestamp - pool.lastPriceUpdate;

        if (timeElapsed == 0) return pool.lastPrice;
        if (timeElapsed > timeWindow) timeElapsed = timeWindow;

        return pool.cumulativePrice / timeElapsed;
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

    function getProtocolFees(address token) external view returns (uint256) {
        return protocolFees[token];
    }

    // ============ ADMIN FUNCTIONS ============

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdrawETH() external onlyOwner whenPaused {
        (bool success, ) = payable(owner()).call{value: address(this).balance}(
            ""
        );
        require(success, "ETH transfer failed");
    }

    function emergencyWithdrawToken(
        address token
    ) external onlyOwner whenPaused {
        IERC20(token).safeTransfer(
            owner(),
            IERC20(token).balanceOf(address(this))
        );
    }

    receive() external payable {
        // Allow contract to receive ETH
    }
}
