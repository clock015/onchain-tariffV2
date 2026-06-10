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
        usdc.approve(address(market), 1000e6);
        // 新逻辑：第二个参数是 interactionTarget
        market.registerMerchant(1000e6, bob);

        // 注意：Merchant 结构体现已包含 interactionTarget 字段
        (uint256 deposit, bool isActive, address interactionTarget) = market
            .merchants(bob);
        assertEq(deposit, 1000e6);
        assertTrue(isActive);
        assertEq(interactionTarget, bob);
        vm.stopPrank();
    }

    function testTradeAndPoints() public {
        // 1. 准备商家逻辑合约（作为交互目标）
        MockBusiness merchantContract = new MockBusiness();
        usdc.mint(bob, 1000e6);

        vm.startPrank(bob);
        usdc.approve(address(market), 1000e6);
        // Bob 作为商家入驻，他的业务逻辑由 merchantContract 处理
        market.registerMerchant(1000e6, address(merchantContract));
        vm.stopPrank();

        // 记录交易前状态
        uint256 marketBalBefore = usdc.balanceOf(address(market));
        uint256 bizBalBefore = usdc.balanceOf(address(merchantContract));
        uint256 vaultBalBefore = usdc.balanceOf(vault);

        // 2. Alice 执行交易
        vm.startPrank(alice);
        uint256 tradeAmount = 100e6;
        usdc.approve(address(market), tradeAmount);

        bytes memory data = abi.encodeWithSignature(
            "myBusinessLogic(address,uint256)",
            address(usdc),
            90e6
        );

        // 交易目标是 bob (merchant)
        market.trade(alice, bob, tradeAmount, data);
        vm.stopPrank();

        // 3. 断言验证
        // 90% 的钱进入了交互目标地址 (merchantContract)
        assertEq(
            usdc.balanceOf(address(merchantContract)) - bizBalBefore,
            90e6,
            "Biz logic should receive 90%"
        );
        assertEq(
            usdc.balanceOf(vault) - vaultBalBefore,
            1e6,
            "Vault should gain 1%"
        );
        assertEq(
            usdc.balanceOf(address(market)) - marketBalBefore,
            9e6,
            "Tax pool should gain 9%"
        );
        assertEq(usdc.balanceOf(address(executor)), 0);

        // 4. 积分与投票权验证 (留在商家 bob 身上)
        assertEq(
            market.sellerPoints(bob),
            9e6,
            "Merchant Bob should get points"
        );

        vm.warp(block.timestamp + 31 days);
        assertEq(buyerElection.getVotes(alice), 100 * 1e18);
        assertEq(
            sellerElection.getVotes(bob),
            100 * 1e18,
            "Merchant Bob should have votes"
        );
    }

    function testTaxRefund() public {
        testTradeAndPoints();

        // Alice (原买家) 现在入驻成为商家以赚取卖方积分
        vm.startPrank(alice);
        usdc.approve(address(market), 1000e6);
        market.registerMerchant(1000e6, alice);
        vm.stopPrank();

        // Bob 购买 Alice 的服务
        vm.startPrank(bob);
        usdc.approve(address(market), 100e6);
        market.trade(bob, alice, 100e6, "");
        vm.stopPrank();

        // Alice 现在有买方积分和卖方积分，申请退税
        uint256 balBefore = usdc.balanceOf(alice);
        market.claimTaxRefund(alice);
        uint256 balAfter = usdc.balanceOf(alice);

        assertEq(balAfter - balBefore, 9e6, "Alice receives refund directly");
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
