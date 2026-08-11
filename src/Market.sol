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

contract Market is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardTransient {
    uint256 public constant BPS = 10000;
    uint256 public constant WAD = 1e18;
    uint256 public constant MIN_CAPACITY_MULTIPLIER = BPS;
    uint256 public constant MAX_CURVE_EXPONENT = 10;

    ISettlementAsset public settlementAsset;
    IRightsToken public buyerRights;
    IRightsToken public sellerRights;
    address public vault;
    address public governance;
    address public executor;

    struct MarketAccount {
        address owner;
        address merchant;
        uint256 deposit;
        uint256 capacityMultiplier;
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

    uint256 public nextAccountId;
    mapping(uint256 => MarketAccount) public accounts;
    mapping(address => mapping(address => uint256)) public accountIdOf;

    mapping(uint256 => uint256) public sellerPoints;
    mapping(uint256 => uint256) public claimed;
    mapping(uint256 => int256) public netTradeBalance;
    mapping(uint256 => uint256) public lastClaimTime;
    mapping(uint256 => uint256) public lastAvailableQuota;

    uint256 public QUOTA_PERIOD;
    uint256 public quotaRatio;
    uint256 public baseTaxRate;
    uint256 public curveExponent;

    modifier notFromExecutor() {
        require(msg.sender != executor, "Executor cannot trigger trade");
        _;
    }

    event AccountCreated(uint256 indexed accountId, address indexed owner, address indexed merchant);
    event MerchantRegistered(
        uint256 indexed accountId,
        address indexed owner,
        address indexed merchant,
        uint256 deposit,
        uint256 capacityMultiplier
    );
    event MerchantDepositIncreased(
        uint256 indexed accountId, address indexed payer, uint256 amount, uint256 totalDeposit
    );
    event CapacityMultiplierUpdated(uint256 indexed accountId, uint256 oldMultiplier, uint256 newMultiplier);
    event Traded(
        address indexed payer,
        address indexed buyer,
        uint256 indexed sellerAccountId,
        uint256 buyerAccountId,
        address merchant,
        uint256 amount,
        uint256 W,
        uint256 deltaS
    );
    event TradeBalanceChanged(
        uint256 indexed buyerAccountId,
        uint256 indexed sellerAccountId,
        address indexed buyer,
        address merchant,
        int256 oldBuyerBalance,
        int256 newBuyerBalance,
        int256 oldMerchantBalance,
        int256 newMerchantBalance
    );
    event TradeBalanceUpdated(uint256 indexed accountId, int256 netTradeBalance);
    event TaxRefunded(uint256 indexed accountId, uint256 amount);
    event MerchantKicked(
        uint256 indexed accountId, address indexed owner, address indexed merchant, uint256 slashedAmount
    );

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
        nextAccountId = 1;
        QUOTA_PERIOD = 30 days;
        quotaRatio = 5000;
        baseTaxRate = 900;
        curveExponent = 2;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

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

    function _createAccount(address owner, address merchant) internal returns (uint256 accountId) {
        require(owner != address(0), "Invalid owner");
        require(merchant != address(0), "Invalid merchant");
        require(accountIdOf[owner][merchant] == 0, "Account already exists");

        accountId = nextAccountId++;
        accounts[accountId].owner = owner;
        accounts[accountId].merchant = merchant;
        accountIdOf[owner][merchant] = accountId;
        emit AccountCreated(accountId, owner, merchant);
    }

    function _resolveBuyerAccount(address buyer, uint256 buyerAccountId) internal returns (uint256 resolvedAccountId) {
        require(buyer != address(0), "Invalid buyer");

        if (buyerAccountId == 0) {
            resolvedAccountId = accountIdOf[buyer][buyer];
            if (resolvedAccountId == 0) {
                resolvedAccountId = _createAccount(buyer, buyer);
            }
            return resolvedAccountId;
        }

        MarketAccount storage account = accounts[buyerAccountId];
        require(account.owner != address(0), "Buyer account not found");
        require(account.owner == buyer, "Buyer is not account owner");
        return buyerAccountId;
    }

    function curveTax(uint256 P, uint256 deposit, uint256 capacityMultiplier) external view returns (uint256) {
        return _curveTax(P, deposit, capacityMultiplier);
    }

    function accountCurveTax(uint256 accountId, uint256 positiveBalance) external view returns (uint256) {
        return _accountCurveTax(accountId, positiveBalance);
    }

    function _curveTax(uint256 P, uint256 deposit, uint256 capacityMultiplier) internal view returns (uint256) {
        if (P == 0) return 0;
        require(deposit > 0, "Deposit required");
        require(capacityMultiplier >= MIN_CAPACITY_MULTIPLIER, "Invalid capacity multiplier");

        uint256 capacity = FixedPointMathLib.fullMulDiv(deposit, capacityMultiplier, BPS);
        require(capacity > 0, "Invalid capacity");
        require(P <= capacity, "Capacity exceeded");

        uint256 baseTax = FixedPointMathLib.fullMulDivUp(P, baseTaxRate, BPS);
        uint256 variableRate = BPS - baseTaxRate;
        if (variableRate == 0) return baseTax > P ? P : baseTax;

        uint256 ratio = FixedPointMathLib.fullMulDiv(P, WAD, capacity);
        uint256 ratioPow = FixedPointMathLib.rpow(ratio, curveExponent, WAD);
        uint256 variableBase = FixedPointMathLib.fullMulDivUp(P, variableRate, BPS);
        uint256 variableTax = FixedPointMathLib.fullMulDivUp(variableBase, ratioPow, WAD * (curveExponent + 1));
        uint256 tax = baseTax + variableTax;
        return tax > P ? P : tax;
    }

    function _accountCurveTax(uint256 accountId, uint256 positiveBalance) internal view returns (uint256) {
        if (positiveBalance == 0) return 0;
        MarketAccount storage account = accounts[accountId];
        if (account.deposit == 0) return 0;
        return _curveTax(positiveBalance, account.deposit, account.capacityMultiplier);
    }

    function _capTaxRefund(uint256 accountId, uint256 requestedRefund) internal view returns (uint256 refund) {
        uint256 collectedTax = sellerPoints[accountId];
        uint256 availableQuota = getAvailableQuota(accountId);
        refund = requestedRefund < collectedTax ? requestedRefund : collectedTax;
        if (refund > availableQuota) refund = availableQuota;
    }

    function _applyTaxRefund(uint256 accountId, uint256 requestedRefund) internal returns (uint256 refund) {
        refund = _capTaxRefund(accountId, requestedRefund);
        if (refund == 0) return 0;

        uint256 availableQuota = getAvailableQuota(accountId);
        sellerPoints[accountId] -= refund;
        claimed[accountId] += refund;
        lastAvailableQuota[accountId] = availableQuota - refund;
        lastClaimTime[accountId] = block.timestamp;
        emit TaxRefunded(accountId, refund);
    }

    function calculateAMM(uint256 sellerAccountId, uint256 amount)
        public
        view
        returns (uint256 deltaW, uint256 deltaS)
    {
        require(amount > 0, "Invalid amount");
        TradeCalculation memory calculation;
        calculation.tradeValue = amount - (amount / 100);
        _calculateSellerTrade(sellerAccountId, calculation);
        return (calculation.deltaW, calculation.deltaS);
    }

    function _calculateSellerTrade(uint256 sellerAccountId, TradeCalculation memory calculation) internal view {
        MarketAccount storage account = accounts[sellerAccountId];
        require(account.isActive, "Merchant account not active");
        require(calculation.tradeValue > 0, "Invalid trade value");

        int256 tradeValueInt = _toInt256(calculation.tradeValue);
        int256 oldSellerBalance = netTradeBalance[sellerAccountId];
        calculation.newSellerBalance = oldSellerBalance + tradeValueInt;
        uint256 newTax = _accountCurveTax(sellerAccountId, _positive(calculation.newSellerBalance));
        uint256 collectedTax = sellerPoints[sellerAccountId];
        if (newTax > collectedTax) {
            calculation.deltaS = newTax - collectedTax;
        }
        require(calculation.deltaS <= calculation.tradeValue, "Tax exceeds trade value");
        calculation.deltaW = calculation.tradeValue - calculation.deltaS;
    }

    function _calculateBuyerRefund(uint256 buyerAccountId, TradeCalculation memory calculation) internal view {
        int256 tradeValueInt = _toInt256(calculation.tradeValue);
        int256 oldBuyerBalance = netTradeBalance[buyerAccountId];
        calculation.newBuyerBalance = oldBuyerBalance - tradeValueInt;
        uint256 newTax = _accountCurveTax(buyerAccountId, _positive(calculation.newBuyerBalance));
        uint256 collectedTax = sellerPoints[buyerAccountId];
        uint256 requestedRefund = collectedTax > newTax ? collectedTax - newTax : 0;
        calculation.buyerRefund = _capTaxRefund(buyerAccountId, requestedRefund);
        if (calculation.buyerRefund > calculation.tradeValue) {
            calculation.buyerRefund = calculation.tradeValue;
        }
    }

    function registerMerchant(address merchant, uint256 amount, uint256 capacityMultiplier)
        external
        nonReentrant
        returns (uint256 accountId)
    {
        require(amount > 0, "Deposit required");
        require(merchant != address(0), "Invalid merchant");
        require(capacityMultiplier >= MIN_CAPACITY_MULTIPLIER, "Invalid capacity multiplier");

        accountId = accountIdOf[msg.sender][merchant];
        if (accountId == 0) {
            accountId = _createAccount(msg.sender, merchant);
        }

        MarketAccount storage account = accounts[accountId];
        require(!account.isActive, "Merchant account already active");

        settlementAsset.pull(msg.sender, amount);
        account.deposit = amount;
        account.capacityMultiplier = capacityMultiplier;
        account.isActive = true;

        emit MerchantRegistered(accountId, account.owner, account.merchant, amount, capacityMultiplier);
    }

    function addDeposit(uint256 accountId, uint256 amount) external nonReentrant {
        require(amount > 0, "Deposit required");
        MarketAccount storage account = accounts[accountId];
        require(account.isActive, "Merchant account not active");

        settlementAsset.pull(msg.sender, amount);
        account.deposit += amount;

        emit MerchantDepositIncreased(accountId, msg.sender, amount, account.deposit);
    }

    function setCapacityMultiplier(uint256 accountId, uint256 newMultiplier) external {
        MarketAccount storage account = accounts[accountId];
        require(account.isActive, "Merchant account not active");
        require(msg.sender == account.owner, "Only account owner");
        require(newMultiplier >= MIN_CAPACITY_MULTIPLIER, "Invalid capacity multiplier");
        uint256 oldMultiplier = account.capacityMultiplier;
        require(newMultiplier <= oldMultiplier, "Multiplier can only decrease");

        uint256 positiveBalance = _positive(netTradeBalance[accountId]);
        if (positiveBalance > 0) {
            uint256 capacity = FixedPointMathLib.fullMulDiv(account.deposit, newMultiplier, BPS);
            require(positiveBalance <= capacity, "Capacity exceeded");
        }

        account.capacityMultiplier = newMultiplier;
        emit CapacityMultiplierUpdated(accountId, oldMultiplier, newMultiplier);
    }

    function trade(
        address buyer,
        uint256 buyerAccountId,
        uint256 sellerAccountId,
        uint160 rechargeTarget,
        uint256 amount,
        bytes calldata data
    ) external nonReentrant notFromExecutor {
        require(amount > 0, "Invalid amount");

        buyerAccountId = _resolveBuyerAccount(buyer, buyerAccountId);
        require(buyerAccountId != sellerAccountId, "Self trade not allowed");

        MarketAccount storage buyerAccount = accounts[buyerAccountId];
        MarketAccount storage sellerAccount = accounts[sellerAccountId];
        require(sellerAccount.isActive, "Merchant account not active");
        if (buyerAccount.isActive) {
            require(sellerAccount.capacityMultiplier <= buyerAccount.capacityMultiplier, "Seller multiplier too high");
        }

        TradeCalculation memory calculation;
        calculation.vaultFee = amount / 100;
        calculation.tradeValue = amount - calculation.vaultFee;
        _calculateSellerTrade(sellerAccountId, calculation);
        _calculateBuyerRefund(buyerAccountId, calculation);

        bool canUseRefund = buyerAccount.owner == buyer && msg.sender == buyerAccount.merchant;
        if (!canUseRefund) calculation.buyerRefund = 0;

        netTradeBalance[sellerAccountId] = calculation.newSellerBalance;
        netTradeBalance[buyerAccountId] = calculation.newBuyerBalance;

        if (calculation.buyerRefund > 0) {
            calculation.buyerRefund = _applyTaxRefund(buyerAccountId, calculation.buyerRefund);
        }

        settlementAsset.pull(msg.sender, amount - calculation.buyerRefund);
        settlementAsset.push(vault, calculation.vaultFee);
        sellerPoints[sellerAccountId] += calculation.deltaS;

        buyerRights.mint(buyerAccount.owner, calculation.vaultFee);
        sellerRights.mint(sellerAccount.owner, calculation.vaultFee);

        ITradeExecutor(executor)
            .executeTrade(
                sellerAccount.merchant,
                sellerAccount.owner,
                rechargeTarget,
                calculation.tradeValue,
                calculation.deltaW,
                data
            );

        emit TradeBalanceUpdated(sellerAccountId, calculation.newSellerBalance);
        emit TradeBalanceUpdated(buyerAccountId, calculation.newBuyerBalance);
        int256 tradeValue = _toInt256(calculation.tradeValue);
        emit TradeBalanceChanged(
            buyerAccountId,
            sellerAccountId,
            buyer,
            sellerAccount.merchant,
            calculation.newBuyerBalance + tradeValue,
            calculation.newBuyerBalance,
            calculation.newSellerBalance - tradeValue,
            calculation.newSellerBalance
        );
        emit Traded(
            msg.sender,
            buyer,
            sellerAccountId,
            buyerAccountId,
            sellerAccount.merchant,
            amount,
            calculation.deltaW,
            calculation.deltaS
        );
    }

    function getAvailableQuota(uint256 accountId) public view returns (uint256) {
        uint256 deposit = accounts[accountId].deposit;
        if (deposit == 0) return 0;
        uint256 maxQuota = FixedPointMathLib.fullMulDiv(deposit, quotaRatio, BPS);
        if (lastClaimTime[accountId] == 0) return maxQuota;
        uint256 timePassed = block.timestamp - lastClaimTime[accountId];
        if (timePassed >= QUOTA_PERIOD) return maxQuota;
        uint256 recovered = FixedPointMathLib.fullMulDiv(maxQuota, timePassed, QUOTA_PERIOD);
        uint256 total = lastAvailableQuota[accountId] + recovered;
        return total > maxQuota ? maxQuota : total;
    }

    function kickMerchant(uint256 accountId) external nonReentrant {
        require(msg.sender == governance, "Only governance");
        MarketAccount memory account = accounts[accountId];
        require(account.isActive, "Merchant account not active");

        uint256 slashedAmount = account.deposit + sellerPoints[accountId];
        delete accountIdOf[account.owner][account.merchant];
        delete accounts[accountId];
        delete sellerPoints[accountId];
        delete claimed[accountId];
        delete netTradeBalance[accountId];
        delete lastClaimTime[accountId];
        delete lastAvailableQuota[accountId];

        settlementAsset.push(vault, slashedAmount);
        emit TradeBalanceUpdated(accountId, 0);
        emit MerchantKicked(accountId, account.owner, account.merchant, slashedAmount);
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

    function setGlobalAMMParams(uint256 _baseTaxRate, uint256 _curveExponent) external onlyOwner {
        require(_baseTaxRate <= BPS, "Invalid base tax rate");
        require(_curveExponent > 0, "Invalid curve exponent");
        require(_curveExponent <= MAX_CURVE_EXPONENT, "Curve exponent too high");
        baseTaxRate = _baseTaxRate;
        curveExponent = _curveExponent;
    }
}
