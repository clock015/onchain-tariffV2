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

/**
 * @title 原子贸易核心 Market 合约 (AMM 动态关税版)
 * @notice 采用 (10D - W)(S + 0.9D) = K 公式实现路径无关的动态关税系统。
 * @dev 移除了挑战逻辑，由治理模块 (Governor) 直接管理商家违规踢出。
 */
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
        bool isActive; // 是否激活
        address interactionTarget; // 交互地址
        uint256 K; // K: 恒定乘积系数
    }

    mapping(address => Merchant) public merchants;
    mapping(address => uint256) public buyerPoints;
    mapping(address => uint256) public sellerPoints;
    mapping(address => uint256) public claimed; // 记录累计退税金额

    address public executor;

    mapping(address => uint256) public lastClaimTime;
    mapping(address => uint256) public lastAvailableQuota;

    uint256 public QUOTA_PERIOD;
    uint256 public quotaRatio; // 配额比例 (10000/10000 * deposit)

    // --- 权限与检查 ---
    modifier notFromExecutor() {
        require(msg.sender != executor, "Executor cannot trigger trade");
        _;
    }

    // --- 事件 ---
    event MerchantRegistered(
        address indexed merchant,
        address indexed interactionTarget,
        uint256 deposit,
        uint256 K
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

    /// @custom:oz-upgrades-unsafe-allow constructor
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
        quotaRatio = 10000; // 默认配额比例为 100%
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    // --- 核心数学逻辑 ---

    /**
     * @dev 获取当前顺差积分 S (SellerPoints - BuyerPoints)
     */
    function _getSurplus(address account) internal view returns (uint256) {
        uint256 sP = sellerPoints[account];
        uint256 bP = buyerPoints[account];
        return sP > bP ? sP - bP : 0;
    }

    /**
     * @notice 计算 AMM 分配
     * 公式: (R - deltaW)(Y + deltaS) = K, 其中 deltaW + deltaS = P
     * 解得: deltaS^2 + (R + Y - P)deltaS - PY = 0
     */
    function calculateAMM(
        address merchant,
        uint256 amount
    ) public view returns (uint256 deltaW, uint256 deltaS) {
        Merchant storage m = merchants[merchant];
        uint256 S = _getSurplus(merchant);
        uint256 D = m.deposit;

        // Y = S + 0.9D 虚拟积分深度
        uint256 Y = S + ((D * 9) / 10);
        // R = K / Y 虚拟现金余额
        uint256 R = m.K / Y;
        // P = 0.99 * amount (1% 固定权利税后的分配池)
        uint256 P = (amount * 99) / 100;

        // 二次方程系数 b = R + Y - P
        int256 b = int256(R) + int256(Y) - int256(P);
        uint256 c = P * Y;

        // discriminant = b^2 + 4PY
        uint256 discriminant = uint256(b * b) + (4 * c);
        uint256 root = FixedPointMathLib.sqrt(discriminant);

        // 根据求根公式求得 deltaS (积分增量/动态关税)
        if (b >= 0) {
            deltaS = (root - uint256(b)) / 2;
        } else {
            deltaS = (root + uint256(-b)) / 2;
        }

        if (deltaS > P) deltaS = P;
        deltaW = P - deltaS;
    }

    // --- 核心业务 ---

    /**
     * @notice 商家缴纳押金入驻或追加押金
     * @param interactionTarget 交互地址，注册后不可更改。
     */
    function registerMerchant(
        uint256 amount,
        address interactionTarget
    ) external {
        require(amount > 0, "Deposit required");
        require(interactionTarget != address(0), "Invalid interactionTarget");

        Merchant storage m = merchants[msg.sender];
        uint256 S = _getSurplus(msg.sender);

        if (m.isActive) {
            require(
                m.interactionTarget == interactionTarget,
                "Interaction target mismatch"
            );

            // 重新计算 K 以保持已收现 W 的连续性
            uint256 Y_old = S + ((m.deposit * 9) / 10);
            uint256 currentW = (10 * m.deposit) - (m.K / Y_old);

            m.deposit += amount;

            uint256 Y_new = S + ((m.deposit * 9) / 10);
            m.K = (10 * m.deposit - currentW) * Y_new;
        } else {
            m.isActive = true;
            m.interactionTarget = interactionTarget;
            m.deposit = amount;
            // 初始 K = (10D - 0) * (S + 0.9D)
            m.K = (10 * amount) * (S + ((amount * 9) / 10));
        }

        underlying.safeTransferFrom(msg.sender, address(this), amount);
        emit MerchantRegistered(msg.sender, interactionTarget, m.deposit, m.K);
    }

    /**
     * @notice 核心交易函数
     * @param buyer 接受买方积分与权利代币的地址
     * @param merchant 商家地址
     * @param amount 交易总额
     * @param data 业务指令数据
     */
    function trade(
        address buyer,
        address merchant,
        uint256 amount,
        bytes calldata data
    ) external nonReentrant notFromExecutor {
        Merchant storage m = merchants[merchant];
        require(m.isActive, "Merchant not active");

        // 1. 根据 AMM 公式计算现金分配与动态关税
        (uint256 deltaW, uint256 deltaS) = calculateAMM(merchant, amount);

        // 2. 资金归集与 1% 固定权利税
        uint256 vaultFee = amount / 100;
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        underlying.safeTransfer(vault, vaultFee);

        // 3. 积分账本更新 (deltaS 为本次交易的关税额，也是顺差积分增量)
        buyerPoints[buyer] += deltaS;
        sellerPoints[merchant] += deltaS;

        // 4. 权利代币铸造 (基于 1% 固定税)
        buyerRights.mint(buyer, vaultFee);
        sellerRights.mint(merchant, vaultFee);

        // 5. 拨付现金至执行器并触发后续逻辑
        underlying.safeTransfer(executor, deltaW);
        ITradeExecutor(executor).executeTrade(
            m.interactionTarget,
            deltaW,
            data
        );

        emit Traded(msg.sender, buyer, merchant, amount, deltaW, deltaS);
    }

    /**
     * @notice 积分对冲退税
     * @dev 积分减少会降低 S，在 K 不变的情况下，自动增加商家的虚拟现金提取额度 R。
     */
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
        require(availableQuota > 0, "Quota exhausted, wait for recovery");

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

        if (lastClaimTime[account] == 0) {
            return maxQuota;
        }

        uint256 timePassed = block.timestamp - lastClaimTime[account];

        if (timePassed >= QUOTA_PERIOD) {
            return maxQuota;
        }

        uint256 recovered = (maxQuota * timePassed) / QUOTA_PERIOD;
        uint256 total = lastAvailableQuota[account] + recovered;

        return total > maxQuota ? maxQuota : total;
    }

    // --- 权限管理与治理 ---

    /**
     * @notice 治理踢出（由治理模块直接调用）
     * @dev 没收商家所有押金进入金库。
     */
    function kickMerchant(address merchant) external nonReentrant {
        require(msg.sender == governance, "Only governance");
        Merchant storage m = merchants[merchant];
        require(m.isActive, "Merchant not active");

        uint256 slashedAmount = m.deposit;

        // --- 修改点 3：精准没收该商家的积分 ---
        uint256 bP = buyerPoints[merchant];
        uint256 sP = sellerPoints[merchant];

        if (bP > 0) {
            buyerPoints[merchant] = 0;
            buyerPoints[vault] += bP; // 没收至金库
        }
        if (sP > 0) {
            sellerPoints[merchant] = 0;
            sellerPoints[vault] += sP; // 没收至金库
        }

        // 清理商家状态
        m.isActive = false;
        m.deposit = 0;
        m.K = 0;

        // 没收押金入库
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
}
