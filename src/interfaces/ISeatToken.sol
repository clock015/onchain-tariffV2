// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";

interface ISeatToken is IERC20, IVotes {
    function mint(address to, uint256 amount) external;
    // 新增：销毁功能
    function burn(address from, uint256 amount) external;
    function forceDelegate(address delegator, address delegatee) external;
}