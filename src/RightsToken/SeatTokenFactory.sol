// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SeatToken.sol";
import "../interfaces/ISeatTokenFactory.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract SeatTokenFactory is ISeatTokenFactory, Ownable {
    // 被授权调用此工厂的选举合约地址
    address public electionContract;

    event ElectionContractSet(
        address indexed oldContract,
        address indexed newContract
    );

    constructor() Ownable(msg.sender) {}

    /**
     * @dev 设置选举合约地址。通常在部署完 ProportionalElection 后由管理员调用一次。
     */
    function setElectionContract(address _electionContract) external onlyOwner {
        require(_electionContract != address(0), "Invalid address");
        address old = electionContract;
        electionContract = _electionContract;
        emit ElectionContractSet(old, _electionContract);
    }

    /**
     * @dev 只有被授权的选举合约可以创建新的席位代币
     */
    function createSeatToken(
        string calldata name,
        string calldata symbol,
        address minter
    ) external override returns (address) {
        require(
            msg.sender == electionContract,
            "Factory: Caller is not the authorized election contract"
        );

        // 创建新的席位合约
        SeatToken newToken = new SeatToken(name, symbol, minter);
        return address(newToken);
    }
}
