// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

contract KingdomSwapRouter {
    address public immutable treasury;
    address public immutable uniswapRouter;
    uint256 public constant FEE_BASIS_POINTS = 30; // 0.3%
    uint256 public constant BASIS_POINTS = 10000;
    
    bool private locked;
    
    event SwapExecuted(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeAmount
    );
    
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    
    modifier nonReentrant() {
        require(!locked, "ReentrancyGuard: reentrant call");
        locked = true;
        _;
        locked = false;
    }
    
    constructor(address _treasury, address _uniswapRouter) {
        require(_treasury != address(0), "Invalid treasury address");
        require(_uniswapRouter != address(0), "Invalid router address");
        treasury = _treasury;
        uniswapRouter = _uniswapRouter;
    }
    
    function swapExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 poolFee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountOut) {
        require(amountIn > 0, "Amount must be greater than 0");
        require(deadline >= block.timestamp, "Transaction deadline passed");
        
        IERC20 inputToken = IERC20(tokenIn);
        require(
            inputToken.transferFrom(msg.sender, address(this), amountIn),
            "Transfer failed"
        );
        
        uint256 feeAmount = (amountIn * FEE_BASIS_POINTS) / BASIS_POINTS;
        uint256 swapAmount = amountIn - feeAmount;
        
        require(inputToken.transfer(treasury, feeAmount), "Fee transfer failed");
        
        require(inputToken.approve(uniswapRouter, 0), "Approval reset failed");
        require(
            inputToken.approve(uniswapRouter, swapAmount),
            "Approval failed"
        );
        
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: poolFee,
            recipient: msg.sender,
            deadline: deadline,
            amountIn: swapAmount,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: 0
        });
        
        amountOut = ISwapRouter(uniswapRouter).exactInputSingle(params);
        
        emit SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut, feeAmount);
        
        return amountOut;
    }
    
    function rescueTokens(address token, uint256 amount) external {
        require(msg.sender == treasury, "Only treasury can rescue tokens");
        IERC20(token).transfer(treasury, amount);
    }
}
