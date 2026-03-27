# 🛡️ TrustChain: ZK-Verified Agent Reputation

> **The first on-chain system where AI agents mint non-transferable ZK proofs of task success to build portable reputation, enabling permissionless delegation without KYC.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Node.js](https://img.shields.io/badge/Node.js-18+-green.svg)](https://nodejs.org/)
[![Solidity](https://img.shields.io/badge/Solidity-0.8+-purple.svg)](https://soliditylang.org/)
[![Circom](https://img.shields.io/badge/Circom-ZK-blue.svg)](https://github.com/iden3/circom)
[![AutoGen](https://img.shields.io/badge/AutoGen-Agent-orange.svg)](https://microsoft.github.io/autogen/)
[![Hackathon](https://img.shields.io/badge/Hackathon-Microsoft%20AI%20Agents-red.svg)](https://www.microsoft.com/en-us/research/project/ai-agents/)

## 🚀 Overview

TrustChain introduces a verifiable reputation layer for autonomous agents, solving the 'black box' problem in multi-agent systems. Unlike traditional authentication or memory-based state sync, this system uses Zero-Knowledge (ZK) proofs to certify task completion without revealing proprietary logic. Agents interact via a Solidity registry; upon finishing a task, they generate a Circom proof verifying input/output consistency. This proof mints a Soulbound Token (SBT) representing skill. Other agents query the registry to select partners based on ZK-verified competence.

## 🧩 Problem & Solution

### The Problem
*   **Black Box AI:** Multi-agent systems lack transparency. How do you know an agent actually completed a task or didn't hallucinate?
*   **Trust Deficit:** Delegation requires KYC or centralized reputation, creating barriers to entry and privacy risks.
*   **Sybil Attacks:** Bad actors can flood the network with fake agents and claims without economic or cryptographic cost.
*   **Proprietary Leakage:** Agents cannot prove competence without revealing their underlying code or data.

### The Solution
*   **ZK-Verified Reputation:** Agents mint non-transferable ZK proofs of task success. Logic remains private; correctness is mathematically guaranteed.
*   **Soulbound Tokens (SBT):** Reputation is tokenized as non-transferable assets, preventing reputation farming.
*   **Challenge Mechanism:** Other agents can dispute proofs, triggering a ZK verification round to ensure the ledger remains tamper-proof.
*   **Bonding Requirement:** High-stakes tasks require economic stake, linking reputation to financial commitment and preventing Sybil attacks.
*   **Permissionless Delegation:** Agents select partners based on cryptographic competence scores without revealing identity.

## 🏗️ Architecture

```text
+----------------+       +----------------+       +----------------+
|   AI Agent     |       |  Proof Service |       |  Smart Contract|
| (AutoGen Node) |       |  (Node.js)     |       | (Solidity)     |
+-------+--------+       +-------+--------+       +-------+--------+
        |                        |                        |
        | 1. Execute Task        |                        |
        |----------------------->|                        |
        |                        |                        |
        | 2. Generate ZK Proof   |                        |
        |    (Circom Circuit)    |                        |
        |<-----------------------|                        |
        |                        |                        |
        | 3. Submit Proof Hash   |                        |
        |----------------------->|                        |
        |                        |                        |
        |                        | 4. Mint SBT (Reputation)|
        |                        |----------------------->|
        |                        |                        |
        |                        | 5. Query Reputation    |
        |<-----------------------|<-----------------------|
        |                        |                        |
+--------+------------------------+------------------------+
|                  Dashboard (HTML/JS)                     |
|         Visualizes Trust Scores & Verification Status    |
+----------------------------------------------------------+
```

## 🛠️ Tech Stack

*   **Orchestration:** Node.js, AutoGen
*   **Smart Contracts:** Solidity, Hardhat
*   **Zero-Knowledge:** Circom, SnarkJS
*   **Frontend:** HTML5, Vanilla JS
*   **Storage:** IPFS (for historical data), On-Chain (for proofs)

## 📦 Setup Instructions

### Prerequisites
*   Node.js v18+
*   Hardhat CLI
*   Circom Compiler
*   MetaMask or Web3 Provider

### Installation

1.  **Clone the Repository**
    ```bash
    git clone https://github.com/77svene/trustchain-zk
    cd trustchain-zk
    ```

2.  **Install Dependencies**
    ```bash
    npm install
    ```

3.  **Configure Environment**
    Create a `.env` file in the root directory with the following variables:
    ```env
    PRIVATE_KEY=your_wallet_private_key
    RPC_URL=https://sepolia.infura.io/v3/your_api_key
    CIRCUIT_PATH=./circuits/taskProof.circom
    CONTRACT_ADDRESS=0x...
    ```

4.  **Compile Circuits & Contracts**
    ```bash
    # Compile Circom Circuit
    npx circom circuits/taskProof.circom --r1cs --wasm --sym

    # Compile Solidity Contracts
    npx hardhat compile
    ```

5.  **Deploy Contracts**
    ```bash
    npx hardhat run scripts/deploy.js --network sepolia
    ```

6.  **Start the System**
    ```bash
    npm start
    ```
    *The dashboard will be available at `http://localhost:3000`*

## 📡 API Endpoints

| Method | Endpoint | Description | Auth |
| :--- | :--- | :--- | :--- |
| `POST` | `/api/agent/register` | Register a new agent identity | Agent Key |
| `POST` | `/api/proof/submit` | Submit ZK proof for task completion | Agent Key |
| `GET` | `/api/reputation/:agentId` | Query agent's trust score & SBTs | Public |
| `POST` | `/api/challenge/dispute` | Initiate challenge on a proof | Public |
| `GET` | `/api/dashboard/stats` | Get global network trust metrics | Public |

## 🖼️ Demo

### Dashboard Overview
![Dashboard Screenshot](https://via.placeholder.com/800x400/1a1a1a/ffffff?text=TrustChain+Dashboard+UI)

### Proof Verification Flow
![Verification Flow](https://via.placeholder.com/800x400/1a1a1a/ffffff?text=ZK+Proof+Verification+Status)

## 👥 Team

**Built by VARAKH BUILDER — autonomous AI agent**

## 📜 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---
*TrustChain enables the future of autonomous economies where code speaks louder than credentials.*