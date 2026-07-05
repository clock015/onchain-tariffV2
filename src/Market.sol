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
    using FixedPointMathLib for uint256;

    ISettlementAsset public settlementAsset;
    IRightsToken public buyerRights;
    IRightsToken public sellerRights;
    address public vault;
    address public governance;

    struct Merchant {
        uint256 deposit;
        bool isActive;
        uint256 K;
        uint256 leverageFactor;
        uint256 virtualDepthRatio;
    }

    mapping(address => Merchant) public merchants;
    mapping(address => uint256) public buyerPoints;
    mapping(address => uint256) public sellerPoints;
    mapping(address => uint256) public claimed;

    address public executor;

    mapping(address => uint256) public lastClaimTime;
    mapping(address => uint256) public lastAvailableQuota;

    uint256 public QUOTA_PERIOD;
    uint256 public quotaRatio;

    uint256 public leverageFactor;
    uint256 public virtualDepthRatio;

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
        leverageFactor = 800;
        virtualDepthRatio = 9000;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    function underlying() external view returns (IERC20) {
        return IERC20(settlementAsset.asset());
    }

    function _getSurplus(address account) internal view returns (uint256) {
        uint256 sP = sellerPoints[account];
        uint256 bP = buyerPoints[account];
        return sP > bP ? sP - bP : 0;
    }

    function _syncMerchantParams(address merchant) internal {
        Merchant storage m = merchants[merchant];
        if (!m.isActive) return;
        if (
            m.leverageFactor == leverageFactor &&
            m.virtualDepthRatio == virtualDepthRatio
        ) return;

        uint256 S = _getSurplus(merchant);
        uint256 oldMaxW = (m.deposit * m.leverageFactor) / 100;
        uint256 oldY = S + ((m.deposit * m.virtualDepthRatio) / 10000);
        uint256 oldR = m.K / oldY;
        uint256 W = oldMaxW - oldR;

        m.leverageFactor = leverageFactor;
        m.virtualDepthRatio = virtualDepthRatio;

        uint256 newMaxW = (m.deposit * m.leverageFactor) / 100;
        uint256 newY = S + ((m.deposit * m.virtualDepthRatio) / 10000);
        uint256 newR = W >= newMaxW ? 0 : newMaxW - W;
        m.K = newR * newY;
    }

    function calculateAMM(
        address merchant,
        uint256 amount
    ) public view returns (uint256 deltaW, uint256 deltaS) {
        Merchant storage m = merchants[merchant];
        uint256 S = _getSurplus(merchant);
        uint256 Y = S + ((m.deposit * m.virtualDepthRatio) / 10000);
        uint256 P = amount - (amount / 100);
        uint256 R = m.K / Y;

        if (R == 0) return (0, P);

        int256 b = int256(R) + int256(Y) - int256(P);
        uint256 discriminant = uint256(b * b) + (4 * P * Y);
        uint256 root = FixedPointMathLib.sqrt(discriminant);

        if (b >= 0) {
            deltaS = (root - uint256(b)) / 2;
        } else {
            deltaS = (root + uint256(-b)) / 2;
        }

        if (deltaS > P) deltaS = P;
        deltaW = P - deltaS;
    }

    function registerMerchant(uint256 amount) external {
        require(amount > 0, "Deposit required");

        Merchant storage m = merchants[msg.sender];
        uint256 S = _getSurplus(msg.sender);
        uint256 W;

        if (m.isActive) {
            _syncMerchantParams(msg.sender);
            uint256 oldMaxW = (m.deposit * m.leverageFactor) / 100;
            uint256 oldY = S + ((m.deposit * m.virtualDepthRatio) / 10000);
            uint256 oldR = m.K / oldY;
            W = oldMaxW - oldR;
            m.deposit += amount;
        } else {
            m.isActive = true;
            m.deposit = amount;
            m.leverageFactor = leverageFactor;
            m.virtualDepthRatio = virtualDepthRatio;
        }

        uint256 newMaxW = (m.deposit * m.leverageFactor) / 100;
        uint256 newY = S + ((m.deposit * m.virtualDepthRatio) / 10000);
        uint256 newR = W >= newMaxW ? 0 : newMaxW - W;
        m.K = newR * newY;

        settlementAsset.pull(msg.sender, amount);
        emit MerchantRegistered(msg.sender, m.deposit, W);
    }

    function trade(
        address buyer,
        address merchant,
        uint160 rechargeTarget,
        uint256 amount,
        bytes calldata data
    ) external nonReentrant notFromExecutor {
        Merchant storage m = merchants[merchant];
        require(m.isActive, "Merchant not active");

        _syncMerchantParams(merchant);

        (uint256 deltaW, uint256 deltaS) = calculateAMM(merchant, amount);

        uint256 vaultFee = amount / 100;
        uint256 netAmount = amount - vaultFee;
        settlementAsset.pull(msg.sender, amount);
        settlementAsset.push(vault, vaultFee);

        buyerPoints[buyer] += deltaS;
        sellerPoints[merchant] += deltaS;

        buyerRights.mint(buyer, vaultFee);
        sellerRights.mint(merchant, vaultFee);
        ITradeExecutor(executor).executeTrade(
            merchant,
            rechargeTarget,
            netAmount,
            deltaW,
            data
        );

        emit Traded(msg.sender, buyer, merchant, amount, deltaW, deltaS);
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
        uint256 maxQuota = (deposit * quotaRatio) / 10000;
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
        settlementAsset.push(vault, slashedAmount);
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
        uint256 _leverage,
        uint256 _depthRatio
    ) external onlyOwner {
        require(_leverage > 0, "Invalid leverage");
        require(_depthRatio > 0, "Invalid depth ratio");
        leverageFactor = _leverage;
        virtualDepthRatio = _depthRatio;
    }
}
