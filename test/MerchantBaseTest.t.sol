// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/Merchant/MerchantBaseUpgradeable.sol";
import "../src/interfaces/IMerchantTradeIn.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

contract MerchantBaseHarness is MerchantBase {
    uint160 public lastRechargeTarget;
    uint256 public lastCapacityMultiplier;
    uint256 public lastNetAmount;
    uint256 public lastDeltaW;

    function initialize(
        address market,
        address underlying,
        address initialAccountOwner,
        address tradeExecutor,
        address business,
        uint256 ownerShareBps,
        uint256 businessShareBps
    ) external initializer {
        __MerchantBase_init(
            market, underlying, initialAccountOwner, tradeExecutor, business, ownerShareBps, businessShareBps
        );
    }

    function _tradeIn(
        uint160 rechargeTarget,
        uint256 capacityMultiplier,
        uint256 netAmount,
        uint256 deltaW,
        bytes calldata
    ) internal override {
        lastRechargeTarget = rechargeTarget;
        lastCapacityMultiplier = capacityMultiplier;
        lastNetAmount = netAmount;
        lastDeltaW = deltaW;
    }
}

contract MerchantBaseTokenMock is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}
}

contract MerchantBaseExecutorMock {
    address public immutable market;

    constructor(address _market) {
        market = _market;
    }

    function forward(address merchant, address accountOwner, uint160 rechargeTarget, uint256 netAmount, uint256 deltaW)
        external
    {
        require(msg.sender == market, "Only market");
        IMerchantTradeIn(merchant).tradeIn(accountOwner, rechargeTarget, netAmount, deltaW, "");
    }
}

contract MerchantBaseMarketMock is ReentrancyGuardTransient {
    struct Account {
        address owner;
        address merchant;
        uint256 deposit;
        uint256 capacityMultiplier;
        bool isActive;
    }

    address public settlementAsset = address(0x5151);
    mapping(uint256 => Account) public accounts;
    mapping(address => mapping(address => uint256)) public accountIdOf;

    address public lastBuyer;
    uint256 public lastBuyerAccountId;
    uint256 public lastSellerAccountId;
    uint160 public lastRechargeTarget;
    uint256 public lastAmount;

    function setAccount(uint256 accountId, address accountOwner, address merchant, uint256 multiplier, bool isActive)
        external
    {
        Account storage account = accounts[accountId];
        account.owner = accountOwner;
        account.merchant = merchant;
        account.deposit = 1000e6;
        account.capacityMultiplier = multiplier;
        account.isActive = isActive;
        accountIdOf[accountOwner][merchant] = accountId;
    }

    function setMultiplier(uint256 accountId, uint256 multiplier) external {
        accounts[accountId].capacityMultiplier = multiplier;
    }

    function executeTradeCallback(
        MerchantBaseExecutorMock executor,
        address merchant,
        address accountOwner,
        uint160 rechargeTarget,
        uint256 netAmount,
        uint256 deltaW
    ) external nonReentrant {
        executor.forward(merchant, accountOwner, rechargeTarget, netAmount, deltaW);
    }

    function trade(
        address buyer,
        uint256 buyerAccountId,
        uint256 sellerAccountId,
        uint160 rechargeTarget,
        uint256 amount,
        bytes calldata
    ) external {
        lastBuyer = buyer;
        lastBuyerAccountId = buyerAccountId;
        lastSellerAccountId = sellerAccountId;
        lastRechargeTarget = rechargeTarget;
        lastAmount = amount;
    }
}

contract MerchantBaseTest is Test {
    MerchantBaseHarness internal merchant;
    MerchantBaseMarketMock internal market;
    MerchantBaseExecutorMock internal executor;
    MerchantBaseTokenMock internal token;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal business = address(0xB051E55);

    function setUp() public {
        market = new MerchantBaseMarketMock();
        executor = new MerchantBaseExecutorMock(address(market));
        token = new MerchantBaseTokenMock();

        MerchantBaseHarness implementation = new MerchantBaseHarness();
        merchant = MerchantBaseHarness(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        MerchantBaseHarness.initialize,
                        (address(market), address(token), alice, address(executor), business, 4000, 6000)
                    )
                )
            )
        );

        market.setAccount(1, alice, address(merchant), 40000, true);
    }

    function testTradeCallbackReadsMultiplierWhileMarketLockIsActive() public {
        market.executeTradeCallback(executor, address(merchant), alice, 7, 99e6, 10e6);

        (uint256 ownerReceived, uint256 ownerReleased) = merchant.accountOwnerFlow(alice, 40000);
        (uint256 businessReceived, uint256 businessReleased) = merchant.businessFlow(40000);
        assertEq(ownerReceived, 99e6);
        assertEq(ownerReleased, 0);
        assertEq(businessReceived, 99e6);
        assertEq(businessReleased, 0);
        assertEq(merchant.lastRechargeTarget(), 7);
        assertEq(merchant.lastCapacityMultiplier(), 40000);
        assertEq(merchant.lastNetAmount(), 99e6);
        assertEq(merchant.lastDeltaW(), 10e6);
    }

    function testMultipleOwnersAndMultipliersAccumulateSeparately() public {
        merchant.setAccountOwnerSupport(bob, true);
        market.setAccount(2, bob, address(merchant), 20000, true);

        market.executeTradeCallback(executor, address(merchant), alice, 9, 100e6, 1);
        market.executeTradeCallback(executor, address(merchant), bob, 9, 50e6, 1);

        (uint256 aliceReceived,) = merchant.accountOwnerFlow(alice, 40000);
        (uint256 bobReceived,) = merchant.accountOwnerFlow(bob, 20000);
        (uint256 businessAt40000,) = merchant.businessFlow(40000);
        (uint256 businessAt20000,) = merchant.businessFlow(20000);
        assertEq(aliceReceived, 100e6);
        assertEq(bobReceived, 50e6);
        assertEq(businessAt40000, 100e6);
        assertEq(businessAt20000, 50e6);
    }

    function testUnsupportedOrInactiveAccountOwnerCannotRecordSales() public {
        market.setAccount(2, bob, address(merchant), 20000, true);

        vm.expectRevert("Unsupported account owner");
        market.executeTradeCallback(executor, address(merchant), bob, 3, 10e6, 1);

        merchant.setAccountOwnerSupport(bob, true);
        market.setAccount(2, bob, address(merchant), 20000, false);

        vm.expectRevert("Market account not active");
        market.executeTradeCallback(executor, address(merchant), bob, 3, 10e6, 1);
        (uint256 ownerReceived,) = merchant.accountOwnerFlow(bob, 20000);
        (uint256 businessReceived,) = merchant.businessFlow(20000);
        assertEq(ownerReceived, 0);
        assertEq(businessReceived, 0);
    }

    function testSupportedAccountOwnerCanReleaseOnlyItsReceivedAmount() public {
        market.executeTradeCallback(executor, address(merchant), alice, 7, 100e6, 1);

        vm.prank(alice);
        merchant.tradeOut(alice, 1, 8, 12, 40e6, "");

        (uint256 received, uint256 released) = merchant.accountOwnerFlow(alice, 40000);
        (, uint256 businessReleased) = merchant.businessFlow(40000);
        assertEq(received, 100e6);
        assertEq(released, 40e6);
        assertEq(businessReleased, 0);
        assertEq(market.lastBuyer(), alice);
        assertEq(market.lastBuyerAccountId(), 1);
        assertEq(market.lastSellerAccountId(), 8);
        assertEq(market.lastRechargeTarget(), 12);
        assertEq(market.lastAmount(), 40e6);

        vm.prank(alice);
        vm.expectRevert("Owner release exceeds received");
        merchant.tradeOut(alice, 1, 8, 12, 1, "");
    }

    function testBusinessCanReleaseOnlyItsReceivedAmount() public {
        market.executeTradeCallback(executor, address(merchant), alice, 7, 100e6, 1);

        vm.prank(business);
        merchant.tradeOut(alice, 1, 8, 12, 60e6, "");

        (uint256 received, uint256 released) = merchant.businessFlow(40000);
        (, uint256 ownerReleased) = merchant.accountOwnerFlow(alice, 40000);
        assertEq(received, 100e6);
        assertEq(released, 60e6);
        assertEq(ownerReleased, 0);

        vm.prank(business);
        vm.expectRevert("Business release exceeds received");
        merchant.tradeOut(alice, 1, 8, 12, 1, "");
    }

    function testAccountOwnerCannotReleaseThroughAnotherOwnersAccount() public {
        merchant.setAccountOwnerSupport(bob, true);
        market.setAccount(2, bob, address(merchant), 20000, true);
        market.executeTradeCallback(executor, address(merchant), bob, 7, 100e6, 1);

        vm.prank(alice);
        vm.expectRevert("Only account owner or business");
        merchant.tradeOut(bob, 2, 8, 12, 1, "");
    }

    function testOwnableAdminHasNoImplicitTradeOutAuthority() public {
        market.executeTradeCallback(executor, address(merchant), alice, 7, 100e6, 1);

        vm.expectRevert("Only account owner or business");
        merchant.tradeOut(alice, 1, 8, 12, 1, "");
    }

    function testChangedMultiplierCannotReleaseAbsorptionFromOldBucket() public {
        market.executeTradeCallback(executor, address(merchant), alice, 7, 100e6, 1);
        market.setMultiplier(1, 30000);

        vm.prank(alice);
        vm.expectRevert("Owner release exceeds received");
        merchant.tradeOut(alice, 1, 8, 12, 1, "");

        (uint256 oldReceived, uint256 oldReleased) = merchant.accountOwnerFlow(alice, 40000);
        assertEq(oldReceived, 100e6);
        assertEq(oldReleased, 0);
    }

    function testBuyerMustMatchBuyerAccountOwner() public {
        market.executeTradeCallback(executor, address(merchant), alice, 7, 100e6, 1);

        vm.prank(alice);
        vm.expectRevert("Buyer/account mismatch");
        merchant.tradeOut(bob, 1, 8, 12, 1, "");
    }

    function testOnlyMerchantOwnerCanChangeAccountOwnerSupport() public {
        vm.prank(bob);
        vm.expectRevert();
        merchant.setAccountOwnerSupport(bob, true);

        merchant.setAccountOwnerSupport(bob, true);
        assertTrue(merchant.isAccountOwnerSupported(bob));

        merchant.setAccountOwnerSupport(bob, false);
        assertFalse(merchant.isAccountOwnerSupported(bob));
    }

    function testSharesAreConfiguredAtInitialization() public view {
        (uint256 ownerShare, uint256 businessShare) = merchant.releaseShares();
        assertEq(ownerShare, 4000);
        assertEq(businessShare, 6000);
    }

    function testInvalidShareTotalReverts() public {
        MerchantBaseHarness implementation = new MerchantBaseHarness();
        vm.expectRevert("Invalid release shares");
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                MerchantBaseHarness.initialize,
                (address(market), address(token), alice, address(executor), business, 6000, 6000)
            )
        );
    }

    function testFractionalReceiptsAccumulateBeforeApplyingShare() public {
        market.executeTradeCallback(executor, address(merchant), alice, 1, 1, 1);
        market.executeTradeCallback(executor, address(merchant), alice, 1, 2, 2);
        vm.prank(alice);
        merchant.tradeOut(alice, 1, 8, 1, 1, ""); // floor(3 * 40%) = 1
        vm.prank(business);
        merchant.tradeOut(alice, 1, 8, 1, 1, ""); // floor(3 * 60%) = 1
        vm.prank(alice);
        vm.expectRevert("Owner release exceeds received");
        merchant.tradeOut(alice, 1, 8, 1, 1, "");
        vm.prank(business);
        vm.expectRevert("Business release exceeds received");
        merchant.tradeOut(alice, 1, 8, 1, 1, "");
    }

    function testFuzzCombinedReleaseSharesNeverExceedReceipts(uint96 a, uint96 b, uint16 share) public {
        uint256 ownerShare = bound(share, 0, 10000);
        uint256 receivedA = bound(a, 1, 1e24);
        uint256 receivedB = bound(b, 1, 1e24);
        MerchantBaseHarness implementation = new MerchantBaseHarness();
        MerchantBaseHarness platform = MerchantBaseHarness(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        MerchantBaseHarness.initialize,
                        (
                            address(market),
                            address(token),
                            alice,
                            address(executor),
                            business,
                            ownerShare,
                            10000 - ownerShare
                        )
                    )
                )
            )
        );
        platform.setAccountOwnerSupport(bob, true);
        market.setAccount(11, alice, address(platform), 40000, true);
        market.setAccount(12, bob, address(platform), 40000, true);
        market.executeTradeCallback(executor, address(platform), alice, 1, receivedA, 0);
        market.executeTradeCallback(executor, address(platform), bob, 1, receivedB, 0);
        uint256 aLimit = receivedA * ownerShare / 10000;
        uint256 bLimit = receivedB * ownerShare / 10000;
        uint256 businessLimit = (receivedA + receivedB) * (10000 - ownerShare) / 10000;
        if (aLimit > 0) {
            vm.prank(alice);
            platform.tradeOut(alice, 11, 8, 1, aLimit, "");
        }
        if (bLimit > 0) {
            vm.prank(bob);
            platform.tradeOut(bob, 12, 8, 1, bLimit, "");
        }
        if (businessLimit > 0) {
            vm.prank(business);
            platform.tradeOut(alice, 11, 8, 1, businessLimit, "");
        }
        (, uint256 aReleased) = platform.accountOwnerFlow(alice, 40000);
        (, uint256 bReleased) = platform.accountOwnerFlow(bob, 40000);
        (, uint256 businessReleased) = platform.businessFlow(40000);
        assertLe(aReleased + bReleased + businessReleased, receivedA + receivedB);
        vm.prank(alice);
        vm.expectRevert("Owner release exceeds received");
        platform.tradeOut(alice, 11, 8, 1, 1, "");
        vm.prank(business);
        vm.expectRevert("Business release exceeds received");
        platform.tradeOut(alice, 11, 8, 1, 1, "");
    }
}
