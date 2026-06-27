// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ITradeExecutor
 * @notice 原子贸易执行器标准接口
 */
interface ITradeExecutor {
    /**
     * @notice 执行逻辑转发与资金授权
     * @param target 目标商家地址或另一个 Market 地址
     * @param amount 扣税后的金额
     * @param data 业务指令数据
     */
    function executeTrade(
        address target,
        uint256 amount,
		uint256 deltaW,
        bytes calldata data
    ) external;
}
