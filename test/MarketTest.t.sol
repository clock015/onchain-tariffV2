// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// 导入你的合约
import "../src/Market.sol";
import "../src/TradeExecutor.sol";
import "../src/settlement/ERC20SettlementAsset.sol";
import "../src/interfaces/IMerchantTradeIn.sol";
import "../src/RightsToken/ProportionalElection.sol";
import "../src/RightsToken/SeatTokenFactory.sol";
import "../src/RightsToken/GenesisSeatToken.sol";
import "../src/Governor/FinalGovernor.sol";

// 导入依赖
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// --- Mock 业务合约 ---
contract MockBusiness is IMerchantTradeIn {
    uint160 public lastRechargeTarget;
    uint256 public lastAmount;
    uint256 public lastDeltaW;
    bytes32 public lastDataHash;

    function tradeIn(
        uint160 rechargeTarget,
        uint256 netAmount,
        uint256 deltaW,
        bytes calldata data
    ) external override {
        lastRechargeTarget = rechargeTarget;
        lastAmount = netAmount;
        lastDeltaW = deltaW;
        lastDataHash = keccak256(data);
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
    ERC20SettlementAsset public settlementAsset;

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
        vm.warp(365 days + 30 days);
        vm.startPrank(admin);

        usdc = new MockUSDC();
        ERC20SettlementAsset settlementImpl = new ERC20SettlementAsset();
        bytes memory settlementInitData = abi.encodeWithSelector(
            ERC20SettlementAsset.initialize.selector,
            address(usdc),
            admin
        );
        settlementAsset = ERC20SettlementAsset(
            address(
                new ERC1967Proxy(address(settlementImpl), settlementInitData)
            )
        );
        merchantContract = new MockBusiness();

        buyerFactory = new SeatTokenFactory();
        sellerFactory = new SeatTokenFactory();

        GenesisSeatToken buyerGenesisSeat = new GenesisSeatToken(
            "Council Seat 0",
            "CS",
            admin
        );
        GenesisSeatToken sellerGenesisSeat = new GenesisSeatToken(
            "Council Seat 0",
            "CS",
            admin
        );
        buyerGenesisSeat.mint(admin, 100 * 1e18);
        sellerGenesisSeat.mint(admin, 100 * 1e18);

        ProportionalElection buyerElectionImpl = new ProportionalElection();
        bytes memory buyerElectionInit = abi.encodeWithSelector(
            ProportionalElection.initialize.selector,
            address(buyerFactory),
            admin,
            address(buyerGenesisSeat)
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
            admin,
            address(sellerGenesisSeat)
        );
        sellerElection = ProportionalElection(
            address(
                new ERC1967Proxy(
                    address(sellerElectionImpl),
                    sellerElectionInit
                )
            )
        );

        buyerGenesisSeat.setMinter(address(buyerElection));
        sellerGenesisSeat.setMinter(address(sellerElection));

        assertEq(buyerElection.currentRoundId(), 1, "Buyer election should start at round 1");
        assertEq(sellerElection.currentRoundId(), 1, "Seller election should start at round 1");
        assertEq(buyerElection.getVotes(admin), 100 * 1e18, "Genesis buyer votes mismatch");
        assertEq(sellerElection.getVotes(admin), 100 * 1e18, "Genesis seller votes mismatch");

        buyerFactory.setElectionContract(address(buyerElection));
        sellerFactory.setElectionContract(address(sellerElection));

        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executorsGov = new address[](1);
        executorsGov[0] = address(0);
        timelock = new TimelockController(0, proposers, executorsGov, admin);

        Market marketImpl = new Market();
        bytes memory marketInitData = abi.encodeWithSelector(
            Market.initialize.selector,
            address(settlementAsset),
            address(buyerElection),
            address(sellerElection),
            address(timelock),
            vault
        );
        market = Market(
            address(new ERC1967Proxy(address(marketImpl), marketInitData))
        );

        executor = new TradeExecutor(address(market), address(settlementAsset));
        market.setExecutor(address(executor));
        settlementAsset.setController(address(market), true);
        settlementAsset.setController(address(executor), true);

        buyerElection.setMinter(address(market));
        sellerElection.setMinter(address(market));

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

        market.transferOwnership(address(timelock));
        settlementAsset.transferOwnership(address(timelock));
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

    function testMerchantRegistration() public {
        vm.startPrank(bob);
        uint256 depositAmount = 1000e6;
        usdc.approve(address(settlementAsset), depositAmount);
        market.registerMerchant(depositAmount);

        (uint256 deposit, bool isActive) = market.merchants(bob);

        assertEq(deposit, depositAmount, "Deposit mismatch");
        assertTrue(isActive, "Merchant should be active");
        assertEq(market.netTradeBalance(bob), 0, "Initial net balance mismatch");

        vm.stopPrank();
    }

    function testTradeAndPoints() public {
        // 1. 准备商家逻辑合约并入驻
        // 注意：现在交互目标就是商家地址，所以我们用 MockBusiness 实例作为商家
        uint256 depositAmount = 1000e6;
        usdc.mint(address(merchantContract), depositAmount);

        vm.startPrank(address(merchantContract));
        usdc.approve(address(settlementAsset), depositAmount);
        market.registerMerchant(depositAmount);
        vm.stopPrank();

        // 2. 预计算 AMM 分配结果
        uint256 tradeAmount = 100e6;
        // 获取预期的 deltaW (给商家的钱) 和 deltaS (留存的积分/税)
        (uint256 expectedW, uint256 expectedS) = market.calculateAMM(
            address(merchantContract),
            tradeAmount
        );
        uint256 vaultFee = tradeAmount / 100;
        uint256 tradeValue = tradeAmount - vaultFee;
        (uint256 merchantDeposit, ) = market.merchants(address(merchantContract));
        uint256 capacity = merchantDeposit * market.capacityMultiplier();
        uint256 oldP = 0;
        uint256 newP = tradeValue;
        uint256 oldCurveTax = market.curveTax(oldP, merchantDeposit);
        uint256 newCurveTax = market.curveTax(newP, merchantDeposit);
        uint256 pOverCapacityBps = (newP * 10000) / capacity;
        uint256 baseTaxPart = (tradeValue * market.baseTaxRate()) / 10000;
        uint256 curveExtraTaxPart = expectedS - baseTaxPart;
        uint256 effectiveTaxRateBps = (expectedS * 10000) / tradeValue;

        console.log("=== AMM Tax Debug ===");
        console.log("amount", tradeAmount);
        console.log("vaultFee", vaultFee);
        console.log("tradeValue", tradeValue);
        console.log("deposit", merchantDeposit);
        console.log("capacity", capacity);
        console.log("baseTaxRate", market.baseTaxRate());
        console.log("capacityMultiplier", market.capacityMultiplier());
        console.log("curveExponent", market.curveExponent());
        console.log("oldP", oldP);
        console.log("newP", newP);
        console.log("pOverCapacityBps", pOverCapacityBps);
        console.log("oldCurveTax", oldCurveTax);
        console.log("newCurveTax", newCurveTax);
        console.log("baseTaxPart", baseTaxPart);
        console.log("curveExtraTaxPart", curveExtraTaxPart);
        console.log("deltaS", expectedS);
        console.log("deltaW", expectedW);
        console.log("effectiveTaxRateBps", effectiveTaxRateBps);

        // ------------------ 差值测试开始 ------------------

        // 3. 记录交易前的各方余额
        uint256 marketBalBefore = usdc.balanceOf(address(settlementAsset));
        uint256 merchantBalBefore = usdc.balanceOf(address(merchantContract));
        uint256 vaultBalBefore = usdc.balanceOf(vault);

        // 4. Alice 执行交易
        vm.startPrank(alice);
        usdc.approve(address(settlementAsset), tradeAmount);

        uint160 rechargeTarget = uint160(alice);
        uint256 expectedNetAmount = tradeAmount - (tradeAmount / 100);
        bytes memory data = abi.encode("test recharge payload");

        market.trade(
            alice,
            address(merchantContract),
            rechargeTarget,
            tradeAmount,
            data
        );
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
            usdc.balanceOf(address(settlementAsset)) - marketBalBefore,
            expectedS,
            "Market tax pool should gain exactly deltaS"
        );

        // 6. 验证充值回调参数
        assertEq(
            merchantContract.lastRechargeTarget(),
            rechargeTarget,
            "Recharge target mismatch"
        );
        assertEq(
            merchantContract.lastAmount(),
            expectedNetAmount,
            "Recharge net amount mismatch"
        );
        assertEq(
            merchantContract.lastDeltaW(),
            expectedW,
            "Recharge deltaW mismatch"
        );
        assertEq(
            merchantContract.lastDataHash(),
            keccak256(data),
            "Recharge data mismatch"
        );

        // 7. 验证卖方已收税账本
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


    function testGlobalAMMParamsAffectNextTrade() public {
        uint256 depositAmount = 1000e6;
        uint256 tradeAmount = 100e6;

        vm.startPrank(bob);
        usdc.approve(address(settlementAsset), depositAmount);
        market.registerMerchant(depositAmount);
        vm.stopPrank();

        (uint256 oldExpectedW, uint256 oldExpectedS) = market.calculateAMM(
            bob,
            tradeAmount
        );

        uint256 newBaseTaxRate = 1800;
        uint256 newCapacityMultiplier = 5;
        uint256 newCurveExponent = 2;
        vm.prank(address(timelock));
        market.setGlobalAMMParams(
            newBaseTaxRate,
            newCapacityMultiplier,
            newCurveExponent
        );

        assertEq(
            market.baseTaxRate(),
            newBaseTaxRate,
            "Global base tax mismatch"
        );
        assertEq(
            market.capacityMultiplier(),
            newCapacityMultiplier,
            "Global capacity mismatch"
        );
        assertEq(
            market.curveExponent(),
            newCurveExponent,
            "Global exponent mismatch"
        );

        vm.startPrank(charlie);
        usdc.approve(address(settlementAsset), depositAmount);
        market.registerMerchant(depositAmount);
        vm.stopPrank();

        (uint256 newExpectedW, uint256 newExpectedS) = market.calculateAMM(
            charlie,
            tradeAmount
        );

        assertTrue(
            oldExpectedW != newExpectedW || oldExpectedS != newExpectedS,
            "AMM params should change tariff calculation"
        );

        uint256 bobBalanceBefore = usdc.balanceOf(bob);
        uint256 sellerPointsBefore = market.sellerPoints(bob);

        vm.startPrank(alice);
        usdc.approve(address(settlementAsset), tradeAmount);
        market.trade(alice, bob, uint160(alice), tradeAmount, "");
        vm.stopPrank();

        assertEq(
            usdc.balanceOf(bob) - bobBalanceBefore,
            newExpectedW,
            "Trade should use synced deltaW"
        );
        assertEq(
            market.sellerPoints(bob) - sellerPointsBefore,
            newExpectedS,
            "Trade should use synced deltaS"
        );
    }

    function testTradeAutoRefundsOwnSellerPoints() public {
        uint256 depositAmount = 1000e6;
        uint256 tradeAmount = 100e6;
        uint256 secondTradeAmount = 200e6;

        vm.startPrank(alice);
        usdc.approve(address(settlementAsset), depositAmount);
        market.registerMerchant(depositAmount);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(settlementAsset), depositAmount);
        market.registerMerchant(depositAmount);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(settlementAsset), tradeAmount);
        market.trade(bob, alice, uint160(bob), tradeAmount, "");
        vm.stopPrank();

        uint256 sellerPointsBefore = market.sellerPoints(alice);
        uint256 quotaBefore = market.getAvailableQuota(alice);
        (, uint256 expectedS) = market.calculateAMM(bob, secondTradeAmount);

        uint256 expectedAutoRefund = sellerPointsBefore < expectedS
            ? sellerPointsBefore
            : expectedS;
        if (expectedAutoRefund > quotaBefore) expectedAutoRefund = quotaBefore;

        uint256 balanceBefore = usdc.balanceOf(alice);
        vm.startPrank(alice);
        usdc.approve(address(settlementAsset), secondTradeAmount);
        market.trade(alice, bob, uint160(alice), secondTradeAmount, "");
        vm.stopPrank();
        uint256 balanceAfter = usdc.balanceOf(alice);

        assertEq(
            balanceBefore - balanceAfter,
            secondTradeAmount - expectedAutoRefund,
            "Buyer should receive automatic refund"
        );
        assertEq(
            market.sellerPoints(alice),
            sellerPointsBefore - expectedAutoRefund,
            "Own seller points should be consumed"
        );
        assertEq(
            market.claimed(alice),
            expectedAutoRefund,
            "Auto refund should update claimed amount"
        );
        assertEq(
            market.getAvailableQuota(alice),
            quotaBefore - expectedAutoRefund,
            "Auto refund should consume quota"
        );
    }

    function testDepositRevaluationDoesNotConsumeRefundQuota() public {
        uint256 initialDeposit = 1000e6;
        uint256 additionalDeposit = 1000e6;
        uint256 tradeAmount = 100e6;

        vm.startPrank(alice);
        usdc.approve(address(settlementAsset), initialDeposit);
        market.registerMerchant(initialDeposit);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(settlementAsset), tradeAmount);
        market.trade(bob, alice, uint160(bob), tradeAmount, "");
        vm.stopPrank();

        uint256 sellerPointsBefore = market.sellerPoints(alice);
        uint256 positiveBalance = uint256(market.netTradeBalance(alice));
        uint256 oldTax = market.curveTax(positiveBalance, initialDeposit);
        uint256 newTax = market.curveTax(
            positiveBalance,
            initialDeposit + additionalDeposit
        );
        uint256 expectedCredit = oldTax - newTax;
        if (expectedCredit > sellerPointsBefore) {
            expectedCredit = sellerPointsBefore;
        }
        if (expectedCredit > additionalDeposit) {
            expectedCredit = additionalDeposit;
        }

        uint256 balanceBefore = usdc.balanceOf(alice);
        vm.startPrank(alice);
        usdc.approve(address(settlementAsset), additionalDeposit);
        market.registerMerchant(additionalDeposit);
        vm.stopPrank();

        assertEq(
            balanceBefore - usdc.balanceOf(alice),
            additionalDeposit - expectedCredit,
            "Revaluation credit should reduce deposit payment"
        );
        assertEq(
            market.sellerPoints(alice),
            sellerPointsBefore - expectedCredit,
            "Revaluation credit should consume collected tax"
        );
        assertEq(market.claimed(alice), 0, "Credit is not a consumer refund");
        assertEq(
            market.lastClaimTime(alice),
            0,
            "Credit should not start the quota recovery period"
        );
        assertEq(
            market.lastAvailableQuota(alice),
            0,
            "Credit should not consume refund quota"
        );
    }

    function testTradeDoesNotAutoRefundWhenPayerIsNotBuyer() public {
        uint256 depositAmount = 1000e6;
        uint256 tradeAmount = 100e6;
        uint256 secondTradeAmount = 200e6;

        vm.startPrank(alice);
        usdc.approve(address(settlementAsset), depositAmount);
        market.registerMerchant(depositAmount);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(settlementAsset), depositAmount);
        market.registerMerchant(depositAmount);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(settlementAsset), tradeAmount);
        market.trade(bob, alice, uint160(bob), tradeAmount, "");
        vm.stopPrank();

        uint256 sellerPointsBefore = market.sellerPoints(alice);
        uint256 quotaBefore = market.getAvailableQuota(alice);

        uint256 balanceBefore = usdc.balanceOf(charlie);
        vm.startPrank(charlie);
        usdc.approve(address(settlementAsset), secondTradeAmount);
        market.trade(alice, bob, uint160(alice), secondTradeAmount, "");
        vm.stopPrank();
        uint256 balanceAfter = usdc.balanceOf(charlie);

        assertEq(
            balanceBefore - balanceAfter,
            secondTradeAmount,
            "Payer should not receive buyer refund"
        );
        assertEq(
            market.sellerPoints(alice),
            sellerPointsBefore,
            "Buyer seller points should not be consumed by payer"
        );
        assertEq(market.claimed(alice), 0, "No auto refund should be claimed");
        assertEq(
            market.getAvailableQuota(alice),
            quotaBefore,
            "Quota should not be consumed"
        );
    }

    function testMissedThirdPartyRefundIsRecoveredByBuyerLater() public {
        uint256 depositAmount = 1000e6;
        uint256 firstTradeAmount = 100e6;
        uint256 thirdPartyTradeAmount = 200e6;
        uint256 catchUpTradeAmount = 10e6;

        vm.startPrank(alice);
        usdc.approve(address(settlementAsset), depositAmount);
        market.registerMerchant(depositAmount);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(settlementAsset), depositAmount);
        market.registerMerchant(depositAmount);
        usdc.approve(address(settlementAsset), firstTradeAmount);
        market.trade(bob, alice, uint160(bob), firstTradeAmount, "");
        vm.stopPrank();

        uint256 collectedTax = market.sellerPoints(alice);

        vm.startPrank(charlie);
        usdc.approve(address(settlementAsset), thirdPartyTradeAmount);
        market.trade(
            alice,
            bob,
            uint160(alice),
            thirdPartyTradeAmount,
            ""
        );
        vm.stopPrank();

        assertEq(
            market.sellerPoints(alice),
            collectedTax,
            "Third-party payer should leave refund pending"
        );

        uint256 quotaBefore = market.getAvailableQuota(alice);
        uint256 catchUpTradeValue = catchUpTradeAmount -
            (catchUpTradeAmount / 100);
        uint256 expectedRefund = collectedTax < quotaBefore
            ? collectedTax
            : quotaBefore;
        if (expectedRefund > catchUpTradeValue) {
            expectedRefund = catchUpTradeValue;
        }

        uint256 balanceBefore = usdc.balanceOf(alice);
        vm.startPrank(alice);
        usdc.approve(address(settlementAsset), catchUpTradeAmount);
        market.trade(
            alice,
            bob,
            uint160(alice),
            catchUpTradeAmount,
            ""
        );
        vm.stopPrank();

        assertEq(
            balanceBefore - usdc.balanceOf(alice),
            catchUpTradeAmount - expectedRefund,
            "Buyer should recover the previously pending refund"
        );
        assertEq(
            market.sellerPoints(alice),
            collectedTax - expectedRefund,
            "Recovered refund should reduce collected tax"
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
        usdc.approve(address(settlementAsset), bobDeposit);
        market.registerMerchant(bobDeposit);
        vm.stopPrank();

        // 2. 产生业务数据：Alice 买 Bob 的东西
        // 从而产生 Bob 的卖方积分和 AMM 状态
        vm.startPrank(alice);
        usdc.approve(address(settlementAsset), 100e6);
        market.trade(alice, bob, uint160(alice), 100e6, "");
        vm.stopPrank();

        // 记录没收前状态
        int256 netBalanceBefore = market.netTradeBalance(bob);
        uint256 bobPointsBefore = market.sellerPoints(bob);
        uint256 vaultPointsBefore = market.sellerPoints(vault);
        uint256 vaultBalBefore = usdc.balanceOf(vault);

        assertTrue(bobPointsBefore > 0, "Bob should have points before kick");
        assertTrue(netBalanceBefore > 0, "Bob should have net balance before kick");

        // 3. 权限校验：普通人无法踢出商家
        vm.startPrank(alice);
        vm.expectRevert("Only governance");
        market.kickMerchant(bob);
        vm.stopPrank();

        // 4. 执行：模拟治理 (Timelock) 调用 kickMerchant
        vm.prank(address(timelock));
        market.kickMerchant(bob);

        // 5. 验证商家结构体被彻底清除 (delete merchants[merchant])
        (uint256 deposit, bool isActive) = market.merchants(bob);

        assertEq(deposit, 0, "Deposit should be cleared");
        assertFalse(isActive, "Merchant should be inactive");
        assertEq(market.netTradeBalance(bob), 0, "Net balance should be reset");

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
