// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.20;

// import "forge-std/Script.sol";
// import "forge-std/console.sol";
// import "../src/Market.sol";
// import "../src/RightsToken/ProportionalElection.sol";
// import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// interface IMintableERC20 is IERC20 {
//     function mint(address to, uint256 amount) external;
// }

// contract Interactor is Script {
//     Market public market = Market(vm.envAddress("MARKET_ADDRESS"));
//     IMintableERC20 public usdc = IMintableERC20(vm.envAddress("USDC_ADDRESS"));
//     ProportionalElection public buyerElection =
//         ProportionalElection(vm.envAddress("BUYER_ELECTION_ADDRESS"));
//     ProportionalElection public sellerElection =
//         ProportionalElection(vm.envAddress("SELLER_ELECTION_ADDRESS"));

//     uint256 public pk = vm.envUint("PRIVATE_KEY");
//     uint256 public pk2 = vm.envUint("PRIVATE_KEY2");
//     uint256 public pk3 = vm.envUint("PRIVATE_KEY3");

//     uint256 public constant DEFAULT_DEPOSIT = 1_000e6;
//     uint256 public constant DEFAULT_TRADE_AMOUNT = 100e6;
//     uint256 public constant PK2_TO_PK3_TRADE_AMOUNT = DEFAULT_TRADE_AMOUNT / 2;
//     uint256 public constant DEFAULT_TEST_MINT = 10_000e6;

//     function fundTestAccounts() external {
//         _fundTestAccounts(DEFAULT_TEST_MINT);
//     }

//     function registerAsMerchant(uint256 amount) external {
//         _registerAsMerchant(pk, amount);
//     }

//     function registerPk2AsMerchant() external {
//         _registerAsMerchant(pk2, DEFAULT_DEPOSIT);
//     }

//     function registerPk3AsMerchant() external {
//         _registerAsMerchant(pk3, DEFAULT_DEPOSIT);
//     }

//     function doTrade(
//         address buyer,
//         address merchant,
//         uint256 amount,
//         bytes memory data
//     ) external {
//         _doTrade(pk, buyer, merchant, amount, data);
//     }

//     function pkTradePk2() external {
//         address pkAddress = vm.addr(pk);
//         address pk2Address = vm.addr(pk2);
//         _doTrade(pk, pkAddress, pk2Address, DEFAULT_TRADE_AMOUNT, bytes(""));
//     }

//     function pk2TradePk3() external {
//         address pk2Address = vm.addr(pk2);
//         address pk3Address = vm.addr(pk3);
//         _doTrade(
//             pk2,
//             pk2Address,
//             pk3Address,
//             PK2_TO_PK3_TRADE_AMOUNT,
//             bytes("")
//         );
//     }

//     function claimRefund(address account) external {
//         _claimRefund(pk, account);
//     }

//     function pk2ClaimRefund() external {
//         _claimRefund(pk2, vm.addr(pk2));
//     }

//     function runPkFlow() external {
//         address pkAddress = vm.addr(pk);
//         address pk2Address = vm.addr(pk2);
//         address pk3Address = vm.addr(pk3);

//         console.log("PK1:", pkAddress);
//         console.log("PK2:", pk2Address);
//         console.log("PK3:", pk3Address);

//         _fundTestAccounts(DEFAULT_TEST_MINT);
//         _registerAsMerchant(pk2, DEFAULT_DEPOSIT);
//         _registerAsMerchant(pk3, DEFAULT_DEPOSIT);
//         _doTrade(pk, pkAddress, pk2Address, DEFAULT_TRADE_AMOUNT, bytes(""));
//         _doTrade(
//             pk2,
//             pk2Address,
//             pk3Address,
//             PK2_TO_PK3_TRADE_AMOUNT,
//             bytes("")
//         );
//         _claimRefund(pk2, pk2Address);
//         _fastForwardForVotes();

//         _logStatus(pkAddress);
//         _logStatus(pk2Address);
//         _logStatus(pk3Address);
//     }

//     function checkStatus(address account) external view {
//         _logStatus(account);
//     }

//     function _fundTestAccounts(uint256 amount) internal {
//         address pkAddress = vm.addr(pk);
//         address pk2Address = vm.addr(pk2);
//         address pk3Address = vm.addr(pk3);

//         vm.startBroadcast(pk);
//         usdc.mint(pkAddress, amount);
//         usdc.mint(pk2Address, amount);
//         usdc.mint(pk3Address, amount);
//         vm.stopBroadcast();

//         console.log("Minted test USDC to PK1:", amount);
//         console.log("Minted test USDC to PK2:", amount);
//         console.log("Minted test USDC to PK3:", amount);
//     }

//     function _registerAsMerchant(uint256 signerPk, uint256 amount) internal {
//         address merchant = vm.addr(signerPk);

//         vm.startBroadcast(signerPk);
//         usdc.approve(address(market), amount);
//         market.registerMerchant(amount);
//         vm.stopBroadcast();

//         console.log("Merchant registered:", merchant);
//         console.log("Deposit:", amount);
//     }

//     function _doTrade(
//         uint256 signerPk,
//         address buyer,
//         address merchant,
//         uint256 amount,
//         bytes memory data
//     ) internal {
//         address payer = vm.addr(signerPk);

//         vm.startBroadcast(signerPk);
//         usdc.approve(address(market), amount);
//         market.trade(buyer, merchant, amount, data);
//         vm.stopBroadcast();

//         console.log("Trade payer:", payer);
//         console.log("Trade buyer:", buyer);
//         console.log("Trade merchant:", merchant);
//         console.log("Trade amount:", amount);
//     }

//     function _claimRefund(uint256 signerPk, address account) internal {
//         vm.startBroadcast(signerPk);
//         market.claimTaxRefund(account);
//         vm.stopBroadcast();

//         console.log("Tax refund claimed for:", account);
//     }

//     function _fastForwardForVotes() internal {
//         vm.warp(block.timestamp + 40 days);
//         vm.roll(block.number + 1);
//         console.log("Fast forwarded days: 40");
//     }

//     function _logStatus(address account) internal view {
//         uint256 sP = market.sellerPoints(account);
//         uint256 bVotes = buyerElection.getVotes(account);
//         uint256 sVotes = sellerElection.getVotes(account);

//         console.log("=== Status ===");
//         console.log("Account:", account);
//         console.log("Seller Points:", sP);
//         console.log("Buyer Votes (Normalized):", bVotes / 1e18);
//         console.log("Seller Votes (Normalized):", sVotes / 1e18);
//     }
// }

// // forge script script/Interact.s.sol:Interactor --sig "runPkFlow()" --rpc-url http://127.0.0.1:8545 --broadcast --gas-limit 50000000 -vv
// // forge script script/Interact.s.sol:Interactor --sig "registerPk2AsMerchant()" --rpc-url http://127.0.0.1:8545 --broadcast -vv
// // forge script script/Interact.s.sol:Interactor --sig "pkTradePk2()" --rpc-url http://127.0.0.1:8545 --broadcast -vv
