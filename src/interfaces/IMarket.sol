// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMarket {
    struct Merchant {
        uint256 deposit;
        bool isActive;
    }

    function settlementAsset() external view returns (address);

    function merchants(
        address account
    ) external view returns (uint256 deposit, bool isActive);

    function sellerPoints(address account) external view returns (uint256);

    function netTradeBalance(address account) external view returns (int256);

    function registerMerchant(uint256 amount) external;

    function trade(
        address buyer,
        address merchant,
        uint160 rechargeTarget,
        uint256 amount,
        bytes calldata data
    ) external;

    function kickMerchant(address merchant) external;
}