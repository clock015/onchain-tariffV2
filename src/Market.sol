// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// 引入 SafeERC20 库
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "./interfaces/ITradeExecutor.sol";
import "./interfaces/IRightsToken.sol";

/**
 * @title 原子贸易核心 market 合约 (UUPS 可升级)
 */
contract Market is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient
{
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

    struct Challenge {
        address challenger;
        uint256 stake; // 挑战者存入的保证金
        uint256 endTime; // 挑战窗口截止时间
    }

    mapping(address => Merchant) public merchants;
    mapping(address => uint256) public buyerPoints;
    mapping(address => uint256) public sellerPoints;
    mapping(address => Challenge) public challenges;
    uint256 public challengePeriod;

    address public executor;

    // 安全检查：不允许执行器自调用以绕过税收逻辑
    modifier notFromExecutor() {
        require(msg.sender != executor, "Executor cannot trigger trade");
        _;
    }

    // --- 事件 ---
    event MerchantRegistered(address indexed merchant, uint256 deposit);
    event Traded(
        address indexed payer,
        address indexed buyer,
        address indexed merchant,
        uint256 amount
    );
    event TaxRefunded(address indexed account, uint256 amount);
    event MerchantChallenged(
        address indexed merchant,
        address indexed challenger,
        uint256 endTime
    );
    event MerchantKicked(address indexed merchant, uint256 slashedAmount);
    event ChallengeSettled(
        address indexed merchant,
        address indexed challenger,
        uint256 slashedAmount
    );

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
        challengePeriod = 7 days;
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

    function trade(
        address buyer,
        address merchant,
        uint256 amount,
        bytes calldata data
    ) external nonReentrant notFromExecutor {
        require(merchants[merchant].isActive, "Merchant not active");

        uint256 taxTotal = amount / 10;
        uint256 vaultFee = amount / 100;
        uint256 merchantProceeds = amount - taxTotal;
        uint256 pointsAmount = (amount * 9) / 100;

        // 1. 资金归集（从付款人处扣除 100%）
        underlying.safeTransferFrom(msg.sender, address(this), amount);

        // 2. 分配 1% 入金库
        underlying.safeTransfer(vault, vaultFee);

        // 3. 确权与积分
        buyerPoints[buyer] += pointsAmount;
        sellerPoints[merchant] += pointsAmount;

        buyerRights.mint(buyer, vaultFee);
        sellerRights.mint(merchant, vaultFee);

        // 4. 将 90% 资金拨付给 Executor 并触发执行
        underlying.safeTransfer(executor, merchantProceeds);

        ITradeExecutor(executor).executeTrade(merchant, merchantProceeds, data);

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

    /**
     * @notice 发起挑战
     * @dev 启动挑战窗口期，存入等额保证金
     */
    function challengeMerchant(address merchant) external nonReentrant {
        Merchant storage m = merchants[merchant];
        require(m.isActive, "Merchant not active");
        require(
            challenges[merchant].challenger == address(0),
            "Challenge pending"
        );

        uint256 stake = m.deposit;
        underlying.safeTransferFrom(msg.sender, address(this), stake);

        challenges[merchant] = Challenge({
            challenger: msg.sender,
            stake: stake,
            endTime: block.timestamp + challengePeriod
        });

        emit MerchantChallenged(
            merchant,
            msg.sender,
            challenges[merchant].endTime
        );
    }

    /**
     * @notice 治理踢出（挑战成功）
     * @dev 只能在窗口期内由治理模块调用
     */
    function kickMerchant(address merchant) external nonReentrant {
        require(msg.sender == governance, "Only governance");
        Challenge storage c = challenges[merchant];
        require(c.challenger != address(0), "No active challenge");
        require(block.timestamp <= c.endTime, "Challenge period expired");

        uint256 merchantDeposit = merchants[merchant].deposit;
        uint256 challengerStake = c.stake;

        // 1. 状态清理
        merchants[merchant].isActive = false;
        merchants[merchant].deposit = 0;
        address challenger = c.challenger;
        delete challenges[merchant];

        // 2. 没收商家押金入库
        underlying.safeTransfer(vault, merchantDeposit);

        // 3. 退还挑战者保证金（或者可以增加奖励）
        underlying.safeTransfer(challenger, challengerStake);

        emit MerchantKicked(merchant, merchantDeposit);
    }

    /**
     * @notice 结算挑战（挑战失败）
     * @dev 任何人可在窗口期过后调用，没收挑战者保证金
     */
    function settleChallenge(address merchant) external nonReentrant {
        Challenge storage c = challenges[merchant];
        require(c.challenger != address(0), "No active challenge");
        require(block.timestamp > c.endTime, "Challenge still active");

        uint256 stakeToSlash = c.stake;
        address challenger = c.challenger;

        // 1. 清理挑战状态，商家继续保持 isActive
        delete challenges[merchant];

        // 2. 没收挑战者的保证金入库，补偿给系统/金库
        underlying.safeTransfer(vault, stakeToSlash);

        emit ChallengeSettled(merchant, challenger, stakeToSlash);
    }

    function setVault(address _newVault) external onlyOwner {
        vault = _newVault;
    }

    function setExecutor(address _executor) external onlyOwner {
        executor = _executor;
    }
}
