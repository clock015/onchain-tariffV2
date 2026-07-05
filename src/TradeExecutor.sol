// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IMerchantTradeIn.sol";
import "./interfaces/ISettlementAsset.sol";

contract TradeExecutor {
    address public immutable market;
    ISettlementAsset public immutable settlementAsset;

    constructor(address _market, address _settlementAsset) {
        market = _market;
        settlementAsset = ISettlementAsset(_settlementAsset);
    }

    function underlying() external view returns (IERC20) {
        return IERC20(settlementAsset.asset());
    }

    function executeTrade(
        address target,
        uint160 rechargeTarget,
        uint256 netAmount,
        uint256 deltaW,
        bytes calldata data
    ) external {
        require(msg.sender == market, "Only market can call");
        require(target != market, "Cannot call back to own market");

        settlementAsset.push(target, deltaW);

        if (target.code.length > 0) {
            IMerchantTradeIn(target).tradeIn(
                rechargeTarget,
                netAmount,
                deltaW,
                data
            );
        }
    }
}
