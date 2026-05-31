// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/Market.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockGovernance {
    function kickMerchant(Market market, address merchant) external {
        market.kickMerchant(merchant);
    }
}

contract MarketTest is Test {
    event MerchantRegistered(address indexed merchant, uint256 deposit);
    event Traded(address indexed payer, address indexed buyer, address indexed merchant, uint256 amount);
    event TaxRefunded(address indexed account, uint256 amount);
    event MerchantKicked(address indexed merchant, uint256 slashedAmount);

    Market market;
    MockERC20 underlying;
    MockERC20 buyerRights;
    MockERC20 sellerRights;
    MockGovernance governance;

    address owner = address(0xA11CE);
    address vault = address(0xA017);
    address payer = address(0xCAFE);
    address buyer = address(0xB0B);
    address merchant = address(0xBEEF);

    function setUp() public {
        underlying = new MockERC20("Underlying", "UND");
        buyerRights = new MockERC20("Buyer Rights", "BR");
        sellerRights = new MockERC20("Seller Rights", "SR");
        governance = new MockGovernance();

        Market implementation = new Market();
        bytes memory initData = abi.encodeCall(
            Market.initialize,
            (
                address(underlying),
                address(buyerRights),
                address(sellerRights),
                address(governance),
                vault
            )
        );

        vm.prank(owner);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        market = Market(address(proxy));

        underlying.mint(payer, 10_000 ether);
        underlying.mint(merchant, 10_000 ether);
    }

    function testInitializeStoresDependenciesAndOwner() public view {
        assertEq(address(market.underlying()), address(underlying));
        assertEq(address(market.buyerRights()), address(buyerRights));
        assertEq(address(market.sellerRights()), address(sellerRights));
        assertEq(market.governance(), address(governance));
        assertEq(market.vault(), vault);
        assertEq(market.owner(), owner);
    }

    function testRegisterMerchantTransfersDepositAndActivatesMerchant() public {
        uint256 deposit = 1_000 ether;

        vm.startPrank(merchant);
        underlying.approve(address(market), deposit);

        vm.expectEmit(true, false, false, true, address(market));
        emit MerchantRegistered(merchant, deposit);
        market.registerMerchant(deposit);
        vm.stopPrank();

        (uint256 storedDeposit, bool isActive) = market.merchants(merchant);
        assertEq(storedDeposit, deposit);
        assertTrue(isActive);
        assertEq(underlying.balanceOf(address(market)), deposit);
    }

    function testTradeTransfersFundsAccruesPointsAndMintsRights() public {
        _registerMerchant(1_000 ether);

        uint256 amount = 1_000 ether;
        vm.startPrank(payer);
        underlying.approve(address(market), amount);

        vm.expectEmit(true, true, true, true, address(market));
        emit Traded(payer, buyer, merchant, amount);
        market.trade(buyer, merchant, amount);
        vm.stopPrank();

        assertEq(underlying.balanceOf(merchant), 10_000 ether - 1_000 ether + 900 ether);
        assertEq(underlying.balanceOf(vault), 10 ether);
        assertEq(underlying.balanceOf(address(market)), 1_000 ether + 90 ether);

        assertEq(market.buyerPoints(buyer), 90 ether);
        assertEq(market.sellerPoints(merchant), 90 ether);
        assertEq(buyerRights.balanceOf(buyer), 10 ether);
        assertEq(sellerRights.balanceOf(merchant), 10 ether);
    }

    function testClaimTaxRefundOffsetsBuyerAndSellerPoints() public {
        _registerMerchant(1_000 ether);
        underlying.mint(buyer, 1_000 ether);
        _registerMerchant(buyer, 1_000 ether);
        _trade(payer, buyer, merchant, 1_000 ether);
        _trade(payer, merchant, buyer, 500 ether);

        uint256 balanceBefore = underlying.balanceOf(buyer);

        vm.expectEmit(true, false, false, true, address(market));
        emit TaxRefunded(buyer, 45 ether);
        market.claimTaxRefund(buyer);

        assertEq(market.buyerPoints(buyer), 45 ether);
        assertEq(market.sellerPoints(buyer), 0);
        assertEq(underlying.balanceOf(buyer), balanceBefore + 45 ether);
    }

    function testOnlyGovernanceCanKickMerchant() public {
        _registerMerchant(1_000 ether);

        vm.expectRevert(bytes("Only governance"));
        market.kickMerchant(merchant);

        vm.expectEmit(true, false, false, true, address(market));
        emit MerchantKicked(merchant, 1_000 ether);
        governance.kickMerchant(market, merchant);

        (uint256 storedDeposit, bool isActive) = market.merchants(merchant);
        assertEq(storedDeposit, 0);
        assertFalse(isActive);
        assertEq(underlying.balanceOf(vault), 1_000 ether);
    }

    function testOwnerCanSetVault() public {
        address newVault = address(0xFEE);

        vm.prank(owner);
        market.setVault(newVault);

        assertEq(market.vault(), newVault);
    }

    function _registerMerchant(uint256 deposit) internal {
        _registerMerchant(merchant, deposit);
    }

    function _registerMerchant(address account, uint256 deposit) internal {
        vm.startPrank(account);
        underlying.approve(address(market), deposit);
        market.registerMerchant(deposit);
        vm.stopPrank();
    }

    function _trade(address tradePayer, address tradeBuyer, address tradeMerchant, uint256 amount) internal {
        vm.startPrank(tradePayer);
        underlying.approve(address(market), amount);
        market.trade(tradeBuyer, tradeMerchant, amount);
        vm.stopPrank();
    }
}
