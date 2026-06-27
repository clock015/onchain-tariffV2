// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITradeExecutor {
    function executeTrade(
        address target,
        uint160 rechargeTarget,
        uint256 amount,
        uint256 deltaW,
        bytes calldata data
    ) external;
}