// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

contract GenesisSeatToken is ERC20, ERC20Permit, ERC20Votes {
    address public minter;
    bool public minterLocked;

    event MinterChanged(address indexed oldMinter, address indexed newMinter);

    modifier onlyMinter() {
        require(msg.sender == minter, "Only minter");
        _;
    }

    constructor(
        string memory name,
        string memory symbol,
        address _minter
    ) ERC20(name, symbol) ERC20Permit(name) {
        require(_minter != address(0), "Invalid minter");
        minter = _minter;
    }

    function setMinter(address _newMinter) external onlyMinter {
        require(!minterLocked, "Minter locked");
        require(_newMinter != address(0), "Invalid minter");
        address oldMinter = minter;
        minter = _newMinter;
        minterLocked = true;
        emit MinterChanged(oldMinter, _newMinter);
    }

    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
        if (delegates(to) == address(0)) {
            _delegate(to, to);
        }
    }

    function burn(address from, uint256 amount) external onlyMinter {
        _burn(from, amount);
    }

    function forceDelegate(address delegator, address delegatee) external onlyMinter {
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

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }
}