# Atomic Trade Core Governance System

## 1. System Overview

The Atomic Trade Core System is a decentralized framework integrating on-chain commerce with a governance model. Its fundamental principle is the deep coupling of commercial activity with governance power: voting weight is not acquired through secondary markets but is generated through verified trade contributions (transaction volume). By implementing "Dual Consensus Governance" and "Annual Weight Normalization," the system aims to balance the long-term interests of both buyers (demand side) and sellers (supply side).

## 2. Core Architecture

The system consists of three distinct layers:

*   **Business Layer**: Comprised of `Market.sol` and `TradeExecutor.sol`. It handles fund distribution, merchant onboarding, and taxation logic.
*   **Rights Layer**: Comprised of `ProportionalElection.sol` and its associated factories. It manages the minting of governance tokens (SeatTokens), annual weight normalization, and sliding window rotation.
*   **Decision Layer**: Built on `FinalGovernor.sol`. It implements the dual-consensus voting logic, permission management, and proposal execution.

---

## 3. Core Operational Principles

### 3.1 Trade Distribution Model (100%-90%-9%-1%)
When a transaction occurs in the `Market` contract, the total amount is distributed as follows:
1.  **Merchant Settlement (90%)**: Forwarded via the `TradeExecutor` to the merchant’s designated business contract or address.
2.  **Tax Pool (9%)**: Retained within the `Market` contract. This portion corresponds to the generation of "Deficit Points" and "Surplus Points."
3.  **Protocol Fee (1%)**: Transferred directly to the protocol Vault.
4.  **Rights Minting**: Based on the 1% protocol fee, the system mints an equivalent value of `SeatTokens` for both the buyer and the seller.

### 3.2 Point Offsetting & Tax Refund Mechanism
The system incentivizes participants to maintain a trade balance within the ecosystem (acting as both buyer and seller).
*   **Buyer Deficit Points**: Accumulated through consumption, representing capital outflow.
*   **Seller Surplus Points**: Accumulated through sales, representing capital inflow.
*   **Operational Logic**: Users can offset "Deficit Points" against "Surplus Points." By calling `claimTaxRefund`, the system calculates `min(Deficit Points, Surplus Points)`, burns the offset amount, and refunds an equivalent value of tokens (e.g., USDC) from the tax pool.

### 3.3 Annual Weight Normalization & Sliding Window
To prevent governance inflation and the permanent dominance of early high-volume participants, the system implements:
*   **Annual Normalization**: The total voting weight for each year (365 days) is fixed at **100 votes**. Regardless of the annual transaction volume, an individual's weight is always calculated as: `(Individual Holdings / Annual Total Supply) * 100`.
*   **5-Year Sliding Window**: Only tokens generated within the most recent **5 years** are eligible for voting. The total governance weight of the entire system is capped at **500 votes** ($100 \text{ votes/year} \times 5 \text{ years}$).
*   **Weight Rotation**: As time progresses, tokens from older years rotate out of the active window, ensuring governance remains in the hands of recent active contributors.

### 3.4 Dual Consensus Voting & Governance Authority
In `FinalGovernor`, the passage of a proposal requires a consensus between buyers and sellers, granting the Governor high-level control over the protocol.

#### **Dual Consensus Logic**
*   **Formula**: `Effective For Votes = min(Total Buyer "For" Votes, Total Seller "For" Votes)`.
*   **Equilibrium**: This model ensures that any protocol-level change must receive majority support from both the Buyer group (deficit side) and the Seller group (surplus side). Unilateral interests (e.g., sellers pushing for fee hikes) cannot pass a proposal due to the constraints of the `min` function.

#### **Governance Scope**
As the supreme authority of the system, the `FinalGovernor` holds powers including:
*   **Market Access & Eviction**: The authority to forcibly remove non-compliant merchants via the `kickMerchant` function and confiscate their deposits.
*   **Protocol Parameter Adjustment**: Modifying the trade challenge period, setting vault addresses, and adjusting governance thresholds.
*   **Logic Upgradeability**: Authorizing UUPS proxy upgrades to determine the future iteration of the protocol.
*   **Asset Management**: Overseeing the allocation and utilization of treasury funds.

---

## 4. Security & Technical Features

*   **Soulbound Properties**: `SeatTokens` are non-transferable. Governance power is earned solely through trade contribution, preventing the decoupling of voting power from actual ecosystem utility.
*   **UUPS Upgradeability**: Core contracts utilize the UUPS (Universal Upgradeable Proxy Standard) for seamless logic iterations.
*   **Reentrancy Protection**: Implements `ReentrancyGuardTransient` (utilizing the EVM Cancun `TSTORE` opcode) to optimize gas efficiency while ensuring safety.
*   **Merchant Challenge Mechanism**: A deposit-based challenge window is provided. Any participant can initiate a challenge, with the final adjudication handled by the Governor.

---

## 5. Development & Testing

This project is developed using the **Foundry** framework:

*   **Compiler Version**: `solc 0.8.20+`
*   **EVM Version**: `cancun` (required for transient storage opcodes)
*   **Libraries**: OpenZeppelin Contracts & Upgradeable v5.x

### Running Tests
```bash
# Execute full test suite (Trade flow, Sliding Window, and Dual Consensus)
forge test --evm-version cancun -vv
```

---

## 6. Directory Structure

```text
src/
├── Market.sol             # Core trade logic, point management, and fund distribution
├── TradeExecutor.sol      # Fund forwarding and external business execution
├── interfaces/            # Standard system interface definitions
├── RightsToken/
│   ├── ProportionalElection.sol # Weight normalization and sliding window calculation
│   ├── SeatToken.sol            # Non-transferable underlying voting tokens
│   └── SeatTokenFactory.sol     # Annual rights token factory
└── Governor/
    ├── GovernorDualConsensusLogic.sol # Dual Consensus (Buyer-Seller) core algorithm
    └── FinalGovernor.sol              # Governance proposal center & Timelock management
```