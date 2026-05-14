// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./WorkerReputation.sol";
import "./ArbitrationPool.sol";


contract TaskEscrow is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // Constants

    uint256 public constant MAX_WORKERS_PER_TASK = 500;
    uint256 public constant MIN_BOUNTY           = 1e16; // 0.01 G$ (18 decimals)
    uint256 public constant DISPUTE_WINDOW       = 48 hours; // after rejection, worker can dispute
    uint256 public constant MAX_DEADLINE         = 90 days;

    // Types

    enum TaskStatus {
        Open,        // accepting submissions
        Filled,      // all slots taken; awaiting reviews
        Completed,   // all slots approved or rejected
        Expired,     // deadline passed before all slots filled/completed
        Cancelled    // cancelled by poster before any submissions
    }

    enum SubmissionStatus {
        None,
        Pending,     // submitted, awaiting poster review
        Approved,
        Rejected,
        Disputed,    // escalated to ArbitrationPool
        Resolved     // dispute settled
    }

    struct Task {
        uint256   id;
        address   poster;
        string    metadataURI;    // IPFS/Arweave URI with title, description, proof requirements
        uint256   bountyPerWorker; // net bounty (after platform fee) per worker, in G$ wei
        uint256   workerSlots;    // total workers needed
        uint256   slotsRemaining;
        uint256   deadline;
        uint256   totalDeposit;   // gross deposit (bounty × slots + fee)
        uint256   platformFee;    // total fee deducted at creation
        TaskStatus status;
        uint256   createdAt;
    }

    struct Submission {
        address   worker;
        uint256   taskId;
        string    proofURI;       // IPFS/Arweave URI of proof (photo, form answers, etc.)
        SubmissionStatus status;
        string    rejectionReason;
        uint256   submittedAt;
        uint256   rejectedAt;
        uint256   disputeId;      // 0 if not disputed
    }

    // State

    IERC20             public immutable gToken;
    WorkerReputation   public immutable reputation;
    ArbitrationPool    public immutable arbitration;

    address  public feeRecipient;
    uint256  public platformFeeBps = 600; // 6% default; max 10%

    uint256  private _nextTaskId;
    uint256  private _nextSubmissionId;

    mapping(uint256 => Task)       private _tasks;
    mapping(uint256 => Submission) private _submissions;

    // taskId → worker address → submissionId (0 = not submitted)
    mapping(uint256 => mapping(address => uint256)) private _workerSubmission;

    // taskId → array of submissionIds
    mapping(uint256 => uint256[]) private _taskSubmissions;

    // Events

    event TaskCreated(
        uint256 indexed taskId,
        address indexed poster,
        uint256 bountyPerWorker,
        uint256 workerSlots,
        uint256 deadline
    );
    event TaskCancelled(uint256 indexed taskId);
    event TaskExpired(uint256 indexed taskId);

    event SubmissionCreated(uint256 indexed submissionId, uint256 indexed taskId, address indexed worker);
    event SubmissionApproved(uint256 indexed submissionId, uint256 indexed taskId, address indexed worker, uint256 payout);
    event SubmissionRejected(uint256 indexed submissionId, uint256 indexed taskId, string reason);
    event SubmissionDisputed(uint256 indexed submissionId, uint256 indexed taskId, uint256 disputeId);

    event PlatformFeeUpdated(uint256 newFeeBps);
    event FeeRecipientUpdated(address newRecipient);

    // Errors

    error TaskNotFound();
    error TaskNotOpen();
    error TaskExpiredError();
    error TaskCancelledError();
    error AlreadySubmitted();
    error SubmissionNotFound();
    error NotPoster();
    error NotWorker();
    error NotPending();
    error DisputeWindowClosed();
    error DisputeWindowOpen();
    error InvalidBounty();
    error InvalidSlots();
    error InvalidDeadline();
    error FeeTooHigh();
    error ZeroAddress();

    // Modifiers

    modifier taskExists(uint256 taskId) {
        if (_tasks[taskId].createdAt == 0) revert TaskNotFound();
        _;
    }

    modifier submissionExists(uint256 submissionId) {
        if (_submissions[submissionId].submittedAt == 0) revert SubmissionNotFound();
        _;
    }

    // Constructor

    constructor(
        address _gToken,
        address _reputation,
        address _arbitration,
        address _feeRecipient
    ) Ownable(msg.sender) {
        if (_gToken == address(0) || _reputation == address(0) ||
            _arbitration == address(0) || _feeRecipient == address(0))
            revert ZeroAddress();

        gToken       = IERC20(_gToken);
        reputation   = WorkerReputation(_reputation);
        arbitration  = ArbitrationPool(_arbitration);
        feeRecipient = _feeRecipient;
        _nextTaskId       = 1;
        _nextSubmissionId = 1;
    }

    // Admin functions

    function setPlatformFee(uint256 feeBps) external onlyOwner {
        if (feeBps > 1000) revert FeeTooHigh(); // max 10%
        platformFeeBps = feeBps;
        emit PlatformFeeUpdated(feeBps);
    }

    function setFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        feeRecipient = recipient;
        emit FeeRecipientUpdated(recipient);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // Poster: create a task
    function createTask(
        string calldata metadataURI,
        uint256 bountyPerWorker,
        uint256 workerSlots,
        uint256 deadline
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 taskId)
    {
        if (bountyPerWorker < MIN_BOUNTY)                         revert InvalidBounty();
        if (workerSlots == 0 || workerSlots > MAX_WORKERS_PER_TASK) revert InvalidSlots();
        if (deadline <= block.timestamp || deadline > block.timestamp + MAX_DEADLINE)
            revert InvalidDeadline();

        // Calculate gross deposit (bounty + platform fee)
        uint256 netTotal  = bountyPerWorker * workerSlots;
        uint256 feeTotal  = (netTotal * platformFeeBps) / 10_000;
        uint256 grossTotal = netTotal + feeTotal;

        taskId = _nextTaskId++;
        _tasks[taskId] = Task({
            id:               taskId,
            poster:           msg.sender,
            metadataURI:      metadataURI,
            bountyPerWorker:  bountyPerWorker,
            workerSlots:      workerSlots,
            slotsRemaining:   workerSlots,
            deadline:         deadline,
            totalDeposit:     grossTotal,
            platformFee:      feeTotal,
            status:           TaskStatus.Open,
            createdAt:        block.timestamp
        });

        // Pull funds from poster; platform fee goes immediately to fee recipient
        gToken.safeTransferFrom(msg.sender, address(this), grossTotal);
        gToken.safeTransfer(feeRecipient, feeTotal);

        emit TaskCreated(taskId, msg.sender, bountyPerWorker, workerSlots, deadline);
    }

    // Poster: cancel task 
       function cancelTask(uint256 taskId)
        external
        nonReentrant
        taskExists(taskId)
    {
        Task storage t = _tasks[taskId];
        if (t.poster != msg.sender) revert NotPoster();
        if (t.status != TaskStatus.Open) revert TaskNotOpen();
        if (_taskSubmissions[taskId].length > 0) revert("Cannot cancel: submissions exist");

        t.status = TaskStatus.Cancelled;

        // Refund net escrow (fee already sent to feeRecipient at creation)
        uint256 refund = t.bountyPerWorker * t.workerSlots;
        gToken.safeTransfer(t.poster, refund);

        emit TaskCancelled(taskId);
    }

    // Worker: submit proof 
    function submitProof(uint256 taskId, string calldata proofURI)
        external
        nonReentrant
        whenNotPaused
        taskExists(taskId)
        returns (uint256 submissionId)
    {
        Task storage t = _tasks[taskId];

        if (t.status == TaskStatus.Cancelled)  revert TaskCancelledError();
        if (t.status != TaskStatus.Open)       revert TaskNotOpen();
        if (block.timestamp > t.deadline)      revert TaskExpiredError();
        if (_workerSubmission[taskId][msg.sender] != 0) revert AlreadySubmitted();
        if (t.poster == msg.sender) revert("Poster cannot work their own task");

        // Auto-register worker if not yet in reputation contract
        if (!reputation.isRegistered(msg.sender)) {
            reputation.register(msg.sender);
        }

        // Claim a slot
        t.slotsRemaining--;
        if (t.slotsRemaining == 0) {
            t.status = TaskStatus.Filled;
        }

        submissionId = _nextSubmissionId++;
        _submissions[submissionId] = Submission({
            worker:           msg.sender,
            taskId:           taskId,
            proofURI:         proofURI,
            status:           SubmissionStatus.Pending,
            rejectionReason:  "",
            submittedAt:      block.timestamp,
            rejectedAt:       0,
            disputeId:        0
        });

        _workerSubmission[taskId][msg.sender] = submissionId;
        _taskSubmissions[taskId].push(submissionId);

        emit SubmissionCreated(submissionId, taskId, msg.sender);
    }

    //  Poster: approve submission 
    function approveSubmission(uint256 submissionId)
        external
        nonReentrant
        submissionExists(submissionId)
    {
        Submission storage s = _submissions[submissionId];
        Task storage t       = _tasks[s.taskId];

        if (t.poster != msg.sender)              revert NotPoster();
        if (s.status != SubmissionStatus.Pending) revert NotPending();

        s.status = SubmissionStatus.Approved;

        // Pay worker instantly
        gToken.safeTransfer(s.worker, t.bountyPerWorker);

        // Update reputation
        try reputation.recordApproval(s.worker, t.bountyPerWorker) {} catch {}

        // Mark task complete if all slots resolved
        _checkTaskCompletion(s.taskId);

        emit SubmissionApproved(submissionId, s.taskId, s.worker, t.bountyPerWorker);
    }

    // Poster: reject submission
    function rejectSubmission(uint256 submissionId, string calldata reason)
        external
        nonReentrant
        submissionExists(submissionId)
    {
        Submission storage s = _submissions[submissionId];
        Task storage t       = _tasks[s.taskId];

        if (t.poster != msg.sender)              revert NotPoster();
        if (s.status != SubmissionStatus.Pending) revert NotPending();
        require(bytes(reason).length > 0, "Rejection reason required");

        s.status          = SubmissionStatus.Rejected;
        s.rejectionReason = reason;
        s.rejectedAt      = block.timestamp;

        // Update reputation
        try reputation.recordRejection(s.worker) {} catch {}

        emit SubmissionRejected(submissionId, s.taskId, reason);
    }

    // Worker: dispute a rejection 
    function disputeSubmission(
        uint256 submissionId,
        address[3] calldata candidatePanel
    )
        external
        nonReentrant
        submissionExists(submissionId)
    {
        Submission storage s = _submissions[submissionId];
        Task storage t       = _tasks[s.taskId];

        if (s.worker != msg.sender)                    revert NotWorker();
        if (s.status != SubmissionStatus.Rejected)     revert NotPending();
        if (block.timestamp > s.rejectedAt + DISPUTE_WINDOW) revert DisputeWindowClosed();

        s.status = SubmissionStatus.Disputed;

        // Transfer bounty to ArbitrationPool
        uint256 bounty = t.bountyPerWorker;
        gToken.safeTransfer(address(arbitration), bounty);

        uint256 disputeId = arbitration.openDispute(
            s.taskId,
            s.worker,
            t.poster,
            bounty,
            candidatePanel
        );

        s.disputeId = disputeId;

        emit SubmissionDisputed(submissionId, s.taskId, disputeId);
    }

    //Poster: reclaim bounty after rejection
    function reclaimRejectedBounty(uint256 submissionId)
        external
        nonReentrant
        submissionExists(submissionId)
    {
        Submission storage s = _submissions[submissionId];
        Task storage t       = _tasks[s.taskId];

        if (t.poster != msg.sender)                   revert NotPoster();
        if (s.status != SubmissionStatus.Rejected)    revert NotPending();
        if (block.timestamp <= s.rejectedAt + DISPUTE_WINDOW) revert DisputeWindowOpen();

        s.status = SubmissionStatus.Resolved;
        gToken.safeTransfer(t.poster, t.bountyPerWorker);

        _checkTaskCompletion(s.taskId);
    }

    // Poster: expire task and reclaim
    function expireTask(uint256 taskId)
        external
        nonReentrant
        taskExists(taskId)
    {
        Task storage t = _tasks[taskId];
        if (t.poster != msg.sender) revert NotPoster();
        if (t.status != TaskStatus.Open && t.status != TaskStatus.Filled)
            revert("Task not active");
        if (block.timestamp <= t.deadline) revert("Deadline not passed");

        t.status = TaskStatus.Expired;

        // Refund bounty for unfilled slots only
        uint256 refund = t.bountyPerWorker * t.slotsRemaining;
        if (refund > 0) {
            gToken.safeTransfer(t.poster, refund);
        }

        emit TaskExpired(taskId);
    }

    // Internal helpers 
    function _checkTaskCompletion(uint256 taskId) internal {
        Task storage t = _tasks[taskId];
        if (t.status == TaskStatus.Completed || t.status == TaskStatus.Expired) return;

        uint256[] storage subs = _taskSubmissions[taskId];
        uint256 resolved = 0;

        for (uint256 i = 0; i < subs.length; i++) {
            SubmissionStatus ss = _submissions[subs[i]].status;
            if (
                ss == SubmissionStatus.Approved ||
                ss == SubmissionStatus.Resolved
            ) {
                resolved++;
            }
        }

        // All slots either approved, resolved, or no pending left
        if (resolved == t.workerSlots) {
            t.status = TaskStatus.Completed;
        }
    }

    // View functions 
    function getTask(uint256 taskId) external view taskExists(taskId) returns (Task memory) {
        return _tasks[taskId];
    }

    function getSubmission(uint256 submissionId)
        external
        view
        submissionExists(submissionId)
        returns (Submission memory)
    {
        return _submissions[submissionId];
    }

    function getWorkerSubmission(uint256 taskId, address worker)
        external
        view
        returns (uint256 submissionId)
    {
        return _workerSubmission[taskId][worker];
    }

    function getTaskSubmissions(uint256 taskId)
        external
        view
        taskExists(taskId)
        returns (uint256[] memory)
    {
        return _taskSubmissions[taskId];
    }

    function totalTasks() external view returns (uint256) {
        return _nextTaskId - 1;
    }

    function totalSubmissions() external view returns (uint256) {
        return _nextSubmissionId - 1;
    }

    function quoteDeposit(uint256 bountyPerWorker, uint256 workerSlots)
        external
        view
        returns (uint256 netTotal, uint256 feeTotal, uint256 grossTotal)
    {
        netTotal  = bountyPerWorker * workerSlots;
        feeTotal  = (netTotal * platformFeeBps) / 10_000;
        grossTotal = netTotal + feeTotal;
    }
}
