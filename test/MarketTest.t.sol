// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/Market.sol";
import "../src/TradeExecutor.sol";
import "../src/settlement/ERC20SettlementAsset.sol";
import "../src/interfaces/IMerchantTradeIn.sol";
import "../src/RightsToken/ProportionalElection.sol";
import "../src/RightsToken/SeatTokenFactory.sol";
import "../src/RightsToken/GenesisSeatToken.sol";
import "../src/Governor/FinalGovernor.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockBusiness is IMerchantTradeIn {
    address public immutable supportedRightsOwner;
    address public lastRightsOwner;
    uint160 public lastRechargeTarget;
    uint256 public lastAmount;
    uint256 public lastDeltaW;
    bytes32 public lastDataHash;

    constructor(address _supportedRightsOwner) {
        supportedRightsOwner = _supportedRightsOwner;
    }

    function tradeIn(
        address rightsOwner,
        uint160 rechargeTarget,
        uint256 netAmount,
        uint256 deltaW,
        bytes calldata data
    ) external override {
        require(rightsOwner == supportedRightsOwner, "Unsupported rights owner");
        lastRightsOwner = rightsOwner;
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
    address public merchantOwner = address(0x5);
    address public vault = address(0x999);

    uint256 public constant INITIAL_BALANCE = 10000e6;
    uint256 public constant DEFAULT_MULTIPLIER = 40000;

    function setUp() public {
        vm.warp(365 days + 30 days);
        vm.startPrank(admin);

        usdc = new MockUSDC();
        ERC20SettlementAsset settlementImpl = new ERC20SettlementAsset();
        bytes memory settlementInitData =
            abi.encodeWithSelector(ERC20SettlementAsset.initialize.selector, address(usdc), admin);
        settlementAsset = ERC20SettlementAsset(address(new ERC1967Proxy(address(settlementImpl), settlementInitData)));
        merchantContract = new MockBusiness(merchantOwner);

        buyerFactory = new SeatTokenFactory();
        sellerFactory = new SeatTokenFactory();

        GenesisSeatToken buyerGenesisSeat = new GenesisSeatToken("Council Seat 0", "CS", admin);
        GenesisSeatToken sellerGenesisSeat = new GenesisSeatToken("Council Seat 0", "CS", admin);
        buyerGenesisSeat.mint(admin, 100 * 1e18);
        sellerGenesisSeat.mint(admin, 100 * 1e18);

        ProportionalElection buyerElectionImpl = new ProportionalElection();
        buyerElection = ProportionalElection(
            address(
                new ERC1967Proxy(
                    address(buyerElectionImpl),
                    abi.encodeWithSelector(
                        ProportionalElection.initialize.selector,
                        address(buyerFactory),
                        admin,
                        address(buyerGenesisSeat)
                    )
                )
            )
        );

        ProportionalElection sellerElectionImpl = new ProportionalElection();
        sellerElection = ProportionalElection(
            address(
                new ERC1967Proxy(
                    address(sellerElectionImpl),
                    abi.encodeWithSelector(
                        ProportionalElection.initialize.selector,
                        address(sellerFactory),
                        admin,
                        address(sellerGenesisSeat)
                    )
                )
            )
        );

        buyerGenesisSeat.setMinter(address(buyerElection));
        sellerGenesisSeat.setMinter(address(sellerElection));
        buyerFactory.setElectionContract(address(buyerElection));
        sellerFactory.setElectionContract(address(sellerElection));

        address[] memory proposers = new address[](0);
        address[] memory executorsGov = new address[](1);
        executorsGov[0] = address(0);
        timelock = new TimelockController(0, proposers, executorsGov, admin);

        Market marketImpl = new Market();
        market = Market(
            address(
                new ERC1967Proxy(
                    address(marketImpl),
                    abi.encodeWithSelector(
                        Market.initialize.selector,
                        address(settlementAsset),
                        address(buyerElection),
                        address(sellerElection),
                        address(timelock),
                        vault
                    )
                )
            )
        );

        executor = new TradeExecutor(address(market), address(settlementAsset));
        market.setExecutor(address(executor));
        settlementAsset.setController(address(market), true);
        settlementAsset.setController(address(executor), true);
        buyerElection.setMinter(address(market));
        sellerElection.setMinter(address(market));

        FinalGovernor governorImpl = new FinalGovernor();
        governor = FinalGovernor(
            payable(address(
                    new ERC1967Proxy(
                        address(governorImpl),
                        abi.encodeWithSelector(
                            FinalGovernor.initialize.selector,
                            IVotes(address(buyerElection)),
                            IVotes(address(sellerElection)),
                            timelock
                        )
                    )
                ))
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
        usdc.mint(merchantOwner, INITIAL_BALANCE);
    }

    function _register(address owner, address merchant, uint256 deposit) internal returns (uint256 accountId) {
        return _register(owner, merchant, deposit, DEFAULT_MULTIPLIER);
    }

    function _register(address owner, address merchant, uint256 deposit, uint256 multiplier)
        internal
        returns (uint256 accountId)
    {
        vm.startPrank(owner);
        usdc.approve(address(settlementAsset), deposit);
        accountId = market.registerMerchant(merchant, deposit, multiplier);
        vm.stopPrank();
    }

    function _trade(address payer, address buyer, uint256 buyerAccountId, uint256 sellerAccountId, uint256 amount)
        internal
    {
        vm.startPrank(payer);
        usdc.approve(address(settlementAsset), amount);
        market.trade(buyer, buyerAccountId, sellerAccountId, uint160(buyer), amount, "");
        vm.stopPrank();
    }

    function testMerchantRegistration() public {
        uint256 depositAmount = 1000e6;
        uint256 accountId = _register(bob, bob, depositAmount);

        (address owner, address merchant, uint256 deposit, uint256 multiplier, bool isActive) =
            market.accounts(accountId);

        assertEq(owner, bob);
        assertEq(merchant, bob);
        assertEq(deposit, depositAmount);
        assertEq(multiplier, DEFAULT_MULTIPLIER);
        assertTrue(isActive);
        assertEq(market.accountIdOf(bob, bob), accountId);
        assertEq(market.netTradeBalance(accountId), 0);
        assertEq(market.deferredSurplus(accountId), 0);
        assertEq(market.taxableSurplus(accountId), 0);
    }

    function testMinimumCapacityMultiplierIsOneThousand() public {
        uint256 accountId = _register(bob, bob, 1000e6, 1000);
        (,,, uint256 multiplier,) = market.accounts(accountId);
        assertEq(multiplier, 1000);
        assertEq(market.MIN_CAPACITY_MULTIPLIER(), 1000);

        vm.startPrank(charlie);
        usdc.approve(address(settlementAsset), 1000e6);
        vm.expectRevert("Invalid capacity multiplier");
        market.registerMerchant(charlie, 1000e6, 999);
        vm.stopPrank();

        assertEq(market.accountIdOf(charlie, charlie), 0);
    }

    function testZeroBuyerAccountCreatesAndReusesDefaultAccount() public {
        uint256 sellerAccountId = _register(bob, bob, 1000e6);

        _trade(alice, alice, 0, sellerAccountId, 100e6);
        uint256 defaultAccountId = market.accountIdOf(alice, alice);
        assertTrue(defaultAccountId != 0);

        (address owner, address merchant, uint256 deposit, uint256 multiplier, bool isActive) =
            market.accounts(defaultAccountId);
        assertEq(owner, alice);
        assertEq(merchant, alice);
        assertEq(deposit, 0);
        assertEq(multiplier, 0);
        assertFalse(isActive);
        assertEq(market.netTradeBalance(defaultAccountId), -99e6);

        _trade(charlie, alice, 0, sellerAccountId, 10e6);
        assertEq(market.accountIdOf(alice, alice), defaultAccountId);
        assertEq(market.netTradeBalance(defaultAccountId), -108900000);
        assertEq(market.deferredSurplus(defaultAccountId), 0);
    }

    function testLazyDefaultAccountCanLaterBecomeMerchant() public {
        uint256 sellerAccountId = _register(bob, bob, 1000e6);
        _trade(alice, alice, 0, sellerAccountId, 100e6);

        uint256 defaultAccountId = market.accountIdOf(alice, alice);
        int256 balanceBefore = market.netTradeBalance(defaultAccountId);
        uint256 registeredId = _register(alice, alice, 1000e6);

        assertEq(registeredId, defaultAccountId);
        assertEq(market.netTradeBalance(registeredId), balanceBefore);
        (,, uint256 deposit, uint256 multiplier, bool isActive) = market.accounts(registeredId);
        assertEq(deposit, 1000e6);
        assertEq(multiplier, DEFAULT_MULTIPLIER);
        assertTrue(isActive);
    }

    function testTradeAndPoints() public {
        uint256 depositAmount = 1000e6;
        uint256 sellerAccountId = _register(merchantOwner, address(merchantContract), depositAmount);
        uint256 tradeAmount = 100e6;
        (uint256 expectedW, uint256 expectedS) = market.calculateAMM(sellerAccountId, tradeAmount);

        uint256 marketBalBefore = usdc.balanceOf(address(settlementAsset));
        uint256 merchantBalBefore = usdc.balanceOf(address(merchantContract));
        uint256 vaultBalBefore = usdc.balanceOf(vault);
        bytes memory data = abi.encode("test recharge payload");

        vm.startPrank(alice);
        usdc.approve(address(settlementAsset), tradeAmount);
        market.trade(alice, 0, sellerAccountId, uint160(alice), tradeAmount, data);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(merchantContract)) - merchantBalBefore, expectedW);
        assertEq(usdc.balanceOf(vault) - vaultBalBefore, tradeAmount / 100);
        assertEq(usdc.balanceOf(address(settlementAsset)) - marketBalBefore, expectedS);
        assertEq(merchantContract.lastRightsOwner(), merchantOwner);
        assertEq(merchantContract.lastRechargeTarget(), uint160(alice));
        assertEq(merchantContract.lastAmount(), tradeAmount - (tradeAmount / 100));
        assertEq(merchantContract.lastDeltaW(), expectedW);
        assertEq(merchantContract.lastDataHash(), keccak256(data));
        assertEq(market.sellerPoints(sellerAccountId), expectedS);

        vm.warp(block.timestamp + 31 days);
        assertEq(buyerElection.getVotes(alice), 100 * 1e18);
        assertEq(sellerElection.getVotes(merchantOwner), 100 * 1e18);
        assertEq(sellerElection.getVotes(address(merchantContract)), 0);
    }

    function testGlobalAMMParamsAffectExistingAccount() public {
        uint256 sellerAccountId = _register(bob, bob, 1000e6);
        uint256 tradeAmount = 100e6;
        (uint256 oldW, uint256 oldS) = market.calculateAMM(sellerAccountId, tradeAmount);

        vm.prank(address(timelock));
        market.setGlobalAMMParams(1800, 3);
        (uint256 newW, uint256 newS) = market.calculateAMM(sellerAccountId, tradeAmount);
        assertTrue(oldW != newW || oldS != newS);

        uint256 pointsBefore = market.sellerPoints(sellerAccountId);
        uint256 bobBalanceBefore = usdc.balanceOf(bob);
        _trade(alice, alice, 0, sellerAccountId, tradeAmount);
        assertEq(usdc.balanceOf(bob) - bobBalanceBefore, newW);
        assertEq(market.sellerPoints(sellerAccountId) - pointsBefore, newS);
    }

    function testResolvedBalanceDoesNotRefundImmediately() public {
        uint256 buyerAccountId = _register(alice, bob, 1000e6);
        uint256 sellerAccountId = _register(charlie, charlie, 1000e6);

        _trade(charlie, charlie, 0, buyerAccountId, 100e6);
        uint256 pointsBefore = market.sellerPoints(buyerAccountId);
        uint256 amount = 200e6;

        uint256 payerBalanceBefore = usdc.balanceOf(bob);
        _trade(bob, alice, buyerAccountId, sellerAccountId, amount);

        assertEq(payerBalanceBefore - usdc.balanceOf(bob), amount);
        assertEq(market.sellerPoints(buyerAccountId), pointsBefore);
        assertEq(market.claimed(buyerAccountId), 0);
        assertEq(market.deferredSurplus(buyerAccountId), 99e6);
        assertEq(market.taxableSurplus(buyerAccountId), 99e6);
    }

    function testNormalSurplusReductionRefundsWithoutAmountQuota() public {
        uint256 buyerAccountId = _register(alice, alice, 1000e6);
        uint256 sellerAccountId = _register(bob, bob, 1000e6);

        _trade(charlie, charlie, 0, buyerAccountId, 100e6);
        uint256 pointsBefore = market.sellerPoints(buyerAccountId);
        uint256 payerBalanceBefore = usdc.balanceOf(alice);

        _trade(alice, alice, buyerAccountId, sellerAccountId, 100e6);

        assertEq(payerBalanceBefore - usdc.balanceOf(alice), 100e6 - pointsBefore);
        assertEq(market.sellerPoints(buyerAccountId), 0);
        assertEq(market.claimed(buyerAccountId), pointsBefore);
        assertEq(market.deferredSurplus(buyerAccountId), 0);
    }

    function testCrossingZeroOnlyDefersMatchedResolution() public {
        uint256 buyerAccountId = _register(alice, alice, 1000e6);
        uint256 sellerAccountId = _register(charlie, charlie, 1000e6);
        uint256 fundingSellerAccountId = _register(bob, bob, 1000e6);

        _trade(merchantOwner, merchantOwner, 0, buyerAccountId, 1000e6);
        _trade(charlie, charlie, sellerAccountId, fundingSellerAccountId, 100e6);
        _trade(alice, alice, buyerAccountId, sellerAccountId, 200e6);

        assertEq(market.netTradeBalance(buyerAccountId), 792e6);
        assertEq(market.netTradeBalance(sellerAccountId), 99e6);
        assertEq(market.deferredSurplus(buyerAccountId), 99e6);
        assertEq(market.taxableSurplus(buyerAccountId), 891e6);
    }

    function testDeferredSurplusDecaysLinearlyWithDeposit() public {
        uint256 buyerAccountId = _register(alice, alice, 1000e6);
        uint256 sellerAccountId = _register(charlie, charlie, 1000e6);

        _trade(charlie, charlie, sellerAccountId, buyerAccountId, 1000e6);
        _trade(alice, alice, buyerAccountId, sellerAccountId, 2000e6);
        assertEq(market.deferredSurplus(buyerAccountId), 990e6);

        uint256 startTime = vm.getBlockTimestamp();
        vm.warp(startTime + 15 days);
        assertEq(market.deferredSurplus(buyerAccountId), 740e6);

        vm.warp(startTime + 30 days);
        assertEq(market.deferredSurplus(buyerAccountId), 490e6);
    }

    function testReleasedDeferredSurplusRefundsOnNextAuthorizedTrade() public {
        uint256 buyerAccountId = _register(alice, alice, 1000e6);
        uint256 resolvingSellerAccountId = _register(charlie, charlie, 1000e6);
        uint256 nextSellerAccountId = _register(bob, bob, 1000e6);

        _trade(charlie, charlie, resolvingSellerAccountId, buyerAccountId, 1000e6);
        _trade(alice, alice, buyerAccountId, resolvingSellerAccountId, 2000e6);

        vm.warp(vm.getBlockTimestamp() + 15 days);
        uint256 pointsBefore = market.sellerPoints(buyerAccountId);
        uint256 newTax = market.accountCurveTax(buyerAccountId, 0);
        uint256 expectedRefund = pointsBefore - newTax;
        uint256 payerBalanceBefore = usdc.balanceOf(alice);

        _trade(alice, alice, buyerAccountId, nextSellerAccountId, 100e6);

        assertEq(payerBalanceBefore - usdc.balanceOf(alice), 100e6 - expectedRefund);
        assertEq(market.sellerPoints(buyerAccountId), newTax);
        assertEq(market.claimed(buyerAccountId), expectedRefund);
    }

    function testAddedDepositOnlyAcceleratesFutureDeferredRelease() public {
        uint256 buyerAccountId = _register(alice, alice, 1000e6);
        uint256 sellerAccountId = _register(charlie, charlie, 1000e6);

        _trade(charlie, charlie, sellerAccountId, buyerAccountId, 1000e6);
        _trade(alice, alice, buyerAccountId, sellerAccountId, 2000e6);

        uint256 startTime = vm.getBlockTimestamp();
        vm.warp(startTime + 15 days);
        vm.startPrank(bob);
        usdc.approve(address(settlementAsset), 1000e6);
        market.addDeposit(buyerAccountId, 1000e6);
        vm.stopPrank();
        assertEq(market.deferredSurplus(buyerAccountId), 740e6);

        vm.warp(startTime + 30 days);
        assertEq(market.deferredSurplus(buyerAccountId), 240e6);
    }

    function testResolutionRatioChangeOnlyAffectsFutureRelease() public {
        uint256 buyerAccountId = _register(alice, alice, 1000e6);
        uint256 sellerAccountId = _register(charlie, charlie, 1000e6);

        _trade(charlie, charlie, sellerAccountId, buyerAccountId, 1000e6);
        _trade(alice, alice, buyerAccountId, sellerAccountId, 2000e6);

        uint256 startTime = vm.getBlockTimestamp();
        vm.warp(startTime + 15 days);
        vm.prank(address(timelock));
        market.setResolutionParams(10000);
        vm.warp(startTime + 15 days + 15 days / 2);

        assertEq(market.deferredSurplus(buyerAccountId), 490e6);
    }

    function testDeferredSurplusCountsTowardStricterCapacity() public {
        uint256 buyerAccountId = _register(alice, alice, 1000e6);
        uint256 sellerAccountId = _register(charlie, charlie, 1000e6);

        _trade(charlie, charlie, sellerAccountId, buyerAccountId, 2000e6);
        _trade(alice, alice, buyerAccountId, sellerAccountId, 4000e6);
        assertEq(market.netTradeBalance(buyerAccountId), -1980e6);
        assertEq(market.deferredSurplus(buyerAccountId), 1980e6);

        vm.prank(alice);
        vm.expectRevert("Capacity exceeded");
        market.setCapacityMultiplier(buyerAccountId, 10000);

        vm.prank(alice);
        market.setCapacityMultiplier(buyerAccountId, 20000);
    }

    function testOwnerCannotUseDifferentMerchantsRefund() public {
        uint256 buyerAccountId = _register(alice, bob, 1000e6);
        uint256 sellerAccountId = _register(charlie, charlie, 1000e6);
        _trade(charlie, charlie, 0, buyerAccountId, 100e6);

        uint256 pointsBefore = market.sellerPoints(buyerAccountId);
        uint256 balanceBefore = usdc.balanceOf(alice);
        _trade(alice, alice, buyerAccountId, sellerAccountId, 200e6);

        assertEq(balanceBefore - usdc.balanceOf(alice), 200e6);
        assertEq(market.sellerPoints(buyerAccountId), pointsBefore);
        assertEq(market.claimed(buyerAccountId), 0);
        assertEq(market.deferredSurplus(buyerAccountId), 99e6);
    }

    function testThirdPartyCanPayForRegisteredAccountButCannotRefund() public {
        uint256 buyerAccountId = _register(alice, bob, 1000e6);
        uint256 sellerAccountId = _register(charlie, charlie, 1000e6);
        _trade(charlie, charlie, 0, buyerAccountId, 100e6);

        uint256 pointsBefore = market.sellerPoints(buyerAccountId);
        uint256 payerBalanceBefore = usdc.balanceOf(merchantOwner);
        _trade(merchantOwner, alice, buyerAccountId, sellerAccountId, 200e6);

        assertEq(payerBalanceBefore - usdc.balanceOf(merchantOwner), 200e6);
        assertEq(market.sellerPoints(buyerAccountId), pointsBefore);
        assertEq(market.claimed(buyerAccountId), 0);
        assertEq(market.deferredSurplus(buyerAccountId), 99e6);

        vm.warp(block.timestamp + 31 days);
        assertTrue(buyerElection.getVotes(alice) > 0);
        assertEq(buyerElection.getVotes(bob), 0);
    }

    function testExplicitBuyerAccountMustBelongToBuyer() public {
        uint256 aliceAccountId = _register(alice, bob, 1000e6);
        uint256 sellerAccountId = _register(charlie, charlie, 1000e6);

        vm.startPrank(merchantOwner);
        usdc.approve(address(settlementAsset), 100e6);
        vm.expectRevert("Buyer is not account owner");
        market.trade(bob, aliceAccountId, sellerAccountId, uint160(bob), 100e6, "");
        vm.stopPrank();
    }

    function testOwnerDepositPaysFullAndLeavesCollectedTaxUntouched() public {
        uint256 accountId = _register(alice, bob, 1000e6);
        _trade(charlie, charlie, 0, accountId, 100e6);

        uint256 pointsBefore = market.sellerPoints(accountId);
        uint256 additionalDeposit = 1000e6;

        uint256 ownerBalanceBefore = usdc.balanceOf(alice);
        uint256 merchantBalanceBefore = usdc.balanceOf(bob);
        vm.startPrank(alice);
        usdc.approve(address(settlementAsset), additionalDeposit);
        market.addDeposit(accountId, additionalDeposit);
        vm.stopPrank();

        assertEq(ownerBalanceBefore - usdc.balanceOf(alice), additionalDeposit);
        assertEq(usdc.balanceOf(bob), merchantBalanceBefore);
        assertEq(market.sellerPoints(accountId), pointsBefore);
        assertEq(market.claimed(accountId), 0);
        assertEq(market.deferredSurplus(accountId), 0);
    }

    function testThirdPartyDepositPaysFullAndExcessRefundIsCapped() public {
        uint256 buyerAccountId = _register(alice, alice, 1000e6);
        uint256 sellerAccountId = _register(charlie, charlie, 1000e6);

        _trade(charlie, charlie, 0, buyerAccountId, 3500e6);
        uint256 pointsBeforeDeposit = market.sellerPoints(buyerAccountId);

        uint256 bobBalanceBefore = usdc.balanceOf(bob);
        vm.startPrank(bob);
        usdc.approve(address(settlementAsset), 1000e6);
        market.addDeposit(buyerAccountId, 1000e6);
        vm.stopPrank();

        assertEq(bobBalanceBefore - usdc.balanceOf(bob), 1000e6);
        assertEq(market.sellerPoints(buyerAccountId), pointsBeforeDeposit);

        uint256 amount = 100e6;
        uint256 tradeValue = amount - (amount / 100);
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        _trade(alice, alice, buyerAccountId, sellerAccountId, amount);

        assertEq(
            aliceBalanceBefore - usdc.balanceOf(alice),
            amount - tradeValue,
            "Only the non-refundable rights fee should be paid"
        );
        assertEq(market.sellerPoints(buyerAccountId), pointsBeforeDeposit - tradeValue);
    }

    function testMultiplierHierarchyAndExternalFunds() public {
        uint256 buyerAccountId = _register(alice, bob, 1000e6, 20000);
        uint256 sellerAccountId = _register(charlie, charlie, 1000e6, 30000);

        vm.startPrank(bob);
        usdc.approve(address(settlementAsset), 100e6);
        vm.expectRevert("Seller multiplier too high");
        market.trade(alice, buyerAccountId, sellerAccountId, uint160(alice), 100e6, "");
        vm.stopPrank();

        _trade(merchantOwner, merchantOwner, 0, sellerAccountId, 100e6);
        assertTrue(market.accountIdOf(merchantOwner, merchantOwner) != 0);
    }

    function testOnlyOwnerCanMakeMultiplierStricter() public {
        uint256 accountId = _register(alice, bob, 1000e6, 40000);

        vm.prank(bob);
        vm.expectRevert("Only account owner");
        market.setCapacityMultiplier(accountId, 30000);

        vm.prank(alice);
        market.setCapacityMultiplier(accountId, 30000);
        (,,, uint256 multiplier,) = market.accounts(accountId);
        assertEq(multiplier, 30000);

        vm.prank(alice);
        vm.expectRevert("Multiplier can only decrease");
        market.setCapacityMultiplier(accountId, 40000);

        vm.prank(alice);
        vm.expectRevert("Invalid capacity multiplier");
        market.setCapacityMultiplier(accountId, 999);
    }

    function testMerchantCanChooseWhichOwnersItSupports() public {
        uint256 supportedId = _register(merchantOwner, address(merchantContract), 1000e6);
        uint256 unsupportedId = _register(charlie, address(merchantContract), 1000e6);
        assertTrue(supportedId != unsupportedId);

        _trade(alice, alice, 0, supportedId, 100e6);

        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        vm.startPrank(alice);
        usdc.approve(address(settlementAsset), 100e6);
        vm.expectRevert("Unsupported rights owner");
        market.trade(alice, 0, unsupportedId, uint160(alice), 100e6, "");
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), aliceBalanceBefore);
        assertEq(market.netTradeBalance(unsupportedId), 0);
        assertEq(market.sellerPoints(unsupportedId), 0);
    }

    function testGovernanceKickDeletesPairAccountState() public {
        uint256 bobAccountId = _register(bob, bob, 1000e6);
        uint256 charlieAccountId = _register(charlie, charlie, 1000e6);
        _trade(charlie, charlie, charlieAccountId, bobAccountId, 50e6);
        _trade(bob, bob, bobAccountId, charlieAccountId, 50e6);

        uint256 surplusBefore = market.taxableSurplus(bobAccountId);
        uint256 pointsBefore = market.sellerPoints(bobAccountId);
        uint256 vaultBalanceBefore = usdc.balanceOf(vault);
        uint256 bobBalanceBefore = usdc.balanceOf(bob);
        assertEq(market.claimed(bobAccountId), 0);
        assertEq(market.deferredSurplus(bobAccountId), 49.5e6);

        vm.prank(alice);
        vm.expectRevert("Only governance");
        market.kickMerchant(bobAccountId);

        vm.prank(address(timelock));
        market.kickMerchant(bobAccountId);

        (address owner, address merchant,,, bool isActive) = market.accounts(bobAccountId);
        assertEq(owner, address(0));
        assertEq(merchant, address(0));
        assertFalse(isActive);
        assertEq(market.accountIdOf(bob, bob), 0);
        assertEq(market.sellerPoints(bobAccountId), 0);
        assertEq(market.claimed(bobAccountId), 0);
        assertEq(market.netTradeBalance(bobAccountId), 0);
        assertEq(market.deferredSurplus(bobAccountId), 0);
        assertEq(usdc.balanceOf(vault) - vaultBalanceBefore, surplusBefore);
        assertEq(usdc.balanceOf(bob) - bobBalanceBefore, 1000e6 + pointsBefore - surplusBefore);

        uint256 newAccountId = _register(bob, bob, 100e6);
        assertTrue(newAccountId != bobAccountId);
    }

    function testDualConsensusVotingLogic() public {
        testTradeAndPoints();
        vm.warp(block.timestamp + 31 days);
        vm.roll(block.number + 100);

        address[] memory targets = new address[](1);
        targets[0] = address(market);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("setVault(address)", address(0xdead));

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, "Change Vault Address");
        vm.warp(block.timestamp + 7201);
        vm.roll(block.number + 7201);

        vm.prank(alice);
        governor.castVote(proposalId, 1);
        (, uint256 forVotes,) = governor.proposalVotes(proposalId);
        assertEq(forVotes, 0);

        vm.prank(merchantOwner);
        governor.castVote(proposalId, 1);
        (, forVotes,) = governor.proposalVotes(proposalId);
        assertEq(forVotes, 100 * 1e18);
    }
}
