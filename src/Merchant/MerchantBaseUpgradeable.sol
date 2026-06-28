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
        address buyerElection;
        address sellerElection;
        address beneficiary;
        address tradeExecutor;
        address business;
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
    event RefundForwarded(address indexed beneficiary, uint256 amount);

    modifier onlyTradeExecutor() {
        require(
            msg.sender == _getMerchantBaseStorage().tradeExecutor,
            "Only trade executor"
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
    function beneficiary() public view returns (address) {
        return _getMerchantBaseStorage().beneficiary;
    }
    function tradeExecutor() public view returns (address) {
        return _getMerchantBaseStorage().tradeExecutor;
    }
    function business() public view returns (address) {
        return _getMerchantBaseStorage().business;
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

    function register(uint256 amount) external virtual onlyOwner {
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        $.underlying.safeTransferFrom(msg.sender, address(this), amount);
        $.underlying.forceApprove($.market, amount);
        IMarket($.market).registerMerchant(amount);
    }

    function tradeOut(
        address buyer,
        address merchant,
        uint160 rechargeTarget,
        uint256 amount,
        bytes calldata data
    ) external virtual onlyOwnerOrBusiness {
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        $.underlying.safeTransferFrom(msg.sender, address(this), amount);
        $.underlying.forceApprove($.market, amount);
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

    function claimAndForward() external virtual {
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        uint256 balBefore = $.underlying.balanceOf(address(this));

        IMarket($.market).claimTaxRefund(address(this));

        uint256 balAfter = $.underlying.balanceOf(address(this));
        uint256 refundAmount = balAfter - balBefore;

        if (refundAmount > 0) {
            $.underlying.safeTransfer($.beneficiary, refundAmount);
            emit RefundForwarded($.beneficiary, refundAmount);
        }
    }

    function delegateVotesToBeneficiary() external virtual onlyOwner {
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        IRightsToken($.buyerElection).delegate($.beneficiary);
        IRightsToken($.sellerElection).delegate($.beneficiary);
    }
}
