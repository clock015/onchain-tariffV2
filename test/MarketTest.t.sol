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

// --- 必须增加：Mock 业务合约 ---
// 原因：TradeExecutor 只是 approve，必须有合约去 transferFrom 钱，否则 90% 的钱会卡在 Executor 里
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
    address public vault = address(0x999); // 专门的金库地址

    uint256 public constant INITIAL_BALANCE = 10000e6;

    function setUp() public {
        vm.startPrank(admin);

        // 1. 部署基础资产
        usdc = new MockUSDC();

        // 2. 部署治理代币工厂
        buyerFactory = new SeatTokenFactory();
        sellerFactory = new SeatTokenFactory();

        // 3. 部署 ProportionalElection (使用代理模式)
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

        // 5. 部署 Market (使用代理模式)
        Market marketImpl = new Market();
        bytes memory marketInitData = abi.encodeWithSelector(
            Market.initialize.selector,
            address(usdc),
            address(buyerElection),
            address(sellerElection),
            admin,
            vault
        );
        market = Market(
            address(new ERC1967Proxy(address(marketImpl), marketInitData))
        );

        // 6. 部署执行器
        executor = new TradeExecutor(address(market), address(usdc));
        market.setExecutor(address(executor));

        // 7. 授权 Market 权限
        buyerElection.setMinter(address(market));
        sellerElection.setMinter(address(market));

        // 8. 部署治理中心
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executorsGov = new address[](1);
        executorsGov[0] = address(0);

        timelock = new TimelockController(0, proposers, executorsGov, admin);

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

        // =============================================================
        // 9. 权限移交：将所有权从 admin 移交给 Timelock
        // =============================================================

        // 移交 Market 的 Owner 权限（控制 setVault, setExecutor 和 UUPS 升级）
        market.transferOwnership(address(timelock));

        // 移交选举聚合器的 Owner 权限（控制 setMinter 和 UUPS 升级）
        buyerElection.transferOwnership(address(timelock));
        sellerElection.transferOwnership(address(timelock));

        // 移交工厂的 Owner 权限（控制 setElectionContract）
        buyerFactory.transferOwnership(address(timelock));
        sellerFactory.transferOwnership(address(timelock));

        // 特别注意：Market 内部还有一个 governance 地址变量，用于 kickMerchant
        // 我们需要确保 Market 的 governance 变量也指向 Timelock（因为 Timelock 是提案执行者）
        // 如果你的 Market initialize 传的是 admin，这里可以通过测试手段验证或在 initialize 时改掉

        // 撤销 admin 在 Timelock 上的临时管理权限（生产环境建议）
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), admin);

        vm.stopPrank();

        usdc.mint(alice, INITIAL_BALANCE);
        usdc.mint(bob, INITIAL_BALANCE);
        usdc.mint(charlie, INITIAL_BALANCE);
    }

    // --- 业务逻辑测试 ---

    function testMerchantRegistration() public {
        vm.startPrank(bob);
        usdc.approve(address(market), 1000e6);
        market.registerMerchant(1000e6);

        (uint256 deposit, bool isActive) = market.merchants(bob);
        assertEq(deposit, 1000e6);
        assertTrue(isActive);
        vm.stopPrank();
    }

    function testTradeAndPoints() public {
        // 1. 准备商家逻辑合约并入驻
        MockBusiness merchantContract = new MockBusiness();
        usdc.mint(address(merchantContract), 1000e6);

        vm.startPrank(address(merchantContract));
        usdc.approve(address(market), 1000e6);
        market.registerMerchant(1000e6);
        vm.stopPrank();

        // ------------------ 差值测试开始 ------------------

        // 2. 记录交易前的各方余额
        uint256 marketBalBefore = usdc.balanceOf(address(market));
        uint256 merchantBalBefore = usdc.balanceOf(address(merchantContract));
        uint256 vaultBalBefore = usdc.balanceOf(vault);

        // 3. Alice 执行交易
        vm.startPrank(alice);
        uint256 tradeAmount = 100e6; // 交易总额 100 USDC
        usdc.approve(address(market), tradeAmount);

        bytes memory data = abi.encodeWithSignature(
            "myBusinessLogic(address,uint256)",
            address(usdc),
            90e6
        );

        market.trade(alice, address(merchantContract), tradeAmount, data);
        vm.stopPrank();

        // 4. 断言验证 (对比差值)

        // 商家应该净增加 90e6 (90%)
        assertEq(
            usdc.balanceOf(address(merchantContract)) - merchantBalBefore,
            90e6,
            "Merchant should gain exactly 90%"
        );

        // 金库应该净增加 1e6 (1%)
        assertEq(
            usdc.balanceOf(vault) - vaultBalBefore,
            1e6,
            "Vault should gain exactly 1%"
        );

        // 市场合约（税池）应该净增加 9e6 (9%)
        assertEq(
            usdc.balanceOf(address(market)) - marketBalBefore,
            9e6,
            "Market tax pool should gain exactly 9%"
        );

        // 执行器必须是空的（钱必须转出去或者转给商家了）
        assertEq(
            usdc.balanceOf(address(executor)),
            0,
            "Executor should not hold any funds"
        );

        // ------------------ 差值测试结束 ------------------

        // 5. 治理权重验证（跳过 30 天缓冲期）
        vm.warp(block.timestamp + 31 days);
        assertEq(buyerElection.getVotes(alice), 100 * 1e18);
        assertEq(
            sellerElection.getVotes(address(merchantContract)),
            100 * 1e18
        );
    }

    function testTaxRefund() public {
        // 先产生 Alice 的买方积分和 Bob 的卖方积分
        testTradeAndPoints();

        // 为了退税，Alice 需要作为卖家再赚 100e6 的交易（产生 9e6 卖方积分，实现对冲）
        vm.startPrank(alice);
        usdc.approve(address(market), 1000e6);
        market.registerMerchant(1000e6);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(market), 100e6);
        market.trade(bob, alice, 100e6, ""); // 不带 data，直接转账
        vm.stopPrank();

        // Alice 现在有 9e6 买方积分和 9e6 卖方积分
        uint256 balBefore = usdc.balanceOf(alice);
        market.claimTaxRefund(alice);
        uint256 balAfter = usdc.balanceOf(alice);

        assertEq(balAfter - balBefore, 9e6, "Refund should be exactly 9e6");
    }

    // --- 治理逻辑测试 ---

    function testDualConsensusVotingLogic() public {
        // 1. 商家入驻
        MockBusiness merchantContract = new MockBusiness();
        usdc.mint(address(merchantContract), 1000e6);
        vm.startPrank(address(merchantContract));
        usdc.approve(address(market), 1000e6);
        market.registerMerchant(1000e6);
        vm.stopPrank();

        // 2. Alice 交易 (产生买卖双方积分和治理代币)
        vm.startPrank(alice);
        usdc.approve(address(market), 100e6);
        bytes memory data = abi.encodeWithSignature(
            "myBusinessLogic(address,uint256)",
            address(usdc),
            90e6
        );
        market.trade(alice, address(merchantContract), 100e6, data);
        vm.stopPrank();

        // 3. 跳过 30 天缓冲期
        // 必须增加时间戳 (warp) 和 区块 (roll)
        vm.warp(block.timestamp + 31 days);
        vm.roll(block.number + 100);

        // 4. 验证权重 (验证前确认权重已生效)
        assertEq(buyerElection.getVotes(alice), 100 * 1e18);
        assertEq(
            sellerElection.getVotes(address(merchantContract)),
            100 * 1e18
        );

        // 5. 模拟治理提案
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

        // --- 关键修复：推进时间戳以度过 Voting Delay ---
        // 你的 votingDelay 是 7200 秒
        vm.warp(block.timestamp + 7201);
        vm.roll(block.number + 7201); // 同时推进区块是好习惯

        // 6. 投票测试 - 双重共识
        // 情况 A: 只有买方投赞成
        vm.prank(alice);
        governor.castVote(proposalId, 1);

        (uint256 againstVotes, uint256 forVotes, ) = governor.proposalVotes(
            proposalId
        );
        // 只有一方投，min(100, 0) = 0
        assertEq(forVotes, 0, "Consensus should be 0");

        // 情况 B: 卖方也投赞成
        vm.prank(address(merchantContract));
        governor.castVote(proposalId, 1);

        (, forVotes, ) = governor.proposalVotes(proposalId);
        // 双方都投，min(100, 100) = 100
        assertEq(forVotes, 100 * 1e18, "Consensus should be 100");
    }

    function testChallengeMerchant() public {
        testMerchantRegistration();

        vm.startPrank(charlie);
        usdc.approve(address(market), 1000e6);
        market.challengeMerchant(bob);

        (address challenger, uint256 stake, uint256 endTime) = market
            .challenges(bob);
        assertEq(challenger, charlie);
        assertEq(stake, 1000e6);
        assertGt(endTime, block.timestamp);
        vm.stopPrank();
    }
}
