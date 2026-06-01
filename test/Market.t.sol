// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./Mocks.sol"; // 包含上面的 Mock 合约
import {Market} from "../src/Market.sol";
import {TradeExecutor} from "../src/TradeExecutor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MarketTest is Test {
    Market market;
    TradeExecutor executor;
    MockUSDC usdc;
    MockRights mr;
    MockRights pr;

    address admin = address(0xAD);
    address gov = address(0x607); // Governance
    address vault = address(0xBB);
    address buyer = address(0x11);
    address merchant = address(0x22);
    address challenger = address(0x33);

    function setUp() public {
        vm.startPrank(admin);

        // 1. 部署逻辑合约与代理
        usdc = new MockUSDC();
        mr = new MockRights("Market Right", "MR");
        pr = new MockRights("Productivity Right", "PR");
        
        Market implementation = new Market();
        
        // 使用代理进行初始化
        bytes memory initData = abi.encodeWithSelector(
            Market.initialize.selector,
            address(usdc),
            address(mr),
            address(pr),
            gov,
            vault,
            address(0) // 暂时传 0，稍后 set
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        market = Market(address(proxy));

        // 2. 部署执行器并关联
        executor = new TradeExecutor(address(market), address(usdc));
        market.setExecutor(address(executor));

        // 3. 授权确权代币铸造权限给 Market
        mr.setMinter(address(market));
        pr.setMinter(address(market));

        vm.stopPrank();
    }

    // --- 1. 商家入驻测试 ---
    function test_RegisterMerchant() public {
        uint256 deposit = 1000 * 1e6; // 假设 1000 USDC
        usdc.mint(merchant, deposit);

        vm.startPrank(merchant);
        usdc.approve(address(market), deposit);
        market.registerMerchant(deposit);
        vm.stopPrank();

        (uint256 mDeposit, bool isActive) = market.merchants(merchant);
        assertEq(mDeposit, deposit);
        assertTrue(isActive);
    }

    // --- 2. 贸易分配测试 (10-9-1) ---
    function test_TradeEconomics() public {
        test_RegisterMerchant(); // 先入驻

        uint256 tradeAmount = 100 * 1e6;
        usdc.mint(buyer, tradeAmount);

        vm.startPrank(buyer);
        usdc.approve(address(market), tradeAmount);
        market.trade(buyer, merchant, tradeAmount, "");
        vm.stopPrank();

        // 校验分配
        // 1. 商家应收 90% = 90
        assertEq(usdc.balanceOf(merchant), 90 * 1e6);
        // 2. 金库应收 1% = 1
        assertEq(usdc.balanceOf(vault), 1 * 1e6);
        // 3. 合约留存 9% = 9
        assertEq(usdc.balanceOf(address(market)), 1000 * 1e6 + 9 * 1e6); // 初始押金1000 + 9税
        
        // 校验积分与权利 (100的9%是9，1%是1)
        assertEq(market.buyerPoints(buyer), 9 * 1e6);
        assertEq(market.sellerPoints(merchant), 9 * 1e6);
        assertEq(mr.balanceOf(buyer), 1 * 1e6);
        assertEq(pr.balanceOf(merchant), 1 * 1e6);
    }

    // --- 3. 退税测试 (产消者对冲) ---
    function test_TaxRefund() public {
        test_TradeEconomics(); // buyer 买了 100 块，现在有 9 买方积分

        // 现在让 buyer 变成卖家，赚取卖方积分
        // 商家买 buyer 的货
        uint256 tradeAmount = 100 * 1e6;
        usdc.mint(merchant, tradeAmount);
        
        vm.startPrank(merchant);
        usdc.approve(address(market), tradeAmount);
        // 为了让 buyer 获得卖方积分，这里 merchant 是 payer，buyer 是 merchant
        // 需要先注册 buyer 为商家
        vm.stopPrank();
        
        vm.startPrank(buyer);
        usdc.mint(buyer, 1000 * 1e6);
        usdc.approve(address(market), 1000 * 1e6);
        market.registerMerchant(1000 * 1e6);
        vm.stopPrank();

        vm.prank(merchant);
        market.trade(merchant, buyer, tradeAmount, "");

        // 此时 buyer 既有 9 买方积分，也有 9 卖方积分
        assertEq(market.buyerPoints(buyer), 9 * 1e6);
        assertEq(market.sellerPoints(buyer), 9 * 1e6);

        uint256 balanceBefore = usdc.balanceOf(buyer);
        market.claimTaxRefund(buyer);
        uint256 balanceAfter = usdc.balanceOf(buyer);

        assertEq(balanceAfter - balanceBefore, 9 * 1e6);
        assertEq(market.buyerPoints(buyer), 0);
    }

    // --- 4. 挑战与成功踢出测试 ---
    function test_ChallengeAndKick() public {
        test_RegisterMerchant(); // 商家押金 1000

        uint256 stake = 1000 * 1e6;
        usdc.mint(challenger, stake);

        vm.startPrank(challenger);
        usdc.approve(address(market), stake);
        market.challengeMerchant(merchant);
        vm.stopPrank();

        // 治理踢出
        vm.prank(gov);
        market.kickMerchant(merchant);

        // 校验：商家状态重置，押金入库，挑战者拿回钱
        (uint256 mDeposit, bool isActive) = market.merchants(merchant);
        assertEq(mDeposit, 0);
        assertFalse(isActive);
        assertEq(usdc.balanceOf(vault), 1000 * 1e6); // 商家押金入库
        assertEq(usdc.balanceOf(challenger), 1000 * 1e6); // 挑战者拿回保证金
    }

    // --- 5. 挑战失败与自动结算测试 ---
    function test_ChallengeAndSettle() public {
        test_RegisterMerchant();

        uint256 stake = 1000 * 1e6;
        usdc.mint(challenger, stake);

        vm.startPrank(challenger);
        usdc.approve(address(market), stake);
        market.challengeMerchant(merchant);
        vm.stopPrank();

        // 时间流逝 8 天 (超过 7 天挑战期)
        vm.warp(block.timestamp + 8 days);

        // 任何人调用结算（这里由商家自己调用）
        market.settleChallenge(merchant);

        // 校验：商家依然 isActive，挑战者钱被没收
        (uint256 mDeposit, bool isActive) = market.merchants(merchant);
        assertEq(mDeposit, 1000 * 1e6);
        assertTrue(isActive);
        assertEq(usdc.balanceOf(vault), 1000 * 1e6); // 挑战者保证金入库
        assertEq(usdc.balanceOf(challenger), 0);
    }

    // --- 6. 权限与重入安全测试 ---
    function test_Security_ExecutorIsolation() public {
        // 尝试让 executor 调用 trade
        vm.prank(address(executor));
        vm.expectRevert("Executor cannot trigger trade");
        market.trade(buyer, merchant, 100, "");
    }
}