// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TradeExecutor {
    using SafeERC20 for IERC20;

    address public immutable market;
    IERC20 public immutable underlying;

    constructor(address _market, address _underlying) {
        market = _market;
        underlying = IERC20(_underlying);
    }

    /**
     * @notice 执行贸易逻辑转发
     * @param target 目标商家（可以是另一个 Market 或业务合约）
     * @param rechargeTarget 充值目标
     * @param amount 转发的金额 (90% 部分)
     * @param data 业务指令
     */
    function executeTrade(
        address target,
		uint160 rechargeTarget,
        uint256 amount,
		uint256 deltaW,
        bytes calldata data
    ) external {
        require(msg.sender == market, "Only market can call");
        require(target != market, "Cannot call back to own market");

        if (data.length > 0) {
            // 核心逻辑：既然有 data，默认 target 会通过 transferFrom 拿钱
            // 直接授权给 target 足够的额度
            underlying.forceApprove(target, deltaW);

            // 执行目标调用
            (bool success, ) = target.call(data);
            require(success, "Execution failed");

            // 归零授权（安全习惯，防止额度残留）
            underlying.forceApprove(target, 0);
        } else {
            // 没有指令，直接转账
            underlying.safeTransfer(target, deltaW);
        }
    }
}
