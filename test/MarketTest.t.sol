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

        // 1. 调用新版 registerMerchant: 传入金额和交互目标地址
        market.registerMerchant(depositAmount, bob);

        // 2. 获取 Merchant 结构体信息
        // 注意：返回值顺序必须对应合约中的字段：deposit, isActive, interactionTarget, K
        (
            uint256 deposit,
            bool isActive,
            address interactionTarget,
            uint256 K
        ) = market.merchants(bob);

        // 3. 断言验证基础字段
        assertEq(deposit, depositAmount, "Deposit mismatch");
        assertTrue(isActive, "Merchant should be active");
        assertEq(interactionTarget, bob, "Target mismatch");

        // 4. 验证初始 K 值计算逻辑
        // 根据合约代码：m.K = (10 * amount) * (S + (amount * 9 / 10))
        // 初始入驻时，bob 的积分 S = 0，所以 K = (10 * 1000e6) * (900e6)
        uint256 expectedK = (10 * depositAmount) * ((depositAmount * 9) / 10);
        assertEq(K, expectedK, "Initial K calculation mismatch");

        vm.stopPrank();
    }

    function testTradeAndPoints() public {
        // 1. 准备商家逻辑合约（作为交互目标）
        MockBusiness merchantContract = new MockBusiness();
        uint256 merchantDeposit = 1000e6; // 商家押金 D

        vm.startPrank(bob);
        usdc.approve(address(market), merchantDeposit);
        // Bob 作为商家入驻，指定业务合约为交互目标
        market.registerMerchant(merchantDeposit, address(merchantContract));
        vm.stopPrank();

        // 2. 预计算 AMM 分配结果
        uint256 tradeAmount = 100e6;
        // 直接从合约读取预期的 deltaW (现金) 和 deltaS (关税/积分)
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

        // 交易目标是 bob
        market.trade(alice, bob, tradeAmount, data);
        vm.stopPrank();

        // 4. 断言验证资金流向
        // 验证 1% 进入了金库
        assertEq(
            usdc.balanceOf(vault) - vaultBalBefore,
            expectedVaultFee,
            "Vault should receive 1% fixed fee"
        );
        // 验证计算出的现金 W 经过执行器最终进入了商家业务合约
        assertEq(
            usdc.balanceOf(address(merchantContract)) - bizBalBefore,
            expectedW,
            "Biz logic should receive deltaW"
        );
        // 验证关税部分 deltaS 留在了 Market 合约内（积分对应的准备金）
        assertEq(
            usdc.balanceOf(address(market)) - marketBalBefore,
            expectedS,
            "Market contract should retain deltaS"
        );
        // 执行器余额应归零
        assertEq(
            usdc.balanceOf(address(executor)),
            0,
            "Executor should have no balance"
        );

        // 5. 验证积分账本更新
        // 买家积分增加 deltaS
        assertEq(
            market.buyerPoints(alice),
            expectedS,
            "Buyer Alice should get deltaS points"
        );
        // 商家卖方积分增加 deltaS
        assertEq(
            market.sellerPoints(bob),
            expectedS,
            "Merchant Bob should get deltaS points"
        );

        // 6. 权利代币与投票权验证
        // 推进时间以确保 IVotes 快照生效
        vm.warp(block.timestamp + 31 days);
        vm.roll(block.number + 100);

        // 验证 Alice 和 Bob 是否获得了基于 1% 税金铸造的权利
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
        market.registerMerchant(1000e6, alice);
        vm.stopPrank();

        // 2. 让 Bob 成为商家 (为了让 Alice 能买他的东西获得买方积分)
        vm.startPrank(bob);
        usdc.approve(address(market), 1000e6);
        market.registerMerchant(1000e6, bob);
        vm.stopPrank();

        // 3. 产生 Alice 的卖方积分 (Bob 买 Alice 的)
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
        assertEq(initialQuota, 1000e6, "Quota should be 100% of deposit");

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
        testTradeAndPoints();
        vm.warp(block.timestamp + 31 days);
        vm.roll(block.number + 100);

        // 模拟治理提案
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

        vm.warp(block.timestamp + 7201);
        vm.roll(block.number + 7201);

        // Alice (买方) 投赞成
        vm.prank(alice);
        governor.castVote(proposalId, 1);

        (uint256 againstVotes, uint256 forVotes, ) = governor.proposalVotes(
            proposalId
        );
        assertEq(forVotes, 0, "Consensus 0 (only buyer voted)");

        // Bob (商家/卖方) 投赞成
        vm.prank(bob);
        governor.castVote(proposalId, 1);

        (, forVotes, ) = governor.proposalVotes(proposalId);
        assertEq(forVotes, 100 * 1e18, "Consensus 100 (both voted)");
    }

    /**
     * @notice 测试治理踢出商家逻辑
     * 验证：1. 只有治理地址能调用；2. 押金被没收至金库；3. 积分被转移至金库；4. 商家状态清除。
     */
    function testGovernanceKick() public {
        // 1. 准备：Bob 入驻并产生一些积分
        vm.startPrank(bob);
        usdc.approve(address(market), 1000e6);
        market.registerMerchant(1000e6, bob);
        vm.stopPrank();

        // Alice 买 Bob 的东西，让 Bob 产生卖方积分
        vm.startPrank(alice);
        usdc.approve(address(market), 100e6);
        market.trade(alice, bob, 100e6, "");
        vm.stopPrank();

        uint256 bobPointsBefore = market.sellerPoints(bob);
        uint256 vaultPointsBefore = market.sellerPoints(vault);
        uint256 vaultBalBefore = usdc.balanceOf(vault);
        assertTrue(bobPointsBefore > 0, "Bob should have points");

        // 2. 执行：模拟治理（timelock）调用 kickMerchant
        // 注意：initialize 时我们将 governance 设置为了 timelock
        vm.prank(address(timelock));
        market.kickMerchant(bob);

        // 3. 验证状态清除
        (uint256 deposit, bool isActive, address target, uint256 K) = market
            .merchants(bob);
        assertEq(deposit, 0, "Deposit should be cleared");
        assertFalse(isActive, "Merchant should be inactive");
        assertEq(K, 0, "K should be reset");

        // 4. 验证资产没收 (押金进入金库)
        assertEq(
            usdc.balanceOf(vault) - vaultBalBefore,
            1000e6,
            "Vault should receive slashed deposit"
        );

        // 5. 验证积分没收 (根据新代码修改点 3：积分转移至金库)
        assertEq(market.sellerPoints(bob), 0, "Bob's points should be cleared");
        assertEq(
            market.sellerPoints(vault) - vaultPointsBefore,
            bobPointsBefore,
            "Vault should receive Bob's points"
        );
    }
}
