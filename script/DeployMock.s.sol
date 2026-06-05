// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// --- 把 Mock 合约直接定义在脚本文件里 ---
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    // USDC 标准是 6 位精度
    function decimals() public view virtual override returns (uint8) {
        return 6;
    }

    // 方便测试的铸造功能
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// --- 部署脚本 ---
contract DeployMock is Script {
    function run() external {
        // 从环境变量读取私钥
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying MockUSDC using address:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 部署
        MockUSDC usdc = new MockUSDC();

        // 初始给自己印 1,000,000 USDC (6位精度)
        usdc.mint(deployer, 1_000_000 * 10 ** 6);

        vm.stopBroadcast();

        console.log("======================================");
        console.log("Mock USDC Address:", address(usdc));
        console.log("Status: 1,000,000 USDC minted to deployer");
        console.log("======================================");
        console.log(
            "Next step: Copy the address above to your .env as USDC_ADDRESS"
        );
    }
}

// forge script script/DeployMock.s.sol:DeployMock --rpc-url http://127.0.0.1:8545 --broadcast -vv
