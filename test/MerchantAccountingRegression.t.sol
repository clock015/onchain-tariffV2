// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MarketTest.t.sol";
import "./MerchantBaseTest.t.sol";

contract MerchantAccountingRegressionTest is MarketTest {
    function testOwnerAndBusinessSharesCannotSpendOtherReceipts() public {
        address businessCaller = address(0xB051);
        address sink = address(0x5155);
        MerchantBaseHarness implementation = new MerchantBaseHarness();
        MerchantBaseHarness platform = MerchantBaseHarness(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        MerchantBaseHarness.initialize,
                        (address(market), address(usdc), alice, address(executor), businessCaller, 2000, 8000)
                    )
                )
            )
        );
        platform.setAccountOwnerSupport(bob, true);
        uint256 a = _register(alice, address(platform), 1000e6, 40000);
        uint256 b = _register(bob, address(platform), 1000e6, 20000);
        usdc.mint(sink, 1000e6);
        uint256 target = _register(sink, sink, 1000e6, 40000);
        _trade(charlie, charlie, 0, a, 100e6);
        _trade(charlie, charlie, 0, b, 1000e6);
        uint256 balanceBefore = usdc.balanceOf(address(platform));
        vm.prank(alice);
        vm.expectRevert("Owner release exceeds received");
        platform.tradeOut(alice, a, target, 0, 99e6, "");
        vm.prank(alice);
        platform.tradeOut(alice, a, target, 0, 19800000, "");
        vm.prank(businessCaller);
        platform.tradeOut(alice, a, target, 0, 79200000, "");
        assertLe(balanceBefore - usdc.balanceOf(address(platform)), 99e6);
        (, uint256 ownerReleased) = platform.accountOwnerFlow(alice, 40000);
        (, uint256 businessReleased) = platform.businessFlow(40000);
        assertEq(ownerReleased + businessReleased, 99e6);
        (, uint256 otherReleased) = platform.accountOwnerFlow(bob, 20000);
        assertEq(otherReleased, 0);
        vm.prank(businessCaller);
        vm.expectRevert("Business release exceeds received");
        platform.tradeOut(alice, a, target, 0, 1, "");
    }
}
