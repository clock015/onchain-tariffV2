// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// 导入你的合约
import "../src/Market.sol";
import "../src/TradeExecutor.sol";
import "../src/RightsToken/ProportionalElection.sol";
import "../src/RightsToken/SeatTokenFactory.sol";
import "../src/Governor/FinalGovernor.sol";

// 导入依赖
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// --- Mock 业务合约 ---
contract MockBusiness {
    function myBusinessLogic(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }
}

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract MarketTest is Test {
    Market public market;
    TradeExecutor public executor;
    MockUSDC public usdc;

    SeatTokenFactory public buyerFactory;
    SeatTokenFactory public sellerFactory;
    ProportionalElection public buyerElection;
    ProportionalElection public sellerElection;

    FinalGovernor public governor;
    TimelockController public timelock;

    address public admin = address(0x1);
    address public alice = address(0x2);
    address public bob = address(0x3);
    address public charlie = address(0x4);
    address public vault = address(0x999);

    uint256 public constant INITIAL_BALANCE = 10000e6;

    function setUp() public {
        vm.startPrank(admin);

        // 1. 部署基础资产
        usdc = new MockUSDC();

        // 2. 部署治理代币工厂
        buyerFactory = new SeatTokenFactory();
        sellerFactory = new SeatTokenFactory();

        // 3. 部署 ProportionalElection 代理
        ProportionalElection buyerElectionImpl = new ProportionalElection();
        bytes memory buyerElectionInit = abi.encodeWithSelector(
            ProportionalElection.initialize.selector,
            address(buyerFactory),
            admin
        );
        buyerElection = ProportionalElection(
            address(
                new ERC1967Proxy(address(buyerElectionImpl), buyerElectionInit)
            )
        );

        ProportionalElection sellerElectionImpl = new ProportionalElection();
        bytes memory sellerElectionInit = abi.encodeWithSelector(
            ProportionalElection.initialize.selector,
            address(sellerFactory),
            admin
        );
        sellerElection = ProportionalElection(
            address(
                new ERC1967Proxy(
                    address(sellerElectionImpl),
                    sellerElectionInit
                )
            )
        );

        // 4. 绑定工厂
        buyerFactory.setElectionContract(address(buyerElection));
        sellerFactory.setElectionContract(address(sellerElection));

        // 5. 部署 Timelock
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executorsGov = new address[](1);
        executorsGov[0] = address(0);
        timelock = new TimelockController(0, proposers, executorsGov, admin);

        // 6. 部署 Market (使用代理模式)
        Market marketImpl = new Market();
        bytes memory marketInitData = abi.encodeWithSelector(
            Market.initialize.selector,
            address(usdc),
            address(buyerElection),
            address(sellerElection),
            address(timelock),
            vault
        );
        market = Market(
            address(new ERC1967Proxy(address(marketImpl), marketInitData))
        );

        // 7. 部署执行器
        executor = new TradeExecutor(address(market), address(usdc));
        market.setExecutor(address(executor));

        // 8. 授权权限
        buyerElection.setMinter(address(market));
        sellerElection.setMinter(address(market));

        // 9. 部署治理合约 FinalGovernor
        FinalGovernor governorImpl = new FinalGovernor();
        bytes memory govInitData = abi.encodeWithSelector(
            FinalGovernor.initialize.selector,
            IVotes(address(buyerElection)),
            IVotes(address(sellerElection)),
            timelock
        );
        governor = FinalGovernor(
            payable(
                address(new ERC1967Proxy(address(governorImpl), govInitData))
            )
        );

        // 10. 权限移交
        market.transferOwnership(address(timelock));
        buyerElection.transferOwnership(address(timelock));
        sellerElection.transferOwnership(address(timelock));
        buyerFactory.transferOwnership(address(timelock));
        sellerFactory.transferOwnership(address(timelock));
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), admin);

        vm.stopPrank();

        usdc.mint(alice, INITIAL_BALANCE);
        usdc.mint(bob, INITIAL_BALANCE);
        usdc.mint(charlie, INITIAL_BALANCE);
    }

    // --- 业务逻辑测试 ---

    function testMerchantRegistration() public {
        vm.startPrank(bob);
        uint256 depositAmount = 1000e6;
        usdc.approve(address(market), depositAmount);

        // 1. 调用新版 registerMerchant
        market.registerMerchant(depositAmount, bob);

        // 2. 获取 Merchant 结构体信息 (按照你指定的最新顺序)
        (
            uint256 deposit,
            bool isActive,
            address interactionTarget,
            uint256 W,
            uint256 lev,
            uint256 vDepth
        ) = market.merchants(bob);

        // 3. 断言验证基础字段
        assertEq(deposit, depositAmount, "Deposit mismatch");
        assertTrue(isActive, "Merchant should be active");
        assertEq(interactionTarget, bob, "Target mismatch");

        // 4. 验证 W 和 参数快照
        // 初始入驻时，已提现金额 W 必须为 0
        assertEq(W, 0, "Initial W should be 0");

        // 验证商家是否正确快照了全局参数
        assertEq(lev, market.leverageFactor(), "Leverage snapshot mismatch");
        assertEq(
            vDepth,
            market.virtualDepthRatio(),
            "Virtual depth snapshot mismatch"
        );

        vm.stopPrank();
    }

    function testTradeAndPoints() public {
        // 1. 准备商家逻辑合约（作为交互目标）
        MockBusiness merchantContract = new MockBusiness();
        uint256 merchantDeposit = 1000e6; // 商家押金 D

        vm.startPrank(bob);
        usdc.approve(address(market), merchantDeposit);
        // Bob 作为商家入驻
        market.registerMerchant(merchantDeposit, address(merchantContract));
        vm.stopPrank();

        // 2. 预计算 AMM 分配结果
        uint256 tradeAmount = 100e6;
        // calculateAMM 内部现在会根据商家快照的 W, leverageFactor, virtualDepthRatio 来计算
        (uint256 expectedW, uint256 expectedS) = market.calculateAMM(
            bob,
            tradeAmount
        );
        uint256 expectedVaultFee = tradeAmount / 100; // 1% 固定权利税

        // 记录交易前状态
        uint256 marketBalBefore = usdc.balanceOf(address(market));
        uint256 bizBalBefore = usdc.balanceOf(address(merchantContract));
        uint256 vaultBalBefore = usdc.balanceOf(vault);

        // 3. Alice 执行交易
        vm.startPrank(alice);
        usdc.approve(address(market), tradeAmount);

        // 业务指令数据：告诉 MockBusiness 转移 deltaW 金额的代币
        bytes memory data = abi.encodeWithSignature(
            "myBusinessLogic(address,uint256)",
            address(usdc),
            expectedW
        );

        market.trade(alice, bob, tradeAmount, data);
        vm.stopPrank();

        // 4. 断言验证资金流向
        assertEq(
            usdc.balanceOf(vault) - vaultBalBefore,
            expectedVaultFee,
            "Vault should receive 1% fixed fee"
        );
        assertEq(
            usdc.balanceOf(address(merchantContract)) - bizBalBefore,
            expectedW,
            "Biz logic should receive deltaW"
        );
        assertEq(
            usdc.balanceOf(address(market)) - marketBalBefore,
            expectedS,
            "Market contract should retain deltaS"
        );

        // 5. 验证商家结构体中的 W 更新
        (
            , // deposit
            , // isActive
            , // interactionTarget
            uint256 wAfter,
            , // lev

        ) = market.merchants(bob); // vDepth
        assertEq(wAfter, expectedW, "Merchant W should increase by expectedW");

        // 6. 验证积分账本更新 (逻辑未变)
        assertEq(
            market.buyerPoints(alice),
            expectedS,
            "Buyer Alice should get deltaS points"
        );
        assertEq(
            market.sellerPoints(bob),
            expectedS,
            "Merchant Bob should get deltaS points"
        );

        // 7. 权利代币与投票权验证 (逻辑未变)
        vm.warp(block.timestamp + 31 days);
        vm.roll(block.number + 100);

        assertTrue(
            buyerElection.getVotes(alice) > 0,
            "Alice should have votes"
        );
        assertTrue(sellerElection.getVotes(bob) > 0, "Bob should have votes");
    }

    function testTaxRefund() public {
        // 1. 让 Alice 成为商家 (为了获得卖方积分并拥有退税配额)
        vm.startPrank(alice);
        usdc.approve(address(market), 1000e6);
        market.registerMerchant(1000e6, alice); // 适配新版参数：金额 + 交互目标
        vm.stopPrank();

        // 2. 让 Bob 成为商家 (为了让 Alice 能买他的东西获得买方积分)
        vm.startPrank(bob);
        usdc.approve(address(market), 1000e6);
        market.registerMerchant(1000e6, bob);
        vm.stopPrank();

        // 3. 产生 Alice 的卖方积分 (Bob 买 Alice 的)
        // 注意：这里传入空 data 因为 MockBusiness 并不是必须的，除非你想验证复杂的执行逻辑
        vm.startPrank(bob);
        usdc.approve(address(market), 200e6);
        market.trade(bob, alice, 200e6, "");
        vm.stopPrank();

        // 4. 产生 Alice 的买方积分 (Alice 买 Bob 的)
        vm.startPrank(alice);
        usdc.approve(address(market), 200e6);
        market.trade(alice, bob, 200e6, "");
        vm.stopPrank();

        // 5. 记录 Alice 当前积分状态并计算可退额度
        uint256 bP = market.buyerPoints(alice);
        uint256 sP = market.sellerPoints(alice);
        // 对冲退税额 = min(买方积分, 卖方积分)
        uint256 expectedRefund = bP < sP ? bP : sP;
        assertTrue(expectedRefund > 0, "Should have points to refund");

        // 6. 验证退税配额 (初始化后默认为 100% 押金 = 1000e6)
        uint256 initialQuota = market.getAvailableQuota(alice);
        assertEq(initialQuota, 500e6, "Quota should be 50% of deposit");

        // 7. 执行退税
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market.claimTaxRefund(alice);
        uint256 balAfter = usdc.balanceOf(alice);

        // 8. 断言验证
        assertEq(
            balAfter - balBefore,
            expectedRefund,
            "Alice should receive the refund amount"
        );
        assertEq(
            market.claimed(alice),
            expectedRefund,
            "Claimed mapping should be updated"
        );

        // 9. 验证积分扣减
        assertEq(
            market.buyerPoints(alice),
            bP - expectedRefund,
            "Buyer points not deducted"
        );
        assertEq(
            market.sellerPoints(alice),
            sP - expectedRefund,
            "Seller points not deducted"
        );

        // 10. 验证配额消耗
        assertEq(
            market.getAvailableQuota(alice),
            initialQuota - expectedRefund,
            "Quota not consumed"
        );
    }

    function testDualConsensusVotingLogic() public {
        // 1. 调用已经适配新版 Market 的交易测试，产生 Alice 和 Bob 的权利代币
        testTradeAndPoints();

        // 2. 推进时间，确保 IVotes 的快照（Snapshot）生效
        vm.warp(block.timestamp + 31 days);
        vm.roll(block.number + 100);

        // 3. 模拟治理提案：修改金库地址
        address[] memory targets = new address[](1);
        targets[0] = address(market);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature(
            "setVault(address)",
            address(0xdead)
        );

        vm.prank(alice);
        uint256 proposalId = governor.propose(
            targets,
            values,
            calldatas,
            "Test Proposal"
        );

        // 推进到投票期
        vm.warp(block.timestamp + 7201);
        vm.roll(block.number + 7201);

        // 4. Alice (买方) 投赞成票
        vm.prank(alice);
        governor.castVote(proposalId, 1);

        // 验证：在双重共识逻辑下，只有买方投票，共识得分应为 0
        (uint256 againstVotes, uint256 forVotes, ) = governor.proposalVotes(
            proposalId
        );
        assertEq(forVotes, 0, "Consensus should be 0 when only buyer voted");

        // 5. Bob (商家/卖方) 也投赞成票
        vm.prank(bob);
        governor.castVote(proposalId, 1);

        // 验证：双方均投赞成票后，共识达成
        // 注意：100 * 1e18 是 FinalGovernor 内部约定的满分值，与具体代币数量无关
        (, forVotes, ) = governor.proposalVotes(proposalId);
        assertEq(
            forVotes,
            100 * 1e18,
            "Consensus 100 expected when both sides voted"
        );
    }

    /**
     * @notice 测试治理踢出商家逻辑
     * 验证：1. 只有治理地址能调用；2. 押金被没收至金库；3. 积分被转移至金库；4. 商家所有状态（含 W 和参数快照）清除。
     */
    function testGovernanceKick() public {
        // 1. 准备：Bob 入驻
        vm.startPrank(bob);
        usdc.approve(address(market), 1000e6);
        market.registerMerchant(1000e6, bob);
        vm.stopPrank();

        // 2. 产生业务数据：Alice 买 Bob 的东西
        // 这会产生：Bob 的卖方积分，以及 Bob 的已提现金额 W
        vm.startPrank(alice);
        usdc.approve(address(market), 100e6);
        market.trade(alice, bob, 100e6, "");
        vm.stopPrank();

        (, , , uint256 bobWBefore, , ) = market.merchants(bob);
        uint256 bobPointsBefore = market.sellerPoints(bob);
        uint256 vaultPointsBefore = market.sellerPoints(vault);
        uint256 vaultBalBefore = usdc.balanceOf(vault);

        assertTrue(bobPointsBefore > 0, "Bob should have points");
        assertTrue(bobWBefore > 0, "Bob should have accumulated W");

        // 3. 执行：模拟治理（timelock）调用 kickMerchant
        vm.prank(address(timelock));
        market.kickMerchant(bob);

        // 4. 验证商家结构体状态彻底清除
        (
            uint256 deposit,
            bool isActive,
            address target,
            uint256 W,
            uint256 lev,
            uint256 vDepth
        ) = market.merchants(bob);

        assertEq(deposit, 0, "Deposit should be cleared");
        assertFalse(isActive, "Merchant should be inactive");
        assertEq(
            target,
            address(0),
            "Target should be reset (if contract clears it)"
        ); // 视合约实现而定，通常建议重置
        assertEq(W, 0, "W should be reset");
        assertEq(lev, 0, "Leverage snapshot should be cleared");
        assertEq(vDepth, 0, "Virtual depth snapshot should be cleared");

        // 5. 验证资产没收 (押金进入金库)
        assertEq(
            usdc.balanceOf(vault) - vaultBalBefore,
            1000e6,
            "Vault should receive slashed deposit"
        );

        // 6. 验证积分没收 (积分转移至金库)
        assertEq(market.sellerPoints(bob), 0, "Bob's points should be cleared");
        assertEq(
            market.sellerPoints(vault) - vaultPointsBefore,
            bobPointsBefore,
            "Vault should receive Bob's points"
        );
    }
}
