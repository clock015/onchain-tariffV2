// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMarket {
    struct MarketAccount {
        address owner;
        address merchant;
        uint256 deposit;
        uint256 capacityMultiplier;
        bool isActive;
    }

    function settlementAsset() external view returns (address);

    function accounts(uint256 accountId)
        external
        view
        returns (address owner, address merchant, uint256 deposit, uint256 capacityMultiplier, bool isActive);

    function accountIdOf(address owner, address merchant) external view returns (uint256);

    function sellerPoints(uint256 accountId) external view returns (uint256);

    function netTradeBalance(uint256 accountId) external view returns (int256);

    function registerMerchant(address merchant, uint256 amount, uint256 capacityMultiplier)
        external
        returns (uint256 accountId);

    function addDeposit(uint256 accountId, uint256 amount) external;

    function setCapacityMultiplier(uint256 accountId, uint256 newMultiplier) external;

    function trade(
        address buyer,
        uint256 buyerAccountId,
        uint256 sellerAccountId,
        uint160 rechargeTarget,
        uint256 amount,
        bytes calldata data
    ) external;

    function kickMerchant(uint256 accountId) external;
}
