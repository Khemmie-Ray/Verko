// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./WorkerReputation.sol";
import "./ArbitrationPool.sol";

contract TaskEscrow {
   
    // Types
    enum TaskStatus {
        Open,       // accepting worker applications
        InProgress, // max workers reached, awaiting submissions
        Completed,  // all slots filled and approved
        Cancelled,  // poster cancelled before completion
        Disputed    // at least one submission under arbitration
    }

    enum SubmissionStatus {
        None,
        Submitted,
        Approved,
        Rejected,
        Disputed
    }

    
    enum VerificationMethod {
        OnChainText,   // worker submits plain text stored on-chain
        GoogleForm,    // poster provides a Google Form URL
        Email,         // poster provides an email address
        SocialPost,    // worker posts on X/Twitter/LinkedIn and submits link
        Custom         // any other method described in verificationRef
    }

    struct Task {
        uint256 id;
        address poster;
        string  title;
        string  description;
        string  category;           
        bool    isPaid;
        uint256 bountyPerWorker;    
        address paymentToken;      
        uint32  maxWorkers;
        uint32  currentWorkers;     
        uint32  approvedCount;
        uint64  deadline;           
        TaskStatus status;
        VerificationMethod verificationMethod;
        string  verificationRef;    
        uint256 totalEscrowed;      
    }

    struct Submission {
        address worker;
        string  proofData;          
        SubmissionStatus status;
        string  rejectionReason;
        uint256 submittedAt;
    }

   
    // State
    WorkerReputation public immutable reputation;
    ArbitrationPool  public immutable arbitration;

    address public owner;
    address public verifier;        
    uint16  public platformFeeBps;  

    uint256 private _taskCounter;

    mapping(uint256 => Task)                            public tasks;
    /// taskId => worker => Submission
    mapping(uint256 => mapping(address => Submission))  public submissions;
    /// taskId => list of worker addresses who submitted
    mapping(uint256 => address[])                       private _taskWorkers;
    /// taskId => worker => has joined (accepted the task)
    mapping(uint256 => mapping(address => bool))        public hasJoined;
    /// GoodDollar-verified workers (set by `verifier` address)
    mapping(address => bool)                            public workerVerified;
    /// Accumulated platform fees per token
    mapping(address => uint256)                         public feesCollected;

  
    // Events
    event TaskCreated(
        uint256 indexed taskId,
        address indexed poster,
        bool isPaid,
        uint256 bountyPerWorker,
        uint32 maxWorkers,
        VerificationMethod verificationMethod
    );
    event WorkerJoined(uint256 indexed taskId, address indexed worker);
    event ProofSubmitted(uint256 indexed taskId, address indexed worker, string proofData);
    event SubmissionApproved(uint256 indexed taskId, address indexed worker, uint256 payout);
    event SubmissionRejected(uint256 indexed taskId, address indexed worker, string reason);
    event SubmissionDisputed(uint256 indexed taskId, address indexed worker);
    event TaskCancelled(uint256 indexed taskId);
    event WorkerVerified(address indexed worker);
    event FeesWithdrawn(address indexed token, uint256 amount);

   
    // Errors
    error NotOwner();
    error NotVerifier();
    error NotPoster();
    error TaskNotOpen();
    error TaskExpired();
    error TaskFull();
    error AlreadyJoined();
    error NotJoined();
    error AlreadySubmitted();
    error WorkerNotVerified();
    error InsufficientEscrow();
    error DeadlineMustBeFuture();
    error MaxWorkersMustBePositive();
    error TransferFailed();
    error InvalidSubmissionStatus();
    error ZeroAddress();

   
    // Modifiers
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyVerifier() {
        if (msg.sender != verifier) revert NotVerifier();
        _;
    }

    modifier onlyPoster(uint256 taskId) {
        if (msg.sender != tasks[taskId].poster) revert NotPoster();
        _;
    }

    
    // Constructor
    constructor(
        address _reputation,
        address _arbitration,
        address _verifier,
        uint16  _platformFeeBps
    ) {
        if (_reputation == address(0) || _arbitration == address(0) || _verifier == address(0))
            revert ZeroAddress();
        reputation      = WorkerReputation(_reputation);
        arbitration     = ArbitrationPool(_arbitration);
        verifier        = _verifier;
        platformFeeBps  = _platformFeeBps;
        owner           = msg.sender;
    }

    // Task Poster Functions
    struct TaskParams {
        string  title;
        string  description;
        string  category;
        uint256 bountyPerWorker;  // 0 = unpaid task
        address paymentToken;     // ignored when bountyPerWorker == 0
        uint32  maxWorkers;
        uint64  deadline;
        VerificationMethod verificationMethod;
        string  verificationRef;
    }

    
    function createTask(TaskParams calldata p) external returns (uint256 taskId) {
        if (p.maxWorkers == 0)             revert MaxWorkersMustBePositive();
        if (p.deadline <= block.timestamp) revert DeadlineMustBeFuture();

        bool    isPaid  = p.bountyPerWorker > 0;
        uint256 escrowed;

        if (isPaid) {
            if (p.paymentToken == address(0)) revert ZeroAddress();
            uint256 gross = p.bountyPerWorker * p.maxWorkers;
            uint256 fee   = (gross * platformFeeBps) / 10_000;
            bool ok = _safeTransferFrom(p.paymentToken, msg.sender, address(this), gross + fee);
            if (!ok) revert TransferFailed();
            feesCollected[p.paymentToken] += fee;
            escrowed = gross;
        }

        taskId = ++_taskCounter;
        tasks[taskId] = Task({
            id:                 taskId,
            poster:             msg.sender,
            title:              p.title,
            description:        p.description,
            category:           p.category,
            isPaid:             isPaid,
            bountyPerWorker:    p.bountyPerWorker,
            paymentToken:       isPaid ? p.paymentToken : address(0),
            maxWorkers:         p.maxWorkers,
            currentWorkers:     0,
            approvedCount:      0,
            deadline:           p.deadline,
            status:             TaskStatus.Open,
            verificationMethod: p.verificationMethod,
            verificationRef:    p.verificationRef,
            totalEscrowed:      escrowed
        });

        emit TaskCreated(
            taskId, msg.sender, isPaid,
            p.bountyPerWorker, p.maxWorkers, p.verificationMethod
        );
    }

   
    function approveSubmission(uint256 taskId, address worker) external onlyPoster(taskId) {
        Task storage t = tasks[taskId];
        Submission storage sub = submissions[taskId][worker];

        if (sub.status != SubmissionStatus.Submitted) revert InvalidSubmissionStatus();

        sub.status = SubmissionStatus.Approved;
        t.approvedCount++;

        // Release bounty to worker
        if (t.isPaid && t.bountyPerWorker > 0) {
            bool ok = _safeTransfer(t.paymentToken, worker, t.bountyPerWorker);
            if (!ok) revert TransferFailed();
            t.totalEscrowed -= t.bountyPerWorker;
            emit SubmissionApproved(taskId, worker, t.bountyPerWorker);
        } else {
            emit SubmissionApproved(taskId, worker, 0);
        }

        // Update on-chain reputation
        reputation.recordCompletion(worker, taskId, true);

        if (t.approvedCount == t.maxWorkers) {
            t.status = TaskStatus.Completed;
        }
    }

    function rejectSubmission(
        uint256 taskId,
        address worker,
        string calldata reason
    ) external onlyPoster(taskId) {
        Task storage t = tasks[taskId];
        Submission storage sub = submissions[taskId][worker];

        if (sub.status != SubmissionStatus.Submitted) revert InvalidSubmissionStatus();

        sub.status = SubmissionStatus.Rejected;
        sub.rejectionReason = reason;

        // Free the slot so another worker can join
        t.currentWorkers--;
        hasJoined[taskId][worker] = false;
        if (t.status == TaskStatus.InProgress) {
            t.status = TaskStatus.Open;
        }

        reputation.recordCompletion(worker, taskId, false);
        emit SubmissionRejected(taskId, worker, reason);
    }

  
    function raiseDispute(uint256 taskId, address worker) external onlyPoster(taskId) {
        Submission storage sub = submissions[taskId][worker];
        if (sub.status != SubmissionStatus.Submitted) revert InvalidSubmissionStatus();

        sub.status = SubmissionStatus.Disputed;
        tasks[taskId].status = TaskStatus.Disputed;

        arbitration.openDispute(taskId, worker, tasks[taskId].poster);
        emit SubmissionDisputed(taskId, worker);
    }

    
    function cancelTask(uint256 taskId) external onlyPoster(taskId) {
        Task storage t = tasks[taskId];
        if (t.status != TaskStatus.Open && t.status != TaskStatus.InProgress)
            revert TaskNotOpen();

        t.status = TaskStatus.Cancelled;

        if (t.isPaid && t.totalEscrowed > 0) {
            uint256 refund = t.totalEscrowed;
            t.totalEscrowed = 0;
            bool ok = _safeTransfer(t.paymentToken, t.poster, refund);
            if (!ok) revert TransferFailed();
        }

        emit TaskCancelled(taskId);
    }

   
    // Worker Functions
    function joinTask(uint256 taskId) external {
        if (!workerVerified[msg.sender]) revert WorkerNotVerified();

        Task storage t = tasks[taskId];
        if (block.timestamp >= t.deadline)            revert TaskExpired();
        if (t.currentWorkers >= t.maxWorkers)         revert TaskFull();
        if (t.status != TaskStatus.Open)             revert TaskNotOpen();
        if (hasJoined[taskId][msg.sender])            revert AlreadyJoined();

        hasJoined[taskId][msg.sender] = true;
        t.currentWorkers++;
        _taskWorkers[taskId].push(msg.sender);

        if (t.currentWorkers == t.maxWorkers) {
            t.status = TaskStatus.InProgress;
        }

        emit WorkerJoined(taskId, msg.sender);
    }

    function submitProof(uint256 taskId, string calldata proofData) external {
        Task storage t = tasks[taskId];
        if (!hasJoined[taskId][msg.sender])           revert NotJoined();
        if (block.timestamp >= t.deadline)            revert TaskExpired();

        Submission storage sub = submissions[taskId][msg.sender];
        if (sub.status != SubmissionStatus.None &&
            sub.status != SubmissionStatus.Rejected)  revert AlreadySubmitted();

        submissions[taskId][msg.sender] = Submission({
            worker:          msg.sender,
            proofData:       proofData,
            status:          SubmissionStatus.Submitted,
            rejectionReason: "",
            submittedAt:     block.timestamp
        });

        emit ProofSubmitted(taskId, msg.sender, proofData);
    }


    // Arbitration Callback   
    function resolveDispute(
        uint256 taskId,
        address worker,
        bool inFavourOfWorker
    ) external {
        if (msg.sender != address(arbitration)) revert NotVerifier();

        Task storage t = tasks[taskId];
        Submission storage sub = submissions[taskId][worker];

        if (inFavourOfWorker) {
            sub.status = SubmissionStatus.Approved;
            t.approvedCount++;
            if (t.isPaid && t.bountyPerWorker > 0) {
                t.totalEscrowed -= t.bountyPerWorker;
                _safeTransfer(t.paymentToken, worker, t.bountyPerWorker);
            }
            reputation.recordCompletion(worker, taskId, true);
            emit SubmissionApproved(taskId, worker, t.bountyPerWorker);
        } else {
            sub.status = SubmissionStatus.Rejected;
            reputation.recordCompletion(worker, taskId, false);
            // Free the slot
            t.currentWorkers--;
            hasJoined[taskId][worker] = false;
            emit SubmissionRejected(taskId, worker, "Arbitration: ruled against worker");
        }

        if (t.status == TaskStatus.Disputed) {
            t.status = t.approvedCount == t.maxWorkers
                ? TaskStatus.Completed
                : TaskStatus.Open;
        }
    }

   
    // Verifier / Admin
    function setWorkerVerified(address worker) external onlyVerifier {
        workerVerified[worker] = true;
        emit WorkerVerified(worker);
    }

    function setVerifier(address _verifier) external onlyOwner {
        if (_verifier == address(0)) revert ZeroAddress();
        verifier = _verifier;
    }

    function setPlatformFee(uint16 bps) external onlyOwner {
        require(bps <= 1000, "Fee too high"); // max 10 %
        platformFeeBps = bps;
    }

    function withdrawFees(address token) external onlyOwner {
        uint256 amount = feesCollected[token];
        feesCollected[token] = 0;
        bool ok = _safeTransfer(token, owner, amount);
        if (!ok) revert TransferFailed();
        emit FeesWithdrawn(token, amount);
    }

    // View Helpers
    function getTask(uint256 taskId) external view returns (Task memory) {
        return tasks[taskId];
    }

    function getSubmission(uint256 taskId, address worker)
        external view returns (Submission memory)
    {
        return submissions[taskId][worker];
    }

    function getTaskWorkers(uint256 taskId)
        external view returns (address[] memory)
    {
        return _taskWorkers[taskId];
    }

    function taskCount() external view returns (uint256) {
        return _taskCounter;
    }

    function _safeTransfer(
        address token,
        address to,
        uint256 amount
    ) internal returns (bool) {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to, amount)
        );
        return success && (data.length == 0 || abi.decode(data, (bool)));
    }

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal returns (bool) {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0x23b872dd, from, to, amount)
        );
        return success && (data.length == 0 || abi.decode(data, (bool)));
    }
}
