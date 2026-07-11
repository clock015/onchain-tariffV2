// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "../interfaces/IMarket.sol";
import "../interfaces/IMerchantTradeIn.sol";
import "../interfaces/IRightsToken.sol";

abstract contract MerchantBase is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    IMerchantTradeIn
{
    using SafeERC20 for IERC20;

    struct MerchantBaseStorage {
        address market;
        IERC20 underlying;
        address settlementAsset;
        address buyerElection;
        address sellerElection;
        address beneficiary;
        address tradeExecutor;
        address business;
        uint256 ownerBalance;
    }

    bytes32 private constant MerchantBaseStorageLocation =
        0x56a421008746973f1d5e3f43501a37c9508c90333d0e376044791307b2298600;

    function _getMerchantBaseStorage()
        private
        pure
        returns (MerchantBaseStorage storage $)
    {
        assembly {
            $.slot := MerchantBaseStorageLocation
        }
    }

    event BeneficiaryUpdated(
        address indexed oldBeneficiary,
        address indexed newBeneficiary
    );
    event TradeExecutorUpdated(
        address indexed oldTradeExecutor,
        address indexed newTradeExecutor
    );
    event BusinessUpdated(
        address indexed oldBusiness,
        address indexed newBusiness
    );
    event OwnerBalanceCredited(uint256 amount, uint256 newBalance);
    event OwnerBalanceSpent(uint256 amount, uint256 newBalance);

    modifier onlyTradeExecutor() {
        require(
            msg.sender == _getMerchantBaseStorage().tradeExecutor,
            "Only trade executor"
        );
        _;
    }

    modifier onlyBusiness() {
        require(
            msg.sender == _getMerchantBaseStorage().business,
            "Only business"
        );
        _;
    }

    modifier onlyOwnerOrBusiness() {
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        require(
            msg.sender == owner() || msg.sender == $.business,
            "Only owner or business"
        );
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function __MerchantBase_init(
        address _market,
        address _underlying,
        address _buyerElection,
        address _sellerElection,
        address _tradeExecutor,
        address _business
    ) internal onlyInitializing {
        __Ownable_init(msg.sender);

        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        $.market = _market;
        $.underlying = IERC20(_underlying);
        $.settlementAsset = IMarket(_market).settlementAsset();
        $.buyerElection = _buyerElection;
        $.sellerElection = _sellerElection;
        $.tradeExecutor = _tradeExecutor;
        $.business = _business;
        $.beneficiary = msg.sender;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    function market() public view returns (address) {
        return _getMerchantBaseStorage().market;
    }
    function underlying() public view returns (IERC20) {
        return _getMerchantBaseStorage().underlying;
    }
    function settlementAsset() public view returns (address) {
        return _getMerchantBaseStorage().settlementAsset;
    }
    function beneficiary() public view returns (address) {
        return _getMerchantBaseStorage().beneficiary;
    }
    function tradeExecutor() public view returns (address) {
        return _getMerchantBaseStorage().tradeExecutor;
    }
    function business() public view returns (address) {
        return _getMerchantBaseStorage().business;
    }
    function ownerBalance() public view returns (uint256) {
        return _getMerchantBaseStorage().ownerBalance;
    }

    function setBeneficiary(
        address _newBeneficiary
    ) external virtual onlyOwner {
        require(_newBeneficiary != address(0), "Invalid address");
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        address old = $.beneficiary;
        $.beneficiary = _newBeneficiary;
        emit BeneficiaryUpdated(old, _newBeneficiary);
    }

    function setTradeExecutor(
        address _newTradeExecutor
    ) external virtual onlyOwner {
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

    function creditOwnerBalance(uint256 amount) external virtual onlyBusiness {
        _creditOwnerBalance(amount);
    }

    function depositOwnerBalance(uint256 amount) external virtual onlyOwner {
        require(amount > 0, "Amount is zero");
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        $.underlying.safeTransferFrom(msg.sender, address(this), amount);
        _creditOwnerBalance(amount);
    }

    function register(uint256 amount) external virtual onlyOwner {
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        _spendOwnerBalance(amount);
        $.underlying.forceApprove($.settlementAsset, amount);
        IMarket($.market).registerMerchant(amount);
    }

    function tradeOut(
        address buyer,
        address merchant,
        uint160 rechargeTarget,
        uint256 amount,
        bytes calldata data
    ) public virtual onlyOwnerOrBusiness {
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        if (msg.sender == owner()) {
            _spendOwnerBalance(amount);
        }

        $.underlying.forceApprove($.settlementAsset, amount);
        IMarket($.market).trade(buyer, merchant, rechargeTarget, amount, data);
    }

    function tradeIn(
        uint160 rechargeTarget,
        uint256 netAmount,
        uint256 deltaW,
        bytes calldata data
    ) external virtual override onlyTradeExecutor {
        _tradeIn(rechargeTarget, netAmount, deltaW, data);
    }

    function _tradeIn(
        uint160 rechargeTarget,
        uint256 netAmount,
        uint256 deltaW,
        bytes calldata data
    ) internal virtual;


    function delegateVotesToBeneficiary() external virtual onlyOwner {
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        IRightsToken($.buyerElection).delegate($.beneficiary);
        IRightsToken($.sellerElection).delegate($.beneficiary);
    }

    function _creditOwnerBalance(uint256 amount) internal {
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        $.ownerBalance += amount;
        emit OwnerBalanceCredited(amount, $.ownerBalance);
    }

    function _spendOwnerBalance(uint256 amount) internal {
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        require($.ownerBalance >= amount, "Insufficient owner balance");
        $.ownerBalance -= amount;
        emit OwnerBalanceSpent(amount, $.ownerBalance);
    }
}
