// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/Market.sol";
import "../src/TradeExecutor.sol";
import "../src/RightsToken/ProportionalElection.sol";
import "../src/RightsToken/SeatTokenFactory.sol";
import "../src/Governor/FinalGovernor.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

contract DeploySystem is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(deployerPrivateKey);
        address underlyingToken = vm.envOr("USDC_ADDRESS", address(0));
        address vault = vm.envOr("VAULT_ADDRESS", admin);

        vm.startBroadcast(deployerPrivateKey);

        // --- 1. 部署工厂 ---
        SeatTokenFactory buyerFactory = new SeatTokenFactory();
        SeatTokenFactory sellerFactory = new SeatTokenFactory();

        // --- 2. 部署选举合约 (使用作用域 {} 减少栈压力) ---
        ProportionalElection buyerElection;
        ProportionalElection sellerElection;
        {
            buyerElection = ProportionalElection(
                address(
                    new ERC1967Proxy(
                        address(new ProportionalElection()),
                        abi.encodeWithSelector(
                            ProportionalElection.initialize.selector,
                            address(buyerFactory),
                            admin
                        )
                    )
                )
            );

            sellerElection = ProportionalElection(
                address(
                    new ERC1967Proxy(
                        address(new ProportionalElection()),
                        abi.encodeWithSelector(
                            ProportionalElection.initialize.selector,
                            address(sellerFactory),
                            admin
                        )
                    )
                )
            );
        }

        // 绑定工厂
        buyerFactory.setElectionContract(address(buyerElection));
        sellerFactory.setElectionContract(address(sellerElection));

        // --- 3. 部署 Timelock ---
        TimelockController timelock;
        {
            address[] memory proposers = new address[](1);
            proposers[0] = admin;
            address[] memory executors = new address[](1);
            executors[0] = address(0);
            timelock = new TimelockController(0, proposers, executors, admin);
        }

        // --- 4. 部署 Market ---
        Market market;
        {
            address marketImpl = address(new Market());
            bytes memory marketInit = abi.encodeWithSelector(
                Market.initialize.selector,
                underlyingToken,
                address(buyerElection),
                address(sellerElection),
                address(timelock),
                vault
            );
            market = Market(address(new ERC1967Proxy(marketImpl, marketInit)));
        }

        // --- 5. 部署执行器与 FinalGovernor ---
        TradeExecutor executor = new TradeExecutor(
            address(market),
            underlyingToken
        );
        market.setExecutor(address(executor));

        // 授权权限
        buyerElection.setMinter(address(market));
        sellerElection.setMinter(address(market));

        FinalGovernor governor;
        {
            address govImpl = address(new FinalGovernor());
            bytes memory govInit = abi.encodeWithSelector(
                FinalGovernor.initialize.selector,
                address(buyerElection),
                address(sellerElection),
                timelock
            );
            governor = FinalGovernor(
                payable(address(new ERC1967Proxy(govImpl, govInit)))
            );
        }

        // --- 6. 权限移交 ---
        market.transferOwnership(address(timelock));
        buyerElection.transferOwnership(address(timelock));
        sellerElection.transferOwnership(address(timelock));
        buyerFactory.transferOwnership(address(timelock));
        sellerFactory.transferOwnership(address(timelock));

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), admin);

        vm.stopBroadcast();

        console.log("Deployment Successful. Market:", address(market));
        console.log("Governor:", address(governor));
        console.log("Timelock:", address(timelock));
    }
}
