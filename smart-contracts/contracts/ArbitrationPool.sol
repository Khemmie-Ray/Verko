// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./WorkerReputation.sol";

contract ArbitrationPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Constants
    uint256 public constant PANEL_SIZE = 3; // arbitrators per dispute
    uint256 public constant VOTE_DEADLINE = 48 hours;
    uint256 public constant ARB_FEE_BPS = 200; // 2% of bounty goes to arbitrators

    // Types
    enum Vote {
        None,
        Approve,
        Reject
    }
    enum Verdict {
        Pending,
        WorkerWins,
        PosterWins,
        NoQuorum
    }

    struct Dispute {
        uint256 taskId;
        address worker;
        address poster;
        uint256 bounty; // G$ amount locked for this dispute
        uint256 arbFee; // portion reserved for arbitrators
        uint256 createdAt;
        address[PANEL_SIZE] panel;
        mapping(address => Vote) votes;
        uint8 voteCount;
        Verdict verdict;
        bool settled;
    }

    // State

    IERC20 public immutable gToken;
    WorkerReputation public immutable reputation;

    // TaskEscrow address
    address public taskEscrow;

    uint256 private _nextDisputeId;

    mapping(uint256 => Dispute) private _disputes;

    // Events

    event DisputeOpened(
        uint256 indexed disputeId,
        uint256 indexed taskId,
        address worker,
        address poster
    );
    event VoteCast(
        uint256 indexed disputeId,
        address indexed arbitrator,
        Vote vote
    );
    event DisputeSettled(uint256 indexed disputeId, Verdict verdict);
    event ArbitratorPaid(
        uint256 indexed disputeId,
        address indexed arbitrator,
        uint256 amount
    );

    // Errors
    error OnlyTaskEscrow();
    error DisputeNotFound();
    error NotOnPanel();
    error AlreadyVoted();
    error AlreadySettled();
    error VotingOpen();
    error VotingClosed();
    error InsufficientPanel();

    // Modifiers
    modifier onlyTaskEscrow() {
        if (msg.sender != taskEscrow) revert OnlyTaskEscrow();
        _;
    }

    // Constructor
    constructor(address _gToken, address _reputation) Ownable(msg.sender) {
        gToken = IERC20(_gToken);
        reputation = WorkerReputation(_reputation);
        _nextDisputeId = 1;
    }

    // Admin functions
    function setTaskEscrow(address _taskEscrow) external onlyOwner {
        taskEscrow = _taskEscrow;
    }

    //Core logic
    function openDispute(
        uint256 taskId,
        address worker,
        address poster,
        uint256 bounty,
        address[PANEL_SIZE] calldata candidatePanel
    ) external onlyTaskEscrow nonReentrant returns (uint256 disputeId) {
        // Validate each candidate
        for (uint256 i = 0; i < PANEL_SIZE; i++) {
            address candidate = candidatePanel[i];
            require(
                candidate != worker && candidate != poster,
                "Arbitrator cannot be a party"
            );
            require(
                reputation.isRegistered(candidate),
                "Candidate not a registered Verker"
            );
            WorkerReputation.Tier t = reputation.getTier(candidate);
            require(
                t == WorkerReputation.Tier.Trusted ||
                    t == WorkerReputation.Tier.Elite,
                "Candidate tier too low"
            );
            // Check for duplicates
            for (uint256 j = 0; j < i; j++) {
                require(candidatePanel[j] != candidate, "Duplicate arbitrator");
            }
        }

        uint256 arbFee = (bounty * ARB_FEE_BPS) / 10_000;

        disputeId = _nextDisputeId++;
        Dispute storage d = _disputes[disputeId];
        d.taskId = taskId;
        d.worker = worker;
        d.poster = poster;
        d.bounty = bounty;
        d.arbFee = arbFee;
        d.createdAt = block.timestamp;
        d.panel = candidatePanel;
        d.verdict = Verdict.Pending;
        d.settled = false;

        emit DisputeOpened(disputeId, taskId, worker, poster);
    }

    function castVote(uint256 disputeId, Vote vote) external nonReentrant {
        Dispute storage d = _disputes[disputeId];
        if (d.createdAt == 0) revert DisputeNotFound();
        if (d.settled) revert AlreadySettled();
        if (block.timestamp > d.createdAt + VOTE_DEADLINE)
            revert VotingClosed();
        if (!_isOnPanel(d, msg.sender)) revert NotOnPanel();
        if (d.votes[msg.sender] != Vote.None) revert AlreadyVoted();
        require(vote == Vote.Approve || vote == Vote.Reject, "Invalid vote");

        d.votes[msg.sender] = vote;
        d.voteCount++;

        emit VoteCast(disputeId, msg.sender, vote);

        // Auto-settle once all panel members have voted
        if (d.voteCount == PANEL_SIZE) {
            _settle(disputeId);
        }
    }

    function settle(uint256 disputeId) external nonReentrant {
        Dispute storage d = _disputes[disputeId];
        if (d.createdAt == 0) revert DisputeNotFound();
        if (d.settled) revert AlreadySettled();
        if (
            block.timestamp <= d.createdAt + VOTE_DEADLINE &&
            d.voteCount < PANEL_SIZE
        ) revert VotingOpen();

        _settle(disputeId);
    }

    // Internal logic

    function _settle(uint256 disputeId) internal {
        Dispute storage d = _disputes[disputeId];
        d.settled = true;

        uint256 approveVotes = 0;
        uint256 rejectVotes = 0;

        for (uint256 i = 0; i < PANEL_SIZE; i++) {
            Vote v = d.votes[d.panel[i]];
            if (v == Vote.Approve) approveVotes++;
            else if (v == Vote.Reject) rejectVotes++;
        }

        Verdict verdict;
        address payoutRecipient;

        if (approveVotes > rejectVotes) {
            verdict = Verdict.WorkerWins;
            payoutRecipient = d.worker;
        } else if (rejectVotes > approveVotes) {
            verdict = Verdict.PosterWins;
            payoutRecipient = d.poster;
        } else {
            // Tie or no votes → conservative: poster gets bounty back
            verdict = Verdict.NoQuorum;
            payoutRecipient = d.poster;
        }

        d.verdict = verdict;

        // Pay bounty (minus arb fee) to the winning party
        uint256 payout = d.bounty - d.arbFee;
        gToken.safeTransfer(payoutRecipient, payout);

        // Split arb fee equally among panel members who actually voted
        uint256 voterCount = approveVotes + rejectVotes;
        if (voterCount > 0) {
            uint256 perArbitrator = d.arbFee / voterCount;
            for (uint256 i = 0; i < PANEL_SIZE; i++) {
                address arb = d.panel[i];
                if (d.votes[arb] != Vote.None) {
                    gToken.safeTransfer(arb, perArbitrator);
                    // Update their reputation stats
                    try
                        reputation.recordArbitration(arb, perArbitrator)
                    {} catch {}
                    emit ArbitratorPaid(disputeId, arb, perArbitrator);
                }
            }
            // Remainder (dust from integer division) goes to poster
            uint256 remainder = d.arbFee - (perArbitrator * voterCount);
            if (remainder > 0) {
                gToken.safeTransfer(d.poster, remainder);
            }
        } else {
            // No one voted — full arb fee also goes back to poster
            gToken.safeTransfer(d.poster, d.arbFee);
        }

        emit DisputeSettled(disputeId, verdict);
    }

    function _isOnPanel(
        Dispute storage d,
        address addr
    ) internal view returns (bool) {
        for (uint256 i = 0; i < PANEL_SIZE; i++) {
            if (d.panel[i] == addr) return true;
        }
        return false;
    }

    // View functions

    function getDisputeInfo(
        uint256 disputeId
    )
        external
        view
        returns (
            uint256 taskId,
            address worker,
            address poster,
            uint256 bounty,
            uint256 createdAt,
            uint8 voteCount,
            Verdict verdict,
            bool settled
        )
    {
        Dispute storage d = _disputes[disputeId];
        if (d.createdAt == 0) revert DisputeNotFound();
        return (
            d.taskId,
            d.worker,
            d.poster,
            d.bounty,
            d.createdAt,
            d.voteCount,
            d.verdict,
            d.settled
        );
    }

    function getPanel(
        uint256 disputeId
    ) external view returns (address[PANEL_SIZE] memory) {
        Dispute storage d = _disputes[disputeId];
        if (d.createdAt == 0) revert DisputeNotFound();
        return d.panel;
    }

    function getVote(
        uint256 disputeId,
        address arbitrator
    ) external view returns (Vote) {
        Dispute storage d = _disputes[disputeId];
        if (d.createdAt == 0) revert DisputeNotFound();
        return d.votes[arbitrator];
    }

    function totalDisputes() external view returns (uint256) {
        return _nextDisputeId - 1;
    }
}
