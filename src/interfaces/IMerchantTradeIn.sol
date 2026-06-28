// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IMerchantTradeIn
 * @notice Merchant-side entry called by the trusted trade executor after an onMarket trade settles.
 */
interface IMerchantTradeIn {
    /**
     * @notice Route the settled trade result back into a merchant-defined target.
     * @param rechargeTarget Merchant-defined target. Implementations may decode it as an address, NFT id, or another local identifier.
     * @param netAmount Trade amount after the 1% rights-token fee is removed.
     * @param deltaW Immediate underlying amount made available to the merchant by the market AMM.
     * @param data Merchant-defined extension payload. Implementations may ignore it.
     */
    function tradeIn(
        uint160 rechargeTarget,
        uint256 netAmount,
        uint256 deltaW,
        bytes calldata data
    ) external;
}
