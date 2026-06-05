// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/Market.sol";
import "../src/RightsToken/ProportionalElection.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Interactor is Script {
    // 从环境变量加载地址
    Market market = Market(vm.envAddress("MARKET_PROXY"));
    IERC20 usdc = IERC20(vm.envAddress("USDC_ADDRESS"));
    ProportionalElection buyerElection = ProportionalElection(vm.envAddress("BUYER_ELECTION"));
    ProportionalElection sellerElection = ProportionalElection(vm.envAddress("SELLER_ELECTION"));

    uint256 pk = vm.envUint("PRIVATE_KEY");

    // --- 模块 1: 商家注册 ---
    function registerAsMerchant(uint256 amount, address beneficiary) external {
        vm.startBroadcast(pk);
        usdc.approve(address(market), amount);
        market.registerMerchant(amount, beneficiary);
        vm.stopBroadcast();
        console.log("Merchant registered with deposit:", amount);
    }

    // --- 模块 2: 执行贸易 ---
    function doTrade(address buyer, address merchant, uint256 amount, bytes memory data) external {
        vm.startBroadcast(pk);
        usdc.approve(address(market), amount);
        market.trade(buyer, merchant, amount, data);
        vm.stopBroadcast();
        console.log("Trade executed for amount:", amount);
    }

    // --- 模块 3: 积分对冲退税 ---
    function claimRefund(address account) external {
        vm.startBroadcast(pk);
        market.claimTaxRefund(account);
        vm.stopBroadcast();
        console.log("Tax refund claimed for:", account);
    }

    // --- 模块 4: 查询状态 (只读，不需要 Broadcast) ---
    function checkStatus(address account) external view {
        uint256 bP = market.buyerPoints(account);
        uint256 sP = market.sellerPoints(account);
        uint256 bVotes = buyerElection.getVotes(account);
        uint256 sVotes = sellerElection.getVotes(account);

        console.log("=== Status for:", account, "===");
        console.log("Buyer Points: ", bP);
        console.log("Seller Points:", sP);
        console.log("Buyer Votes (Normalized): ", bVotes / 1e18);
        console.log("Seller Votes (Normalized):", sVotes / 1e18);
    }
}