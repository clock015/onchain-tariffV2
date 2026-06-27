// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IMerchantRechargeable
 * @notice Standard merchant-side recharge entry called by the trusted trade executor.
 */
interface IMerchantRechargeable {
    /**
     * @notice Recharge a merchant-defined target from a market trade.
     * @param rechargeTarget Merchant-defined target. Implementations may decode it as an address, NFT id, or another local identifier.
     * @param amount Gross trade amount paid by the buyer.
     * @param deltaW Immediate underlying amount made available to the merchant by the market AMM.
     * @param data Merchant-defined extension payload. Implementations may ignore it.
     */
    function rechargeFromTrade(
        uint160 rechargeTarget,
        uint256 amount,
        uint256 deltaW,
        bytes calldata data
    ) external;
}