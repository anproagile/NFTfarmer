// SPDX-License-Identifier: MIT

pragma solidity ^0.6.6;

import "./comm/Ownable.sol";
import "./comm/Pausable.sol";
import "./comm/ReentrancyGuard.sol";
import "./comm/SafeMath.sol";
import "./comm/ERC20.sol";
import "./comm/IERC20.sol";
import "./comm/SafeERC20.sol";

interface IPancakeSwapRouter {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

contract MoboxStrategyPMBOX is Pausable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // WBNB Token address
    address public constant wbnb = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    // PancakeSwap Token(CAKE) address
    address public constant cake = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    // Pancake MasterChef
    address public constant pancakeFarmer = 0x73feaa1eE314F8c655E354234017bE2193C9E24E;
    // Pancake Swap rounter
    address public constant pancakeRouter = 0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F;
    uint256 public constant maxBuyBackRate = 600;   // max 6%
    uint256 public constant maxDevFeeRate = 200;    // max 2%

    uint256 public shareTotal;
    uint256 public wantTotal;

    address public moboxFarm;
    address public wantToken;
    address public strategist;      // Control investment strategies
    address public buyBackPool;
    address public devAddress;
    uint256 public buyBackRate;
    uint256 public devFeeRate;

    constructor() public {

    }

    function init(
        address moboxFarm_,
        address strategist_,
        address wantToken_,
        address buyBackPool_,
        address devAddress_,
        uint256 buyBackRate_,
        uint256 devFeeRate_
    ) external onlyOwner {
        require(moboxFarm == address(0), "may only be init once");
        require(moboxFarm_ != address(0) && buyBackPool_ != address(0), "invalid param");
        require(buyBackRate_ < maxBuyBackRate && devFeeRate_ < maxDevFeeRate, "invalid param");
        moboxFarm = moboxFarm_;
        strategist = strategist_;
        wantToken = wantToken_;
        buyBackPool = buyBackPool_;
        devAddress = devAddress_;
        buyBackRate = buyBackRate_;
        devFeeRate = devFeeRate_;

        transferOwnership(moboxFarm_);
    }

    function getTotal() external view returns(uint256 wantTotal_, uint256 sharesTotal_) {
        wantTotal_ = wantTotal;
        sharesTotal_ = shareTotal;
    }

    // Deposit wantToken for user, can only call from moboxFarm
    // Just deposit and waiting for harvest to stake to pancake
    function deposit(uint256 amount_) external onlyOwner whenNotPaused nonReentrant returns(uint256) {
        IERC20(wantToken).safeTransferFrom(moboxFarm, address(this), amount_);
        
        uint256 shareAdd;
        if (shareTotal == 0 || wantTotal == 0) {
            shareAdd = amount_;
        } else {
            // shareAdd / (shareAdd + shareTotal) = amount_ / (amount_ + wantTotal)
            shareAdd = amount_.mul(shareTotal).div(wantTotal); 
        }
        wantTotal = wantTotal.add(amount_);
        shareTotal = shareTotal.add(shareAdd);

        return shareAdd;
    }

    // Deposit wantToken for user, can only call from moboxFarm
    function withdraw(address user_, uint256 amount_, uint256 feeRate_) 
        external 
        onlyOwner 
        nonReentrant 
        returns(uint256) 
    {
        require(amount_ > 0 && feeRate_ <= 50, "invalid param");
        uint256 lpBalance = IERC20(wantToken).balanceOf(address(this));

        if (wantTotal > lpBalance) {
            wantTotal = lpBalance;
        }

        uint256 wantAmount = amount_;
        if (wantAmount > wantTotal) {
            wantAmount = wantTotal;
        }

        // shareSub / shareTotal = wantAmount / wantTotal;
        uint256 shareSub = wantAmount.mul(shareTotal).div(wantTotal);
        wantTotal = wantTotal.sub(wantAmount);
        shareTotal = shareTotal.sub(shareSub);

        if (feeRate_ > 0) {
            uint256 feeAmount = wantAmount.mul(feeRate_).div(10000);
            wantAmount = wantAmount.sub(feeAmount);
            uint256 buyBackAmount = feeAmount.mul(buyBackRate).div(buyBackRate.add(devFeeRate));
            if (buyBackAmount > 0) {
                IERC20(wantToken).safeTransfer(buyBackPool, buyBackAmount);
            }
            uint256 devAmount = feeAmount.sub(buyBackAmount);
            if (devAmount > 0) {
                IERC20(wantToken).safeTransfer(devAddress, devAmount);
            }
        } 
        IERC20(wantToken).safeTransfer(user_, wantAmount);
        
        return shareSub;
    }

    // _tokenA != _tokenB
    function _makePath(address _tokenA, address _tokenB) internal pure returns(address[] memory path) {
        if (_tokenA == wbnb) {
            path = new address[](2);
            path[0] = wbnb;
            path[1] = _tokenB;
        } else if(_tokenB == wbnb) {
            path = new address[](2);
            path[0] = _tokenA;
            path[1] = wbnb;
        } else {
            path = new address[](3);
            path[0] = _tokenA;
            path[1] = wbnb;
            path[2] = _tokenB;
        }
    }

    function harvest() whenNotPaused external {
       
    }

    function farm() external {

    } 

    /**
     * @dev Throws if called by any account other than the strategist
     */
    modifier onlyStrategist() {
        require(_msgSender() == strategist, "not strategist");
        _;
    }

    /**
     * @dev Transfer dustTokens out of cake, and wait for the next reinvestment to convert to LP
     */
    function dustToEarnToken(address dustToken_) external onlyStrategist {
        require(dustToken_ != cake && dustToken_ != wantToken, "invalid param");
        uint256 dustAmount = IERC20(dustToken_).balanceOf(address(this));
        if (dustAmount > 0) {
            IERC20(dustToken_).safeIncreaseAllowance(pancakeRouter, dustAmount);
            IPancakeSwapRouter(pancakeRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                dustAmount,
                0,
                _makePath(dustToken_, cake),
                address(this),
                block.timestamp + 60
            );
        }
    }

    function setStrategist(address strategist_) external onlyStrategist {
        strategist = strategist_;
    }

    function setDevAddress(address newDev_) external onlyStrategist {
        devAddress = newDev_;
    }

    function setFeeRate(uint256 buyBackRate_, uint256 devFeeRate_) external onlyStrategist {
        require(buyBackRate_ <= maxBuyBackRate && devFeeRate_ <= maxDevFeeRate, "invalid param");
        buyBackRate = buyBackRate_;
        devFeeRate = devFeeRate_;
    }

    function pause() external onlyStrategist {
        _pause();
    }

    function unpause() external onlyStrategist {
        _unpause();
    }
}

