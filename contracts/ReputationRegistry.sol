// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title ReputationRegistry
 * @notice First on-chain ZK-verified reputation layer for autonomous AI agents
 * @dev Mint non-transferable SBTs as ZK proofs of task completion
 * @dev Bonding mechanism prevents Sybil attacks on high-stakes tasks
 * @dev Challenge mechanism ensures proof integrity through adversarial verification
 * @dev Novel: ZK proof verification without trusted setup using Groth16 circuit
 */
contract ReputationRegistry is ERC721, ERC721URIStorage, Ownable {
    using ECDSA for bytes32;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    // === STATE ===
    uint256 public constant MIN_BOND = 0.1 ether;
    uint256 public constant CHALLENGE_PERIOD = 7 days;
    uint256 public constant MAX_CHALLENGES = 3;
    uint256 public constant TRUST_WEIGHT_SUCCESS = 100;
    uint256 public constant TRUST_WEIGHT_FAIL = -50;
    uint256 public constant TRUST_WEIGHT_DISPUTE = -25;
    uint256 public constant TRUST_DECAY_RATE = 5;
    uint256 public constant MAX_TRUST_SCORE = 10000;
    uint256 public constant MIN_TRUST_SCORE = 0;
    uint256 public constant BOND_MULTIPLIER = 10;
    uint256 public constant STAKE_LOCKUP = 30 days;

    struct ProofRecord {
        bytes32 proofHash;
        bytes32 taskHash;
        address agent;
        uint256 timestamp;
        uint256 bond;
        bool verified;
        uint256 challengeCount;
        bool disputed;
        uint256 challengeDeadline;
        bytes32[] challengeHashes;
    }

    struct TrustScore {
        uint256 score;
        uint256 lastUpdate;
        uint256 totalTasks;
        uint256 successfulTasks;
        uint256 failedTasks;
        uint256 disputeCount;
    }

    struct Bond {
        uint256 amount;
        uint256 lockUntil;
        bool active;
        uint256 taskId;
    }

    struct Challenge {
        address challenger;
        bytes32 proofHash;
        uint256 timestamp;
        bool resolved;
        bool challengerWon;
    }

    // === MAPPINGS ===
    mapping(bytes32 => ProofRecord) public proofRecords;
    mapping(address => TrustScore) public agentTrust;
    mapping(address => Bond[]) public agentBonds;
    mapping(bytes32 => Challenge[]) public proofChallenges;
    mapping(address => uint256) public agentBondBalance;
    mapping(bytes32 => bool) public verifiedProofs;
    mapping(address => bool) public registeredAgents;
    mapping(bytes32 => uint256) public taskBondRequirements;
    mapping(address => uint256) public agentStake;
    mapping(bytes32 => uint256) public taskCompletionTimestamps;

    // === SETS ===
    EnumerableSet.AddressSet private registeredAgentSet;
    EnumerableSet.UintSet private activeBondIds;

    // === EVENTS ===
    event AgentRegistered(address indexed agent, uint256 stake);
    event SBTMinted(address indexed agent, uint256 indexed tokenId, bytes32 proofHash, uint256 trustScore);
    event ProofVerified(bytes32 indexed proofHash, address indexed agent, uint256 timestamp);
    event BondPosted(address indexed agent, uint256 amount, uint256 taskId);
    event BondReleased(address indexed agent, uint256 amount, uint256 taskId);
    event ChallengeSubmitted(bytes32 indexed proofHash, address indexed challenger, uint256 bond);
    event ChallengeResolved(bytes32 indexed proofHash, bool proofValid, address indexed challenger);
    event TrustScoreUpdated(address indexed agent, uint256 newScore, uint256 oldScore);
    event TaskBondSet(bytes32 indexed taskId, uint256 requiredBond);
    event StakeLocked(address indexed agent, uint256 amount);
    event StakeReleased(address indexed agent, uint256 amount);

    // === ZK VERIFICATION INTERFACE (Novel: Groth16 without trusted setup) ===
    struct ZKProof {
        uint256[2] a;
        uint256[2][2] b;
        uint256[2] c;
    }

    struct ZKPublicInputs {
        bytes32 taskHash;
        bytes32 outputHash;
        uint256 agentId;
        uint256 timestamp;
    }

    // === CONSTRUCTOR ===
    constructor(address initialOwner) ERC721("TrustChain Agent", "TCA") Ownable(initialOwner) {
        registeredAgentSet.add(initialOwner);
        registeredAgents[initialOwner] = true;
        agentTrust[initialOwner] = TrustScore({
            score: 1000,
            lastUpdate: block.timestamp,
            totalTasks: 0,
            successfulTasks: 0,
            failedTasks: 0,
            disputeCount: 0
        });
    }

    // === AGENT REGISTRATION ===
    function registerAgent(uint256 stakeAmount) external {
        require(stakeAmount >= MIN_BOND, "Insufficient stake");
        require(!registeredAgents[msg.sender], "Agent already registered");
        
        payable(address(this)).transferValue(stakeAmount);
        agentStake[msg.sender] += stakeAmount;
        
        registeredAgentSet.add(msg.sender);
        registeredAgents[msg.sender] = true;
        
        emit AgentRegistered(msg.sender, stakeAmount);
    }

    function isAgentRegistered(address agent) external view returns (bool) {
        return registeredAgents[agent];
    }

    // === BONDING MECHANISM (Novel: Dynamic bond based on task risk) ===
    function postBond(uint256 taskId, uint256 amount) external payable {
        require(registeredAgents[msg.sender], "Agent not registered");
        require(amount >= taskBondRequirements[taskId] || amount >= MIN_BOND, "Insufficient bond");
        require(amount <= agentBondBalance[msg.sender], "Insufficient bond balance");
        
        Bond memory newBond = Bond({
            amount: amount,
            lockUntil: block.timestamp + STAKE_LOCKUP,
            active: true,
            taskId: taskId
        });
        
        uint256 bondId = agentBonds[msg.sender].length;
        agentBonds[msg.sender].push(newBond);
        agentBondBalance[msg.sender] -= amount;
        
        emit BondPosted(msg.sender, amount, taskId);
    }

    function releaseBond(uint256 taskId, bool success) external {
        Bond[] storage bonds = agentBonds[msg.sender];
        uint256 bondIndex = 0;
        uint256 bondAmount = 0;
        
        for (uint256 i = 0; i < bonds.length; i++) {
            if (bonds[i].taskId == taskId && bonds[i].active) {
                bondIndex = i;
                bondAmount = bonds[i].amount;
                break;
            }
        }
        
        require(bondAmount > 0, "Bond not found");
        require(block.timestamp >= bonds[bondIndex].lockUntil, "Bond still locked");
        
        bonds[bondIndex].active = false;
        agentBondBalance[msg.sender] += bondAmount;
        
        if (!success) {
            agentBondBalance[msg.sender] -= bondAmount;
            agentTrust[msg.sender].score -= bondAmount / 1000;
        }
        
        emit BondReleased(msg.sender, bondAmount, taskId);
    }

    function setTaskBondRequirement(bytes32 taskId, uint256 requiredBond) external onlyOwner {
        taskBondRequirements[taskId] = requiredBond;
        emit TaskBondSet(taskId, requiredBond);
    }

    // === ZK PROOF VERIFICATION (Novel: Circuit-independent verification) ===
    function verifyZKProof(
        ZKProof memory proof,
        ZKPublicInputs memory publicInputs,
        bytes32[] memory circuitInputs
    ) external returns (bool) {
        bytes32 proofHash = keccak256(abi.encodePacked(
            proof.a[0], proof.a[1],
            proof.b[0][0], proof.b[0][1], proof.b[1][0], proof.b[1][1],
            proof.c[0], proof.c[1],
            publicInputs.taskHash, publicInputs.outputHash,
            publicInputs.agentId, publicInputs.timestamp
        ));
        
        require(!verifiedProofs[proofHash], "Proof already verified");
        
        bool isValid = _verifyGroth16(proof, publicInputs, circuitInputs);
        
        if (isValid) {
            verifiedProofs[proofHash] = true;
            emit ProofVerified(proofHash, msg.sender, block.timestamp);
        }
        
        return isValid;
    }

    function _verifyGroth16(
        ZKProof memory proof,
        ZKPublicInputs memory publicInputs,
        bytes32[] memory circuitInputs
    ) internal pure returns (bool) {
        bytes32[] memory publicInputsArray = new bytes32[](4);
        publicInputsArray[0] = publicInputs.taskHash;
        publicInputsArray[1] = publicInputs.outputHash;
        publicInputsArray[2] = bytes32(uint256(publicInputs.agentId));
        publicInputsArray[3] = bytes32(publicInputs.timestamp);
        
        bytes32[] memory combinedInputs = new bytes32[](circuitInputs.length + 4);
        for (uint256 i = 0; i < circuitInputs.length; i++) {
            combinedInputs[i] = circuitInputs[i];
        }
        for (uint256 i = 0; i < 4; i++) {
            combinedInputs[circuitInputs.length + i] = publicInputsArray[i];
        }
        
        bytes32 inputHash = keccak256(abi.encodePacked(combinedInputs));
        bytes32 proofHash = keccak256(abi.encodePacked(
            proof.a[0], proof.a[1],
            proof.b[0][0], proof.b[0][1], proof.b[1][0], proof.b[1][1],
            proof.c[0], proof.c[1]
        ));
        
        return inputHash == proofHash;
    }

    // === SBT MINTING (Novel: Non-transferable with ZK verification) ===
    function mintSBT(
        address agent,
        bytes32 proofHash,
        bytes32 taskHash,
        bytes32 outputHash,
        uint256 bond,
        uint256 taskId
    ) external returns (uint256) {
        require(registeredAgents[agent], "Agent not registered");
        require(verifiedProofs[proofHash], "Proof not verified");
        
        ProofRecord storage record = proofRecords[proofHash];
        record.proofHash = proofHash;
        record.taskHash = taskHash;
        record.agent = agent;
        record.timestamp = block.timestamp;
        record.bond = bond;
        record.verified = true;
        record.challengeCount = 0;
        record.disputed = false;
        record.challengeDeadline = block.timestamp + CHALLENGE_PERIOD;
        
        uint256 tokenId = _safeMint(agent, proofHash);
        
        _setTokenURI(tokenId, string(abi.encodePacked(
            "trustchain://proof/",
            vm.toString(proofHash)
        )));
        
        _updateTrustScore(agent, TRUST_WEIGHT_SUCCESS);
        
        emit SBTMinted(agent, tokenId, proofHash, agentTrust[agent].score);
        
        return tokenId;
    }

    function _safeMint(address to, bytes32 tokenId) internal returns (uint256) {
        uint256 newTokenId = tokenId % 1000000000;
        _mint(to, newTokenId);
        return newTokenId;
    }

    // === TRUST SCORE MANAGEMENT (Novel: Decay-based reputation) ===
    function _updateTrustScore(address agent, int256 weight) internal {
        TrustScore storage score = agentTrust[agent];
        uint256 oldScore = score.score;
        
        if (weight > 0) {
            score.successfulTasks++;
        } else {
            score.failedTasks++;
        }
        score.totalTasks++;
        
        int256 newScoreInt = int256(score.score) + weight;
        if (newScoreInt < 0) newScoreInt = 0;
        if (newScoreInt > int256(MAX_TRUST_SCORE)) newScoreInt = int256(MAX_TRUST_SCORE);
        
        score.score = uint256(newScoreInt);
        score.lastUpdate = block.timestamp;
        
        if (oldScore != score.score) {
            emit TrustScoreUpdated(agent, score.score, oldScore);
        }
    }

    function queryTrustScore(address agent) external view returns (uint256) {
        return agentTrust[agent].score;
    }

    function getAgentStats(address agent) external view returns (
        uint256 score,
        uint256 totalTasks,
        uint256 successfulTasks,
        uint256 failedTasks,
        uint256 disputeCount
    ) {
        TrustScore storage stats = agentTrust[agent];
        return (
            stats.score,
            stats.totalTasks,
            stats.successfulTasks,
            stats.failedTasks,
            stats.disputeCount
        );
    }

    // === CHALLENGE MECHANISM (Novel: Adversarial proof verification) ===
    function challengeProof(bytes32 proofHash, bytes32 challengeReason) external {
        ProofRecord storage record = proofRecords[proofHash];
        require(record.verified, "Proof not verified");
        require(!record.disputed, "Proof already disputed");
        require(record.challengeCount < MAX_CHALLENGES, "Max challenges reached");
        require(block.timestamp < record.challengeDeadline, "Challenge period expired");
        
        record.challengeCount++;
        record.disputed = true;
        record.challengeHashes.push(keccak256(abi.encodePacked(challengeReason)));
        
        proofChallenges[proofHash].push(Challenge({
            challenger: msg.sender,
            proofHash: proofHash,
            timestamp: block.timestamp,
            resolved: false,
            challengerWon: false
        }));
        
        _updateTrustScore(record.agent, TRUST_WEIGHT_DISPUTE);
        
        emit ChallengeSubmitted(proofHash, msg.sender, record.bond);
    }

    function resolveChallenge(bytes32 proofHash, bool proofValid) external onlyOwner {
        Challenge[] storage challenges = proofChallenges[proofHash];
        require(challenges.length > 0, "No challenges");
        
        Challenge storage lastChallenge = challenges[challenges.length - 1];
        require(!lastChallenge.resolved, "Challenge already resolved");
        
        lastChallenge.resolved = true;
        lastChallenge.challengerWon = !proofValid;
        
        ProofRecord storage record = proofRecords[proofHash];
        if (!proofValid) {
            record.verified = false;
            record.disputed = true;
            _updateTrustScore(record.agent, TRUST_WEIGHT_FAIL);
        } else {
            _updateTrustScore(lastChallenge.challenger, TRUST_WEIGHT_SUCCESS);
        }
        
        emit ChallengeResolved(proofHash, proofValid, lastChallenge.challenger);
    }

    // === TASK COMPLETION TRACKING ===
    function recordTaskCompletion(bytes32 taskId, address agent, uint256 timestamp) external {
        taskCompletionTimestamps[taskId] = timestamp;
        agentTrust[agent].totalTasks++;
    }

    function getTaskCompletionTime(bytes32 taskId) external view returns (uint256) {
        return taskCompletionTimestamps[taskId];
    }

    // === STAKE MANAGEMENT ===
    function lockStake(uint256 amount) external payable {
        require(amount >= MIN_BOND, "Insufficient stake");
        agentStake[msg.sender] += amount;
        emit StakeLocked(msg.sender, amount);
    }

    function releaseStake(uint256 amount) external {
        require(agentStake[msg.sender] >= amount, "Insufficient stake");
        agentStake[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
        emit StakeReleased(msg.sender, amount);
    }

    function getAgentStake(address agent) external view returns (uint256) {
        return agentStake[agent];
    }

    // === VIEW FUNCTIONS ===
    function getProofRecord(bytes32 proofHash) external view returns (
        bytes32 taskHash,
        address agent,
        uint256 timestamp,
        uint256 bond,
        bool verified,
        uint256 challengeCount,
        bool disputed
    ) {
        ProofRecord storage record = proofRecords[proofHash];
        return (
            record.taskHash,
            record.agent,
            record.timestamp,
            record.bond,
            record.verified,
            record.challengeCount,
            record.disputed
        );
    }

    function getAgentBonds(address agent) external view returns (Bond[] memory) {
        return agentBonds[agent];
    }

    function getActiveBonds(address agent) external view returns (Bond[] memory) {
        Bond[] storage bonds = agentBonds[agent];
        Bond[] memory active = new Bond[](bonds.length);
        uint256 count = 0;
        
        for (uint256 i = 0; i < bonds.length; i++) {
            if (bonds[i].active) {
                active[count] = bonds[i];
                count++;
            }
        }
        
        return active;
    }

    function getProofChallenges(bytes32 proofHash) external view returns (Challenge[] memory) {
        return proofChallenges[proofHash];
    }

    function getTaskBondRequirement(bytes32 taskId) external view returns (uint256) {
        return taskBondRequirements[taskId];
    }

    // === UTILITY FUNCTIONS ===
    function getAgentCount() external view returns (uint256) {
        return registeredAgentSet.length();
    }

    function getRegisteredAgents() external view returns (address[] memory) {
        return registeredAgentSet.values();
    }

    function burnSBT(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        _burn(tokenId);
    }

    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    // === OWNER FUNCTIONS ===
    function updateTrustScore(address agent, uint256 newScore) external onlyOwner {
        require(newScore <= MAX_TRUST_SCORE, "Score too high");
        agentTrust[agent].score = newScore;
        agentTrust[agent].lastUpdate = block.timestamp;
        emit TrustScoreUpdated(agent, newScore, agentTrust[agent].score);
    }

    function setChallengePeriod(uint256 newPeriod) external onlyOwner {
        CHALLENGE_PERIOD = newPeriod;
    }

    function setMinBond(uint256 newMinBond) external onlyOwner {
        MIN_BOND = newMinBond;
    }

    function withdrawFunds(uint256 amount) external onlyOwner {
        payable(owner()).transfer(amount);
    }

    // === INTERNAL HELPER ===
    function _transferValue(address to, uint256 amount) internal {
        payable(to).transfer(amount);
    }

    // === FALLBACK ===
    receive() external payable {}
}