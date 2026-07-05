// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMarket {
    struct Merchant {
        uint256 deposit;
        bool isActive;
        uint256 K;
        uint256 leverageFactor;
        uint256 virtualDepthRatio;
    }

    function settlementAsset() external view returns (address);

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

    function buyerPoints(address account) external view returns (uint256);

    function sellerPoints(address account) external view returns (uint256);

    function registerMerchant(uint256 amount) external;

    function trade(
        address buyer,
        address merchant,
        uint160 rechargeTarget,
        uint256 amount,
        bytes calldata data
    ) external;

    function claimTaxRefund(address account) external;

    function kickMerchant(address merchant) external;
}