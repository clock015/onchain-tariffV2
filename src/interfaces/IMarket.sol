// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title 原子贸易核心市场接口
 * @notice 基于单币（USDC）的 10%-9%-1% 积分闭环系统
 */
interface IMarket {
    struct Merchant {
        uint256 deposit; // 商家押金 (USDC)
        bool isActive; // 商家准入状态
    }

    // --- 状态查询 ---

    /**
     * @notice 查询商家信息
     */
    function merchants(
        address account
    ) external view returns (uint256 deposit, bool isActive);

    /**
     * @notice 查询指定账户积攒的买方积分
     */
    function buyerPoints(address account) external view returns (uint256);

    /**
     * @notice 查询指定账户积攒的卖方积分
     */
    function sellerPoints(address account) external view returns (uint256);

    // --- 核心业务功能 ---

    /**
     * @notice 商家缴纳押金入驻
     * @param amount 缴纳的 USDC 数量
     * @dev msg.sender 支付押金并成为商家
     */
    function registerMerchant(uint256 amount) external;

    /**
     * @notice 核心交易函数
     * @param buyer 接受买方积分和权利 Token 的地址
     * @param merchant 卖家地址（接受货款、卖方积分和权利 Token）
     * @param amount 交易总额 (USDC)
     * @dev 逻辑：
     * 1. msg.sender 支付 100% amount。
     * 2. merchant 收到 90% amount。
     * 3. 市场合约留存 10% amount 入税池。
     * 4. 为 buyer 增加 9% amount 的买方积分。
     * 5. 为 merchant 增加 9% amount 的卖方积分。
     * 6. 为 buyer 和 merchant 各铸造 1% amount 的权利 Token。
     */
    function trade(address buyer, address merchant, uint256 amount) external;

    /**
     * @notice 积分对冲退税
     * @param account 申请退税的地址
     * @dev 自动计算该地址买卖积分的交集（最小值），销毁积分并从税池退还等量 USDC
     */
    function claimTaxRefund(address account) external;

    // --- 治理权限接口 ---

    /**
     * @notice 驱逐商家（由治理模块调用）
     * @param merchant 被驱逐的商家地址
     */
    function kickMerchant(address merchant) external;
}
