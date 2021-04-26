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
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

interface IVenusDistribution {
    function claimVenus(address holder) external;

    function enterMarkets(address[] memory _vtokens) external;

    function exitMarket(address _vtoken) external;
}

interface IVToken {
    function underlying() external returns (address);

    function mint(uint256 mintAmount) external returns (uint256);

    function redeem(uint256 redeemTokens) external returns (uint256);

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);

    function borrow(uint256 borrowAmount) external returns (uint256);

    function repayBorrow(uint256 repayAmount) external returns (uint256);

    function balanceOfUnderlying(address owner) external returns (uint256);

    function borrowBalanceCurrent(address account) external returns (uint256);
}

contract MoboxStrategyV is Pausable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct VenusData {
        uint128 totalSupply;
        uint128 totalBorrow;
    }

    // WBNB Token address
    address public constant wbnb = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    // Pancake Swap rounter
    address public constant pancakeRouter = 0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F;
    // Venus XVS token address
    address public constant venusXvs = 0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63;
    // Venus distribution address
    address public constant venusDistribution = 0xfD36E2c2a6789Db23113685031d7F16329158384;
    uint256 public constant maxBuyBackRate = 600;   // max 6%
    uint256 public constant maxDevFeeRate = 200;    // max 2%
    uint256 public constant borrow_rate_max_hard = 5990;

    uint256 public shareTotal;
    address public moboxFarm;
    address public wantToken;       // like 'BUSD/USDT/USDC'
    address public vToken;          // like 'vBUSD/vUSDT/vUDC'
    address public strategist;      // Control investment strategies
    address public buyBackPool;
    address public devAddress;
    uint256 public buyBackRate;
    uint256 public devFeeRate;
    bool public recoverPublic;

    VenusData public venusData;
    uint256 public borrowRate;
    uint256 public borrowDepth;
    // After deposit, if the margin exceeds maxMarginTriggerDeposit, a deposit to venus will be triggered
    // If the margin is not enough when withdrawing funds, take out a part of the token to the vault when withdrawing funds so that keep the margin reaching baseMarginForWithdraw
    uint256 public baseMarginForWithdraw;      
    uint256 public maxMarginTriggerDeposit;
    

    function init(
        address moboxFarm_,
        address strategist_,
        address wantToken_,
        address vToken_,
        address buyBackPool_,
        address devAddress_,
        uint256 buyBackRate_,
        uint256 devFeeRate_,
        uint256 margin_
    ) external onlyOwner {
        require(wantToken == address(0) && moboxFarm == address(0), "may only be init once");
        require(wantToken_ != address(0) && vToken_ != address(0) && moboxFarm_ != address(0) && buyBackPool_ != address(0), "invalid param");
        require(buyBackRate_ < maxBuyBackRate && devFeeRate_ < maxDevFeeRate, "invalid param");

        moboxFarm = moboxFarm_;
        strategist = strategist_;
        wantToken = wantToken_;
        vToken = vToken_;
        buyBackPool = buyBackPool_;
        devAddress = devAddress_;
        buyBackRate = buyBackRate_;
        devFeeRate = devFeeRate_;

        borrowRate = 5800;
        borrowDepth = 0;
        baseMarginForWithdraw = margin_;
        maxMarginTriggerDeposit = margin_.mul(2);

        transferOwnership(moboxFarm_);

        IERC20(venusXvs).safeApprove(pancakeRouter, uint256(-1));
        IERC20(wantToken).safeApprove(vToken, uint256(-1));

        address[] memory venusMarkets = new address[](1);
        venusMarkets[0] = vToken;
        IVenusDistribution(venusDistribution).enterMarkets(venusMarkets);
    }

    // Deposit to venus
    function _supply(uint256 amount_) internal {
        IVToken(vToken).mint(amount_);
    }

    // Withdraw funds
    function _removeSupply(uint256 amount_) internal {
        IVToken(vToken).redeemUnderlying(amount_);
    }

    function _removeSupplyAll() internal {
        uint256 vTokenAmount = IERC20(vToken).balanceOf(address(this));
        IVToken(vToken).redeem(vTokenAmount);
    }

    function _borrow(uint256 amount_) internal {
        IVToken(vToken).borrow(amount_);
    }

    function _repayBorrow(uint256 amount_) internal {
        IVToken(vToken).repayBorrow(amount_); 
    }

    function wantLocal() public view returns(uint256) {
        return IERC20(wantToken).balanceOf(address(this));
    }

    function wantTotal() public view returns(uint256) {
        // Margin + Deposit-Borrow
        return wantLocal().add(uint256(venusData.totalSupply)).sub(uint256(venusData.totalBorrow));
    }

    function getTotal() public view returns(uint256 wantTotal_, uint256 shareTotal_) {
        wantTotal_ = wantTotal();
        shareTotal_ = shareTotal;
    }

    function deposit(uint256 amount_) 
        external 
        onlyOwner
        whenNotPaused 
        nonReentrant 
        returns(uint256) 
    {
        updateBalance();
        uint256 oldWantTotal = wantTotal();

        IERC20(wantToken).safeTransferFrom(moboxFarm, address(this), amount_);

        uint256 shareAdd;
        if (shareTotal == 0 || oldWantTotal == 0) {
             shareAdd = amount_;
        } else {
            // shareAdd / (shareAdd + shareTotal) = amount_ / (amount_ + wantTotal)
            shareAdd = amount_.mul(shareTotal).div(oldWantTotal);
        } 
        shareTotal = shareTotal.add(shareAdd);

        _farm();

        return shareAdd;
    }

    function withdraw(address user_, uint256 amount_, uint256 feeRate_) 
        external
        onlyOwner
        nonReentrant
        returns(uint256)
    {
        require(user_ != address(0) && amount_ > 0 && feeRate_ <= 50, "invalid param");
        updateBalance();
        uint256 wantTotalAmount = wantTotal();
        uint256 wantAmount = amount_ > wantTotalAmount ? wantTotalAmount : amount_;
    
        uint256 shareSub = wantAmount.mul(shareTotal).div(wantTotalAmount);
        shareTotal = shareTotal.sub(shareSub);

        uint256 wantBalance = wantLocal();
        if (wantBalance < wantAmount) {
            uint256 needRedeem = wantAmount.sub(wantBalance);
            if (needRedeem <= uint256(venusData.totalSupply)) {
                _removeSupply(needRedeem);
            } else {
                _removeSupplyAll();
            }
            updateBalance();
            wantAmount = wantLocal();
        } 

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

        _farm();

        return shareSub;
    }

    function updateBalance() public {
        uint256 totalSupply = IVToken(vToken).balanceOfUnderlying(address(this));
        uint256 totalBorrow = IVToken(vToken).borrowBalanceCurrent(address(this));
        venusData.totalSupply = SafeMathExt.safe128(totalSupply);
        venusData.totalBorrow = SafeMathExt.safe128(totalBorrow);
    }

    function _farm() internal {
       // Before calling this function, need to call 'updateBalance' first
        uint256 wantLocalAmount = wantLocal();
        if (wantLocalAmount < maxMarginTriggerDeposit) {
            return;
        }

        uint256 investAmount = wantLocalAmount.sub(baseMarginForWithdraw);
        _supply(investAmount);

        updateBalance();
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

    function harvest() whenNotPaused nonReentrant external {
        if (!recoverPublic) {
            require(_msgSender() == strategist, "not strategist");
        }

        IVenusDistribution(venusDistribution).claimVenus(address(this));
        uint256 xvsAmount = IERC20(venusXvs).balanceOf(address(this));
        if (xvsAmount <= 0) {
            return;
        }
        uint256 buyBackAmount = xvsAmount.mul(buyBackRate).div(10000);
        if (buyBackAmount > 0) {
            IERC20(venusXvs).safeTransfer(buyBackPool, buyBackAmount);
        }
        uint256 devAmount = xvsAmount.mul(devFeeRate).div(10000);
        if (devAmount > 0) {
            IERC20(venusXvs).safeTransfer(devAddress, devAmount);
        }
        xvsAmount = xvsAmount.sub(buyBackAmount).sub(devAmount);

        if (xvsAmount <= 0) {
            return;
        }

        if (venusXvs != wantToken) {
            IPancakeSwapRouter(pancakeRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                xvsAmount,
                0,
                _makePath(venusXvs, wantToken),
                address(this),
                block.timestamp.add(60)
            );
        }
        _farm();
    }

    function farm() nonReentrant external {
        if (!recoverPublic) {
            require(_msgSender() == strategist, "not strategist");
        }
        _farm();
    }

    /**
     * @dev Throws if called by any account other than the strategist
     */
    modifier onlyStrategist() {
        require(_msgSender() == strategist, "not strategist");
        _;
    }

    function rebalance(uint256 borrowRate_, uint256 borrowDepth_, bool redeem_, bool withFarm_) external onlyStrategist {
        require(borrowRate_ <= 5950 && borrowDepth_ <= 5, "invalid param");

        if (redeem_) {
            // Redeem all wantToken
            _removeSupplyAll();
            updateBalance();
        }
        
        borrowRate = borrowRate_;
        borrowDepth = borrowDepth_;

        if (withFarm_) {
            _farm();
        }
    }

    // Transfer dustTokens out of xvs and wait for the next reinvestment to convert to wantToken
    function dustToEarnToken(address dustToken_) external onlyStrategist {
        require(dustToken_ != venusXvs && dustToken_ != wantToken, "invalid param");
        uint256 dustAmount = IERC20(dustToken_).balanceOf(address(this));
        if (dustAmount > 0) {
            IERC20(dustToken_).safeIncreaseAllowance(pancakeRouter, dustAmount);
            IPancakeSwapRouter(pancakeRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                dustAmount,
                0,
                _makePath(dustToken_, venusXvs),
                address(this),
                block.timestamp.add(60)
            );
        } 
    }

    function setStrategist(address strategist_) external onlyStrategist {
        require(strategist_ != address(0), "addr 0");
        strategist = strategist_;
    }

    function setDevAddress(address newDev_) external onlyStrategist {
        require(newDev_ != address(0), "addr 0");
        devAddress = newDev_;
    }

    function setFeeRate(uint256 buyBackRate_, uint256 devFeeRate_) external onlyStrategist {
        require(buyBackRate_ <= maxBuyBackRate && devFeeRate_ <= maxDevFeeRate, "invalid param");
        buyBackRate = buyBackRate_;
        devFeeRate = devFeeRate_;
    }

    function setRecoverPublic(bool val_) external onlyStrategist {
        recoverPublic = val_;
    } 

    function setMargin(uint256 margin_) external onlyStrategist {
        baseMarginForWithdraw = margin_;
        maxMarginTriggerDeposit = margin_.mul(2);
    }

    function pause() external onlyStrategist {
        _pause();
        IERC20(wantToken).safeApprove(vToken, 0);
    }

    function unpause() external onlyStrategist {
        _unpause();
        IERC20(wantToken).safeApprove(vToken, uint256(-1));
    }
}
