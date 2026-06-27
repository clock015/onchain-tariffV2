 // // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.20;

// import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// // 引入 SafeERC20 库
// import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
// import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
// import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
// import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
// import "./interfaces/ITradeExecutor.sol";
// import "./interfaces/IRightsToken.sol";

// /**
//  * @title 原子贸易核心 market 合约 (UUPS 可升级)
//  */
// contract MarketOld is
//     Initializable,
//     OwnableUpgradeable,
//     UUPSUpgradeable,
//     ReentrancyGuardTransient
// {
//     // 声明使用 SafeERC20
//     using SafeERC20 for IERC20;

//     // --- 状态变量 ---
//     IERC20 public underlying;
//     IRightsToken public buyerRights;
//     IRightsToken public sellerRights;
//     address public vault;
//     address public governance;

//     struct Merchant {
//         uint256 deposit;
//         bool isActive;
//         address interactionTarget;
//     }

//     struct Challenge {
//         address challenger;
//         uint256 stake; // 挑战者存入的保证金
//         uint256 endTime; // 挑战窗口截止时间
//     }

//     mapping(address => Merchant) public merchants;
//     mapping(address => uint256) public buyerPoints;
//     mapping(address => uint256) public sellerPoints;
//     mapping(address => uint256) public claimed;
//     mapping(address => Challenge) public challenges;
//     uint256 public challengePeriod;

//     address public executor;

//     mapping(address => uint256) public lastClaimTime; // 上次提款时间戳
//     mapping(address => uint256) public lastAvailableQuota; // 上次结算后剩余的可用配额

//     uint256 public QUOTA_PERIOD; // 配额完全恢复的周期
//     uint256 public quotaRatio; // 配额比例 (10000/10000 * deposit)

//     // 安全检查：不允许执行器自调用以绕过税收逻辑
//     modifier notFromExecutor() {
//         require(msg.sender != executor, "Executor cannot trigger trade");
//         _;
//     }

//     // --- 事件 ---
//     event MerchantRegistered(
//         address indexed merchant,
//         address indexed interactionTarget,
//         uint256 deposit
//     );
//     event Traded(
//         address indexed payer,
//         address indexed buyer,
//         address indexed merchant,
//         uint256 amount
//     );
//     event TaxRefunded(address indexed account, uint256 amount);
//     event MerchantChallenged(
//         address indexed merchant,
//         address indexed challenger,
//         uint256 endTime
//     );
//     event MerchantKicked(address indexed merchant, uint256 slashedAmount);
//     event ChallengeSettled(
//         address indexed merchant,
//         address indexed challenger,
//         uint256 slashedAmount
//     );

//     /// @custom:oz-upgrades-unsafe-allow constructor
//     constructor() {
//         _disableInitializers();
//     }

//     function initialize(
//         address _underlying,
//         address _buyerRights,
//         address _sellerRights,
//         address _governance,
//         address _vault
//     ) public initializer {
//         // UUPS 的初始化需要手动调用相应的初始化函数
//         __Ownable_init(msg.sender);

//         underlying = IERC20(_underlying);
//         buyerRights = IRightsToken(_buyerRights);
//         sellerRights = IRightsToken(_sellerRights);
//         governance = _governance;
//         vault = _vault;
//         challengePeriod = 7 days;
//         QUOTA_PERIOD = 30 days;
//         quotaRatio = 10000; // 默认配额比例为 100%
//     }

//     function _authorizeUpgrade(
//         address newImplementation
//     ) internal override onlyOwner {}

//     // --- 核心业务 ---

//     /**
//      * @notice 商家缴纳押金入驻
//      * @param amount 押金金额
//      * @param interactionTarget 交互目标地址
//      */
//     function registerMerchant(
//         uint256 amount,
//         address interactionTarget
//     ) external {
//         require(amount > 0, "Deposit required");
//         require(interactionTarget != address(0), "Invalid target");
//         // 如果是重新入驻或追加押金，交互目标必须保持一致（或新注册）
//         if (merchants[msg.sender].interactionTarget != address(0)) {
//             require(
//                 merchants[msg.sender].interactionTarget == interactionTarget,
//                 "Interaction target mismatch"
//             );
//         }

//         underlying.safeTransferFrom(msg.sender, address(this), amount);

//         merchants[msg.sender].deposit += amount;
//         merchants[msg.sender].isActive = true;
//         merchants[msg.sender].interactionTarget = interactionTarget;

//         emit MerchantRegistered(msg.sender, interactionTarget, amount);
//     }

//     function trade(
//         address buyer,
//         address merchant,
//         uint256 amount,
//         bytes calldata data
//     ) external nonReentrant notFromExecutor {
//         Merchant storage m = merchants[merchant];
//         require(m.isActive, "Merchant not active");

//         address interactionTarget = m.interactionTarget; // 提取交互目标地址

//         uint256 taxTotal = amount / 10;
//         uint256 vaultFee = amount / 100;
//         uint256 merchantProceeds = amount - taxTotal;
//         uint256 pointsAmount = (amount * 9) / 100;

//         underlying.safeTransferFrom(msg.sender, address(this), amount);
//         underlying.safeTransfer(vault, vaultFee);

//         // 记账给受益人
//         buyerPoints[buyer] += pointsAmount;
//         sellerPoints[merchant] += pointsAmount;

//         buyerRights.mint(buyer, vaultFee);
//         sellerRights.mint(merchant, vaultFee);

//         underlying.safeTransfer(executor, merchantProceeds);
//         ITradeExecutor(executor).executeTrade(
//             interactionTarget,
//             merchantProceeds,
//             data
//         );

//         emit Traded(msg.sender, buyer, merchant, amount);
//     }

//     function claimTaxRefund(address account) external nonReentrant {
//         uint256 bP = buyerPoints[account];
//         uint256 sP = sellerPoints[account];

//         // 原始应退金额
//         uint256 totalRefundable = bP < sP ? bP : sP;
//         require(totalRefundable > 0, "No refundable points");

//         // 获取当前时间点的可用配额
//         uint256 availableQuota = getAvailableQuota(account);
//         require(availableQuota > 0, "Quota exhausted, wait for recovery");

//         // 取 [应退金额] 和 [可用配额] 的最小值
//         uint256 actualClaim = totalRefundable > availableQuota
//             ? availableQuota
//             : totalRefundable;

//         // --- 更新状态 ---
//         // 1. 更新配额结余：当前的可用额度减去本次消耗的额度
//         lastAvailableQuota[account] = availableQuota - actualClaim;
//         // 2. 更新时间戳
//         lastClaimTime[account] = block.timestamp;

//         // 3. 扣减积分
//         buyerPoints[account] -= actualClaim;
//         sellerPoints[account] -= actualClaim;
//         claimed[account] += actualClaim;

//         // 4. 转账
//         underlying.safeTransfer(account, actualClaim);

//         emit TaxRefunded(account, actualClaim);
//     }

//     /**
//      * @notice 计算当前用户可用的提款配额上限
//      * @dev 逻辑：上次剩余配额 + (时间流逝 / 周期) * 最大配额
//      */
//     function getAvailableQuota(address account) public view returns (uint256) {
//         uint256 deposit = merchants[account].deposit;
//         if (deposit == 0) return 0;

//         // 最大总配额 = 押金 * 比例
//         uint256 maxQuota = (deposit * quotaRatio) / 10000;

//         // 如果从未提款，初始配额为满额
//         if (lastClaimTime[account] == 0) {
//             return maxQuota;
//         }

//         uint256 timePassed = block.timestamp - lastClaimTime[account];

//         // 如果时间超过一个月，直接返回最大配额
//         if (timePassed >= QUOTA_PERIOD) {
//             return maxQuota;
//         }

//         // 计算这段时间内恢复的额度: (maxQuota * timePassed) / QUOTA_PERIOD
//         uint256 recovered = (maxQuota * timePassed) / QUOTA_PERIOD;
//         uint256 total = lastAvailableQuota[account] + recovered;

//         // 不能超过最大配额上限
//         return total > maxQuota ? maxQuota : total;
//     }

//     // --- 权限管理 ---

//     /**
//      * @notice 发起挑战
//      * @dev 启动挑战窗口期，存入等额保证金
//      */
//     function challengeMerchant(address merchant) external nonReentrant {
//         Merchant storage m = merchants[merchant];
//         require(m.isActive, "Merchant not active");
//         require(
//             challenges[merchant].challenger == address(0),
//             "Challenge pending"
//         );

//         uint256 stake = m.deposit;
//         underlying.safeTransferFrom(msg.sender, address(this), stake);

//         challenges[merchant] = Challenge({
//             challenger: msg.sender,
//             stake: stake,
//             endTime: block.timestamp + challengePeriod
//         });

//         emit MerchantChallenged(
//             merchant,
//             msg.sender,
//             challenges[merchant].endTime
//         );
//     }

//     /**
//      * @notice 治理踢出（挑战成功）
//      * @dev 只能在窗口期内由治理模块调用
//      */
//     function kickMerchant(address merchant) external nonReentrant {
//         require(msg.sender == governance, "Only governance");
//         Challenge storage c = challenges[merchant];
//         require(c.challenger != address(0), "No active challenge");
//         require(block.timestamp <= c.endTime, "Challenge period expired");

//         uint256 merchantDeposit = merchants[merchant].deposit;
//         uint256 challengerStake = c.stake;

//         // --- 修改点 3：精准没收该商家的积分 ---
//         uint256 bP = buyerPoints[merchant];
//         uint256 sP = sellerPoints[merchant];

//         if (bP > 0) {
//             buyerPoints[merchant] = 0;
//             buyerPoints[vault] += bP; // 没收至金库
//         }
//         if (sP > 0) {
//             sellerPoints[merchant] = 0;
//             sellerPoints[vault] += sP; // 没收至金库
//         }

//         // 1. 状态清理
//         merchants[merchant].isActive = false;
//         merchants[merchant].deposit = 0;
//         address challenger = c.challenger;
//         delete challenges[merchant];

//         // 2. 没收商家押金入库
//         underlying.safeTransfer(vault, merchantDeposit);

//         // 3. 退还挑战者保证金（或者可以增加奖励）
//         underlying.safeTransfer(challenger, challengerStake);

//         emit MerchantKicked(merchant, merchantDeposit);
//     }

//     /**
//      * @notice 结算挑战（挑战失败）
//      * @dev 任何人可在窗口期过后调用，没收挑战者保证金
//      */
//     function settleChallenge(address merchant) external nonReentrant {
//         Challenge storage c = challenges[merchant];
//         require(c.challenger != address(0), "No active challenge");
//         require(block.timestamp > c.endTime, "Challenge still active");

//         uint256 stakeToSlash = c.stake;
//         address challenger = c.challenger;

//         // 1. 清理挑战状态，商家继续保持 isActive
//         delete challenges[merchant];

//         // 2. 没收挑战者的保证金入库，补偿给系统/金库
//         underlying.safeTransfer(vault, stakeToSlash);

//         emit ChallengeSettled(merchant, challenger, stakeToSlash);
//     }

//     function setVault(address _newVault) external onlyOwner {
//         vault = _newVault;
//     }

//     function setExecutor(address _executor) external onlyOwner {
//         executor = _executor;
//     }

//     function setQuotaParams(uint256 _newRatio) external onlyOwner {
//         quotaRatio = _newRatio;
//     }
// }
