// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockUSDC
 * @dev 模拟底层资产，带有公共 mint 函数方便测试
 */
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    // 某些 USDC 版本小数位是 6
    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
}

/**
 * @title MockRights
 * @dev 严格匹配测试脚本 Market.t.sol 的需求
 */
contract MockRights is ERC20, ERC20Permit, ERC20Votes, Ownable {
    address public minter;

    // OpenZeppelin V5: ERC20Permit 内部处理了 EIP712 的初始化
    constructor(
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) ERC20Permit(name) Ownable(msg.sender) {}

    /**
     * @dev 修复测试脚本报错：添加 setMinter 函数
     */
    function setMinter(address _minter) external onlyOwner {
        minter = _minter;
    }

    /**
     * @dev 实现 IRightsToken 接口
     */
    function mint(address to, uint256 amount) external {
        require(
            msg.sender == minter || msg.sender == owner(),
            "Caller is not the minter or owner"
        );
        _mint(to, amount);
    }

    // --- 必须重写的函数 (OpenZeppelin V5 标准) ---

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    /**
     * @dev 修复错误 (2333) 和 (6275):
     * 在 OZ V5 中，nonces 定义在 Nonces.sol 中，
     * 而 ERC20Permit 和 ERC20Votes 都继承了它。
     */
    function nonces(
        address owner
    ) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}

/**
 * @title MockTradeTarget
 * @dev 用于测试数据透传
 */
contract MockTradeTarget {
    function processOrder(
        address buyer,
        uint256 amount,
        string memory message
    ) external {
        // 业务逻辑模拟
    }
}
