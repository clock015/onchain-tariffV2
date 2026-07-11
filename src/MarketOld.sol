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

contract MarketOld is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient
{
    using FixedPointMathLib for uint256;

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

    mapping(address => Merchant) public merchants;
    mapping(address => uint256) public buyerPoints;
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
        uint256 deposit,
        uint256 W
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
        capacityMultiplier = 5;
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

        uint256 capacity = deposit * capacityMultiplier;
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

    function calculateAMM(
        address merchant,
        uint256 amount
    ) public view returns (uint256 deltaW, uint256 deltaS) {
        (deltaW, deltaS, , ) = _calculateTrade(merchant, amount);
    }

    function _calculateTrade(
        address merchant,
        uint256 amount
    )
        internal
        view
        returns (
            uint256 deltaW,
            uint256 deltaS,
            uint256 tradeValue,
            int256 newSellerBalance
        )
    {
        Merchant storage m = merchants[merchant];
        require(m.isActive, "Merchant not active");
        require(amount > 0, "Invalid amount");

        uint256 vaultFee = amount / 100;
        tradeValue = amount - vaultFee;
        require(tradeValue > 0, "Invalid trade value");

        int256 oldBalance = netTradeBalance[merchant];
        newSellerBalance = oldBalance + _toInt256(tradeValue);
        uint256 oldP = _positive(oldBalance);
        uint256 newP = oldP + tradeValue;

        deltaS = _curveTax(newP, m.deposit) - _curveTax(oldP, m.deposit);
        require(deltaS <= tradeValue, "Tax exceeds trade value");
        deltaW = tradeValue - deltaS;
    }

    function registerMerchant(uint256 amount) external {
        require(amount > 0, "Deposit required");

        settlementAsset.pull(msg.sender, amount);

        Merchant storage m = merchants[msg.sender];
        if (!m.isActive) {
            m.isActive = true;
        }
        m.deposit += amount;
        emit MerchantRegistered(msg.sender, m.deposit, 0);
    }

    function trade(
        address buyer,
        address merchant,
        uint160 rechargeTarget,
        uint256 amount,
        bytes calldata data
    ) external nonReentrant notFromExecutor {
        require(buyer != merchant, "Self trade not allowed");

        uint256 vaultFee = amount / 100;
        (
            uint256 deltaW,
            uint256 deltaS,
            uint256 tradeValue,
            int256 newSellerBalance
        ) = _calculateTrade(merchant, amount);

        netTradeBalance[merchant] = newSellerBalance;
        netTradeBalance[buyer] -= _toInt256(tradeValue);

        (
            uint256 buyerPointDelta,
            uint256 autoRefund
        ) = _autoRefundFromSellerPoints(buyer, deltaS);

        settlementAsset.pull(msg.sender, amount - autoRefund);
        settlementAsset.push(vault, vaultFee);

        buyerPoints[buyer] += buyerPointDelta;
        sellerPoints[merchant] += deltaS;

        if (autoRefund > 0) {
            emit TaxRefunded(buyer, autoRefund);
        }

        buyerRights.mint(buyer, vaultFee);
        sellerRights.mint(merchant, vaultFee);

        ITradeExecutor(executor).executeTrade(
            merchant,
            rechargeTarget,
            tradeValue,
            deltaW,
            data
        );

        emit TradeBalanceUpdated(merchant, newSellerBalance);
        emit TradeBalanceUpdated(buyer, netTradeBalance[buyer]);
        emit Traded(msg.sender, buyer, merchant, amount, deltaW, deltaS);
    }

    function _autoRefundFromSellerPoints(
        address buyer,
        uint256 maxRefund
    ) internal returns (uint256 buyerPointDelta, uint256 autoRefund) {
        buyerPointDelta = maxRefund;
        if (msg.sender != buyer || maxRefund == 0) return (buyerPointDelta, 0);

        uint256 sellerBalance = sellerPoints[buyer];
        if (sellerBalance == 0) return (buyerPointDelta, 0);

        uint256 availableQuota = getAvailableQuota(buyer);
        if (availableQuota == 0) return (buyerPointDelta, 0);

        autoRefund = sellerBalance < maxRefund ? sellerBalance : maxRefund;
        if (autoRefund > availableQuota) autoRefund = availableQuota;

        sellerPoints[buyer] -= autoRefund;
        buyerPointDelta = maxRefund - autoRefund;
        lastAvailableQuota[buyer] = availableQuota - autoRefund;
        lastClaimTime[buyer] = block.timestamp;
        claimed[buyer] += autoRefund;
    }

    function claimTaxRefund(address account) external nonReentrant {
        (uint256 actualClaim, uint256 newAvailableQuota) = claimable(account);
        lastAvailableQuota[account] = newAvailableQuota;
        lastClaimTime[account] = block.timestamp;
        buyerPoints[account] -= actualClaim;
        sellerPoints[account] -= actualClaim;
        claimed[account] += actualClaim;
        settlementAsset.push(account, actualClaim);
        emit TaxRefunded(account, actualClaim);
    }

    function claimable(
        address account
    ) public view returns (uint256 actualClaim, uint256 newAvailableQuota) {
        uint256 bP = buyerPoints[account];
        uint256 sP = sellerPoints[account];
        uint256 totalRefundable = bP < sP ? bP : sP;
        require(totalRefundable > 0, "No refundable points");
        uint256 availableQuota = getAvailableQuota(account);
        require(availableQuota > 0, "Quota exhausted");
        actualClaim = totalRefundable > availableQuota
            ? availableQuota
            : totalRefundable;
        newAvailableQuota = availableQuota - actualClaim;
        return (actualClaim, newAvailableQuota);
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
        uint256 slashedAmount = m.deposit;
        if (buyerPoints[merchant] > 0) {
            buyerPoints[vault] += buyerPoints[merchant];
            buyerPoints[merchant] = 0;
        }
        if (sellerPoints[merchant] > 0) {
            sellerPoints[vault] += sellerPoints[merchant];
            sellerPoints[merchant] = 0;
        }
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
