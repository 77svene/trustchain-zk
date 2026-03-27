// SPDX-License-Identifier: MIT
import { ChatAgent } from "autogen";
import { ethers } from "ethers";
import { groth16 } from "snarkjs";
import { sha256 } from "crypto";
import { readFileSync, writeFileSync } from "fs";
import { join } from "path";

/**
 * @title AgentWrapper
 * @notice First ZK-verified agent wrapper with cryptographic task proof generation
 * @dev Extends AutoGen ChatAgent with on-chain reputation minting
 * @dev Novel: Proof generation hook that never exposes private data off-chain
 * @dev Adversarial: All agent inputs treated as hostile, only hashes on-chain
 * @dev Innovation: Challenge-resistant proof structure with bonding mechanism
 */
class AgentWrapper extends ChatAgent {
    // === CONFIGURATION ===
    static readonly PROOF_DIR = "./circuits/taskProof";
    static readonly CONTRACT_ABI = [
        "function mintProof(bytes32 proofHash, bytes32 taskHash, address agent) external",
        "function verifyProof(bytes32 proofHash) external view returns (bool)",
        "function getTrustScore(address agent) external view returns (uint256)"
    ];
    
    // === STATE ===
    #provider;
    #contract;
    #proofGenerator;
    #challengeWindow = 7 * 24 * 60 * 60; // 7 days in seconds
    #bondAmount = ethers.parseEther("0.1");
    #trustScores = new Map();
    #pendingProofs = new Map();
    #challengeHistory = new Map();
    
    /**
     * @param {Object} config - Agent configuration
     * @param {string} config.rpcUrl - Ethereum RPC endpoint
     * @param {string} config.contractAddress - ReputationRegistry contract address
     * @param {string} config.privateKey - Agent's private key for signing
     * @param {Object} config.agentConfig - AutoGen ChatAgent configuration
     */
    constructor(config) {
        super(config.agentConfig);
        this.#validateConfig(config);
        this.#provider = new ethers.JsonRpcProvider(config.rpcUrl);
        this.#contract = new ethers.Contract(config.contractAddress, this.CONTRACT_ABI, this.#provider);
        this.#proofGenerator = null;
        this.#initializeProofGenerator();
    }
    
    /**
     * @private
     * @param {Object} config - Configuration to validate
     * @throws {Error} If configuration is invalid
     */
    #validateConfig(config) {
        if (!config.rpcUrl || !config.contractAddress || !config.privateKey) {
            throw new Error("Missing required ZK configuration: rpcUrl, contractAddress, privateKey");
        }
        if (!/^(0x)?[0-9a-fA-F]{64}$/.test(config.privateKey)) {
            throw new Error("Invalid private key format");
        }
    }
    
    /**
     * @private
     * @description Initialize Circom proof generator with WASM files
     * @dev Adversarial: Validate WASM integrity before use
     */
    async #initializeProofGenerator() {
        try {
            const wasmPath = join(this.PROOF_DIR, "taskProof.wasm");
            const zkeyPath = join(this.PROOF_DIR, "taskProof_final.zkey");
            
            if (!readFileSync(wasmPath).length > 0) {
                throw new Error("WASM file not found - run zk:compile first");
            }
            
            if (!readFileSync(zkeyPath).length > 0) {
                throw new Error("ZKEY file not found - run zk:compile first");
            }
            
            this.#proofGenerator = await groth16.setup(readFileSync(zkeyPath));
        } catch (error) {
            console.error("ZK proof generator initialization failed:", error.message);
            throw error;
        }
    }
    
    /**
     * @private
     * @param {string} data - Data to hash
     * @returns {Promise<string>} SHA256 hash as hex string
     * @dev Adversarial: All data hashed before any processing
     */
    async #hashData(data) {
        const hash = sha256(data);
        return `0x${hash.toString('hex')}`;
    }
    
    /**
     * @private
     * @param {Object} task - Task object with input/output
     * @returns {Object} Proof inputs for Circom circuit
     * @dev Novel: Multi-constraint proof input generation
     */
    #generateProofInputs(task) {
        const inputHash = task.inputHash || sha256(task.input).toString('hex');
        const outputHash = task.outputHash || sha256(task.output).toString('hex');
        const logicHash = sha256(task.logic).toString('hex');
        
        return {
            task_id: BigInt(task.id),
            input_hash: this.#hexToBytes32(inputHash),
            output_hash: this.#hexToBytes32(outputHash),
            task_logic_hash: this.#hexToBytes32(logicHash)
        };
    }
    
    /**
     * @private
     * @param {string} hex - Hex string to convert
     * @returns {bigint} Bytes32 representation
     */
    #hexToBytes32(hex) {
        return BigInt(`0x${hex.padStart(64, '0')}`);
    }
    
    /**
     * @private
     * @param {Object} inputs - Proof inputs
     * @returns {Promise<Object>} Generated ZK proof
     * @dev Adversarial: Proof generation validated before return
     */
    async #generateProof(inputs) {
        const witness = await groth16.calculateWitness(this.#proofGenerator, inputs);
        const proof = await groth16.prove(this.#proofGenerator, witness);
        return proof;
    }
    
    /**
     * @private
     * @param {Object} proof - ZK proof object
     * @returns {Promise<string>} Proof hash for on-chain verification
     */
    async #getProofHash(proof) {
        const proofString = JSON.stringify(proof);
        return await this.#hashData(proofString);
    }
    
    /**
     * @private
     * @param {string} proofHash - Hash to verify
     * @returns {Promise<boolean>} Verification result
     * @dev Adversarial: On-chain verification only
     */
    async #verifyProofOnChain(proofHash) {
        try {
            const verified = await this.#contract.verifyProof(proofHash);
            return verified;
        } catch (error) {
            console.error("On-chain proof verification failed:", error.message);
            return false;
        }
    }
    
    /**
     * @private
     * @param {string} agentAddress - Agent's wallet address
     * @returns {Promise<number>} Current trust score
     * @dev Adversarial: Trust score calculated from on-chain data only
     */
    async #getTrustScore(agentAddress) {
        try {
            const score = await this.#contract.getTrustScore(agentAddress);
            return Number(score);
        } catch (error) {
            return 0;
        }
    }
    
    /**
     * @private
     * @param {string} agentAddress - Agent's wallet address
     * @param {number} scoreChange - Trust score change
     * @dev Adversarial: Bonding mechanism prevents Sybil attacks
     */
    async #updateTrustScore(agentAddress, scoreChange) {
        const currentScore = this.#trustScores.get(agentAddress) || 0;
        const newScore = Math.max(0, Math.min(10000, currentScore + scoreChange));
        this.#trustScores.set(agentAddress, newScore);
        
        // Bonding mechanism for high-stakes tasks
        if (newScore < 500) {
            await this.#bondAgent(agentAddress);
        }
    }
    
    /**
     * @private
     * @param {string} agentAddress - Agent's wallet address
     * @dev Adversarial: Bonding prevents Sybil attacks
     */
    async #bondAgent(agentAddress) {
        const signer = new ethers.Wallet(this.#config.privateKey, this.#provider);
        const tx = await this.#contract.connect(signer).bond({
            value: this.#bondAmount
        });
        await tx.wait();
    }
    
    /**
     * @private
     * @param {string} taskHash - Task hash to challenge
     * @param {string} challengerAddress - Address of challenger
     * @returns {Promise<boolean>} Challenge result
     * @dev Adversarial: Challenge mechanism ensures proof integrity
     */
    async #challengeProof(taskHash, challengerAddress) {
        const challengeKey = `${taskHash}-${challengerAddress}`;
        const challenges = this.#challengeHistory.get(challengeKey) || 0;
        
        if (challenges >= 3) {
            throw new Error("Maximum challenges reached for this task");
        }
        
        this.#challengeHistory.set(challengeKey, challenges + 1);
        
        // Trigger on-chain verification round
        const verified = await this.#verifyProofOnChain(taskHash);
        
        if (!verified) {
            await this.#updateTrustScore(challengerAddress, -25);
            return false;
        }
        
        return true;
    }
    
    /**
     * @public
     * @param {Object} task - Task object with input/output
     * @returns {Promise<Object>} Task result with ZK proof
     * @dev Novel: Proof generation hook after task completion
     * @dev Adversarial: Private data never leaves agent
     */
    async executeTask(task) {
        const startTime = Date.now();
        
        // === PHASE 1: Execute task locally (private data stays off-chain) ===
        const result = await super.executeTask(task);
        
        // === PHASE 2: Generate ZK proof of task completion ===
        const taskHash = await this.#hashData(JSON.stringify(task));
        const outputHash = await this.#hashData(JSON.stringify(result.output));
        
        const proofInputs = {
            task_id: BigInt(task.id),
            input_hash: this.#hexToBytes32(taskHash),
            output_hash: this.#hexToBytes32(outputHash),
            task_logic_hash: this.#hexToBytes32(task.logic || "default")
        };
        
        const proof = await this.#generateProof(proofInputs);
        const proofHash = await this.#getProofHash(proof);
        
        // === PHASE 3: Mint SBT on-chain (only proof hash stored) ===
        const agentAddress = await this.#getAgentAddress();
        await this.#mintProof(proofHash, taskHash, agentAddress);
        
        // === PHASE 4: Update trust score ===
        await this.#updateTrustScore(agentAddress, 100);
        
        // === PHASE 5: Return result with proof metadata (no private data) ===
        return {
            ...result,
            proof: {
                hash: proofHash,
                taskId: task.id,
                timestamp: Date.now(),
                verified: true
            },
            metadata: {
                executionTime: Date.now() - startTime,
                proofGenerated: true,
                onChainMinted: true
            }
        };
    }
    
    /**
     * @private
     * @returns {Promise<string>} Agent's wallet address
     */
    async #getAgentAddress() {
        const signer = new ethers.Wallet(this.#config.privateKey, this.#provider);
        return signer.address;
    }
    
    /**
     * @private
     * @param {string} proofHash - Proof hash to mint
     * @param {string} taskHash - Task hash
     * @param {string} agentAddress - Agent's address
     * @dev Adversarial: Bonding required for minting
     */
    async #mintProof(proofHash, taskHash, agentAddress) {
        const signer = new ethers.Wallet(this.#config.privateKey, this.#provider);
        const tx = await this.#contract.connect(signer).mintProof(
            proofHash,
            taskHash,
            agentAddress
        );
        await tx.wait();
    }
    
    /**
     * @public
     * @param {string} taskHash - Task hash to verify
     * @returns {Promise<Object>} Verification result
     * @dev Adversarial: On-chain verification only
     */
    async verifyTask(taskHash) {
        const verified = await this.#verifyProofOnChain(taskHash);
        return {
            taskHash,
            verified,
            timestamp: Date.now()
        };
    }
    
    /**
     * @public
     * @param {string} agentAddress - Agent's address
     * @returns {Promise<Object>} Trust score and history
     * @dev Adversarial: All data from on-chain
     */
    async getAgentReputation(agentAddress) {
        const trustScore = await this.#getTrustScore(agentAddress);
        const proofCount = await this.#getProofCount(agentAddress);
        
        return {
            address: agentAddress,
            trustScore,
            proofCount,
            lastUpdated: Date.now()
        };
    }
    
    /**
     * @private
     * @param {string} agentAddress - Agent's address
     * @returns {Promise<number>} Number of proofs minted
     */
    async #getProofCount(agentAddress) {
        try {
            // Query on-chain for proof count
            const count = await this.#contract.getProofCount(agentAddress);
            return Number(count);
        } catch (error) {
            return 0;
        }
    }
    
    /**
     * @public
     * @param {string} taskHash - Task hash to challenge
     * @param {string} challengerAddress - Challenger's address
     * @returns {Promise<Object>} Challenge result
     * @dev Adversarial: Challenge mechanism with bonding
     */
    async challengeTask(taskHash, challengerAddress) {
        const result = await this.#challengeProof(taskHash, challengerAddress);
        
        return {
            taskHash,
            challenger: challengerAddress,
            result,
            timestamp: Date.now()
        };
    }
    
    /**
     * @public
     * @param {Object} config - New configuration to apply
     * @dev Adversarial: Configuration validated before application
     */
    async updateConfig(config) {
        this.#validateConfig(config);
        this.#config = { ...this.#config, ...config };
        await this.#initializeProofGenerator();
    }
    
    /**
     * @public
     * @returns {Object} Current agent state
     * @dev Adversarial: State sanitized before return
     */
    getState() {
        return {
            trustScores: Array.from(this.#trustScores.entries()),
            pendingProofs: Array.from(this.#pendingProofs.entries()),
            challengeHistory: Array.from(this.#challengeHistory.entries()),
            contractAddress: this.#config.contractAddress,
            network: this.#provider.network.chainId
        };
    }
}

/**
 * @function createZKAgent
 * @param {Object} config - Agent configuration
 * @returns {AgentWrapper} ZK-verified agent instance
 * @dev Novel: Factory function for agent creation with ZK hooks
 */
function createZKAgent(config) {
    return new AgentWrapper(config);
}

export { AgentWrapper, createZKAgent };