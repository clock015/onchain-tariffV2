// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title 原子贸易核心市场接口
 * @notice 基于单币（USDC）的 AMM 关税积分闭环系统
 */
interface IMarket {
    struct Merchant {
        uint256 deposit; // 商家押金 (USDC)
        bool isActive; // 商家准入状态
        uint256 K; // AMM invariant
        uint256 leverageFactor; // 商家快照杠杆
        uint256 virtualDepthRatio; // 商家快照深度比例
    }

    // --- 状态查询 ---

    /**
     * @notice 查询商家信息
     */
    function merchants(
        address account
    )
        external
        view
        returns (
            uint256 deposit,
            bool isActive,
            uint256 K,
            uint256 leverageFactor,
            uint256 virtualDepthRatio
        );

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
     * @param rechargeTarget 商家定义的充值目标，可解析为地址、NFT id 或本地标识
     * @param amount 交易总额 (USDC)
     * @param data 商家定义的扩展数据
     * @dev 逻辑：
     * 1. msg.sender 支付 100% amount。
     * 2. 1% 固定权利税进入 vault。
     * 3. AMM 计算 deltaW 和 deltaS。
     * 4. deltaW 经 TradeExecutor 发给 merchant。
     * 5. 为 buyer 和 merchant 增加 deltaS 积分。
     * 6. 若 merchant 是合约，TradeExecutor 会回调 tradeIn。
     */
    function trade(
        address buyer,
        address merchant,
        uint160 rechargeTarget,
        uint256 amount,
        bytes calldata data
    ) external;

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
