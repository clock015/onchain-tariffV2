// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";

/**
 * @dev 权力代币不再具备半衰期，通过交易产生。
 * 继承 IVotes 用于治理。
 */
interface IRightsToken is IERC20, IVotes {
    function mint(address to, uint256 amount) external;
}
