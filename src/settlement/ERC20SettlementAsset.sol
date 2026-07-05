// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/ISettlementAsset.sol";

contract ERC20SettlementAsset is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ISettlementAsset
{
    using SafeERC20 for IERC20;

    IERC20 public token;
    mapping(address => bool) public controllers;

    event ControllerUpdated(address indexed controller, bool allowed);

    constructor() {
        _disableInitializers();
    }

    function initialize(address _token, address initialOwner) public initializer {
        require(_token != address(0), "Invalid token");
        require(initialOwner != address(0), "Invalid owner");
        __Ownable_init(initialOwner);
        token = IERC20(_token);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    modifier onlyController() {
        require(controllers[msg.sender], "Only controller");
        _;
    }

    function asset() external view returns (address) {
        return address(token);
    }

    function setController(address controller, bool allowed) external onlyOwner {
        require(controller != address(0), "Invalid controller");
        controllers[controller] = allowed;
        emit ControllerUpdated(controller, allowed);
    }

    function pull(address from, uint256 amount) external onlyController {
        if (amount == 0) return;
        token.safeTransferFrom(from, address(this), amount);
    }

    function push(address to, uint256 amount) external onlyController {
        if (amount == 0) return;
        token.safeTransfer(to, amount);
    }
}