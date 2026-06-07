#!/bin/bash

# 创建存放 ABI 的文件夹
mkdir -p ./abis

# 提取核心合约的 ABI
forge inspect Market abi --json > ./abis/Market.json
forge inspect ProportionalElection abi --json > ./abis/ProportionalElection.json
forge inspect FinalGovernor abi --json > ./abis/FinalGovernor.json
# forge inspect TradeExecutor abi --json > ./abis/TradeExecutor.json

echo "ABI 提取完成，存放在 ./abis 目录"

# chmod +x extract-abi.sh && ./extract-abi.sh