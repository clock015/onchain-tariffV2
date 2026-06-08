// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
// 1. 引入 UUPS 升级模块
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "../interfaces/ISeatToken.sol";
import "../interfaces/ISeatTokenFactory.sol";

/**
 * @title ProportionalElection
 * @notice 动态权重治理聚合器 - 完全支持 UUPS 可升级模式
 */
contract ProportionalElection is
    Initializable,
    IVotes,
    EIP712Upgradeable,
    NoncesUpgradeable,
    OwnableUpgradeable,
    // 2. 继承 UUPS 接口
    UUPSUpgradeable
{
    // --- 常量 (不占用存储槽) ---
    uint256 public constant CYCLE_DURATION = 365 days;
    uint256 public constant BUFFER_DURATION = 30 days;
    uint256 public constant WEIGHT_PER_YEAR = 100 * 1e18;
    uint256 public constant MAX_ACTIVE_ROUNDS = 5;

    // --- 状态变量 ---
    ISeatTokenFactory public seatFactory;
    uint256 public genesisTime;
    address public minter;

    struct Round {
        address seatToken;
        bool initialized;
    }

    mapping(uint256 => Round) public rounds;
    mapping(address => address) private _userDelegates;

    bytes32 private constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    // --- 事件 ---
    event RoundInitialized(uint256 indexed roundId, address tokenAddress);
    event SeatMinted(
        uint256 indexed roundId,
        address indexed to,
        uint256 amount
    );
    event SeatBurned(
        uint256 indexed roundId,
        address indexed from,
        uint256 amount
    );
    event MinterChanged(address indexed oldMinter, address indexed newMinter);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice 初始化函数
     */
    function initialize(
        address _factory,
        address _initialMinter
    ) public initializer {
        // 3. 调用各基类的初始化
        __Ownable_init(msg.sender);
        __EIP712_init("ProportionalElection", "1");
        __Nonces_init();

        seatFactory = ISeatTokenFactory(_factory);
        minter = _initialMinter;
        genesisTime = block.timestamp;
    }

    // 4. 必须实现此函数以支持 UUPS 升级授权
    // 只有 Owner 可以升级此合约
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    /**
     * @notice 设置新的铸造执行者地址
     */
    function setMinter(address _newMinter) external onlyOwner {
        require(_newMinter != address(0), "Invalid address");
        address oldMinter = minter;
        minter = _newMinter;
        emit MinterChanged(oldMinter, _newMinter);
    }

    // =============================================================
    //                      核心逻辑 (保持不变)
    // =============================================================

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "ProportionalElection: only minter");
        uint256 rId = currentRoundId();

        if (!rounds[rId].initialized) {
            _initializeRound(rId);
        }

        ISeatToken(rounds[rId].seatToken).mint(to, amount);

        address currentDel = _userDelegates[to];
        if (currentDel != address(0) && currentDel != to) {
            ISeatToken(rounds[rId].seatToken).forceDelegate(to, currentDel);
        }

        emit SeatMinted(rId, to, amount);
    }

    /**
     * @notice 销毁指定地址在“最新活跃轮次”中的席位代币
     * @dev 只能由 Owner（治理合约/Timelock）调用
     * @param from 被处罚的地址
     * @param amount 销毁的数量
     */
    function burn(address from, uint256 amount) external onlyOwner {
        (, uint256 endId) = getActiveRange(block.timestamp);

        address token = rounds[endId].seatToken;

        // 鲁棒性检查：如果系统处于最开始的 30 天，可能没有任何活跃轮次
        require(
            token != address(0),
            "ProportionalElection: no active round token to burn"
        );

        // 调用底层 SeatToken 的销毁函数
        ISeatToken(token).burn(from, amount);

        // 触发销毁事件，记录实际执行的轮次 ID
        emit SeatBurned(endId, from, amount);
    }

    function _initializeRound(uint256 rId) internal {
        address newToken = seatFactory.createSeatToken(
            string(abi.encodePacked("Council Seat ", _uintToString(rId))),
            "CS",
            address(this)
        );
        rounds[rId].seatToken = newToken;
        rounds[rId].initialized = true;
        emit RoundInitialized(rId, newToken);
    }

    function getActiveRange(
        uint256 timepoint
    ) public view returns (uint256 startId, uint256 endId) {
        if (timepoint < genesisTime) return (1, 0);
        uint256 elapsed = timepoint - genesisTime;
        uint256 rId = elapsed / CYCLE_DURATION;
        uint256 offset = elapsed % CYCLE_DURATION;

        if (offset < BUFFER_DURATION) {
            if (rId == 0) return (1, 0);
            endId = rId - 1;
        } else {
            endId = rId;
        }
        startId = endId >= (MAX_ACTIVE_ROUNDS - 1)
            ? endId - (MAX_ACTIVE_ROUNDS - 1)
            : 0;
    }

    function _normalize(
        uint256 amount,
        uint256 supply
    ) internal pure returns (uint256) {
        if (supply == 0 || amount == 0) return 0;
        return (amount * WEIGHT_PER_YEAR) / supply;
    }

    function getVotes(address account) public view override returns (uint256) {
        (uint256 start, uint256 end) = getActiveRange(block.timestamp);
        if (start > end) return 0;
        uint256 totalWeight = 0;
        for (uint256 r = start; r <= end; r++) {
            address token = rounds[r].seatToken;
            if (token != address(0)) {
                totalWeight += _normalize(
                    IVotes(token).getVotes(account),
                    IERC20(token).totalSupply()
                );
            }
        }
        return totalWeight;
    }

    function getPastVotes(
        address account,
        uint256 timepoint
    ) public view override returns (uint256) {
        (uint256 start, uint256 end) = getActiveRange(timepoint);
        if (start > end) return 0;
        uint256 totalWeight = 0;
        for (uint256 r = start; r <= end; r++) {
            address token = rounds[r].seatToken;
            if (token != address(0)) {
                totalWeight += _normalize(
                    IVotes(token).getPastVotes(account, timepoint),
                    IVotes(token).getPastTotalSupply(timepoint)
                );
            }
        }
        return totalWeight;
    }

    function getPastTotalSupply(
        uint256 timepoint
    ) public view override returns (uint256) {
        (uint256 start, uint256 end) = getActiveRange(timepoint);
        if (start > end) return 0;
        uint256 activeCount = 0;
        for (uint256 r = start; r <= end; r++) {
            if (rounds[r].initialized) activeCount++;
        }
        return activeCount * WEIGHT_PER_YEAR;
    }

    function delegate(address delegatee) public override {
        _delegate(msg.sender, delegatee);
    }
    function delegates(address account) public view override returns (address) {
        return _userDelegates[account];
    }

    function delegateBySig(
        address delegatee,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public override {
        require(block.timestamp <= expiry, "Signature expired");
        bytes32 structHash = keccak256(
            abi.encode(DELEGATION_TYPEHASH, delegatee, nonce, expiry)
        );
        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(hash, v, r, s);
        _useCheckedNonce(signer, nonce);
        _delegate(signer, delegatee);
    }

    function _delegate(address delegator, address delegatee) internal {
        address oldDelegate = _userDelegates[delegator];
        _userDelegates[delegator] = delegatee;
        uint256 cur = currentRoundId();
        uint256 start = cur >= MAX_ACTIVE_ROUNDS ? cur - MAX_ACTIVE_ROUNDS : 0;
        for (uint256 r = start; r <= cur; r++) {
            address token = rounds[r].seatToken;
            if (token != address(0)) {
                ISeatToken(token).forceDelegate(delegator, delegatee);
            }
        }
        emit DelegateChanged(delegator, oldDelegate, delegatee);
    }

    function currentRoundId() public view returns (uint256) {
        return (block.timestamp - genesisTime) / CYCLE_DURATION;
    }

    function clock() public view returns (uint48) {
        return uint48(block.timestamp);
    }
    function CLOCK_MODE() public pure returns (string memory) {
        return "mode=timestamp";
    }
    function nonces(address owner) public view override returns (uint256) {
        return super.nonces(owner);
    }

    function _uintToString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 j = v;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (v != 0) {
            k--;
            bstr[k] = bytes1(uint8(48 + (v % 10)));
            v /= 10;
        }
        return string(bstr);
    }
}
