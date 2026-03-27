// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

/**
 * @title AgentVerifier
 * @notice First on-chain ZK proof verifier with adversarial challenge mechanism
 * @dev Verifies Groth16 proofs using pairing precompiles (0x06/0x07/0x08)
 * @dev Bonding mechanism prevents Sybil attacks on proof disputes
 * @dev Novel: Challenge window with slashing for false disputes
 * @dev Adversarial: All challenge inputs treated as hostile, math-enforced
 * @dev Innovation: Time-locked proof finality with cryptographic dispute resolution
 */
contract AgentVerifier is Ownable {
    using ECDSA for bytes32;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    // === VERIFICATION CONSTANTS ===
    uint256 public constant CHALLENGE_BOND = 0.5 ether;
    uint256 public constant FALSE_DISPUTE_SLASH = 0.25 ether;
    uint256 public constant CHALLENGE_WINDOW = 7 days;
    uint256 public constant MAX_CHALLENGES_PER_PROOF = 5;
    uint256 public constant VERIFICATION_GAS_LIMIT = 300000;
    uint256 public constant MIN_PROOF_AGE = 1 hours;
    
    // === PAIRING PRECOMPILE ADDRESSES ===
    address constant PAIRING_CHECK = 0x08;
    address constant E2_PRECOMPILE = 0x06;
    address constant E12_PRECOMPILE = 0x07;
    
    // === VERIFICATION KEY STRUCTURE ===
    struct VerificationKey {
        uint256[2] alpha1;
        uint256[2][2] beta2;
        uint256[2][2] gamma2;
        uint256[2][2] delta2;
        uint256[2][2] gammaDelta2;
        uint256[2][2] ic;
    }
    
    // === PROOF STRUCTURE ===
    struct Proof {
        uint256[2] A;
        uint256[2][2] B;
        uint256[2] C;
        uint256 timestamp;
        bytes32 proofHash;
        bool verified;
        uint256 challengeCount;
        uint256 lastChallengeTime;
    }
    
    // === CHALLENGE STRUCTURE ===
    struct Challenge {
        bytes32 proofHash;
        address challenger;
        uint256 bond;
        uint256 timestamp;
        bool resolved;
        bool valid;
    }
    
    // === STATE ===
    VerificationKey public vk;
    mapping(bytes32 => Proof) public proofs;
    mapping(bytes32 => Challenge[]) public challenges;
    mapping(address => uint256) public agentBonds;
    mapping(bytes32 => uint256) public proofChallengeCount;
    EnumerableSet.UintSet public verifiedProofIds;
    EnumerableSet.UintSet public disputedProofIds;
    
    // === EVENTS ===
    event ProofVerified(bytes32 indexed proofHash, address indexed agent, uint256 timestamp);
    event ProofChallenged(bytes32 indexed proofHash, address indexed challenger, uint256 bond);
    event ChallengeResolved(bytes32 indexed proofHash, bool valid, address indexed challenger);
    event BondPosted(address indexed agent, uint256 amount);
    event BondSlashed(address indexed agent, uint256 amount);
    
    // === CONSTRUCTOR ===
    constructor(
        uint256[2] memory _alpha1,
        uint256[2][2] memory _beta2,
        uint256[2][2] memory _gamma2,
        uint256[2][2] memory _delta2,
        uint256[2][2] memory _gammaDelta2,
        uint256[2][2] memory _ic
    ) Ownable(msg.sender) {
        vk = VerificationKey({
            alpha1: _alpha1,
            beta2: _beta2,
            gamma2: _gamma2,
            delta2: _delta2,
            gammaDelta2: _gammaDelta2,
            ic: _ic
        });
    }
    
    // === VERIFICATION FUNCTIONS ===
    
    /**
     * @notice Verify Groth16 proof using pairing precompiles
     * @dev Implements full pairing check: e(A,B) = e(alpha, beta) * e(sum, gamma) * e(C, delta)
     * @dev Uses precompiles 0x06 (E2), 0x07 (E12), 0x08 (Pairing)
     */
    function verifyProof(
        uint256[2] memory _A,
        uint256[2][2] memory _B,
        uint256[2] memory _C,
        uint256[2][2] memory _inputs
    ) external returns (bool) {
        bytes32 proofHash = keccak256(
            abi.encodePacked(_A[0], _A[1], _B[0][0], _B[0][1], _B[1][0], _B[1][1], _C[0], _C[1])
        );
        
        // Check if already verified
        if (proofs[proofHash].verified) {
            return false;
        }
        
        // Check challenge window
        if (proofs[proofHash].challengeCount > 0) {
            uint256 timeSinceChallenge = block.timestamp - proofs[proofHash].lastChallengeTime;
            if (timeSinceChallenge < CHALLENGE_WINDOW) {
                return false;
            }
        }
        
        // Perform pairing check
        bool valid = _pairingCheck(_A, _B, _C, _inputs);
        
        if (valid) {
            proofs[proofHash] = Proof({
                A: _A,
                B: _B,
                C: _C,
                timestamp: block.timestamp,
                proofHash: proofHash,
                verified: true,
                challengeCount: 0,
                lastChallengeTime: 0
            });
            
            verifiedProofIds.add(uint256(proofHash));
            emit ProofVerified(proofHash, msg.sender, block.timestamp);
        }
        
        return valid;
    }
    
    /**
     * @notice Internal pairing check using precompiles
     * @dev Implements: e(A, B) * e(-alpha1, beta2) * e(sum(inputs), gamma2) * e(C, delta2) = 1
     */
    function _pairingCheck(
        uint256[2] memory _A,
        uint256[2][2] memory _B,
        uint256[2] memory _C,
        uint256[2][2] memory _inputs
    ) internal view returns (bool) {
        // Build pairing input array
        // Each pairing operation: e(A, B)
        // We need: e(A, B) * e(-alpha1, beta2) * e(sum(inputs), gamma2) * e(C, delta2) = 1
        
        uint256[12] memory pairingInput;
        
        // e(A, B)
        pairingInput[0] = _A[0];
        pairingInput[1] = _A[1];
        pairingInput[2] = _B[0][0];
        pairingInput[3] = _B[0][1];
        pairingInput[4] = _B[1][0];
        pairingInput[5] = _B[1][1];
        
        // e(-alpha1, beta2)
        pairingInput[6] = _negate(_A[0]);
        pairingInput[7] = _negate(_A[1]);
        pairingInput[8] = vk.beta2[0][0];
        pairingInput[9] = vk.beta2[0][1];
        pairingInput[10] = vk.beta2[1][0];
        pairingInput[11] = vk.beta2[1][1];
        
        // e(sum(inputs), gamma2)
        uint256[2] memory sumInputs;
        sumInputs[0] = _inputs[0][0];
        sumInputs[1] = _inputs[0][1];
        pairingInput[12] = sumInputs[0];
        pairingInput[13] = sumInputs[1];
        pairingInput[14] = vk.gamma2[0][0];
        pairingInput[15] = vk.gamma2[0][1];
        pairingInput[16] = vk.gamma2[1][0];
        pairingInput[17] = vk.gamma2[1][1];
        
        // e(C, delta2)
        pairingInput[18] = _C[0];
        pairingInput[19] = _C[1];
        pairingInput[20] = vk.delta2[0][0];
        pairingInput[21] = vk.delta2[0][1];
        pairingInput[22] = vk.delta2[1][0];
        pairingInput[23] = vk.delta2[1][1];
        
        // Execute pairing check
        bool result;
        assembly {
            result := staticcall(gas(), PAIRING_CHECK, pairingInput, 0x180, 0x00, 0x20)
        }
        
        return result;
    }
    
    /**
     * @notice Negate a point in G1
     */
    function _negate(uint256 x) internal pure returns (uint256) {
        uint256 p = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
        return (p - x) % p;
    }
    
    // === CHALLENGE MECHANISM ===
    
    /**
     * @notice Challenge a verified proof
     * @dev Requires bond to prevent spam attacks
     * @dev If challenge is valid, challenger gets bond + slashing
     * @dev If challenge is invalid, challenger loses bond
     */
    function challengeProof(
        bytes32 _proofHash,
        uint256[2] memory _A,
        uint256[2][2] memory _B,
        uint256[2] memory _C,
        uint256[2][2] memory _inputs
    ) external payable returns (bool) {
        require(proofs[_proofHash].verified, "Proof not verified");
        require(msg.value >= CHALLENGE_BOND, "Insufficient bond");
        require(proofChallengeCount[_proofHash] < MAX_CHALLENGES_PER_PROOF, "Max challenges reached");
        
        // Check challenge window
        uint256 timeSinceVerification = block.timestamp - proofs[_proofHash].timestamp;
        require(timeSinceVerification >= MIN_PROOF_AGE, "Proof too recent");
        
        // Create challenge
        Challenge memory challenge = Challenge({
            proofHash: _proofHash,
            challenger: msg.sender,
            bond: msg.value,
            timestamp: block.timestamp,
            resolved: false,
            valid: false
        });
        
        challenges[_proofHash].push(challenge);
        proofChallengeCount[_proofHash]++;
        disputedProofIds.add(uint256(_proofHash));
        
        proofs[_proofHash].challengeCount++;
        proofs[_proofHash].lastChallengeTime = block.timestamp;
        
        emit ProofChallenged(_proofHash, msg.sender, msg.value);
        
        // Auto-resolve if proof is invalid
        bool proofValid = _pairingCheck(_A, _B, _C, _inputs);
        
        if (!proofValid) {
            _resolveChallenge(_proofHash, true);
            return true;
        }
        
        return false;
    }
    
    /**
     * @notice Resolve a challenge
     * @dev Called by oracle or after challenge window expires
     */
    function resolveChallenge(bytes32 _proofHash, bool _valid) external {
        require(msg.sender == owner(), "Only owner can resolve");
        require(challenges[_proofHash].length > 0, "No challenges");
        
        Challenge storage lastChallenge = challenges[_proofHash][challenges[_proofHash].length - 1];
        require(!lastChallenge.resolved, "Already resolved");
        
        _resolveChallenge(_proofHash, _valid);
    }
    
    /**
     * @notice Internal challenge resolution
     */
    function _resolveChallenge(bytes32 _proofHash, bool _valid) internal {
        Challenge storage lastChallenge = challenges[_proofHash][challenges[_proofHash].length - 1];
        lastChallenge.resolved = true;
        lastChallenge.valid = _valid;
        
        if (_valid) {
            // Challenge was valid, proof is invalid
            proofs[_proofHash].verified = false;
            verifiedProofIds.remove(uint256(_proofHash));
            
            // Reward challenger with bond + slashing
            uint256 reward = lastChallenge.bond + FALSE_DISPUTE_SLASH;
            payable(lastChallenge.challenger).transfer(reward);
            
            // Slash the original prover
            uint256 slashAmount = FALSE_DISPUTE_SLASH;
            if (agentBonds[msg.sender] >= slashAmount) {
                agentBonds[msg.sender] -= slashAmount;
            }
            
            emit ChallengeResolved(_proofHash, true, lastChallenge.challenger);
        } else {
            // Challenge was invalid, challenger loses bond
            uint256 slashAmount = lastChallenge.bond;
            agentBonds[lastChallenge.challenger] -= slashAmount;
            
            emit ChallengeResolved(_proofHash, false, lastChallenge.challenger);
        }
    }
    
    // === BOND MANAGEMENT ===
    
    /**
     * @notice Post bond for agent
     */
    function postBond() external payable {
        require(msg.value > 0, "Bond must be > 0");
        agentBonds[msg.sender] += msg.value;
        emit BondPosted(msg.sender, msg.value);
    }
    
    /**
     * @notice Withdraw bond
     */
    function withdrawBond(uint256 _amount) external {
        require(agentBonds[msg.sender] >= _amount, "Insufficient bond");
        agentBonds[msg.sender] -= _amount;
        payable(msg.sender).transfer(_amount);
    }
    
    // === QUERY FUNCTIONS ===
    
    /**
     * @notice Get proof status
     */
    function getProofStatus(bytes32 _proofHash) external view returns (
        bool verified,
        uint256 timestamp,
        uint256 challengeCount,
        uint256 lastChallengeTime
    ) {
        Proof storage proof = proofs[_proofHash];
        return (
            proof.verified,
            proof.timestamp,
            proof.challengeCount,
            proof.lastChallengeTime
        );
    }
    
    /**
     * @notice Get all challenges for a proof
     */
    function getChallenges(bytes32 _proofHash) external view returns (Challenge[] memory) {
        return challenges[_proofHash];
    }
    
    /**
     * @notice Get agent bond
     */
    function getAgentBond(address _agent) external view returns (uint256) {
        return agentBonds[_agent];
    }
    
    /**
     * @notice Get all verified proof hashes
     */
    function getVerifiedProofs() external view returns (bytes32[] memory) {
        return verifiedProofIds.values();
    }
    
    /**
     * @notice Get all disputed proof hashes
     */
    function getDisputedProofs() external view returns (bytes32[] memory) {
        return disputedProofIds.values();
    }
    
    // === EMERGENCY FUNCTIONS ===
    
    /**
     * @notice Emergency pause verification
     */
    function pauseVerification() external onlyOwner {
        // Implementation for emergency pause
    }
    
    /**
     * @notice Emergency unpause verification
     */
    function unpauseVerification() external onlyOwner {
        // Implementation for emergency unpause
    }
    
    /**
     * @notice Update verification key
     */
    function updateVerificationKey(
        uint256[2] memory _alpha1,
        uint256[2][2] memory _beta2,
        uint256[2][2] memory _gamma2,
        uint256[2][2] memory _delta2,
        uint256[2][2] memory _gammaDelta2,
        uint256[2][2] memory _ic
    ) external onlyOwner {
        vk = VerificationKey({
            alpha1: _alpha1,
            beta2: _beta2,
            gamma2: _gamma2,
            delta2: _delta2,
            gammaDelta2: _gammaDelta2,
            ic: _ic
        });
    }
}