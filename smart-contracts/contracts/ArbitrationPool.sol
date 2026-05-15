// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./WorkerReputation.sol";

/**
 * @title ArbitrationPool
 * @notice Decentralised dispute resolution for Verko.
 *
 * When a poster disputes a submission, a small panel of high-reputation
 * workers (Tier ≥ 2) are registered as arbitrators. Any registered
 * arbitrator can vote on open disputes. The first side to reach
 * `QUORUM` votes wins; ties break in favour of the worker.
 *
 * Arbitrators earn a small G$ fee (funded from platform fees) for each
 * case they vote on — paid out when the dispute is resolved.
 *
 * Arbitrator registration:
 *   - Self-register via `registerArbitrator()` if Tier ≥ 2.
 *   - Owner can also forcibly add/remove (for the bootstrap period).
 */
contract ArbitrationPool {
    // ─────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────

    uint8 public constant QUORUM = 3;   // votes needed to resolve

    // ─────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────

    enum DisputeOutcome { Pending, WorkerWins, PosterWins }

    struct Dispute {
        uint256 taskId;
        address worker;
        address poster;
        uint32  votesForWorker;
        uint32  votesForPoster;
        DisputeOutcome outcome;
        uint256 openedAt;
        uint256 resolvedAt;
        address paymentToken;   // token used to pay arbitrator fees
        uint256 feePerVote;     // in token wei
    }

    // ─────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────

    address public owner;
    address public escrow;           // TaskEscrow — the only caller of openDispute
    WorkerReputation public immutable reputation;

    uint256 public defaultFeePerVote;
    address public defaultFeeToken;

    uint256 private _disputeCounter;

    mapping(uint256 => Dispute)                         public disputes;
    /// taskId → disputeId (one active dispute per task at a time)
    mapping(uint256 => uint256)                         public taskDispute;
    mapping(address => bool)                            public isArbitrator;
    address[]                                           private _arbitrators;
    /// disputeId → arbitrator → has voted
    mapping(uint256 => mapping(address => bool))        public hasVoted;
    /// disputeId → arbitrator → fee earned (claimable)
    mapping(uint256 => mapping(address => uint256))     public pendingFees;
    /// arbitrator → total fees earned across all disputes
    mapping(address => uint256)                         public totalFeesEarned;

    // ─────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────

    event ArbitratorRegistered(address indexed arbitrator);
    event ArbitratorRemoved(address indexed arbitrator);
    event DisputeOpened(uint256 indexed disputeId, uint256 indexed taskId, address worker, address poster);
    event VoteCast(uint256 indexed disputeId, address indexed arbitrator, bool inFavourOfWorker);
    event DisputeResolved(uint256 indexed disputeId, DisputeOutcome outcome);
    event FeeClaimed(address indexed arbitrator, uint256 amount);

    // ─────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────

    error NotOwner();
    error NotEscrow();
    error NotArbitrator();
    error AlreadyVoted();
    error DisputeNotPending();
    error InsufficientTier();
    error AlreadyArbitrator();
    error ZeroAddress();
    error NothingToClaim();
    error TransferFailed();

    // ─────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyEscrow() {
        if (msg.sender != escrow) revert NotEscrow();
        _;
    }

    // ─────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────

    constructor(address _reputation, address _defaultFeeToken, uint256 _defaultFeePerVote) {
        if (_reputation == address(0)) revert ZeroAddress();
        reputation       = WorkerReputation(_reputation);
        defaultFeeToken  = _defaultFeeToken;
        defaultFeePerVote = _defaultFeePerVote;
        owner            = msg.sender;
    }

    // ─────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────

    function setEscrow(address _escrow) external onlyOwner {
        if (_escrow == address(0)) revert ZeroAddress();
        escrow = _escrow;
    }

    function setDefaultFee(address token, uint256 feePerVote) external onlyOwner {
        defaultFeeToken  = token;
        defaultFeePerVote = feePerVote;
    }

    /// @notice Owner can add arbitrators during the bootstrap phase.
    function addArbitrator(address arb) external onlyOwner {
        if (arb == address(0))     revert ZeroAddress();
        if (isArbitrator[arb])     revert AlreadyArbitrator();
        isArbitrator[arb] = true;
        _arbitrators.push(arb);
        emit ArbitratorRegistered(arb);
    }

    function removeArbitrator(address arb) external onlyOwner {
        isArbitrator[arb] = false;
        emit ArbitratorRemoved(arb);
    }

    // ─────────────────────────────────────────────
    // Self-Registration
    // ─────────────────────────────────────────────

    /**
     * @notice Workers with Tier ≥ 2 can register themselves as arbitrators.
     */
    function registerArbitrator() external {
        if (reputation.getTier(msg.sender) < 2) revert InsufficientTier();
        if (isArbitrator[msg.sender]) revert AlreadyArbitrator();
        isArbitrator[msg.sender] = true;
        _arbitrators.push(msg.sender);
        emit ArbitratorRegistered(msg.sender);
    }

    // ─────────────────────────────────────────────
    // Dispute Lifecycle — called by TaskEscrow
    // ─────────────────────────────────────────────

    /**
     * @notice Open a new dispute. Called exclusively by TaskEscrow.
     */
    function openDispute(
        uint256 taskId,
        address worker,
        address poster
    ) external onlyEscrow returns (uint256 disputeId) {
        disputeId = ++_disputeCounter;
        taskDispute[taskId] = disputeId;

        disputes[disputeId] = Dispute({
            taskId:       taskId,
            worker:       worker,
            poster:       poster,
            votesForWorker: 0,
            votesForPoster: 0,
            outcome:      DisputeOutcome.Pending,
            openedAt:     block.timestamp,
            resolvedAt:   0,
            paymentToken: defaultFeeToken,
            feePerVote:   defaultFeePerVote
        });

        emit DisputeOpened(disputeId, taskId, worker, poster);
    }

    // ─────────────────────────────────────────────
    // Voting — called by Arbitrators
    // ─────────────────────────────────────────────

    /**
     * @notice Cast a vote on an open dispute.
     * @param disputeId          The dispute to vote on.
     * @param inFavourOfWorker   true = rule for worker; false = rule for poster.
     */
    function vote(uint256 disputeId, bool inFavourOfWorker) external {
        if (!isArbitrator[msg.sender])  revert NotArbitrator();
        if (hasVoted[disputeId][msg.sender]) revert AlreadyVoted();

        Dispute storage d = disputes[disputeId];
        if (d.outcome != DisputeOutcome.Pending) revert DisputeNotPending();

        hasVoted[disputeId][msg.sender] = true;
        pendingFees[disputeId][msg.sender] = d.feePerVote;
        totalFeesEarned[msg.sender] += d.feePerVote;

        if (inFavourOfWorker) {
            d.votesForWorker++;
        } else {
            d.votesForPoster++;
        }

        emit VoteCast(disputeId, msg.sender, inFavourOfWorker);

        // Check if quorum reached
        if (d.votesForWorker >= QUORUM) {
            _resolve(disputeId, d, DisputeOutcome.WorkerWins);
        } else if (d.votesForPoster >= QUORUM) {
            _resolve(disputeId, d, DisputeOutcome.PosterWins);
        }
    }

    // ─────────────────────────────────────────────
    // Fee Claims
    // ─────────────────────────────────────────────

    /**
     * @notice Arbitrator claims their fee after a dispute resolves.
     */
    function claimFee(uint256 disputeId) external {
        if (!isArbitrator[msg.sender]) revert NotArbitrator();
        uint256 fee = pendingFees[disputeId][msg.sender];
        if (fee == 0) revert NothingToClaim();

        Dispute storage d = disputes[disputeId];
        if (d.outcome == DisputeOutcome.Pending) revert DisputeNotPending();

        pendingFees[disputeId][msg.sender] = 0;
        bool ok = _safeTransfer(d.paymentToken, msg.sender, fee);
        if (!ok) revert TransferFailed();

        emit FeeClaimed(msg.sender, fee);
    }

    // ─────────────────────────────────────────────
    // View Helpers
    // ─────────────────────────────────────────────

    function getDispute(uint256 disputeId) external view returns (Dispute memory) {
        return disputes[disputeId];
    }

    function getArbitratorCount() external view returns (uint256) {
        return _arbitrators.length;
    }

    function disputeCount() external view returns (uint256) {
        return _disputeCounter;
    }

    // ─────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────

    function _resolve(
        uint256 disputeId,
        Dispute storage d,
        DisputeOutcome outcome
    ) internal {
        d.outcome    = outcome;
        d.resolvedAt = block.timestamp;

        bool workerWins = (outcome == DisputeOutcome.WorkerWins);

        // Callback into TaskEscrow
        // Using a low-level call to avoid circular import issues at deploy time.
        (bool ok,) = escrow.call(
            abi.encodeWithSignature(
                "resolveDispute(uint256,address,bool)",
                d.taskId,
                d.worker,
                workerWins
            )
        );
        // We emit even if the callback fails (escrow state may need manual fix)
        require(ok, "Escrow callback failed");

        emit DisputeResolved(disputeId, outcome);
    }

    function _safeTransfer(
        address token,
        address to,
        uint256 amount
    ) internal returns (bool) {
        if (token == address(0) || amount == 0) return true;
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to, amount)
        );
        return success && (data.length == 0 || abi.decode(data, (bool)));
    }
}
