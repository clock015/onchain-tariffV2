// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/Market.sol";
import "../src/Vault.sol";
import "../src/TradeExecutor.sol";
import "../src/settlement/ERC20SettlementAsset.sol";

contract VaultTestToken is ERC20 {
    constructor() ERC20("Test token", "TEST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract VaultTest is Test {
    Market internal market;
    Vault internal vault;
    VaultTestToken internal token;
    VaultTestToken internal rights;
    ERC20SettlementAsset internal settlement;
    address internal seller = address(0x51);
    address internal customer = address(0xC0);
    address internal keeper = address(0xA1);
    uint256 internal sellerId;

    function setUp() public {
        token = new VaultTestToken();
        rights = new VaultTestToken();
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
                        Market.initialize,
                        (address(settlement), address(rights), address(rights), address(this), address(0))
                    )
                )
            )
        );
        vault = new Vault(address(market));
        market.setVault(address(vault));
        TradeExecutor executor = new TradeExecutor(address(market), address(settlement));
        market.setExecutor(address(executor));
        settlement.setController(address(market), true);
        settlement.setController(address(executor), true);

        token.mint(seller, 1000e6);
        vm.startPrank(seller);
        token.approve(address(settlement), 1000e6);
        sellerId = market.registerMerchant(seller, 1000e6, 20000);
        vm.stopPrank();
    }

    function _fundVaultFromFee() internal {
        token.mint(customer, 100e6);
        vm.startPrank(customer);
        token.approve(address(settlement), 100e6);
        market.trade(customer, 0, sellerId, 0, 100e6, "");
        vm.stopPrank();
        assertEq(token.balanceOf(address(vault)), 1e6);
    }

    function _queue(uint256 sellerAccountId, uint256 amount) internal returns (uint256 orderId) {
        orderId = vault.tradeOrderCount();
        Vault.TradeInput[] memory inputs = new Vault.TradeInput[](1);
        inputs[0] = Vault.TradeInput(sellerAccountId, 42, amount, hex"1234");
        vault.queueTrades(inputs);
    }

    function testGovernanceRegistersWithOneUnitAndCanOnlyTightenLimit() public {
        _fundVaultFromFee();
        vm.prank(keeper);
        vm.expectRevert("Only governance");
        vault.register(40000);

        vault.register(40000);
        uint256 id = vault.accountId();
        (address owner, address merchant, uint256 deposit, uint256 multiplier, bool active) = market.accounts(id);
        assertEq(owner, address(vault));
        assertEq(merchant, address(vault));
        assertEq(deposit, 1);
        assertEq(multiplier, 40000);
        assertTrue(active);
        assertEq(vault.capacityMultiplierLimit(), 40000);
        assertEq(market.netTradeBalance(id), 0);
        assertEq(token.balanceOf(address(vault)), 1e6 - 1);

        vault.register(30000);
        (,,, multiplier,) = market.accounts(id);
        assertEq(multiplier, 30000);
        assertEq(vault.capacityMultiplierLimit(), 30000);
        vm.expectRevert("Cannot loosen limit");
        vault.register(40000);
    }

    function testExecutesApprovedTradesOneAtATimeUsingFeeFunds() public {
        _fundVaultFromFee();
        vault.register(40000);
        uint256 vaultId = vault.accountId();
        uint256 order0 = _queue(sellerId, 400_000);
        uint256 order1 = _queue(sellerId, 300_000);
        uint256 sellerBalance = token.balanceOf(seller);

        vm.prank(keeper);
        vault.executeTrade(order0);
        assertEq(market.netTradeBalance(vaultId), -396_000);
        assertEq(token.balanceOf(address(vault)), 1e6 - 1 - 400_000 + 4_000);
        assertGt(token.balanceOf(seller), sellerBalance);
        assertEq(rights.balanceOf(address(vault)), 4_000);
        (,,,, bool executed0,) = vault.tradeOrders(order0);
        (,,,, bool executed1,) = vault.tradeOrders(order1);
        assertTrue(executed0);
        assertFalse(executed1);

        vm.prank(keeper);
        vault.executeTrade(order1);
        assertEq(market.netTradeBalance(vaultId), -693_000);
        assertEq(rights.balanceOf(address(vault)), 7_000);
        vm.expectRevert("Order closed");
        vault.executeTrade(order0);
    }

    function testAllowsEqualSellerMultiplier() public {
        token.mint(address(vault), 1e6);
        vault.register(20000);
        uint256 orderId = _queue(sellerId, 100_000);
        vault.executeTrade(orderId);
        (,,,, bool executed,) = vault.tradeOrders(orderId);
        assertTrue(executed);
        assertEq(token.allowance(address(vault), address(settlement)), 0);
    }

    function testRejectsSellerMultiplierAboveOwnLimit() public {
        token.mint(address(vault), 1e6);
        vault.register(10000);
        uint256 orderId = _queue(sellerId, 100_000);
        vm.expectRevert("Seller limit exceeds Vault limit");
        vault.executeTrade(orderId);
        (,,,, bool executed,) = vault.tradeOrders(orderId);
        assertFalse(executed);
        assertEq(token.allowance(address(vault), address(settlement)), 0);
    }

    function testCancelAndGovernanceGate() public {
        _fundVaultFromFee();
        vault.register(40000);
        Vault.TradeInput[] memory inputs = new Vault.TradeInput[](1);
        inputs[0] = Vault.TradeInput(sellerId, 0, 100_000, "");
        vm.prank(keeper);
        vm.expectRevert("Only governance");
        vault.queueTrades(inputs);
        vault.queueTrades(inputs);
        vm.prank(keeper);
        vm.expectRevert("Only governance");
        vault.cancelTrade(0);
        vault.cancelTrade(0);
        vm.expectRevert("Order closed");
        vault.executeTrade(0);
    }

    function testVaultCannotSellAndAccumulateSurplus() public {
        _fundVaultFromFee();
        vault.register(40000);
        token.mint(customer, 2);
        vm.startPrank(customer);
        token.approve(address(settlement), 2);
        uint256 vaultId = vault.accountId();
        vm.expectRevert("Vault cannot sell");
        market.trade(customer, 0, vaultId, 0, 2, "");
        vm.stopPrank();
        assertEq(market.netTradeBalance(vault.accountId()), 0);
    }
}
