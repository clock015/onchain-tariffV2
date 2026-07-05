// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ISettlementAsset {
    function asset() external view returns (address);

    function pull(address from, uint256 amount) external;

    function push(address to, uint256 amount) external;
}
