// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/Market.sol";
import "../src/TradeExecutor.sol";
import "../src/settlement/ERC20SettlementAsset.sol";
import "./MerchantBaseTest.t.sol";

contract DepositWithdrawalToken is ERC20 {
    constructor() ERC20("Test token", "TEST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DepositWithdrawalTest is Test {
    Market internal market;
    DepositWithdrawalToken internal token;
    ERC20SettlementAsset internal settlement;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA201);
    address internal vault = address(0x999);
    uint256 internal constant DEPOSIT = 1000e6;

    event DepositWithdrawalRequested(
        uint256 indexed accountId, address indexed owner, uint256 amount, uint256 availableAt
    );
    event DepositWithdrawn(uint256 indexed accountId, address indexed recipient, uint256 amount);

    function setUp() public {
        vm.warp(100 days);
        token = new DepositWithdrawalToken();
        DepositWithdrawalToken rights = new DepositWithdrawalToken();
        settlement = ERC20SettlementAsset(
            address(
                new ERC1967Proxy(
                    address(new ERC20SettlementAsset()),
                    abi.encodeCall(ERC20SettlementAsset.initialize, (address(token), address(this)))
                )
            )
        );
        market = Market(
            address(
                new ERC1967Proxy(
                    address(new Market()),
                    abi.encodeCall(
                        Market.initialize, (address(settlement), address(rights), address(rights), address(this), vault)
                    )
                )
            )
        );
        TradeExecutor executor = new TradeExecutor(address(market), address(settlement));
        market.setExecutor(address(executor));
        settlement.setController(address(market), true);
        settlement.setController(address(executor), true);
        token.mint(alice, 10000e6);
        token.mint(bob, 10000e6);
        token.mint(carol, 10000e6);
    }

    function _register(address owner, address merchant, uint256 multiplier) internal returns (uint256 id) {
        vm.startPrank(owner);
        token.approve(address(settlement), DEPOSIT);
        id = market.registerMerchant(merchant, DEPOSIT, multiplier);
        vm.stopPrank();
    }

    function _trade(address payer, address buyer, uint256 buyerId, uint256 sellerId, uint256 amount) internal {
        vm.startPrank(payer);
        token.approve(address(settlement), amount);
        market.trade(buyer, buyerId, sellerId, 0, amount, "");
        vm.stopPrank();
    }

    function _request(uint256 id, address owner) internal {
        vm.prank(owner);
        market.requestDepositWithdrawal(id);
    }

    function testRequestAtZeroRemovesCapacityButPreservesAccountAndPrincipal() public {
        uint256 id = _register(alice, bob, 40000);
        uint256 custodyBefore = token.balanceOf(address(settlement));
        uint256 ownerBefore = token.balanceOf(alice);
        uint256 deadline = block.timestamp + 180 days;
        vm.expectEmit(true, true, false, true, address(market));
        emit DepositWithdrawalRequested(id, alice, DEPOSIT, deadline);
        _request(id, alice);

        (address owner, address merchant, uint256 deposit, uint256 multiplier, bool active) = market.accounts(id);
        assertEq(owner, alice);
        assertEq(merchant, bob);
        assertEq(deposit, 0);
        assertEq(multiplier, 40000);
        assertTrue(active);
        assertTrue(market.isAccountFrozen(id));
        assertEq(market.accountIdOf(alice, bob), id);
        (uint256 pending, uint256 availableAt) = market.depositWithdrawals(id);
        assertEq(pending, DEPOSIT);
        assertEq(availableAt, deadline);
        assertEq(token.balanceOf(address(settlement)), custodyBefore);
        assertEq(token.balanceOf(alice), ownerBefore);
    }

    function testOnlyOwnerCanRequestOrWithdraw() public {
        uint256 id = _register(alice, bob, 40000);
        vm.prank(bob);
        vm.expectRevert("Only account owner");
        market.requestDepositWithdrawal(id);
        vm.expectRevert("Only account owner");
        market.requestDepositWithdrawal(id);
        _request(id, alice);
        vm.warp(block.timestamp + 180 days);
        vm.prank(bob);
        vm.expectRevert("Only account owner");
        market.withdrawDeposit(id);
    }

    function testInactiveOrUnknownAccountCannotRequest() public {
        uint256 seller = _register(bob, bob, 40000);
        _trade(alice, alice, 0, seller, 100e6);
        uint256 defaultId = market.accountIdOf(alice, alice);
        vm.prank(alice);
        vm.expectRevert("Merchant account not active");
        market.requestDepositWithdrawal(defaultId);
        vm.prank(alice);
        vm.expectRevert("Merchant account not active");
        market.requestDepositWithdrawal(999);
    }

    function testPositiveRealSurplusCannotRequest() public {
        uint256 id = _register(alice, alice, 40000);
        _trade(bob, bob, 0, id, 100e6);
        assertEq(market.deferredSurplus(id), 0);
        vm.prank(alice);
        vm.expectRevert("Outstanding surplus");
        market.requestDepositWithdrawal(id);
        (,, uint256 deposit,,) = market.accounts(id);
        assertEq(deposit, DEPOSIT);
    }

    function testDeferredSurplusMustFullyDecayBeforeRequestEvenWithDeficit() public {
        uint256 id = _register(alice, alice, 40000);
        uint256 other = _register(bob, bob, 40000);
        _trade(bob, bob, other, id, 100e6);
        _trade(alice, alice, id, other, 200e6);
        assertEq(market.netTradeBalance(id), -99e6);
        assertEq(market.deferredSurplus(id), 99e6);

        vm.prank(alice);
        vm.expectRevert("Outstanding deferred surplus");
        market.requestDepositWithdrawal(id);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vm.expectRevert("Outstanding deferred surplus");
        market.requestDepositWithdrawal(id);

        vm.warp(block.timestamp + 6 days);
        assertEq(market.deferredSurplus(id), 0);
        uint256 points = market.sellerPoints(id);
        _trade(alice, alice, id, other, 100e6);
        assertEq(market.sellerPoints(id), 0);
        _request(id, alice);
        assertEq(market.claimed(id), points);
        assertEq(market.netTradeBalance(id), -198e6);
        vm.warp(block.timestamp + 180 days);
        assertEq(market.taxableSurplus(id), 0);
    }

    function testZeroRealBalanceWithDeferredSurplusCannotRequest() public {
        uint256 id = _register(alice, alice, 40000);
        uint256 other = _register(bob, bob, 40000);
        _trade(bob, bob, other, id, 100e6);
        _trade(alice, alice, id, other, 100e6);
        assertEq(market.netTradeBalance(id), 0);
        vm.prank(alice);
        vm.expectRevert("Outstanding deferred surplus");
        market.requestDepositWithdrawal(id);
    }

    function testFrozenDeficitCannotReceiveDuringOrAfterWithdrawal() public {
        uint256 id = _register(alice, alice, 40000);
        uint256 other = _register(bob, bob, 40000);
        _trade(alice, alice, id, other, 100e6);
        _request(id, alice);
        uint256 custodyBefore = token.balanceOf(address(settlement));
        vm.expectRevert("Account frozen");
        market.calculateAMM(id, 1);
        vm.startPrank(carol);
        token.approve(address(settlement), 1);
        vm.expectRevert("Account frozen");
        market.trade(carol, 0, id, 0, 1, "");
        vm.stopPrank();
        assertEq(market.accountIdOf(carol, carol), 0);
        assertEq(token.balanceOf(address(settlement)), custodyBefore);

        vm.warp(block.timestamp + 180 days);
        vm.prank(alice);
        market.withdrawDeposit(id);
        vm.expectRevert("Merchant account not active");
        market.calculateAMM(id, 1);
        vm.prank(carol);
        vm.expectRevert("Merchant account not active");
        market.trade(carol, 0, id, 0, 1, "");
        assertEq(market.netTradeBalance(id), 0);
        assertFalse(market.isAccountFrozen(id));
    }

    function testFrozenDefaultAccountCannotPayWithExplicitOrZeroIdOrThirdPartyPayer() public {
        uint256 id = _register(alice, alice, 20000);
        uint256 stricter = _register(bob, bob, 10000);
        _request(id, alice);
        vm.startPrank(alice);
        token.approve(address(settlement), 100e6);
        vm.expectRevert("Account frozen");
        market.trade(alice, 0, stricter, 0, 100e6, "");
        vm.expectRevert("Account frozen");
        market.trade(alice, id, stricter, 0, 100e6, "");
        vm.stopPrank();
        vm.startPrank(carol);
        token.approve(address(settlement), 100e6);
        vm.expectRevert("Account frozen");
        market.trade(alice, 0, stricter, 0, 100e6, "");
        vm.expectRevert("Account frozen");
        market.trade(alice, id, stricter, 0, 100e6, "");
        vm.stopPrank();
        assertEq(market.netTradeBalance(id), 0);
        assertEq(market.netTradeBalance(stricter), 0);
    }

    function testPendingRequestCannotBeRepeatedExtendedOrReRegistered() public {
        uint256 id = _register(alice, bob, 40000);
        _request(id, alice);
        (, uint256 deadline) = market.depositWithdrawals(id);
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(alice);
        vm.expectRevert("Deposit withdrawal pending");
        market.requestDepositWithdrawal(id);
        vm.expectRevert("Merchant account already active");
        market.registerMerchant(bob, DEPOSIT, 40000);
        vm.stopPrank();
        (, uint256 unchangedDeadline) = market.depositWithdrawals(id);
        assertEq(unchangedDeadline, deadline);
    }

    function testFrozenAccountCannotAddDepositOrChangeMultiplier() public {
        uint256 id = _register(alice, bob, 40000);
        _request(id, alice);
        vm.prank(alice);
        vm.expectRevert("Account frozen");
        market.addDeposit(id, 1);
        vm.prank(carol);
        vm.expectRevert("Account frozen");
        market.addDeposit(id, 1);
        vm.prank(alice);
        vm.expectRevert("Account frozen");
        market.setCapacityMultiplier(id, 20000);
    }

    function testWithdrawOnlyAtDeadlineToOwnerNotMerchantAndOnlyOnce() public {
        uint256 id = _register(alice, bob, 40000);
        _request(id, alice);
        (, uint256 deadline) = market.depositWithdrawals(id);
        vm.warp(deadline - 1);
        vm.prank(alice);
        vm.expectRevert("Deposit withdrawal not ready");
        market.withdrawDeposit(id);

        uint256 ownerBefore = token.balanceOf(alice);
        uint256 merchantBefore = token.balanceOf(bob);
        vm.warp(deadline);
        vm.expectEmit(true, true, false, true, address(market));
        emit DepositWithdrawn(id, alice, DEPOSIT);
        vm.prank(alice);
        market.withdrawDeposit(id);
        assertEq(token.balanceOf(alice) - ownerBefore, DEPOSIT);
        assertEq(token.balanceOf(bob), merchantBefore);
        (address owner, address merchant, uint256 deposit, uint256 multiplier, bool active) = market.accounts(id);
        assertEq(owner, address(0));
        assertEq(merchant, address(0));
        assertEq(deposit, 0);
        assertEq(multiplier, 0);
        assertFalse(active);
        assertEq(market.accountIdOf(alice, bob), 0);
        assertFalse(market.isAccountFrozen(id));
        (uint256 pending, uint256 availableAt) = market.depositWithdrawals(id);
        assertEq(pending, 0);
        assertEq(availableAt, 0);
        vm.prank(alice);
        vm.expectRevert("Only account owner");
        market.withdrawDeposit(id);
        vm.prank(alice);
        vm.expectRevert("Merchant account not active");
        market.requestDepositWithdrawal(id);
    }

    function testThirdPartyDepositIsAlsoReturnedToOwner() public {
        uint256 id = _register(alice, bob, 40000);
        vm.startPrank(carol);
        token.approve(address(settlement), 123e6);
        market.addDeposit(id, 123e6);
        vm.stopPrank();
        _request(id, alice);
        vm.warp(block.timestamp + 180 days);
        uint256 ownerBefore = token.balanceOf(alice);
        uint256 thirdPartyBefore = token.balanceOf(carol);
        vm.prank(alice);
        market.withdrawDeposit(id);
        assertEq(token.balanceOf(alice) - ownerBefore, DEPOSIT + 123e6);
        assertEq(token.balanceOf(carol), thirdPartyBefore);
    }

    function testWithdrawalReturnsPairToUnregisteredStateAndFreshRegistrationGetsNewId() public {
        uint256 id = _register(alice, alice, 40000);
        _request(id, alice);
        vm.warp(block.timestamp + 180 days);
        vm.prank(alice);
        market.withdrawDeposit(id);
        assertEq(market.accountIdOf(alice, alice), 0);
        (address oldOwner, address oldMerchant,,, bool oldActive) = market.accounts(id);
        assertEq(oldOwner, address(0));
        assertEq(oldMerchant, address(0));
        assertFalse(oldActive);
        assertFalse(market.isAccountFrozen(id));
        vm.startPrank(alice);
        token.approve(address(settlement), DEPOSIT);
        uint256 fresh = market.registerMerchant(alice, DEPOSIT, 40000);
        vm.stopPrank();
        assertTrue(fresh != id);
        assertEq(market.accountIdOf(alice, alice), fresh);
        assertFalse(market.isAccountFrozen(fresh));
        _trade(bob, bob, 0, fresh, 100e6);
        assertEq(market.netTradeBalance(fresh), 99e6);
    }

    function testResidualTariffIsRefundedToMerchantWhenDepositIsWithdrawn() public {
        uint256 id = _register(alice, bob, 40000);
        uint256 other = _register(carol, carol, 40000);
        _trade(carol, carol, other, id, 100e6);
        _trade(carol, alice, id, other, 200e6);
        vm.warp(block.timestamp + 7 days);
        uint256 points = market.sellerPoints(id);
        assertGt(points, 0);
        _request(id, alice);
        assertTrue(market.isAccountFrozen(id));
        assertEq(market.sellerPoints(id), points);

        uint256 ownerBefore = token.balanceOf(alice);
        uint256 merchantBefore = token.balanceOf(bob);
        vm.warp(block.timestamp + 180 days);
        vm.prank(alice);
        market.withdrawDeposit(id);
        assertEq(token.balanceOf(alice) - ownerBefore, DEPOSIT);
        assertEq(token.balanceOf(bob) - merchantBefore, points);
        assertEq(market.sellerPoints(id), 0);
        assertEq(market.claimed(id), 0);
    }

    function testKickSlashesPendingDepositAndResidualTariff() public {
        uint256 id = _register(alice, bob, 40000);
        uint256 other = _register(carol, carol, 40000);
        _trade(carol, carol, other, id, 100e6);
        _trade(carol, alice, id, other, 200e6);
        vm.warp(block.timestamp + 7 days);
        uint256 tariff = market.sellerPoints(id);
        assertGt(tariff, 0);
        _request(id, alice);
        uint256 before = token.balanceOf(vault);
        market.kickMerchant(id);
        assertEq(token.balanceOf(vault) - before, DEPOSIT + tariff);
        assertEq(market.accountIdOf(alice, bob), 0);
        assertFalse(market.isAccountFrozen(id));
        (uint256 pending, uint256 deadline) = market.depositWithdrawals(id);
        assertEq(pending, 0);
        assertEq(deadline, 0);
        assertEq(market.sellerPoints(id), 0);
        vm.warp(block.timestamp + 180 days);
        vm.prank(alice);
        vm.expectRevert("Only account owner");
        market.withdrawDeposit(id);
        uint256 fresh = _register(alice, bob, 40000);
        assertTrue(fresh != id);
        assertFalse(market.isAccountFrozen(fresh));
        (pending, deadline) = market.depositWithdrawals(fresh);
        assertEq(pending, 0);
        assertEq(deadline, 0);
    }

    function testKickAfterWithdrawalCannotSlashPrincipalAgain() public {
        uint256 id = _register(alice, alice, 40000);
        _request(id, alice);
        vm.warp(block.timestamp + 180 days);
        vm.prank(alice);
        market.withdrawDeposit(id);
        uint256 before = token.balanceOf(vault);
        vm.expectRevert("Merchant account not active");
        market.kickMerchant(id);
        assertEq(token.balanceOf(vault), before);
    }

    function testTransferFailureRestoresWithdrawalForRetry() public {
        uint256 id = _register(alice, bob, 40000);
        _request(id, alice);
        vm.warp(block.timestamp + 180 days);
        bytes memory pushCall = abi.encodeCall(ERC20SettlementAsset.push, (alice, DEPOSIT));
        vm.mockCallRevert(address(settlement), pushCall, abi.encodeWithSignature("Error(string)", "Transfer failed"));
        vm.prank(alice);
        vm.expectRevert("Transfer failed");
        market.withdrawDeposit(id);
        (uint256 pending,) = market.depositWithdrawals(id);
        assertEq(pending, DEPOSIT);
        vm.clearMockedCalls();
        vm.prank(alice);
        market.withdrawDeposit(id);
        (pending,) = market.depositWithdrawals(id);
        assertEq(pending, 0);
    }

    function testFuzzWithdrawalConservesPrincipal(uint96 additional, uint32 elapsed) public {
        additional = uint96(bound(additional, 1, 1e20));
        uint256 id = _register(alice, bob, 40000);
        token.mint(carol, additional);
        vm.startPrank(carol);
        token.approve(address(settlement), additional);
        market.addDeposit(id, additional);
        vm.stopPrank();
        _request(id, alice);
        vm.warp(block.timestamp + 180 days + uint256(elapsed));
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        market.withdrawDeposit(id);
        assertEq(token.balanceOf(alice) - before, DEPOSIT + additional);
        assertEq(token.balanceOf(address(settlement)), 0);
    }

    function testFreezeIsScopedToAccountNotSharedMerchantAddress() public {
        uint256 frozen = _register(alice, bob, 40000);
        uint256 live = _register(carol, bob, 40000);
        _request(frozen, alice);
        _trade(alice, alice, 0, live, 100e6);
        assertEq(market.netTradeBalance(frozen), 0);
        assertEq(market.netTradeBalance(live), 99e6);
        assertTrue(market.isAccountFrozen(frozen));
        assertFalse(market.isAccountFrozen(live));
    }

    function testMerchantBaseCannotPayOrReceiveOnFrozenAccountAndBucketsRollBack() public {
        MerchantBaseHarness platform = MerchantBaseHarness(
            address(
                new ERC1967Proxy(
                    address(new MerchantBaseHarness()),
                    abi.encodeCall(
                        MerchantBaseHarness.initialize,
                        (address(market), address(token), alice, market.executor(), bob, 2000, 8000)
                    )
                )
            )
        );
        uint256 id = _register(alice, address(platform), 40000);
        uint256 other = _register(carol, carol, 40000);
        _trade(carol, carol, other, id, 100e6);
        _trade(carol, alice, id, other, 200e6);
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        platform.tradeOut(alice, id, other, 0, 11e6, "");
        assertEq(market.sellerPoints(id), 0);
        _request(id, alice);

        uint256 before = token.balanceOf(address(platform));
        uint256 allowanceBefore = token.allowance(address(platform), address(settlement));
        vm.prank(alice);
        vm.expectRevert("Account frozen");
        platform.tradeOut(alice, id, other, 0, 1e6, "");
        vm.prank(bob);
        vm.expectRevert("Account frozen");
        platform.tradeOut(alice, id, other, 0, 1e6, "");
        vm.prank(carol);
        vm.expectRevert("Account frozen");
        market.trade(carol, other, id, 0, 1e6, "");

        (uint256 received, uint256 released) = platform.accountOwnerFlow(alice, 40000);
        assertEq(received, 99e6);
        assertEq(released, 11e6);
        (received, released) = platform.businessFlow(40000);
        assertEq(received, 99e6);
        assertEq(released, 0);
        assertEq(token.balanceOf(address(platform)), before);
        assertEq(token.allowance(address(platform), address(settlement)), allowanceBefore);
    }
}
