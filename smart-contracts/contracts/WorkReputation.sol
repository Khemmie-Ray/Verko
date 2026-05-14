// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";


contract WorkerReputation is Ownable, ReentrancyGuard {

    enum Tier { Starter, Trusted, Elite }

    struct WorkerStats {
        uint256 tokenId;           // Soulbound NFT id
        uint256 tasksCompleted;    // Approved tasks
        uint256 tasksRejected;     // Rejected tasks
        uint256 tasksArbitrated;   // Disputes arbitrated (as arbitrator)
        uint256 totalGEarned;      // Lifetime G$ earned (in wei)
        uint256 registeredAt;      // Block timestamp of first registration
        bool    exists;
    }

    // ─────────────────────────── State ───────────────────────────

    uint256 private _nextTokenId;

    // worker address → stats
    mapping(address => WorkerStats) private _stats;

    // tokenId → worker address (for reverse lookup)
    mapping(uint256 => address) private _tokenOwner;

    // authorised callers that can update stats (TaskEscrow, ArbitrationPool)
    mapping(address => bool) public authorised;

    // ─────────────────────────── Events ──────────────────────────

    event WorkerRegistered(address indexed worker, uint256 tokenId);
    event StatsUpdated(address indexed worker, uint256 tasksCompleted, uint256 tasksRejected, Tier tier);
    event TierUpgraded(address indexed worker, Tier newTier);
    event AuthorisedCallerSet(address indexed caller, bool status);

    // ────────────────────────── Errors ───────────────────────────

    error AlreadyRegistered();
    error NotRegistered();
    error NotAuthorised();
    error Soulbound();

    // ─────────────────────────── Modifiers ───────────────────────

    modifier onlyAuthorised() {
        if (!authorised[msg.sender] && msg.sender != owner()) revert NotAuthorised();
        _;
    }

    // ───────────────────────── Constructor ───────────────────────

    constructor() Ownable(msg.sender) {
        _nextTokenId = 1;
    }

    // ─────────────────────── Admin functions ─────────────────────

    /**
     * @notice Grant or revoke update rights to a contract (e.g. TaskEscrow).
     */
    function setAuthorised(address caller, bool status) external onlyOwner {
        authorised[caller] = status;
        emit AuthorisedCallerSet(caller, status);
    }

    // ────────────────────── Worker registration ──────────────────

    /**
     * @notice Register a new verified worker and mint their soulbound Verko Score NFT.
     *         Called by TaskEscrow the first time a worker submits a task, or can be
     *         called directly by the worker to pre-register before any task.
     * @dev    In production, add a GoodDollar face-verification proof check here.
     *         For the MVP this is open; access control is handled at the app layer.
     */
    function register(address worker) external onlyAuthorised nonReentrant {
        if (_stats[worker].exists) revert AlreadyRegistered();

        uint256 id = _nextTokenId++;
        _stats[worker] = WorkerStats({
            tokenId:         id,
            tasksCompleted:  0,
            tasksRejected:   0,
            tasksArbitrated: 0,
            totalGEarned:    0,
            registeredAt:    block.timestamp,
            exists:          true
        });
        _tokenOwner[id] = worker;

        emit WorkerRegistered(worker, id);
    }

    // ──────────────────── Stat update functions ───────────────────

    /**
     * @notice Record a successfully completed (approved) task.
     * @param worker   Worker's address.
     * @param gEarned  G$ amount earned (in wei).
     */
    function recordApproval(address worker, uint256 gEarned)
        external
        onlyAuthorised
        nonReentrant
    {
        if (!_stats[worker].exists) revert NotRegistered();

        Tier before_ = _getTier(_stats[worker].tasksCompleted);

        _stats[worker].tasksCompleted += 1;
        _stats[worker].totalGEarned   += gEarned;

        Tier after_ = _getTier(_stats[worker].tasksCompleted);

        emit StatsUpdated(
            worker,
            _stats[worker].tasksCompleted,
            _stats[worker].tasksRejected,
            after_
        );

        if (after_ > before_) {
            emit TierUpgraded(worker, after_);
        }
    }

    /**
     * @notice Record a rejected task submission.
     */
    function recordRejection(address worker) external onlyAuthorised nonReentrant {
        if (!_stats[worker].exists) revert NotRegistered();
        _stats[worker].tasksRejected += 1;
        emit StatsUpdated(
            worker,
            _stats[worker].tasksCompleted,
            _stats[worker].tasksRejected,
            _getTier(_stats[worker].tasksCompleted)
        );
    }

    /**
     * @notice Record an arbitration case completed by this worker (as arbitrator).
     * @param arbitrator  Address of the arbitrator.
     * @param gEarned     G$ fee earned for arbitrating.
     */
    function recordArbitration(address arbitrator, uint256 gEarned)
        external
        onlyAuthorised
        nonReentrant
    {
        if (!_stats[arbitrator].exists) revert NotRegistered();
        _stats[arbitrator].tasksArbitrated += 1;
        _stats[arbitrator].totalGEarned    += gEarned;
    }

    // ─────────────────────── View functions ──────────────────────

    function getStats(address worker) external view returns (WorkerStats memory) {
        if (!_stats[worker].exists) revert NotRegistered();
        return _stats[worker];
    }

    function getTier(address worker) external view returns (Tier) {
        if (!_stats[worker].exists) revert NotRegistered();
        return _getTier(_stats[worker].tasksCompleted);
    }

    function getApprovalRate(address worker) external view returns (uint256 bps) {
        WorkerStats memory s = _stats[worker];
        if (!s.exists) revert NotRegistered();
        uint256 total = s.tasksCompleted + s.tasksRejected;
        if (total == 0) return 0;
        // Returns basis points (0–10000). e.g. 9700 = 97%
        return (s.tasksCompleted * 10_000) / total;
    }

    function isRegistered(address worker) external view returns (bool) {
        return _stats[worker].exists;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _tokenOwner[tokenId];
    }

    function totalSupply() external view returns (uint256) {
        return _nextTokenId - 1;
    }

    // ─────────────────────── Internal helpers ────────────────────

    function _getTier(uint256 completed) internal pure returns (Tier) {
        if (completed >= 50) return Tier.Elite;
        if (completed >= 10) return Tier.Trusted;
        return Tier.Starter;
    }

    // ─────────────── Soulbound: block all transfers ───────────────
    // These functions exist so the contract can respond correctly to any
    // external call attempting a transfer. There is no ERC-721 inheritance
    // here by design — this is a minimal on-chain credential, not a tradeable NFT.

    function transferFrom(address, address, uint256) external pure {
        revert Soulbound();
    }

    function safeTransferFrom(address, address, uint256) external pure {
        revert Soulbound();
    }

    function safeTransferFrom(address, address, uint256, bytes calldata) external pure {
        revert Soulbound();
    }

    function approve(address, uint256) external pure {
        revert Soulbound();
    }

    function setApprovalForAll(address, bool) external pure {
        revert Soulbound();
    }
}
