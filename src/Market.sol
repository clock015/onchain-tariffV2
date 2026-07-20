// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import "./interfaces/ITradeExecutor.sol";
import "./interfaces/IRightsToken.sol";
import "./interfaces/ISettlementAsset.sol";

contract Market is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient
{
    uint256 public constant BPS = 10000;
    uint256 public constant WAD = 1e18;
    uint256 public constant MAX_CURVE_EXPONENT = 10;

    ISettlementAsset public settlementAsset;
    IRightsToken public buyerRights;
    IRightsToken public sellerRights;
    address public vault;
    address public governance;

    struct Merchant {
        uint256 deposit;
        bool isActive;
    }

    struct TradeCalculation {
        uint256 vaultFee;
        uint256 tradeValue;
        uint256 deltaW;
        uint256 deltaS;
        uint256 buyerRefund;
        int256 newSellerBalance;
        int256 newBuyerBalance;
    }

    mapping(address => Merchant) public merchants;
    mapping(address => uint256) public sellerPoints;
    mapping(address => uint256) public claimed;
    mapping(address => int256) public netTradeBalance;

    address public executor;

    mapping(address => uint256) public lastClaimTime;
    mapping(address => uint256) public lastAvailableQuota;

    uint256 public QUOTA_PERIOD;
    uint256 public quotaRatio;

    uint256 public baseTaxRate;
    uint256 public capacityMultiplier;
    uint256 public curveExponent;

    modifier notFromExecutor() {
        require(msg.sender != executor, "Executor cannot trigger trade");
        _;
    }

    event MerchantRegistered(
        address indexed merchant,
        uint256 deposit
    );
    event Traded(
        address indexed payer,
        address indexed buyer,
        address indexed merchant,
        uint256 amount,
        uint256 W,
        uint256 deltaS
    );
    event TradeBalanceUpdated(address indexed account, int256 netTradeBalance);
    event TaxRefunded(address indexed account, uint256 amount);
    event MerchantKicked(address indexed merchant, uint256 slashedAmount);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _settlementAsset,
        address _buyerRights,
        address _sellerRights,
        address _governance,
        address _vault
    ) public initializer {
        __Ownable_init(msg.sender);
        settlementAsset = ISettlementAsset(_settlementAsset);
        buyerRights = IRightsToken(_buyerRights);
        sellerRights = IRightsToken(_sellerRights);
        governance = _governance;
        vault = _vault;
        QUOTA_PERIOD = 30 days;
        quotaRatio = 5000;
        baseTaxRate = 900;
        capacityMultiplier = 50000;
        curveExponent = 2;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    function underlying() external view returns (IERC20) {
        return IERC20(settlementAsset.asset());
    }

    function _positive(int256 value) internal pure returns (uint256) {
        return value > 0 ? uint256(value) : 0;
    }

    function _toInt256(uint256 value) internal pure returns (int256) {
        require(value <= uint256(type(int256).max), "Value too large");
        return int256(value);
    }

    function curveTax(
        uint256 P,
        uint256 deposit
    ) external view returns (uint256) {
        return _curveTax(P, deposit);
    }

    function _curveTax(
        uint256 P,
        uint256 deposit
    ) internal view returns (uint256) {
        if (P == 0) return 0;
        require(deposit > 0, "Deposit required");

        uint256 capacity = FixedPointMathLib.fullMulDiv(
            deposit,
            capacityMultiplier,
            BPS
        );
        require(capacity > 0, "Invalid capacity");
        require(P <= capacity, "Capacity exceeded");

        uint256 baseTax = FixedPointMathLib.fullMulDivUp(P, baseTaxRate, BPS);
        uint256 variableRate = BPS - baseTaxRate;
        if (variableRate == 0) return baseTax > P ? P : baseTax;

        uint256 ratio = FixedPointMathLib.fullMulDiv(P, WAD, capacity);
        uint256 ratioPow = FixedPointMathLib.rpow(ratio, curveExponent, WAD);
        uint256 variableBase = FixedPointMathLib.fullMulDivUp(
            P,
            variableRate,
            BPS
        );
        uint256 variableTax = FixedPointMathLib.fullMulDivUp(
            variableBase,
            ratioPow,
            WAD * (curveExponent + 1)
        );
        uint256 tax = baseTax + variableTax;
        return tax > P ? P : tax;
    }

    function _accountCurveTax(
        address account,
        uint256 positiveBalance
    ) internal view returns (uint256) {
        if (positiveBalance == 0) return 0;
        uint256 deposit = merchants[account].deposit;
        if (deposit == 0) return 0;
        return _curveTax(positiveBalance, deposit);
    }

    function _capTaxRefund(
        address account,
        uint256 requestedRefund
    ) internal view returns (uint256 refund) {
        uint256 collectedTax = sellerPoints[account];
        uint256 availableQuota = getAvailableQuota(account);
        refund = requestedRefund < collectedTax ? requestedRefund : collectedTax;
        if (refund > availableQuota) refund = availableQuota;
    }

    function _applyTaxRefund(
        address account,
        uint256 requestedRefund
    ) internal returns (uint256 refund) {
        refund = _capTaxRefund(account, requestedRefund);
        if (refund == 0) return 0;

        uint256 availableQuota = getAvailableQuota(account);
        sellerPoints[account] -= refund;
        claimed[account] += refund;
        lastAvailableQuota[account] = availableQuota - refund;
        lastClaimTime[account] = block.timestamp;
        emit TaxRefunded(account, refund);
    }

    function calculateAMM(
        address merchant,
        uint256 amount
    ) public view returns (uint256 deltaW, uint256 deltaS) {
        require(amount > 0, "Invalid amount");
        TradeCalculation memory calculation;
        calculation.tradeValue = amount - (amount / 100);
        _calculateSellerTrade(merchant, calculation);
        return (calculation.deltaW, calculation.deltaS);
    }

    function _calculateSellerTrade(
        address merchant,
        TradeCalculation memory calculation
    ) internal view {
        Merchant storage m = merchants[merchant];
        require(m.isActive, "Merchant not active");
        require(calculation.tradeValue > 0, "Invalid trade value");

        int256 tradeValueInt = _toInt256(calculation.tradeValue);
        int256 oldSellerBalance = netTradeBalance[merchant];
        calculation.newSellerBalance = oldSellerBalance + tradeValueInt;
        uint256 newTax = _accountCurveTax(
            merchant,
            _positive(calculation.newSellerBalance)
        );
        uint256 collectedTax = sellerPoints[merchant];
        if (newTax > collectedTax) {
            calculation.deltaS = newTax - collectedTax;
        }
        require(
            calculation.deltaS <= calculation.tradeValue,
            "Tax exceeds trade value"
        );
        calculation.deltaW = calculation.tradeValue - calculation.deltaS;
    }

    function _calculateBuyerRefund(
        address buyer,
        TradeCalculation memory calculation
    ) internal view {
        int256 tradeValueInt = _toInt256(calculation.tradeValue);
        int256 oldBuyerBalance = netTradeBalance[buyer];
        calculation.newBuyerBalance = oldBuyerBalance - tradeValueInt;
        uint256 newTax = _accountCurveTax(
            buyer,
            _positive(calculation.newBuyerBalance)
        );
        uint256 collectedTax = sellerPoints[buyer];
        uint256 requestedRefund = collectedTax > newTax
            ? collectedTax - newTax
            : 0;
        calculation.buyerRefund = _capTaxRefund(
            buyer,
            requestedRefund
        );
        if (calculation.buyerRefund > calculation.tradeValue) {
            calculation.buyerRefund = calculation.tradeValue;
        }
    }

    function registerMerchant(uint256 amount) external nonReentrant {
        require(amount > 0, "Deposit required");

        Merchant storage m = merchants[msg.sender];
        uint256 oldDeposit = m.deposit;
        uint256 newDeposit = oldDeposit + amount;
        uint256 depositCredit = 0;
        uint256 oldP = _positive(netTradeBalance[msg.sender]);

        if (oldP > 0 && oldDeposit > 0) {
            uint256 oldTax = _curveTax(oldP, oldDeposit);
            uint256 newTax = _curveTax(oldP, newDeposit);
            if (oldTax > newTax) {
                depositCredit = oldTax - newTax;
                uint256 collectedTax = sellerPoints[msg.sender];
                if (depositCredit > collectedTax) {
                    depositCredit = collectedTax;
                }
                if (depositCredit > amount) depositCredit = amount;
            }
        }

        settlementAsset.pull(msg.sender, amount - depositCredit);

        if (depositCredit > 0) {
            sellerPoints[msg.sender] -= depositCredit;
        }

        if (!m.isActive) {
            m.isActive = true;
        }
        m.deposit = newDeposit;
        emit MerchantRegistered(msg.sender, m.deposit);
    }

    function trade(
        address buyer,
        address merchant,
        uint160 rechargeTarget,
        uint256 amount,
        bytes calldata data
    ) external nonReentrant notFromExecutor {
        require(buyer != merchant, "Self trade not allowed");
        require(amount > 0, "Invalid amount");

        TradeCalculation memory calculation;
        calculation.vaultFee = amount / 100;
        calculation.tradeValue = amount - calculation.vaultFee;
        _calculateSellerTrade(merchant, calculation);
        _calculateBuyerRefund(buyer, calculation);
        if (msg.sender != buyer) {
            calculation.buyerRefund = 0;
        }

        netTradeBalance[merchant] = calculation.newSellerBalance;
        netTradeBalance[buyer] = calculation.newBuyerBalance;

        if (calculation.buyerRefund > 0) {
            calculation.buyerRefund = _applyTaxRefund(
                buyer,
                calculation.buyerRefund
            );
        }

        settlementAsset.pull(msg.sender, amount - calculation.buyerRefund);
        settlementAsset.push(vault, calculation.vaultFee);

        sellerPoints[merchant] += calculation.deltaS;

        buyerRights.mint(buyer, calculation.vaultFee);
        sellerRights.mint(merchant, calculation.vaultFee);

        ITradeExecutor(executor).executeTrade(
            merchant,
            rechargeTarget,
            calculation.tradeValue,
            calculation.deltaW,
            data
        );

        emit TradeBalanceUpdated(merchant, calculation.newSellerBalance);
        emit TradeBalanceUpdated(buyer, calculation.newBuyerBalance);
        emit Traded(
            msg.sender,
            buyer,
            merchant,
            amount,
            calculation.deltaW,
            calculation.deltaS
        );
    }


    function getAvailableQuota(address account) public view returns (uint256) {
        uint256 deposit = merchants[account].deposit;
        if (deposit == 0) return 0;
        uint256 maxQuota = (deposit * quotaRatio) / BPS;
        if (lastClaimTime[account] == 0) return maxQuota;
        uint256 timePassed = block.timestamp - lastClaimTime[account];
        if (timePassed >= QUOTA_PERIOD) return maxQuota;
        uint256 recovered = (maxQuota * timePassed) / QUOTA_PERIOD;
        uint256 total = lastAvailableQuota[account] + recovered;
        return total > maxQuota ? maxQuota : total;
    }

    function kickMerchant(address merchant) external nonReentrant {
        require(msg.sender == governance, "Only governance");
        Merchant storage m = merchants[merchant];
        require(m.isActive, "Merchant not active");
        uint256 slashedAmount = m.deposit + sellerPoints[merchant];
        sellerPoints[merchant] = 0;
        delete merchants[merchant];
        delete netTradeBalance[merchant];
        settlementAsset.push(vault, slashedAmount);
        emit TradeBalanceUpdated(merchant, 0);
        emit MerchantKicked(merchant, slashedAmount);
    }

    function setVault(address _newVault) external onlyOwner {
        vault = _newVault;
    }

    function setExecutor(address _executor) external onlyOwner {
        executor = _executor;
    }

    function setQuotaParams(uint256 _newRatio) external onlyOwner {
        quotaRatio = _newRatio;
    }

    function setGlobalAMMParams(
        uint256 _baseTaxRate,
        uint256 _capacityMultiplier,
        uint256 _curveExponent
    ) external onlyOwner {
        require(_baseTaxRate <= BPS, "Invalid base tax rate");
        require(_capacityMultiplier > 0, "Invalid capacity multiplier");
        require(_curveExponent > 0, "Invalid curve exponent");
        require(
            _curveExponent <= MAX_CURVE_EXPONENT,
            "Curve exponent too high"
        );
        baseTaxRate = _baseTaxRate;
        capacityMultiplier = _capacityMultiplier;
        curveExponent = _curveExponent;
    }
}
