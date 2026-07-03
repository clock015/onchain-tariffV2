// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import "./interfaces/ITradeExecutor.sol";
import "./interfaces/IRightsToken.sol";

contract Market is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    // --- 状态变量 ---
    IERC20 public underlying;
    IRightsToken public buyerRights;
    IRightsToken public sellerRights;
    address public vault;
    address public governance;

    struct Merchant {
        uint256 deposit; // D: 押金
        bool isActive;
        uint256 W; // W: 已提现现金总额 (实际业务意义)
        uint256 leverageFactor; // 商家快照杠杆 (100基准)
        uint256 virtualDepthRatio; // 商家快照深度比例 (10000基准)
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

    // --- 全局默认参数 ---
    uint256 public leverageFactor; // 默认最大利润押金比 (例如 1000 代表 10倍)
    uint256 public virtualDepthRatio; // 默认最低关税基数 (例如 9000 代表 0.9)

    // --- 权限与检查 ---
    modifier notFromExecutor() {
        require(msg.sender != executor, "Executor cannot trigger trade");
        _;
    }

    // --- 事件 ---
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
        address _underlying,
        address _buyerRights,
        address _sellerRights,
        address _governance,
        address _vault
    ) public initializer {
        __Ownable_init(msg.sender);
        underlying = IERC20(_underlying);
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

    // --- 核心数学逻辑 ---

    function _getSurplus(address account) internal view returns (uint256) {
        uint256 sP = sellerPoints[account];
        uint256 bP = buyerPoints[account];
        return sP > bP ? sP - bP : 0;
    }

    /**
     * @dev 同步商家参数快照。因为存储的是 W，同步时无需重新计算 W。
     */
    function _syncMerchantParams(address merchant) internal {
        Merchant storage m = merchants[merchant];
        if (!m.isActive) return;
        if (
            m.leverageFactor == leverageFactor &&
            m.virtualDepthRatio == virtualDepthRatio
        ) return;

        m.leverageFactor = leverageFactor;
        m.virtualDepthRatio = virtualDepthRatio;
    }

    /**
     * @notice 计算 AMM 分配
     * 使用 (MaxW - W) * Y = K 原理计算
     */
    function calculateAMM(
        address merchant,
        uint256 amount
    ) public view returns (uint256 deltaW, uint256 deltaS) {
        Merchant storage m = merchants[merchant];
        uint256 S = _getSurplus(merchant);
        uint256 D = m.deposit;
        uint256 MaxW = (D * m.leverageFactor) / 100;

        // P = amount after the fixed 1% rights-token fee.
        uint256 P = amount - (amount / 100);
        // Y = S + virtualDepthRatio * D
        uint256 Y = S + ((D * m.virtualDepthRatio) / 10000);

        // 如果已提现 W 超过或等于当前最大额度 MaxW，则无法提取现金
        if (m.W >= MaxW) {
            return (0, P);
        }

        // 现金余额 R = MaxW - W
        uint256 R = MaxW - m.W;
        // 现场计算本次交易的临时 K = R * Y
        // uint256 K = R * Y;

        // 解二次方程: (R - deltaW)(Y + deltaS) = K 且 deltaW + deltaS = P
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

    // --- 核心业务 ---

    function registerMerchant(uint256 amount) external {
        require(amount > 0, "Deposit required");

        Merchant storage m = merchants[msg.sender];

        if (m.isActive) {
            _syncMerchantParams(msg.sender);
            // 直接追加押金，W 保持不变 (自然实现了 W 在新 MaxW 下的延续)
            m.deposit += amount;
        } else {
            m.isActive = true;
            m.deposit = amount;
            m.W = 0; // 新商家已提现为 0
            m.leverageFactor = leverageFactor;
            m.virtualDepthRatio = virtualDepthRatio;
        }

        underlying.safeTransferFrom(msg.sender, address(this), amount);
        emit MerchantRegistered(msg.sender, m.deposit, m.W);
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
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        underlying.safeTransfer(vault, vaultFee);

        // 更新商家已提现现金总额 W
        m.W += deltaW;

        buyerPoints[buyer] += deltaS;
        sellerPoints[merchant] += deltaS;

        buyerRights.mint(buyer, vaultFee);
        sellerRights.mint(merchant, vaultFee);

        underlying.safeTransfer(executor, deltaW);
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
        underlying.safeTransfer(account, actualClaim);
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
        underlying.safeTransfer(vault, slashedAmount);
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
        leverageFactor = _leverage;
        virtualDepthRatio = _depthRatio;
    }
}
