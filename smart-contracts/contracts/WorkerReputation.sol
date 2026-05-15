// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract WorkerReputation {
   
    // Types
    struct WorkerStats {
        uint256 tasksCompleted;
        uint256 tasksAttempted;   
        uint256 totalEarned;      
        uint8   tier;             
        uint256 tokenId;         
    }

   
    // State
    address public owner;
    address public escrow;       

    uint256 private _tokenCounter;

    mapping(address => WorkerStats) public stats;
    mapping(uint256 => address)     public tokenOwner;   
    mapping(address => uint256)     public workerToken;  

  
    // Events
    event ReputationUpdated(address indexed worker, uint256 completed, uint8 tier);
    event NFTMinted(address indexed worker, uint256 tokenId);
    event TierUpgraded(address indexed worker, uint8 newTier);
    event EscrowSet(address indexed escrow);

    
    // Errors
    error NotOwner();
    error NotEscrow();
    error NonTransferable();
    error ZeroAddress();

   
    // Constructor
    constructor() {
        owner = msg.sender;
    }

   
    // Modifiers
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyEscrow() {
        if (msg.sender != escrow) revert NotEscrow();
        _;
    }

   
    // Admin
    function setEscrow(address _escrow) external onlyOwner {
        if (_escrow == address(0)) revert ZeroAddress();
        escrow = _escrow;
        emit EscrowSet(_escrow);
    }

   
    function recordCompletion(
        address worker,
        uint256 taskId,
        bool    approved
    ) external onlyEscrow {
        WorkerStats storage s = stats[worker];

        s.tasksAttempted++;
        if (approved) {
            s.tasksCompleted++;
        }

        // Mint soul-bound NFT on first completion
        if (s.tokenId == 0 && s.tasksCompleted >= 1) {
            _mintNFT(worker, s);
        }

        // Recalculate tier
        uint8 oldTier = s.tier;
        s.tier = _calculateTier(s.tasksCompleted, s.tasksAttempted);

        emit ReputationUpdated(worker, s.tasksCompleted, s.tier);

        if (s.tier > oldTier) {
            emit TierUpgraded(worker, s.tier);
        }

        // Suppress unused variable warning
        taskId;
    }

    function getStats(address worker) external view returns (WorkerStats memory) {
        return stats[worker];
    }

    function approvalRate(address worker) external view returns (uint256 bps) {
        WorkerStats storage s = stats[worker];
        if (s.tasksAttempted == 0) return 0;
        return (s.tasksCompleted * 10_000) / s.tasksAttempted;
    }

    function getTier(address worker) external view returns (uint8) {
        return stats[worker].tier;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return tokenOwner[tokenId];
    }

    
    function _mintNFT(address worker, WorkerStats storage s) internal {
        uint256 id = ++_tokenCounter;
        s.tokenId = id;
        tokenOwner[id] = worker;
        workerToken[worker] = id;
        emit NFTMinted(worker, id);
    }

    function _calculateTier(
        uint256 completed,
        uint256 attempted
    ) internal pure returns (uint8) {
        if (completed == 0 || attempted == 0) return 0;

        uint256 rateBps = (completed * 10_000) / attempted;

        if (completed >= 50 && rateBps >= 8_000) return 3;
        if (completed >= 20 && rateBps >= 7_000) return 2;
        if (completed >= 5  && rateBps >= 6_000) return 1;
        return 0;
    }

    
    function transferFrom(address, address, uint256) external pure {
        revert NonTransferable();
    }
}
