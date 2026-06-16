// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IMarket.sol";
import "./interfaces/IRightsToken.sol";

/**
 * @title MerchantBase
 * @notice 商家接入原子贸易系统的标准基类
 * 职责：
 * 1. 代理商家地址与 Market 交互（注册、交易逻辑承载）
 * 2. 管理受益人地址 (Beneficiary)
 * 3. 自动将退税资金归集至受益人
 * 4. 托管并将买卖双方治理票数委托给受益人
 */
abstract contract MerchantBase is Ownable {
    using SafeERC20 for IERC20;

    // 系统核心组件
    address public immutable market;
    IERC20 public immutable underlying;
    address public immutable buyerElection;
    address public immutable sellerElection;

    // 受益人地址（通常是商家的冷钱包或 DAO 财库）
    address public beneficiary;

    event BeneficiaryUpdated(
        address indexed oldBeneficiary,
        address indexed newBeneficiary
    );
    event RefundForwarded(address indexed beneficiary, uint256 amount);

    /**
     * @param _market Market 合约地址
     * @param _underlying USDC 合约地址
     * @param _buyerElection 买方权利代币（选举合约）地址
     * @param _sellerElection 卖方权利代币（选举合约）地址
     * @param _initialBeneficiary 初始受益人
     */
    constructor(
        address _market,
        address _underlying,
        address _buyerElection,
        address _sellerElection,
        address _initialBeneficiary
    ) Ownable(msg.sender) {
        market = _market;
        underlying = IERC20(_underlying);
        buyerElection = _buyerElection;
        sellerElection = _sellerElection;
        beneficiary = _initialBeneficiary;
    }

    // =============================================================
    //                      商家管理功能
    // =============================================================

    /**
     * @notice 设置受益人
     */
    function setBeneficiary(address _newBeneficiary) external onlyOwner {
        require(_newBeneficiary != address(0), "Invalid address");
        address old = beneficiary;
        beneficiary = _newBeneficiary;
        emit BeneficiaryUpdated(old, _newBeneficiary);
    }

    /**
     * @notice 向 Market 注册/追加押金
     * @param amount 押金金额
     */
    function register(uint256 amount) external onlyOwner {
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        underlying.forceApprove(market, amount);
        IMarket(market).registerMerchant(amount);
    }

    /**
     * @notice 申请积分退税并自动转发给受益人
     */
    function claimAndForward() external {
        uint256 balBefore = underlying.balanceOf(address(this));

        // 调用市场退税，积分记在本合约头上
        IMarket(market).claimTaxRefund(address(this));

        uint256 balAfter = underlying.balanceOf(address(this));
        uint256 refundAmount = balAfter - balBefore;

        if (refundAmount > 0) {
            underlying.safeTransfer(beneficiary, refundAmount);
            emit RefundForwarded(beneficiary, refundAmount);
        }
    }

    // =============================================================
    //                      治理权限托管
    // =============================================================

    /**
     * @notice 将本合约持有的所有治理票数（买方+卖方）委托给受益人
     * 这样受益人可以直接用自己的钱包在 Governor 中投票，无需通过本合约转发指令
     */
    function delegateVotesToBeneficiary() external onlyOwner {
        // 委托买方投票权
        IRightsToken(buyerElection).delegate(beneficiary);
        // 委托卖方投票权
        IRightsToken(sellerElection).delegate(beneficiary);
    }

    // =============================================================
    //                      业务逻辑承载
    // =============================================================

    /**
     * @dev 接收来自 Market -> TradeExecutor 的回调
     * 实际的业务逻辑（如订单确认、库存扣减等）在子合约中实现
     */
    function onTradeReceived(
        uint256 amount,
        bytes calldata data
    ) internal virtual;

    /**
     * @notice 承接 TradeExecutor 的低级调用 (call)
     */
    fallback(bytes calldata callData) external payable returns (bytes memory) {
        // 这里可以根据 data 进一步路由，或者简单地触发业务函数
        // 假设 TradeExecutor 传入的 data 是由子合约定义的
        (bool success, ) = address(this).delegatecall(callData);
        require(success, "Business logic execution failed");
        return "";
    }

    receive() external payable {}
}
