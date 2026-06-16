// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./interfaces/IMarket.sol";
import "./interfaces/IRightsToken.sol";

/**
 * @title MerchantBase (UUPS with Namespaced Storage)
 * @notice 使用命名空间存储模式，确保继承安全性
 */
abstract contract MerchantBase is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /**
     * @dev 将所有状态变量定义在结构体中
     * 按照 ERC-7201 标准，这可以防止继承时的存储冲突
     */
    struct MerchantBaseStorage {
        address market;
        IERC20Upgradeable underlying;
        address buyerElection;
        address sellerElection;
        address beneficiary;
    }

    // 计算存储槽位置: keccak256(abi.encode(uint256(keccak256("merchant.storage.MerchantBase")) - 1)) & ~bytes32(uint256(0xff))
    // 这是为了遵循 ERC-7201 避免碰撞的推荐计算方式
    bytes32 private constant MerchantBaseStorageLocation =
        0x56a421008746973f1d5e3f43501a37c9508c90333d0e376044791307b2298600;

    /**
     * @dev 获取存储结构体的指针
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

    // --- 事件 ---
    event BeneficiaryUpdated(
        address indexed oldBeneficiary,
        address indexed newBeneficiary
    );
    event RefundForwarded(address indexed beneficiary, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice 初始化函数
     */
    function __MerchantBase_init(
        address _market,
        address _underlying,
        address _buyerElection,
        address _sellerElection,
        address _initialBeneficiary
    ) internal onlyInitializing {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        $.market = _market;
        $.underlying = IERC20Upgradeable(_underlying);
        $.buyerElection = _buyerElection;
        $.sellerElection = _sellerElection;
        $.beneficiary = _initialBeneficiary;
    }

    // =============================================================
    //                      权限与升级
    // =============================================================

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    // =============================================================
    //                      只读查询 (Getters)
    // =============================================================
    // 由于变量在结构体里，需要手动暴露 Getter

    function market() public view returns (address) {
        return _getMerchantBaseStorage().market;
    }
    function underlying() public view returns (IERC20Upgradeable) {
        return _getMerchantBaseStorage().underlying;
    }
    function beneficiary() public view returns (address) {
        return _getMerchantBaseStorage().beneficiary;
    }

    // =============================================================
    //                      商家管理功能
    // =============================================================

    function setBeneficiary(address _newBeneficiary) external onlyOwner {
        require(_newBeneficiary != address(0), "Invalid address");
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        address old = $.beneficiary;
        $.beneficiary = _newBeneficiary;
        emit BeneficiaryUpdated(old, _newBeneficiary);
    }

    function register(uint256 amount) external onlyOwner {
        MerchantBaseStorage storage $ = _getMerchantBaseStorage();
        $.underlying.safeTransferFrom(msg.sender, address(this), amount);
        $.underlying.forceApprove($.market, amount);
        IMarket($.market).registerMerchant(amount);
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
