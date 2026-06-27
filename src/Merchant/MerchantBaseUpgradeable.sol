// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "../interfaces/IMarket.sol";
import "../interfaces/IRightsToken.sol";

/**
 * @title MerchantBase (UUPS with Namespaced Storage)
 * @notice 浣跨敤鍛藉悕绌洪棿瀛樺偍妯″紡锛岀‘淇濈户鎵垮畨鍏ㄦ€?
 */
abstract contract MerchantBase is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /**
     * @dev 灏嗘墍鏈夌姸鎬佸彉閲忓畾涔夊湪缁撴瀯浣撲腑
     * 鎸夌収 ERC-7201 鏍囧噯锛岃繖鍙互闃叉缁ф壙鏃剁殑瀛樺偍鍐茬獊
     */
    struct MerchantBaseStorage {
        address market;
        IERC20 underlying;
        address buyerElection;
        address sellerElection;
        address beneficiary;
        address tradeExecutor;
    }

    // 璁＄畻瀛樺偍妲戒綅缃? keccak256(abi.encode(uint256(keccak256("merchant.storage.MerchantBase")) - 1)) & ~bytes32(uint256(0xff))
    // 杩欐槸涓轰簡閬靛惊 ERC-7201 閬垮厤纰版挒鐨勬帹鑽愯绠楁柟寮?
    bytes32 private constant MerchantBaseStorageLocation =
        0x56a421008746973f1d5e3f43501a37c9508c90333d0e376044791307b2298600;

    /**
     * @dev 鑾峰彇瀛樺偍缁撴瀯浣撶殑鎸囬拡
     */
    function _getMerchantBaseStorage()
        private
        pure
        returns (MerchantBaseStorage storage $)
    {
        assembly {
            $.slot := MerchantBaseStorageLocation
        }
    }

    // --- 浜嬩欢 ---
    event BeneficiaryUpdated(
        address indexed oldBeneficiary,
        address indexed newBeneficiary
    );
    event TradeExecutorUpdated(
        address indexed oldTradeExecutor,
        address indexed newTradeExecutor
    );
    event RefundForwarded(address indexed beneficiary, uint256 amount);

    modifier onlyTradeExecutor() {
        require(
            msg.sender == _getMerchantBaseStorage().tradeExecutor,
            "Only trade executor"
        );
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice 鍒濆鍖栧嚱鏁?
     */
    function __MerchantBase_init(
        address _market,
        address _underlying,
        address _buyerElection,
        address _sellerElection,
        address _tradeExecutor,
        address _initialBeneficiary
    ) internal onlyInitializing {
        __Ownable_init(msg.sender);

        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        $.market = _market;
        $.underlying = IERC20(_underlying);
        $.buyerElection = _buyerElection;
        $.sellerElection = _sellerElection;
        $.tradeExecutor = _tradeExecutor;
        $.beneficiary = _initialBeneficiary;
    }

    // =============================================================
    //                      鏉冮檺涓庡崌绾?
    // =============================================================

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    // =============================================================
    //                      鍙鏌ヨ (Getters)
    // =============================================================
    // 鐢变簬鍙橀噺鍦ㄧ粨鏋勪綋閲岋紝闇€瑕佹墜鍔ㄦ毚闇?Getter

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

    // =============================================================
    //                      鍟嗗绠＄悊鍔熻兘
    // =============================================================

    function setBeneficiary(address _newBeneficiary) external onlyOwner {
        require(_newBeneficiary != address(0), "Invalid address");
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        address old = $.beneficiary;
        $.beneficiary = _newBeneficiary;
        emit BeneficiaryUpdated(old, _newBeneficiary);
    }

    function setTradeExecutor(address _newTradeExecutor) external onlyOwner {
        require(_newTradeExecutor != address(0), "Invalid address");
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        address old = $.tradeExecutor;
        $.tradeExecutor = _newTradeExecutor;
        emit TradeExecutorUpdated(old, _newTradeExecutor);
    }

    function register(uint256 amount) external onlyOwner {
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        $.underlying.safeTransferFrom(msg.sender, address(this), amount);
        $.underlying.forceApprove($.market, amount);
        IMarket($.market).registerMerchant(amount);
    }

    function trade(
        address buyer,
        address merchant,
        uint256 amount,
        bytes calldata data
    ) external onlyOwner {
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        $.underlying.safeTransferFrom(msg.sender, address(this), amount);
        $.underlying.forceApprove($.market, amount);
        IMarket($.market).trade(buyer, merchant, amount, data);
    }

    function claimAndForward() external {
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

    function delegateVotesToBeneficiary() external onlyOwner {
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        IRightsToken($.buyerElection).delegate($.beneficiary);
        IRightsToken($.sellerElection).delegate($.beneficiary);
    }
}
