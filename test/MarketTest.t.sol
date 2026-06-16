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

    MockBusiness public merchantContract;

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
        merchantContract = new MockBusiness();

        // 2. 部署治理代币工厂
        buyerFactory = new SeatTokenFactory();
        sellerFactory = new SeatTokenFactory();

        // 3. 部署 ProportionalElection (使用代理模式)
        // --- 买方选举合约 ---
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

        // --- 卖方选举合约 ---
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

        // 4. 绑定工厂与选举合约代理地址
        buyerFactory.setElectionContract(address(buyerElection));
        sellerFactory.setElectionContract(address(sellerElection));

        // 5. 提前部署 TimelockController (用于 Market 初始化)
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
            address(timelock), // governance 设为 timelock
            vault
        );
        market = Market(
            address(new ERC1967Proxy(address(marketImpl), marketInitData))
        );

        // 7. 部署执行器并关联 Market
        executor = new TradeExecutor(address(market), address(usdc));
        market.setExecutor(address(executor));

        // 8. 授权权限
        buyerElection.setMinter(address(market));
        sellerElection.setMinter(address(market));

        // 9. 部署治理中心 FinalGovernor
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

        // 10. 权限移交 (Ownership Handover)
        market.transferOwnership(address(timelock));
        buyerElection.transferOwnership(address(timelock));
        sellerElection.transferOwnership(address(timelock));
        buyerFactory.transferOwnership(address(timelock));
        sellerFactory.transferOwnership(address(timelock));

        // 治理角色配置
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));

        // 彻底去中心化
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), admin);

        vm.stopPrank();

        // 11. 分发测试代币
        usdc.mint(alice, INITIAL_BALANCE);
        usdc.mint(bob, INITIAL_BALANCE);
        usdc.mint(charlie, INITIAL_BALANCE);
    }

    // --- 业务逻辑测试 ---

    function testMerchantRegistration() public {
        vm.startPrank(bob);
        uint256 depositAmount = 1000e6;
        usdc.approve(address(market), depositAmount);

        // 1. 适配新接口：现在的 registerMerchant 只有 1 个参数 (amount)
        market.registerMerchant(depositAmount);

        // 2. 适配新结构体解构：现在返回 5 个字段
        // (uint256 deposit, bool isActive, uint256 W, uint256 lev, uint256 vDepth)
        (
            uint256 deposit,
            bool isActive,
            uint256 withdrawnW,
            uint256 levFactor,
            uint256 vDepthRatio
        ) = market.merchants(bob);

        // 3. 断言验证
        assertEq(deposit, depositAmount, "Deposit mismatch");
        assertTrue(isActive, "Merchant should be active");
        assertEq(withdrawnW, 0, "Initial W should be 0");

        // 验证参数快照是否成功同步了全局默认值
        assertEq(
            levFactor,
            market.leverageFactor(),
            "Leverage snapshot mismatch"
        );
        assertEq(
            vDepthRatio,
            market.virtualDepthRatio(),
            "Virtual depth snapshot mismatch"
        );

        vm.stopPrank();
    }

    function testTradeAndPoints() public {
        // 1. 准备商家逻辑合约并入驻
        // 注意：现在交互目标就是商家地址，所以我们用 MockBusiness 实例作为商家
        uint256 depositAmount = 1000e6;
        usdc.mint(address(merchantContract), depositAmount);

        vm.startPrank(address(merchantContract));
        usdc.approve(address(market), depositAmount);
        market.registerMerchant(depositAmount);
        vm.stopPrank();

        // 2. 预计算 AMM 分配结果
        uint256 tradeAmount = 100e6;
        // 获取预期的 deltaW (给商家的钱) 和 deltaS (留存的积分/税)
        (uint256 expectedW, uint256 expectedS) = market.calculateAMM(
            address(merchantContract),
            tradeAmount
        );

        // ------------------ 差值测试开始 ------------------

        // 3. 记录交易前的各方余额
        uint256 marketBalBefore = usdc.balanceOf(address(market));
        uint256 merchantBalBefore = usdc.balanceOf(address(merchantContract));
        uint256 vaultBalBefore = usdc.balanceOf(vault);

        // 4. Alice 执行交易
        vm.startPrank(alice);
        usdc.approve(address(market), tradeAmount);

        // 构造 data：让 TradeExecutor 调用 merchantContract 的业务逻辑
        // 传入 expectedW，因为 MockBusiness 会尝试划扣这笔钱
        bytes memory data = abi.encodeWithSignature(
            "myBusinessLogic(address,uint256)",
            address(usdc),
            expectedW
        );

        market.trade(alice, address(merchantContract), tradeAmount, data);
        vm.stopPrank();

        // 5. 断言验证资金流向

        // 商家应该净增加 deltaW (AMM 计算结果)
        assertEq(
            usdc.balanceOf(address(merchantContract)) - merchantBalBefore,
            expectedW,
            "Merchant should gain exactly deltaW from AMM"
        );

        // 金库应该净增加 1% (固定权利税)
        assertEq(
            usdc.balanceOf(vault) - vaultBalBefore,
            tradeAmount / 100,
            "Vault should gain exactly 1%"
        );

        // 市场合约（税池）应该净增加 deltaS
        assertEq(
            usdc.balanceOf(address(market)) - marketBalBefore,
            expectedS,
            "Market tax pool should gain exactly deltaS"
        );

        // 6. 验证商家状态更新
        (, , uint256 wAfter, , ) = market.merchants(address(merchantContract));
        assertEq(wAfter, expectedW, "Merchant W should be updated by deltaW");

        // 7. 验证积分账本 (积分现在等于 deltaS)
        assertEq(
            market.buyerPoints(alice),
            expectedS,
            "Buyer should get deltaS points"
        );
        assertEq(
            market.sellerPoints(address(merchantContract)),
            expectedS,
            "Merchant should get deltaS points"
        );

        // ------------------ 差值测试结束 ------------------

        // 8. 治理权重验证（跳过 30 天缓冲期）
        vm.warp(block.timestamp + 31 days);
        assertEq(buyerElection.getVotes(alice), 100 * 1e18);
        assertEq(
            sellerElection.getVotes(address(merchantContract)),
            100 * 1e18
        );
    }

    function testTaxRefund() public {
        // 1. 商家入驻 (Alice 必须有押金才有退税配额，否则 getAvailableQuota 为 0)
        vm.startPrank(alice);
        uint256 aliceDeposit = 1000e6;
        usdc.approve(address(market), aliceDeposit);
        market.registerMerchant(aliceDeposit);
        vm.stopPrank();

        // 2. 产生积分 (为了让 Alice 有双向积分)
        // 先让 Bob 入驻，作为卖方
        vm.startPrank(bob);
        usdc.approve(address(market), 1000e6);
        market.registerMerchant(1000e6);
        vm.stopPrank();

        // A. Alice 买 Bob 的 (产生 Alice 的买方积分)
        vm.startPrank(alice);
        usdc.approve(address(market), 200e6);
        market.trade(alice, bob, 200e6, "");
        vm.stopPrank();

        // B. Bob 买 Alice 的 (产生 Alice 的卖方积分)
        vm.startPrank(bob);
        usdc.approve(address(market), 200e6);
        market.trade(bob, alice, 200e6, "");
        vm.stopPrank();

        // 3. 准备退税断言数据
        uint256 bP = market.buyerPoints(alice);
        uint256 sP = market.sellerPoints(alice);
        uint256 refundablePoints = bP < sP ? bP : sP;

        // 初始配额应为押金的 50%
        uint256 availableQuota = market.getAvailableQuota(alice);
        assertEq(
            availableQuota,
            (aliceDeposit * 5000) / 10000,
            "Initial quota mismatch"
        );

        // 实际退税额 = min(可对冲积分, 可用配额)
        uint256 expectedClaim = refundablePoints > availableQuota
            ? availableQuota
            : refundablePoints;
        assertTrue(
            expectedClaim > 0,
            "Expected claim should be greater than 0"
        );

        // 4. 执行退税
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market.claimTaxRefund(alice);
        uint256 balAfter = usdc.balanceOf(alice);

        // 5. 断言验证
        assertEq(
            balAfter - balBefore,
            expectedClaim,
            "USDC refund amount mismatch"
        );
        assertEq(
            market.claimed(alice),
            expectedClaim,
            "Claimed mapping update mismatch"
        );

        // 验证积分扣减
        assertEq(
            market.buyerPoints(alice),
            bP - expectedClaim,
            "Buyer points deduction mismatch"
        );
        assertEq(
            market.sellerPoints(alice),
            sP - expectedClaim,
            "Seller points deduction mismatch"
        );

        // 验证配额消耗
        assertEq(
            market.getAvailableQuota(alice),
            availableQuota - expectedClaim,
            "Quota consumption mismatch"
        );
    }

    function testDualConsensusVotingLogic() public {
        // 1. 产生投票权 (调用之前适配好的交易测试)
        // Alice 买 Bob 的东西，产生 Alice 的买方权利代币 和 Bob 的卖方权利代币
        testTradeAndPoints();

        // 2. 推进时间，确保选举合约的 30 天缓冲期过去，且 Checkpoints 生效
        vm.warp(block.timestamp + 31 days);
        vm.roll(block.number + 100);

        // 3. 模拟治理提案：修改市场合约的金库地址
        address[] memory targets = new address[](1);
        targets[0] = address(market);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature(
            "setVault(address)",
            address(0xdead)
        );

        // Alice (买方) 发起提案
        vm.prank(alice);
        uint256 proposalId = governor.propose(
            targets,
            values,
            calldatas,
            "Change Vault Address"
        );

        // 推进时间以跳过投票延迟 (Voting Delay, 通常为 7200 秒)
        vm.warp(block.timestamp + 7201);
        vm.roll(block.number + 7201);

        // 4. 情况 A：只有买方 (Alice) 投赞成票
        vm.prank(alice);
        governor.castVote(proposalId, 1); // 1 = For

        (uint256 againstVotes, uint256 forVotes, ) = governor.proposalVotes(
            proposalId
        );

        // 断言：由于卖方没投票，min(100, 0) = 0。有效赞成票应为 0。
        assertEq(forVotes, 0, "Consensus should be 0 when only buyer voted");

        // 5. 情况 B：卖方 (Bob) 也投赞成票
        vm.prank(address(merchantContract));
        governor.castVote(proposalId, 1);

        (, forVotes, ) = governor.proposalVotes(proposalId);

        // 断言：双方均投赞成票，min(100, 100) = 100。
        // 注意：100 * 1e18 是 ProportionalElection 归一化后的满分权重
        assertEq(
            forVotes,
            100 * 1e18,
            "Consensus should be 100 when both voted"
        );
    }

    /**
     * @notice 测试治理踢出商家逻辑
     * 验证：1. 只有治理地址能调用；2. 押金被没收至金库；3. 积分被转移至金库；4. 商家所有状态（含 W 和参数快照）清除。
     */
    function testGovernanceKick() public {
        // 1. 准备：Bob 入驻
        vm.startPrank(bob);
        uint256 bobDeposit = 1000e6;
        usdc.approve(address(market), bobDeposit);
        market.registerMerchant(bobDeposit);
        vm.stopPrank();

        // 2. 产生业务数据：Alice 买 Bob 的东西
        // 从而产生 Bob 的卖方积分和已提现金额 W
        vm.startPrank(alice);
        usdc.approve(address(market), 100e6);
        market.trade(alice, bob, 100e6, "");
        vm.stopPrank();

        // 记录没收前状态
        (, , uint256 wBefore, , ) = market.merchants(bob);
        uint256 bobPointsBefore = market.sellerPoints(bob);
        uint256 vaultPointsBefore = market.sellerPoints(vault);
        uint256 vaultBalBefore = usdc.balanceOf(vault);

        assertTrue(bobPointsBefore > 0, "Bob should have points before kick");
        assertTrue(wBefore > 0, "Bob should have accumulated W before kick");

        // 3. 权限校验：普通人无法踢出商家
        vm.startPrank(alice);
        vm.expectRevert("Only governance");
        market.kickMerchant(bob);
        vm.stopPrank();

        // 4. 执行：模拟治理 (Timelock) 调用 kickMerchant
        vm.prank(address(timelock));
        market.kickMerchant(bob);

        // 5. 验证商家结构体被彻底清除 (delete merchants[merchant])
        (
            uint256 deposit,
            bool isActive,
            uint256 W,
            uint256 lev,
            uint256 vDepth
        ) = market.merchants(bob);

        assertEq(deposit, 0, "Deposit should be cleared");
        assertFalse(isActive, "Merchant should be inactive");
        assertEq(W, 0, "Withdrawn W should be reset");
        assertEq(lev, 0, "Leverage snapshot should be cleared");
        assertEq(vDepth, 0, "Virtual depth snapshot should be cleared");

        // 6. 验证资产没收：押金进入金库 (Vault)
        assertEq(
            usdc.balanceOf(vault) - vaultBalBefore,
            bobDeposit,
            "Vault should receive bob's deposit"
        );

        // 7. 验证积分没收：积分被转移至金库 (Vault)
        assertEq(
            market.sellerPoints(bob),
            0,
            "Bob's seller points should be cleared"
        );
        assertEq(
            market.sellerPoints(vault) - vaultPointsBefore,
            bobPointsBefore,
            "Vault should receive Bob's seller points"
        );
    }
}
