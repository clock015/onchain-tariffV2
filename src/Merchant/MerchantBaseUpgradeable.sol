// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "../interfaces/IMarket.sol";
import "../interfaces/IMerchantTradeIn.sol";

abstract contract MerchantBase is Initializable, OwnableUpgradeable, UUPSUpgradeable, IMerchantTradeIn {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10000;

    struct FlowBucket {
        uint256 received;
        uint256 released;
    }

    struct MerchantBaseStorage {
        address market;
        IERC20 underlying;
        address settlementAsset;
        address tradeExecutor;
        address business;
        mapping(address => bool) supportedAccountOwners;
        mapping(address => mapping(uint256 => FlowBucket)) accountOwnerFlows;
        mapping(uint256 => FlowBucket) businessFlows;
        uint256 ownerShareBps;
        uint256 businessShareBps;
    }

    bytes32 private constant MerchantBaseStorageLocation =
        0x56a421008746973f1d5e3f43501a37c9508c90333d0e376044791307b2298600;

    function _getMerchantBaseStorage() private pure returns (MerchantBaseStorage storage $) {
        assembly {
            $.slot := MerchantBaseStorageLocation
        }
    }

    event TradeExecutorUpdated(address indexed oldTradeExecutor, address indexed newTradeExecutor);
    event BusinessUpdated(address indexed oldBusiness, address indexed newBusiness);
    event AccountOwnerSupportUpdated(address indexed accountOwner, bool supported);
    event ReleaseSharesConfigured(uint256 ownerShareBps, uint256 businessShareBps);
    event SaleRecorded(
        uint256 indexed accountId,
        address indexed accountOwner,
        uint160 indexed rechargeTarget,
        uint256 capacityMultiplier,
        uint256 netAmount
    );
    event AccountOwnerReleaseRecorded(
        uint256 indexed accountId, address indexed accountOwner, uint256 indexed capacityMultiplier, uint256 amount
    );
    event BusinessReleaseRecorded(uint256 indexed accountId, uint256 indexed capacityMultiplier, uint256 amount);

    modifier onlyTradeExecutor() {
        require(msg.sender == _getMerchantBaseStorage().tradeExecutor, "Only trade executor");
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function __MerchantBase_init(
        address _market,
        address _underlying,
        address _initialAccountOwner,
        address _tradeExecutor,
        address _business,
        uint256 _ownerShareBps,
        uint256 _businessShareBps
    ) internal onlyInitializing {
        require(_initialAccountOwner != address(0), "Invalid account owner");
        require(_ownerShareBps <= BPS && _businessShareBps == BPS - _ownerShareBps, "Invalid release shares");
        __Ownable_init(msg.sender);

        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        $.market = _market;
        $.underlying = IERC20(_underlying);
        $.settlementAsset = IMarket(_market).settlementAsset();
        $.supportedAccountOwners[_initialAccountOwner] = true;
        $.tradeExecutor = _tradeExecutor;
        $.business = _business;
        // Fixed for this instance: changing shares would reallocate historical receipts.
        $.ownerShareBps = _ownerShareBps;
        $.businessShareBps = _businessShareBps;
        emit AccountOwnerSupportUpdated(_initialAccountOwner, true);
        emit ReleaseSharesConfigured(_ownerShareBps, _businessShareBps);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function market() public view returns (address) {
        return _getMerchantBaseStorage().market;
    }

    function underlying() public view returns (IERC20) {
        return _getMerchantBaseStorage().underlying;
    }

    function settlementAsset() public view returns (address) {
        return _getMerchantBaseStorage().settlementAsset;
    }

    function isAccountOwnerSupported(address accountOwner) public view returns (bool) {
        return _getMerchantBaseStorage().supportedAccountOwners[accountOwner];
    }

    function accountOwnerFlow(address accountOwner, uint256 capacityMultiplier)
        public
        view
        returns (uint256 received, uint256 released)
    {
        FlowBucket storage flow = _getMerchantBaseStorage().accountOwnerFlows[accountOwner][capacityMultiplier];
        return (flow.received, flow.released);
    }

    function businessFlow(uint256 capacityMultiplier) public view returns (uint256 received, uint256 released) {
        FlowBucket storage flow = _getMerchantBaseStorage().businessFlows[capacityMultiplier];
        return (flow.received, flow.released);
    }

    function tradeExecutor() public view returns (address) {
        return _getMerchantBaseStorage().tradeExecutor;
    }

    function business() public view returns (address) {
        return _getMerchantBaseStorage().business;
    }

    function releaseShares() public view returns (uint256 ownerShareBps, uint256 businessShareBps) {
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        return ($.ownerShareBps, $.businessShareBps);
    }

    function setTradeExecutor(address _newTradeExecutor) external virtual onlyOwner {
        require(_newTradeExecutor != address(0), "Invalid address");
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        address old = $.tradeExecutor;
        $.tradeExecutor = _newTradeExecutor;
        emit TradeExecutorUpdated(old, _newTradeExecutor);
    }

    function setBusiness(address _newBusiness) external virtual onlyOwner {
        require(_newBusiness != address(0), "Invalid address");
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        address old = $.business;
        $.business = _newBusiness;
        emit BusinessUpdated(old, _newBusiness);
    }

    function setAccountOwnerSupport(address accountOwner, bool supported) external virtual onlyOwner {
        require(accountOwner != address(0), "Invalid account owner");
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        require($.supportedAccountOwners[accountOwner] != supported, "Support unchanged");
        $.supportedAccountOwners[accountOwner] = supported;
        emit AccountOwnerSupportUpdated(accountOwner, supported);
    }

    function tradeOut(
        address buyer,
        uint256 buyerAccountId,
        uint256 sellerAccountId,
        uint160 rechargeTarget,
        uint256 amount,
        bytes calldata data
    ) public virtual {
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        (address accountOwner, address accountMerchant,, uint256 capacityMultiplier, bool isActive) =
            IMarket($.market).accounts(buyerAccountId);
        require(isActive, "Market account not active");
        require(accountMerchant == address(this), "Invalid market account");
        require(accountOwner == buyer, "Buyer/account mismatch");
        require($.supportedAccountOwners[accountOwner], "Unsupported account owner");

        if (msg.sender == $.business) {
            _recordBusinessRelease(buyerAccountId, capacityMultiplier, amount);
        } else {
            require(msg.sender == accountOwner, "Only account owner or business");
            _recordAccountOwnerRelease(buyerAccountId, accountOwner, capacityMultiplier, amount);
        }

        $.underlying.forceApprove($.settlementAsset, amount);
        IMarket($.market).trade(buyer, buyerAccountId, sellerAccountId, rechargeTarget, amount, data);
    }

    function tradeIn(
        address registeredRightsOwner,
        uint160 rechargeTarget,
        uint256 netAmount,
        uint256 deltaW,
        bytes calldata data
    ) external virtual override onlyTradeExecutor {
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        require($.supportedAccountOwners[registeredRightsOwner], "Unsupported account owner");

        uint256 accountId = IMarket($.market).accountIdOf(registeredRightsOwner, address(this));
        require(accountId != 0, "Market account not found");
        (address accountOwner, address accountMerchant,, uint256 capacityMultiplier, bool isActive) =
            IMarket($.market).accounts(accountId);
        require(isActive, "Market account not active");
        require(accountOwner == registeredRightsOwner && accountMerchant == address(this), "Invalid market account");

        $.accountOwnerFlows[registeredRightsOwner][capacityMultiplier].received += netAmount;
        $.businessFlows[capacityMultiplier].received += netAmount;
        emit SaleRecorded(accountId, registeredRightsOwner, rechargeTarget, capacityMultiplier, netAmount);
        _tradeIn(rechargeTarget, capacityMultiplier, netAmount, deltaW, data);
    }

    function _tradeIn(
        uint160 rechargeTarget,
        uint256 capacityMultiplier,
        uint256 netAmount,
        uint256 deltaW,
        bytes calldata data
    ) internal virtual;

    function _recordAccountOwnerRelease(
        uint256 accountId,
        address accountOwner,
        uint256 capacityMultiplier,
        uint256 amount
    ) private {
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        FlowBucket storage flow = $.accountOwnerFlows[accountOwner][capacityMultiplier];
        uint256 limit = Math.mulDiv(flow.received, $.ownerShareBps, BPS);
        require(amount <= limit - flow.released, "Owner release exceeds received");
        flow.released += amount;
        emit AccountOwnerReleaseRecorded(accountId, accountOwner, capacityMultiplier, amount);
    }

    function _recordBusinessRelease(uint256 accountId, uint256 capacityMultiplier, uint256 amount) private {
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        FlowBucket storage flow = $.businessFlows[capacityMultiplier];
        uint256 limit = Math.mulDiv(flow.received, $.businessShareBps, BPS);
        require(amount <= limit - flow.released, "Business release exceeds received");
        flow.released += amount;
        emit BusinessReleaseRecorded(accountId, capacityMultiplier, amount);
    }
}
