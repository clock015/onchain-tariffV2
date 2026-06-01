// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

contract SeatToken is ERC20, ERC20Permit, ERC20Votes {
    address public minter;

    constructor(
        string memory name,
        string memory symbol,
        address _minter
    ) ERC20(name, symbol) ERC20Permit(name) {
        minter = _minter;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "Only minter");
        _mint(to, amount);
        // 如果用户从未委派过，默认委派给自己
        if (delegates(to) == address(0)) {
            _delegate(to, to);
        }
    }

    // 新增：由核心合约调用的同步委派
    function forceDelegate(address delegator, address delegatee) external {
        require(msg.sender == minter, "Only minter");
        _delegate(delegator, delegatee);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Votes) {
        if (from != address(0) && to != address(0)) revert("Non-transferable");
        super._update(from, to, value);
    }

    function nonces(
        address owner
    ) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }
    function CLOCK_MODE() public view override returns (string memory) {
        return "mode=timestamp";
    }
}
