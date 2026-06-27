// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IMerchantRechargeable.sol";

contract TradeExecutor {
    using SafeERC20 for IERC20;

    address public immutable market;
    IERC20 public immutable underlying;

    constructor(address _market, address _underlying) {
        market = _market;
        underlying = IERC20(_underlying);
    }

    function executeTrade(
        address target,
        uint160 rechargeTarget,
        uint256 amount,
        uint256 deltaW,
        bytes calldata data
    ) external {
        require(msg.sender == market, "Only market can call");
        require(target != market, "Cannot call back to own market");

        underlying.safeTransfer(target, deltaW);

        if (target.code.length > 0) {
            IMerchantRechargeable(target).rechargeFromTrade(
                rechargeTarget,
                amount,
                deltaW,
                data
            );
        }
    }
}
