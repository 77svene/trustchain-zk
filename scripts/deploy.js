// SPDX-License-Identifier: MIT
import { ethers } from "ethers";
import { writeFileSync, readFileSync, existsSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

/**
 * @title TrustChain Deployer
 * @notice Secure deployment script for ZK-verified reputation system
 * @dev All secrets from environment variables - no hardcoded credentials
 * @dev Adversarial: Validates all inputs, handles reverts gracefully
 * @dev Novel: Automated verification key loading from compiled artifacts
 */

// === CONFIGURATION ===
const NETWORKS = {
  sepolia: {
    chainId: 11155111,
    rpcUrl: process.env.SEPOLIA_RPC_URL || "https://sepolia.infura.io/v3/" + (process.env.INFURA_PROJECT_ID || ""),
    explorer: "https://sepolia.etherscan.io",
    gasPrice: 30000000000,
    gasLimit: 30000000
  }
};

const CONTRACTS = {
  AgentVerifier: "AgentVerifier",
  ReputationRegistry: "ReputationRegistry"
};

// === SECURITY: Environment Variable Validation ===
function validateEnv() {
  const required = [
    "DEPLOYER_PRIVATE_KEY",
    "SEPOLIA_RPC_URL",
    "ETHERSCAN_API_KEY"
  ];
  
  const missing = required.filter(key => !process.env[key]);
  if (missing.length > 0) {
    throw new Error(`Missing required environment variables: ${missing.join(", ")}`);
  }
  
  // Validate private key format
  if (!process.env.DEPLOYER_PRIVATE_KEY.startsWith("0x")) {
    throw new Error("DEPLOYER_PRIVATE_KEY must be in hex format (0x...)");
  }
  
  // Validate key length (32 bytes = 64 hex chars + 0x prefix)
  if (process.env.DEPLOYER_PRIVATE_KEY.length !== 66) {
    throw new Error("DEPLOYER_PRIVATE_KEY must be 32 bytes (66 characters including 0x)");
  }
}

// === SECURITY: Load Verification Key from Compiled Artifact ===
function loadVerificationKey() {
  try {
    const proofArtifactPath = join(__dirname, "../circuits/taskProof.json");
    if (!existsSync(proofArtifactPath)) {
      throw new Error("ZK verification key not found. Run 'npm run zk:compile' first.");
    }
    
    const artifact = JSON.parse(readFileSync(proofArtifactPath, "utf-8"));
    if (!artifact.vk) {
      throw new Error("Verification key not found in artifact");
    }
    
    return artifact.vk;
  } catch (error) {
    console.error("Failed to load verification key:", error.message);
    throw error;
  }
}

// === SECURITY: Gas Estimation with Fallback ===
async function estimateGas(provider, tx) {
  try {
    const gasEstimate = await provider.estimateGas(tx);
    // Add 20% buffer for safety
    return Math.floor(gasEstimate * 1.2);
  } catch (error) {
    console.warn("Gas estimation failed, using default limit");
    return NETWORKS.sepolia.gasLimit;
  }
}

// === DEPLOYMENT: Contract Factory Setup ===
async function getContractFactory(signer, contractName) {
  const artifactPath = join(__dirname, `../artifacts/contracts/${contractName}.sol/${contractName}.json`);
  
  if (!existsSync(artifactPath)) {
    throw new Error(`Artifact not found: ${artifactPath}. Run 'npm run build' first.`);
  }
  
  const artifact = JSON.parse(readFileSync(artifactPath, "utf-8"));
  const factory = new ethers.ContractFactory(
    artifact.abi,
    artifact.bytecode,
    signer
  );
  
  return factory;
}

// === DEPLOYMENT: Deploy AgentVerifier ===
async function deployAgentVerifier(signer, verificationKey) {
  console.log("🔧 Deploying AgentVerifier...");
  
  const factory = await getContractFactory(signer, CONTRACTS.AgentVerifier);
  const tx = await factory.getDeployTransaction(verificationKey);
  const gasLimit = await estimateGas(signer.provider, tx);
  
  const contract = await factory.deploy(verificationKey, {
    gasLimit,
    gasPrice: NETWORKS.sepolia.gasPrice
  });
  
  await contract.waitForDeployment();
  const address = await contract.getAddress();
  
  console.log(`✅ AgentVerifier deployed at: ${address}`);
  return address;
}

// === DEPLOYMENT: Deploy ReputationRegistry ===
async function deployReputationRegistry(signer, verifierAddress) {
  console.log("🔧 Deploying ReputationRegistry...");
  
  const factory = await getContractFactory(signer, CONTRACTS.ReputationRegistry);
  const tx = await factory.getDeployTransaction(verifierAddress);
  const gasLimit = await estimateGas(signer.provider, tx);
  
  const contract = await factory.deploy(verifierAddress, {
    gasLimit,
    gasPrice: NETWORKS.sepolia.gasPrice
  });
  
  await contract.waitForDeployment();
  const address = await contract.getAddress();
  
  console.log(`✅ ReputationRegistry deployed at: ${address}`);
  return address;
}

// === DEPLOYMENT: Initialize Registry with Test Agents ===
async function initializeTestAgents(registry, signer, testAgentCount = 3) {
  console.log(`🧪 Initializing ${testAgentCount} test agents...`);
  
  const testAgents = [];
  
  for (let i = 0; i < testAgentCount; i++) {
    const agentAddress = `0x${(1000 + i).toString(16).padStart(40, "0")}`;
    
    // Mint initial SBT for test agent
    const tx = await registry.mintAgentSBT(
      agentAddress,
      `Test Agent ${i + 1}`,
      "test-agent",
      1000,
      { gasPrice: NETWORKS.sepolia.gasPrice }
    );
    
    await tx.wait();
    testAgents.push({ address: agentAddress, name: `Test Agent ${i + 1}` });
    console.log(`   ✅ Test Agent ${i + 1} initialized: ${agentAddress}`);
  }
  
  return testAgents;
}

// === VERIFICATION: Verify Contract on Etherscan ===
async function verifyContract(address, constructorArgs, contractName) {
  console.log(`🔍 Verifying ${contractName} on Etherscan...`);
  
  try {
    const provider = new ethers.JsonRpcProvider(NETWORKS.sepolia.rpcUrl);
    const etherscanApiKey = process.env.ETHERSCAN_API_KEY;
    
    if (!etherscanApiKey) {
      console.warn("⚠️  Etherscan API key not provided, skipping verification");
      return;
    }
    
    const verifyUrl = `${NETWORKS.sepolia.explorer}/api`;
    const params = new URLSearchParams({
      module: "contract",
      action: "verifysourcecode",
      contractaddress: address,
      sourceCode: readFileSync(join(__dirname, `../artifacts/contracts/${contractName}.sol/${contractName}.json`), "utf-8"),
      contractname: `contracts/${contractName}.sol:${contractName}`,
      codeformat: "solidity-standard-json-input",
      sourceCodeFormat: "solidity-standard-json-input",
      solcInputVersion: "0.8.24",
      solcOptimizerEnabled: "true",
      solcOptimizerRuns: 200,
      constructorArguements: ethers.AbiCoder.defaultAbiCoder().encode(
        ["bytes"],
        [JSON.stringify({ verificationKey: loadVerificationKey() })]
      ),
      apikey: etherscanApiKey
    });
    
    const response = await fetch(`${verifyUrl}?${params.toString()}`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" }
    });
    
    const result = await response.json();
    
    if (result.status === "1") {
      console.log(`✅ ${contractName} verification submitted: ${NETWORKS.sepolia.explorer}/address/${address}`);
    } else {
      console.warn(`⚠️  Verification failed: ${result.message}`);
    }
  } catch (error) {
    console.warn(`⚠️  Verification error: ${error.message}`);
  }
}

// === DEPLOYMENT: Main Deployment Function ===
async function main() {
  console.log("🚀 TrustChain Deployment Starting...");
  console.log("=".repeat(60));
  
  try {
    // Step 1: Validate Environment
    console.log("🔐 Validating environment variables...");
    validateEnv();
    
    // Step 2: Connect to Network
    console.log("🔗 Connecting to Sepolia...");
    const provider = new ethers.JsonRpcProvider(NETWORKS.sepolia.rpcUrl);
    const wallet = new ethers.Wallet(process.env.DEPLOYER_PRIVATE_KEY, provider);
    
    const balance = await provider.getBalance(wallet.address);
    console.log(`   Wallet: ${wallet.address}`);
    console.log(`   Balance: ${ethers.formatEther(balance)} ETH`);
    
    if (balance < ethers.parseEther("0.1")) {
      throw new Error("Insufficient balance. Fund wallet with Sepolia ETH.");
    }
    
    // Step 3: Load ZK Verification Key
    console.log("🔑 Loading ZK verification key...");
    const verificationKey = loadVerificationKey();
    console.log(`   VK loaded: ${verificationKey.alpha1[0].slice(0, 10)}...`);
    
    // Step 4: Deploy Contracts
    console.log("📦 Deploying contracts...");
    const verifierAddress = await deployAgentVerifier(wallet, verificationKey);
    const registryAddress = await deployReputationRegistry(wallet, verifierAddress);
    
    // Step 5: Initialize Test Agents
    console.log("🧪 Initializing test agents...");
    const testAgents = await initializeTestAgents(
      new ethers.Contract(registryAddress, JSON.parse(readFileSync(join(__dirname, "../artifacts/contracts/ReputationRegistry.sol/ReputationRegistry.json"), "utf-8")).abi, wallet),
      wallet,
      3
    );
    
    // Step 6: Verify on Etherscan
    console.log("🔍 Verifying contracts...");
    await verifyContract(verifierAddress, [verificationKey], CONTRACTS.AgentVerifier);
    await verifyContract(registryAddress, [verifierAddress], CONTRACTS.ReputationRegistry);
    
    // Step 7: Save Deployment Artifacts
    const deploymentArtifacts = {
      network: "sepolia",
      chainId: NETWORKS.sepolia.chainId,
      timestamp: new Date().toISOString(),
      deployer: wallet.address,
      contracts: {
        AgentVerifier: verifierAddress,
        ReputationRegistry: registryAddress
      },
      testAgents: testAgents.map(a => a.address),
      verificationKey: {
        alpha1: verificationKey.alpha1,
        beta2: verificationKey.beta2,
        gamma2: verificationKey.gamma2,
        delta2: verificationKey.delta2,
        gammaABC1: verificationKey.gammaABC1,
        gammaABC2: verificationKey.gammaABC2,
        IC: verificationKey.IC
      }
    };
    
    const artifactsPath = join(__dirname, "../.deploy/sepolia.json");
    writeFileSync(artifactsPath, JSON.stringify(deploymentArtifacts, null, 2));
    console.log(`💾 Deployment artifacts saved: ${artifactsPath}`);
    
    // Step 8: Generate Environment Template
    const envTemplate = `# TrustChain Deployment Configuration
# Copy this to .env and fill in your values

# Network Configuration
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/YOUR_INFURA_ID
SEPOLIA_CHAIN_ID=11155111

# Deployer Wallet (NEVER commit this file!)
DEPLOYER_PRIVATE_KEY=0xYOUR_PRIVATE_KEY_HERE

# Etherscan API Key (for contract verification)
ETHERSCAN_API_KEY=YOUR_ETHERSCAN_API_KEY

# Infura Project ID (if using Infura RPC)
INFURA_PROJECT_ID=YOUR_INFURA_PROJECT_ID

# ZK Circuit Configuration
CIRCUIT_PATH=circuits/taskProof.circom
VERIFICATION_KEY_PATH=circuits/taskProof.json

# Agent Configuration
MIN_BOND=0.1
CHALLENGE_PERIOD=604800
MAX_CHALLENGES=3
`;
    
    const envPath = join(__dirname, "../.env.example");
    if (!existsSync(envPath)) {
      writeFileSync(envPath, envTemplate);
      console.log(`📝 Environment template created: ${envPath}`);
    }
    
    // Step 9: Summary
    console.log("=".repeat(60));
    console.log("✅ DEPLOYMENT COMPLETE");
    console.log("=".repeat(60));
    console.log(`Network: Sepolia (${NETWORKS.sepolia.chainId})`);
    console.log(`Deployer: ${wallet.address}`);
    console.log(`AgentVerifier: ${verifierAddress}`);
    console.log(`ReputationRegistry: ${registryAddress}`);
    console.log(`Test Agents: ${testAgents.length}`);
    console.log(`Verification: ${NETWORKS.sepolia.explorer}/address/${registryAddress}`);
    console.log("=".repeat(60));
    
  } catch (error) {
    console.error("❌ DEPLOYMENT FAILED");
    console.error("Error:", error.message);
    console.error("Stack:", error.stack);
    process.exit(1);
  }
}

// === EXECUTION ===
if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((error) => {
    console.error("Fatal error:", error);
    process.exit(1);
  });
}

export { main, validateEnv, loadVerificationKey, deployAgentVerifier, deployReputationRegistry, initializeTestAgents, verifyContract };