# MerchantBase 接入与交互文档

本文对应当前 [`MerchantBase`](../src/Merchant/MerchantBaseUpgradeable.sol)、[`IMarket`](../src/interfaces/IMarket.sol) 和 [`TradeExecutor`](../src/TradeExecutor.sol) 的实现。文件名是 `MerchantBaseUpgradeable.sol`，实际合约名是 `MerchantBase`。

MerchantBase 是一个可升级的商家接入基类：一个实例连接一个 Market，可以同时支持多个 Account Owner，以不同的 Market Account ID 参与不同押金乘数层。它负责校验收款身份、记录按乘数隔离的吸收/释放桶，以及通过 Market 对外支付；平台币、消费者消费、创作者分成等业务账本由派生合约或 business 系统实现。

本文描述现有接口，不表示旧版本代理可以直接无迁移升级到当前版本。

## 1. 身份与账户

| 名称 | 含义与权限 |
| --- | --- |
| 合约管理员 `owner()` | Ownable 管理员；维护支持的 Account Owner、business、executor，并授权 UUPS 升级。 |
| Account Owner | Market 中某个 `(owner, merchant)` 账户的 owner；注册账户、调整该账户乘数，持有该账户对应的权利 token。 |
| Merchant | 承担账户经济收支的地址；接入本基类时是 **MerchantBase 代理地址**。 |
| `business()` | 平台业务执行地址，可为 EOA 或业务合约；调用 `tradeOut` 时使用 business 释放桶。 |
| `rechargeTarget` | 传给收款商家的 `uint160` 业务标识，例如消费者/玩家充值 ID；不是基类维护的创作者分账账户。 |

这几个身份可以是不同地址。合约管理员没有自动提取资金的权限：若它既不是所选账户的 Account Owner，也不是 business，就不能调用该账户的 `tradeOut`。

一个平台可以有以下账户：

```text
同一个 Market
├─ accountId 11：owner A + 平台代理，multiplier 30000
├─ accountId 12：owner B + 平台代理，multiplier 40000
└─ accountId 13：owner C + 平台代理，multiplier 30000
```

各 Market 账户的押金、顺逆差、已收关税和延迟顺差独立。权利 token 直接铸给交易两侧账户各自的 Account Owner，不由 MerchantBase 代持。相同 merchant 的不同账户 ID 可以互相交易，但仍受 Market 的其他约束。

## 2. 部署、初始化与注册

### 2.1 派生合约初始化

基类是抽象合约，构造函数禁用了实现合约的初始化。派生合约应通过代理使用，并公开带 `initializer` 修饰符的初始化入口，调用：

```solidity
__MerchantBase_init(
    marketAddress,
    underlyingAddress,
    initialAccountOwner,
    tradeExecutorAddress,
    businessAddress,
    ownerShareBps,
    businessShareBps
);
```

参数说明：

| 参数 | 说明 |
| --- | --- |
| `marketAddress` | 唯一接入的 Market。 |
| `underlyingAddress` | 结算 ERC20，必须与该 Market 的 SettlementAsset 一致。 |
| `initialAccountOwner` | 初始支持的 Account Owner，不能为零地址；这一步只加入支持名单，不注册 Market 账户。 |
| `tradeExecutorAddress` | 该 Market 使用的 TradeExecutor，是唯一允许调用外部 `tradeIn` 的地址。 |
| `businessAddress` | 平台业务执行地址。 |
| `ownerShareBps` | owner 桶释放比例，10000 表示 100%。 |
| `businessShareBps` | business 桶释放比例，必须与 owner 比例相加等于 10000。 |

例如 `2000 / 8000` 表示 owner 占 20%，business 占 80%。允许 `0 / 10000` 或 `10000 / 0`。

当前接口没有比例修改函数：比例在初始化后固定，并作用于整个实例的全部 owner 和乘数桶。不能在不处理历史账本的情况下通过升级随意改变比例。

`owner()` 初始化为 **初始化调用者 `msg.sender`**，不是 `initialAccountOwner`。通过工厂部署时尤其要确认最终管理员，并在需要时移交所有权。推荐在创建代理时携带初始化数据，避免留下未初始化代理。

初始化会从 Market 读取并缓存 `settlementAsset()`。当前没有修改 market、underlying、settlementAsset 的 setter；部署端应核对它们与 executor 的配置一致，基类初始化没有完整验证全部地址组合。

### 2.2 注册平台的 Market 账户

注册逻辑在 Market，不在 MerchantBase。

1. 管理员调用 `setAccountOwnerSupport(accountOwner, true)`，允许平台接收该 owner 的订单；初始 owner 已自动支持。
2. Account Owner 从自己的地址向 **SettlementAsset** 授权押金 ERC20。
3. 同一个 Account Owner 调用 Market：

```solidity
uint256 accountId = market.registerMerchant(
    platformProxy,
    depositAmount,
    capacityMultiplier
);
```

押金必须大于零，乘数必须至少为 `1000`。例如 `40000` 对应容量为押金的 4 倍；不同 owner 可以为同一个平台注册不同乘数的账户。

可用 `market.accountIdOf(accountOwner, platformProxy)` 查询 ID，再用 `market.accounts(accountId)` 检查：

```solidity
(address owner, address merchant, uint256 deposit,
 uint256 capacityMultiplier, bool isActive)
```

支持名单和 Market 注册是两件事。Market 注册成功不代表平台已支持该 owner；不支持的 owner 对应收款订单会在回调时回滚。

### 2.3 增押与参数维护

- `Market.addDeposit(accountId, amount)`：任何人都可以调用，由调用者全额支付押金；事先向 SettlementAsset 授权。增押不记入 MerchantBase 的 `received`，也不会即时退还关税。
- `Market.setCapacityMultiplier(accountId, newMultiplier)`：仅该 Account Owner 可以调用，只能保持或降低乘数，最低 1000，并满足当前应税顺差容量要求。
- MerchantBase 当前设计预期同一账户参与期间保持乘数不变，但 **基类没有在链上冻结乘数**。如果 owner 修改乘数，后续吸收和释放会使用新乘数桶，旧桶不会迁移。接入方必须协调这一约束，不能认为改乘数会自动搬迁额度。

### 2.4 押金退出：申请后等待 180 天

由账户 owner 直接调用 Market，而不是调用 MerchantBase：

```solidity
market.requestDepositWithdrawal(accountId);
(uint256 amount, uint256 availableAt) = market.depositWithdrawals(accountId);
// block.timestamp >= availableAt 后，由同一个账户 owner 调用：
market.withdrawDeposit(accountId);
```

申请要求账户已激活、有有效押金，同时 `netTradeBalance <= 0`、当前 `deferredSurplus == 0`。尚未释放完的延迟顺差不能通过申请退出清除；`sellerPoints` 可以保留到到期领取时结算。

- 申请一次退出全部押金；有效 `deposit` 立即归零，资金转为待退记录，不再提供顺差容量或延迟顺差释放能力。等待期固定为 `180 days`，不是按自然月计算。
- 账户 ID、owner、merchant、乘数和已有经济账本保留；`isActive` 不会变为 false，但 `isAccountFrozen(accountId)` 立即变为 true。冻结账户不能作为买方付款或卖方收款，即使收款只用于补平逆差也不允许。
- 第三方代付、merchant 为 owner 消费、传入 ID 0 复用冻结默认账户，都受相同检查。冻结按账户 ID 隔离，不冻结共享 merchant 地址的其他账户。
- 冻结期间不可增押、修改乘数或通过 registerMerchant 重注册该账户；待退申请不可重复。当前没有取消申请、解冻或部分退押接口。
- 到期后仅账户 owner 可以发起领取。押金本金固定转给 **账户 owner**，第三方曾追加的押金也一并退给该 owner，不按历史付款人拆分；剩余 `sellerPoints` 则直接转给 **merchant**。
- 待退押金到期但尚未领取时，仍可被治理踢出罚没；踢出会同时删除待退记录，之后不能再次领取。
- `sellerPoints` 在真实顺差和延迟顺差归零后仍可能残留：例如此前由第三方代付，未满足使用退税的身份条件；或者延迟顺差刚随时间释放完，尚未发生下一笔授权消费来触发退款。申请后这部分资金随账户冻结，领取时不再要求通过消费触发，而是直接退给 merchant。
- 领取成功后删除 Market 账户、`accountIdOf(owner, merchant)` 和该 ID 的经济记录，owner–merchant 对重新回到未注册状态。以后重新注册会取得新的 accountId。MerchantBase 自己保存的 owner/multiplier 流量桶不属于 Market，不会随 Market 账户删除而重置。

前端不能只检查 `isActive` 判断账户能否交易，还应检查 `isAccountFrozen(accountId)`；使用 `depositWithdrawals(accountId)` 展示待退金额和到期时间。领取后账户和冻结标记一起删除。退给 owner 的本金不经过 MerchantBase.tradeIn，也不会增加平台的 received 桶。

Market 会发出 `DepositWithdrawalRequested(accountId, owner, amount, availableAt)` 和 `DepositWithdrawn(accountId, recipient, amount)` 事件，供链下跟踪申请和领取状态；若领取时一并退还了 `sellerPoints`，还会发出 `TaxRefunded(accountId, amount)`。

## 3. 用户向平台付款：调用 Market，不直接调用 tradeIn

典型调用顺序：

```text
付款人授权 SettlementAsset
  → 付款人调用 Market.trade
  → Market 记账、计算关税和退税、铸造权利 token
  → TradeExecutor 将 deltaW 转给平台代理
  → TradeExecutor 调用平台 tradeIn
  → 基类记录吸收桶，再执行派生合约 _tradeIn
```

付款人调用 Market 的接口：

```solidity
market.trade(
    buyer,
    buyerAccountId,
    platformSellerAccountId,
    rechargeTarget,
    amount,
    data
);
```

- `buyer` 是买方账户的 owner，不一定是付款人。
- `buyerAccountId = 0` 表示创建或复用 `(buyer, buyer)` 默认账户，不是自动选择 buyer 在平台上的账户。若默认账户已经正式激活，仍受它的乘数约束。
- 显式传入买方账户 ID 时，该账户 owner 必须等于 `buyer`。
- `platformSellerAccountId` 决定这笔平台收入记到哪个 owner–platform 账户，以及卖方权利铸给哪个 owner。卖方账户必须已激活。
- 第三方可以代付，但只有 Market 调用者等于买方账户 merchant、且 buyer 等于账户 owner 时才可以使用该账户退税。
- `rechargeTarget`、`data` 交给收款平台解释；`data` 不是交给 executor 任意执行的调用指令。

买方账户激活时，Market 要求：

```text
seller.capacityMultiplier <= buyer.capacityMultiplier
```

即源账户只能向相同或更低乘数的目标账户交易。未正式激活的默认外部买家账户不受这项限制。此规则约束 Market 账户经济活动，不是为离开协议的每个 ERC20 单位附加流转标签。

### 3.1 外部回调与内部业务钩子

外部回调的准确签名：

```solidity
function tradeIn(
    address registeredRightsOwner,
    uint160 rechargeTarget,
    uint256 netAmount,
    uint256 deltaW,
    bytes calldata data
) external;
```

只接受配置的 executor 调用。基类检查 owner 在支持名单内，通过 `(registeredRightsOwner, address(this))` 查询账户，确认其已激活且身份匹配，并从账户读取当前乘数。

随后，基类把完整的 `netAmount` 同时记入：

```text
accountOwnerFlows[registeredRightsOwner][multiplier].received
businessFlows[multiplier].received
```

最后调用派生合约必须实现的钩子：

```solidity
function _tradeIn(
    uint160 rechargeTarget,
    uint256 capacityMultiplier,
    uint256 netAmount,
    uint256 deltaW,
    bytes calldata data
) internal override {
    // 在这里按消费者、乘数和业务数据处理充值。
    // 若币种、充值目标或业务参数不被接受，应 revert。
}
```

**乘数是内部 `_tradeIn` 的参数，不是外部 `tradeIn` 的参数。** 基类不按 rechargeTarget 保存销售桶，也不处理平台币发行、用户消费或创作者应得余额；这些由业务层完成。

### 3.2 金额口径

所有金额均使用 underlying 的最小单位；不要在接入代码中假定所有代币都为 6 位小数。

```text
vaultFee = floor(amount / 100)
netAmount = amount - vaultFee
deltaW = netAmount - 本次卖方新增关税
```

- `amount`：订单总额，包含 1% 权利费用（整数向下取整）。
- `netAmount`：扣权利费用后的交易量，也是吸收桶计量值。
- `deltaW`：此次实际转入收款平台的 ERC20 数量。

基类不累计 `deltaW`。按 `netAmount` 入桶不代表对应 ERC20 已全部可用，差额可能仍作为关税留在 Market。

当前 executor **先转账，再回调**；无论 data 是否为空，只要收款地址有代码都会调用 `tradeIn`。平台不需要在回调中 `transferFrom` executor。EOA 收款地址则跳过回调，无需实现 MerchantBase。

回调中读取 Market 的 view 接口不会触发重入锁；但再次调用同一个 Market 的 `trade` 会因其 `nonReentrant` 限制回滚。MerchantBase 本身没有额外重入锁，派生业务若新增其他外部调用或提现入口，需要自行考虑安全边界。回调失败会回滚整笔交易，包括资金转移、Market 记账、权利铸造和基类桶更新。

## 4. 吸收桶、比例与可释放额度

| 桶 | 键 | `received` | `released` |
| --- | --- | --- | --- |
| owner 桶 | Account Owner + multiplier | 经该 owner 账户收到的累计 netAmount | 该 owner 路径已支出的累计 amount |
| business 桶 | multiplier | 所有 owner 在该乘数收到的累计 netAmount | business 路径已支出的累计 amount |

两套 received 是同一销售额的两个统计视角，不能相加当成双倍收入。真正的释放上限通过比例拆分：

```text
ownerLimit = floor(ownerReceived × ownerShareBps / 10000)
ownerAvailable = ownerLimit - ownerReleased

businessLimit = floor(businessReceived × businessShareBps / 10000)
businessAvailable = businessLimit - businessReleased
```

合约用 `Math.mulDiv` 对累计 received 计算比例。新交易要求 `amount <= available`，即允许刚好用完额度，不允许超出。比例为零的路径不能进行正金额释放。

例如某乘数只有 owner A 带来一笔总额 100 的订单：扣费后 netAmount 为 99，owner/business 比例为 20%/80%。两个桶的 received 都增加 99，但释放上限分别仅为 19.8 和 79.2，不会各自获得 99。实际到账 deltaW 还要减去卖方关税。

每个乘数桶独立，不能用 30000 桶的吸收额度直接释放 40000 桶的资金。business 在同一乘数下跨 owner 聚合；owner 只能使用自己的桶。按最小单位向下取整可能留下少量余数，之后新增吸收额可能使其变为可用额度。

读取接口返回的是 **原始累计值**，前端应自己乘比例：

```solidity
platform.accountOwnerFlow(accountOwner, multiplier); // (received, released)
platform.businessFlow(multiplier);                  // (received, released)
platform.releaseShares();                           // (ownerShareBps, businessShareBps)
```

释放额度不是 ERC20 余额，也不是 Market 保证立即兑现的余额。底层转账仍要求平台有足够的可支付资金；可退关税受当前应税顺差、延迟顺差及已收关税等规则限制。额度充足但现金不足时，交易仍可能回滚。

## 5. 平台向外付款：tradeOut

```solidity
function tradeOut(
    address buyer,
    uint256 buyerAccountId,
    uint256 sellerAccountId,
    uint160 rechargeTarget,
    uint256 amount,
    bytes calldata data
) public;
```

这里平台是资金来源方，在 Market 中扮演买方账户的 merchant。参数含义：

| 参数 | 要求 |
| --- | --- |
| `buyer` | 源账户的 Account Owner；不是收款人，也不是必然等于外部调用者。 |
| `buyerAccountId` | 已激活、merchant 等于本平台代理的源账户；owner 必须等于 buyer，且仍在支持名单中。 |
| `sellerAccountId` | 目标收款账户，必须已激活；不能等于源 ID，且满足 Market 乘数限制。 |
| `rechargeTarget` | 目标商家的业务标识；含义由目标商家决定。 |
| `amount` | 此次完整交易总额，同时是释放桶的扣减量。 |
| `data` | 传递给目标商家回调的业务参数。 |

MerchantBase 的 `tradeOut` **不支持 buyerAccountId 为 0**：它要求先读到有效、激活的源账户。不要把 Market 面向外部买家的默认账户行为套用到此接口。

### 5.1 Account Owner 调用

外部调用者必须等于所选源账户的 owner，并且该 owner 当前受到平台支持。扣减 `accountOwnerFlows[owner][multiplier]` 的比例额度。

例如 owner A 让平台用 `(A, 平台)` 账户向另一个商家支付：

```solidity
// 由 owner A 发起，platform 是代理地址。
platform.tradeOut(A, accountIdA, destinationAccountId, target, amount, data);
```

### 5.2 business 调用

外部调用者等于 `business()` 时，使用 `businessFlows[multiplier]` 的比例额度。business 可以选择任意仍受支持、已激活且 merchant 为平台的源账户，但 buyer 必须匹配该账户 owner。

```solidity
// 由 business 发起。buyer 仍是源账户 owner A，不是 business 或创作者。
platform.tradeOut(A, accountIdA, creatorSellerAccountId, target, amount, data);
```

用于创作者提现时，创作者对应的是目标卖方账户。基类只检查聚合 business 桶，不验证具体创作者应得金额；business 必须先完成创作者身份、余额和提现授权检查，不能把无限制的对外转发入口交给所有用户。

如果 business 地址同时也是所选 Account Owner，**business 分支优先**，这次消耗 business 桶，不会自动改用 owner 桶或合并额度。

### 5.3 谁付款、如何退税

通过权限与额度检查后，基类先记录释放，再执行：

```text
平台用自己的 underlying 向 SettlementAsset 授权 amount
  → 平台调用 Market.trade
  → Market 从平台拉取 amount - buyerRefund
  → 目标商家接收它自己的 deltaW
```

外部 owner/business 不需要为这次 tradeOut 用自己的钱包授权或付款。平台调用 Market 时，sender 正好是源账户 merchant，buyer 是源账户 owner，因此满足使用源账户退税的身份条件；实际是否可退、能退多少，由 Market 当次计算。

退税抵扣付款，不会单独转给 owner 或 business。当前退税最多覆盖 `netAmount`，不能支付 1% 权利费用。

无论此次现金实际支付多少，释放桶始终增加完整的 `amount`，不是 `amount - buyerRefund`，也不是目标商家的 deltaW。Market 或目标回调失败时，释放记录也一起回滚。

## 6. 管理、查询与事件索引

仅合约管理员可以调用：

```solidity
setAccountOwnerSupport(address accountOwner, bool supported)
setBusiness(address newBusiness)
setTradeExecutor(address newTradeExecutor)
```

- 关闭 owner 支持会同时阻止该 owner 对应平台账户的后续收款回调和 tradeOut；不会删除 Market 账户或历史桶。恢复支持后继续使用原记录。
- 修改 business 会把同一份 business 额度交给新地址使用，不会清空桶。
- 修改 executor 需要与 Market 配置协调，不应指向不可信地址；它是 tradeIn 的信任入口。
- `owner()`、所有权转移和 UUPS 升级遵循继承的 Ownable/UUPS 权限。升级权限属于管理员，比例固定等约束指当前实现的正常接口。

常用查询入口：

```solidity
owner()
market()
underlying()
settlementAsset()
tradeExecutor()
business()
isAccountOwnerSupported(address accountOwner)
releaseShares()
accountOwnerFlow(address accountOwner, uint256 capacityMultiplier)
businessFlow(uint256 capacityMultiplier)
```

事件用于链下索引：

| 事件 | 含义 |
| --- | --- |
| `SaleRecorded(accountId, accountOwner, rechargeTarget, capacityMultiplier, netAmount)` | 平台收到一笔订单，并增加吸收桶。 |
| `AccountOwnerReleaseRecorded(accountId, accountOwner, capacityMultiplier, amount)` | owner 路径成功释放。 |
| `BusinessReleaseRecorded(accountId, capacityMultiplier, amount)` | business 路径成功释放。 |
| `AccountOwnerSupportUpdated(accountOwner, supported)` | 支持名单变化。 |
| `ReleaseSharesConfigured(ownerShareBps, businessShareBps)` | 初始化配置的两侧比例。 |
| `TradeExecutorUpdated(oldTradeExecutor, newTradeExecutor)` | 回调执行器变化。 |
| `BusinessUpdated(oldBusiness, newBusiness)` | 业务执行地址变化。 |

这些桶没有链上枚举接口。索引器可按事件维护已出现的 owner 和 multiplier，再调用 getter 校验累计值。Market 的顺逆差、退税和权利铸造应结合 Market 与权利合约事件统计，不要仅靠 SaleRecorded 推导全部经济状态。

## 7. 生命周期与接入检查清单

Market 踢出的是 accountId，删除该账户经济状态；但 MerchantBase 的桶以 owner + multiplier 或 multiplier 为键，**不会随踢出自动清零**。相同 owner–merchant 重新注册取得新 ID 后，如果乘数相同，会继续匹配原有的 MerchantBase 桶。重新注册不是平台业务账本的自动重置机制。

发布集成前应确认：

- 使用平台代理地址注册、收款和调用，不误用实现合约地址。
- 初始化调用者与最终合约管理员符合预期，初始化比例之和为 10000。
- Market、underlying、SettlementAsset、TradeExecutor 配置一致。
- 每个接入账户已注册激活，owner 在支持名单内，业务约定保持账户乘数不变。
- `_tradeIn` 使用传入的 multiplier 区分业务资金口径，并校验 rechargeTarget 和 data。
- 前端显示的可释放额经过比例计算；不会把 owner/business 的原始 received 重复当成可支出余额。
- tradeOut 的 buyer 是源账户 owner，sellerAccountId 是目标收款账户，释放金额包含权利费用。
- business 入口自行验证创作者应得金额；有额度不等于有足够的即时现金。
- 不在收款回调中再次调用同一个 Market.trade；不再使用旧 executor 的 approve/transferFrom 收款模式。
- 若升级已有代理，单独审查存储布局、历史桶和新增比例字段的初始化/迁移；本文的新部署流程不能替代升级迁移方案。

当前相关行为可对照 [`MerchantBaseTest.t.sol`](../test/MerchantBaseTest.t.sol) 与 [`MerchantAccountingRegression.t.sol`](../test/MerchantAccountingRegression.t.sol)。
