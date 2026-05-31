// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// 引入 SafeERC20 库
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IRightsToken.sol";

/**
 * @title 原子贸易核心 market 合约 (UUPS 可升级)
 */
contract Market is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    // 声明使用 SafeERC20
    using SafeERC20 for IERC20;

    // --- 状态变量 ---
    IERC20 public underlying;
    IRightsToken public buyerRights;
    IRightsToken public sellerRights;
    address public vault;
    address public governance;

    struct Merchant {
        uint256 deposit;
        bool isActive;
    }

    mapping(address => Merchant) public merchants;
    mapping(address => uint256) public buyerPoints;
    mapping(address => uint256) public sellerPoints;

    // --- 事件 ---
    event MerchantRegistered(address indexed merchant, uint256 deposit);
    event Traded(
        address indexed payer,
        address indexed buyer,
        address indexed merchant,
        uint256 amount
    );
    event TaxRefunded(address indexed account, uint256 amount);
    event MerchantKicked(address indexed merchant, uint256 slashedAmount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _underlying,
        address _buyerRights,
        address _sellerRights,
        address _governance,
        address _vault
    ) public initializer {
        // UUPS 的初始化需要手动调用相应的初始化函数
        __Ownable_init(msg.sender);

        underlying = IERC20(_underlying);
        buyerRights = IRightsToken(_buyerRights);
        sellerRights = IRightsToken(_sellerRights);
        governance = _governance;
        vault = _vault;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    // --- 核心业务 ---

    function registerMerchant(uint256 amount) external {
        require(amount > 0, "Deposit required");
        // 使用 safeTransferFrom
        underlying.safeTransferFrom(msg.sender, address(this), amount);

        merchants[msg.sender].deposit += amount;
        merchants[msg.sender].isActive = true;

        emit MerchantRegistered(msg.sender, amount);
    }

    function trade(address buyer, address merchant, uint256 amount) external {
        require(merchants[merchant].isActive, "Merchant not active");

        uint256 taxTotal = amount / 10;
        uint256 vaultFee = amount / 100;
        uint256 merchantProceeds = amount - taxTotal;
        uint256 pointsAmount = (amount * 9) / 100;

        // 所有的 transfer/transferFrom 都改为 safe 方法
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        underlying.safeTransfer(merchant, merchantProceeds);
        underlying.safeTransfer(vault, vaultFee);

        buyerPoints[buyer] += pointsAmount;
        sellerPoints[merchant] += pointsAmount;

        buyerRights.mint(buyer, vaultFee);
        sellerRights.mint(merchant, vaultFee);

        emit Traded(msg.sender, buyer, merchant, amount);
    }

    function claimTaxRefund(address account) external {
        uint256 bP = buyerPoints[account];
        uint256 sP = sellerPoints[account];

        uint256 refundable = bP < sP ? bP : sP;
        require(refundable > 0, "No refundable points");

        buyerPoints[account] -= refundable;
        sellerPoints[account] -= refundable;

        // 使用 safeTransfer
        underlying.safeTransfer(account, refundable);

        emit TaxRefunded(account, refundable);
    }

    // --- 权限管理 ---

    function kickMerchant(address merchant) external {
        require(msg.sender == governance, "Only governance");
        require(merchants[merchant].isActive, "Merchant not active");

        uint256 slashedAmount = merchants[merchant].deposit;

        merchants[merchant].isActive = false;
        merchants[merchant].deposit = 0;

        // 使用 safeTransfer
        underlying.safeTransfer(vault, slashedAmount);

        emit MerchantKicked(merchant, slashedAmount);
    }

    function setVault(address _newVault) external onlyOwner {
        vault = _newVault;
    }
}
