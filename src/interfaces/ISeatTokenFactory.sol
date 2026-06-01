// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ISeatTokenFactory {
    function createSeatToken(
        string calldata name,
        string calldata symbol,
        address minter
    ) external returns (address);
}
