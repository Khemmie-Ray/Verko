import { expect } from "chai";
import { network } from "hardhat";
import { parseEther, ZeroAddress } from "ethers";
import type { TaskEscrow, WorkerReputation, ArbitrationPool } from "../types/ethers-contracts";

const ONE_DAY = 86_400;
const VerificationMethod = { OnChainText: 0, GoogleForm: 1, Email: 2, SocialPost: 3, Custom: 4 } as const;


let _conn: Awaited<ReturnType<typeof network.create>> | undefined;
async function getConn() {
  if (!_conn) _conn = await network.create();
  return _conn;
}
async function getEthers() {
  return (await getConn()).ethers;
}
async function now(): Promise<number> {
  const ethers = await getEthers();
  const block = await ethers.provider.getBlock("latest");
  return block!.timestamp;
}
async function increaseTime(seconds: number) {
  const conn = await getConn();
  await conn.provider.send("evm_increaseTime", [seconds]);
  await conn.provider.send("evm_mine", []);
}

async function deployAll() {
  const ethers = await getEthers();
  const signers = await ethers.getSigners();
  const [owner, poster, worker1, worker2, worker3, verifierSigner, arb1, arb2, arb3] = signers;

  const reputation = await (await ethers.getContractFactory("WorkerReputation", owner)).deploy() as unknown as WorkerReputation;
  await reputation.waitForDeployment();

  const token = await (await ethers.getContractFactory("MockERC20", owner)).deploy(parseEther("1000000"));
  await token.waitForDeployment();

  const arbitration = await (await ethers.getContractFactory("ArbitrationPool", owner)).deploy(
    await reputation.getAddress(), await token.getAddress(), parseEther("10")
  ) as unknown as ArbitrationPool;
  await arbitration.waitForDeployment();

  const escrow = await (await ethers.getContractFactory("TaskEscrow", owner)).deploy(
    await reputation.getAddress(), await arbitration.getAddress(), verifierSigner.address, 600
  ) as unknown as TaskEscrow;
  await escrow.waitForDeployment();

  await (reputation.connect(owner) as any).setEscrow(await escrow.getAddress());
  await (arbitration.connect(owner) as any).setEscrow(await escrow.getAddress());

  await (token as any).transfer(poster.address, parseEther("50000"));
  await (token.connect(poster) as any).approve(await escrow.getAddress(), parseEther("50000"));
  await (token as any).transfer(await arbitration.getAddress(), parseEther("10000"));

  await (escrow.connect(verifierSigner) as any).setWorkerVerified(worker1.address);
  await (escrow.connect(verifierSigner) as any).setWorkerVerified(worker2.address);
  await (escrow.connect(verifierSigner) as any).setWorkerVerified(worker3.address);

  return { owner, poster, worker1, worker2, worker3, verifierSigner, arb1, arb2, arb3, reputation, arbitration, escrow, token };
}

async function createPaidTask(escrow: TaskEscrow, poster: any, token: any, overrides: Partial<{ bountyPerWorker: bigint; maxWorkers: number; deadline: number; method: number; ref: string }> = {}) {
  const deadline   = overrides.deadline        ?? (await now()) + ONE_DAY;
  const bounty     = overrides.bountyPerWorker ?? parseEther("100");
  const maxWorkers = overrides.maxWorkers      ?? 2;
  const method     = overrides.method          ?? VerificationMethod.OnChainText;
  const ref        = overrides.ref             ?? "";
  const tx = await (escrow.connect(poster) as any).createTask({
    title: "Test Task", description: "Do the thing", category: "Survey",
    bountyPerWorker: bounty, paymentToken: await token.getAddress(),
    maxWorkers, deadline, verificationMethod: method, verificationRef: ref,
  });
  await tx.wait();
  return { taskId: await escrow.taskCount(), deadline, bounty, maxWorkers };
}

async function createUnpaidTask(escrow: TaskEscrow, poster: any) {
  const deadline = (await now()) + ONE_DAY;
  const tx = await (escrow.connect(poster) as any).createTask({
    title: "Unpaid Survey", description: "Help us out", category: "Survey",
    bountyPerWorker: 0n, paymentToken: ZeroAddress, maxWorkers: 3,
    deadline, verificationMethod: VerificationMethod.GoogleForm, verificationRef: "https://forms.google.com/xyz",
  });
  await tx.wait();
  return { taskId: await escrow.taskCount(), deadline };
}

describe("Verko Smart Contracts", function () {

  describe("WorkerReputation", function () {
    it("starts every worker at tier 0 with zero stats", async function () {
      const { reputation, worker1 } = await deployAll();
      const s = await reputation.getStats(worker1.address);
      expect(s.tasksCompleted).to.equal(0n);
      expect(s.tier).to.equal(0);
      expect(s.tokenId).to.equal(0n);
    });

    it("only escrow can call recordCompletion", async function () {
      const { reputation, worker1 } = await deployAll();
      await expect(reputation.recordCompletion(worker1.address, 1n, true))
        .to.be.revertedWithCustomError(reputation, "NotEscrow");
    });

    it("mints soul-bound NFT on first approved completion", async function () {
      const { escrow, reputation, poster, worker1, token } = await deployAll();
      const { taskId } = await createPaidTask(escrow, poster, token, { maxWorkers: 1 });
      await (escrow.connect(worker1) as any).joinTask(taskId);
      await (escrow.connect(worker1) as any).submitProof(taskId, "proof");
      await (escrow.connect(poster) as any).approveSubmission(taskId, worker1.address);
      const s = await reputation.getStats(worker1.address);
      expect(s.tasksCompleted).to.equal(1n);
      expect(s.tokenId).to.be.gt(0n);
      expect(await reputation.ownerOf(s.tokenId)).to.equal(worker1.address);
    });

    it("soul-bound NFT reverts on transfer", async function () {
      const { reputation } = await deployAll();
      await expect(reputation.transferFrom(ZeroAddress, ZeroAddress, 1n))
        .to.be.revertedWithCustomError(reputation, "NonTransferable");
    });

    it("reaches Tier 1 after 5 approved completions", async function () {
      const { escrow, reputation, poster, worker1, token } = await deployAll();
      for (let i = 0; i < 5; i++) {
        const { taskId } = await createPaidTask(escrow, poster, token, { maxWorkers: 1 });
        await (escrow.connect(worker1) as any).joinTask(taskId);
        await (escrow.connect(worker1) as any).submitProof(taskId, `proof-${i}`);
        await (escrow.connect(poster) as any).approveSubmission(taskId, worker1.address);
      }
      expect(await reputation.getTier(worker1.address)).to.equal(1);
    });
  });

  describe("TaskEscrow: Task Creation", function () {
    it("creates a paid task and locks escrow correctly", async function () {
      const { escrow, poster, token } = await deployAll();
      const bounty = parseEther("100"); const maxWorkers = 3;
      const fee = (bounty * BigInt(maxWorkers) * 600n) / 10_000n;
      const posterBefore = await (token as any).balanceOf(poster.address);
      await createPaidTask(escrow, poster, token, { bountyPerWorker: bounty, maxWorkers });
      const posterAfter = await (token as any).balanceOf(poster.address);
      expect(posterBefore - posterAfter).to.equal(bounty * BigInt(maxWorkers) + fee);
      const task = await escrow.getTask(1n);
      expect(task.isPaid).to.be.true;
      expect(task.totalEscrowed).to.equal(bounty * BigInt(maxWorkers));
    });

    it("creates an unpaid task with zero escrow", async function () {
      const { escrow, poster } = await deployAll();
      await createUnpaidTask(escrow, poster);
      const task = await escrow.getTask(1n);
      expect(task.isPaid).to.be.false;
      expect(task.totalEscrowed).to.equal(0n);
    });

    it("stores the verification method and reference correctly", async function () {
      const { escrow, poster, token } = await deployAll();
      await createPaidTask(escrow, poster, token, { method: VerificationMethod.GoogleForm, ref: "https://forms.gle/abc" });
      const task = await escrow.getTask(1n);
      expect(task.verificationMethod).to.equal(VerificationMethod.GoogleForm);
      expect(task.verificationRef).to.equal("https://forms.gle/abc");
    });

    it("reverts if deadline is in the past", async function () {
      const { escrow, poster, token } = await deployAll();
      await expect(createPaidTask(escrow, poster, token, { deadline: (await now()) - 1 }))
        .to.be.revertedWithCustomError(escrow, "DeadlineMustBeFuture");
    });

    it("reverts if maxWorkers is zero", async function () {
      const { escrow, poster, token } = await deployAll();
      await expect(createPaidTask(escrow, poster, token, { maxWorkers: 0 }))
        .to.be.revertedWithCustomError(escrow, "MaxWorkersMustBePositive");
    });
  });

  describe("TaskEscrow: Worker Flow", function () {
    it("unverified worker cannot join", async function () {
      const { escrow, poster, token, arb1 } = await deployAll();
      const { taskId } = await createPaidTask(escrow, poster, token);
      await expect((escrow.connect(arb1) as any).joinTask(taskId))
        .to.be.revertedWithCustomError(escrow, "WorkerNotVerified");
    });

    it("worker joins and task moves to InProgress when full", async function () {
      const { escrow, poster, worker1, worker2, token } = await deployAll();
      const { taskId } = await createPaidTask(escrow, poster, token, { maxWorkers: 2 });
      await (escrow.connect(worker1) as any).joinTask(taskId);
      expect((await escrow.getTask(taskId)).status).to.equal(0);
      await (escrow.connect(worker2) as any).joinTask(taskId);
      expect((await escrow.getTask(taskId)).status).to.equal(1);
    });

    it("cannot join a full task", async function () {
      const { escrow, poster, worker1, worker2, worker3, token } = await deployAll();
      const { taskId } = await createPaidTask(escrow, poster, token, { maxWorkers: 2 });
      await (escrow.connect(worker1) as any).joinTask(taskId);
      await (escrow.connect(worker2) as any).joinTask(taskId);
      await expect((escrow.connect(worker3) as any).joinTask(taskId))
        .to.be.revertedWithCustomError(escrow, "TaskFull");
    });

    it("cannot join the same task twice", async function () {
      const { escrow, poster, worker1, token } = await deployAll();
      const { taskId } = await createPaidTask(escrow, poster, token);
      await (escrow.connect(worker1) as any).joinTask(taskId);
      await expect((escrow.connect(worker1) as any).joinTask(taskId))
        .to.be.revertedWithCustomError(escrow, "AlreadyJoined");
    });

    it("worker submits proof and poster approves — bounty sent", async function () {
      const { escrow, poster, worker1, token } = await deployAll();
      const bounty = parseEther("100");
      const { taskId } = await createPaidTask(escrow, poster, token, { bountyPerWorker: bounty, maxWorkers: 1 });
      await (escrow.connect(worker1) as any).joinTask(taskId);
      await (escrow.connect(worker1) as any).submitProof(taskId, "ipfs://Qm...");
      const before = await (token as any).balanceOf(worker1.address);
      await (escrow.connect(poster) as any).approveSubmission(taskId, worker1.address);
      const after = await (token as any).balanceOf(worker1.address);
      expect(after - before).to.equal(bounty);
      expect((await escrow.getTask(taskId)).status).to.equal(2);
    });

    it("rejection frees the slot for another worker", async function () {
      const { escrow, poster, worker1, worker3, token } = await deployAll();
      const { taskId } = await createPaidTask(escrow, poster, token, { maxWorkers: 1 });
      await (escrow.connect(worker1) as any).joinTask(taskId);
      await (escrow.connect(worker1) as any).submitProof(taskId, "bad proof");
      await (escrow.connect(poster) as any).rejectSubmission(taskId, worker1.address, "Wrong format");
      await (escrow.connect(worker3) as any).joinTask(taskId);
      expect(await escrow.hasJoined(taskId, worker3.address)).to.be.true;
    });

    it("cannot submit without joining", async function () {
      const { escrow, poster, worker1, token } = await deployAll();
      const { taskId } = await createPaidTask(escrow, poster, token);
      await expect((escrow.connect(worker1) as any).submitProof(taskId, "proof"))
        .to.be.revertedWithCustomError(escrow, "NotJoined");
    });

    it("cannot submit after task deadline", async function () {
      const { escrow, poster, worker1, token } = await deployAll();
      const { taskId } = await createPaidTask(escrow, poster, token, { maxWorkers: 1 });
      await (escrow.connect(worker1) as any).joinTask(taskId);
      await increaseTime(ONE_DAY + 1);
      await expect((escrow.connect(worker1) as any).submitProof(taskId, "late proof"))
        .to.be.revertedWithCustomError(escrow, "TaskExpired");
    });
  });

  describe("TaskEscrow: Unpaid Task Flow", function () {
    it("unpaid task completes without transferring tokens", async function () {
      const { escrow, poster, worker1, token, reputation } = await deployAll();
      const { taskId } = await createUnpaidTask(escrow, poster);
      const w1Before = await (token as any).balanceOf(worker1.address);
      await (escrow.connect(worker1) as any).joinTask(taskId);
      await (escrow.connect(worker1) as any).submitProof(taskId, "volunteer proof");
      await (escrow.connect(poster) as any).approveSubmission(taskId, worker1.address);
      expect(await (token as any).balanceOf(worker1.address)).to.equal(w1Before);
      expect((await reputation.getStats(worker1.address)).tasksCompleted).to.equal(1n);
    });
  });

  describe("TaskEscrow: Cancellation", function () {
    it("poster can cancel and receive refund of unused escrow", async function () {
      const { escrow, poster, worker1, token } = await deployAll();
      const bounty = parseEther("100");
      const { taskId } = await createPaidTask(escrow, poster, token, { bountyPerWorker: bounty, maxWorkers: 3 });
      await (escrow.connect(worker1) as any).joinTask(taskId);
      await (escrow.connect(worker1) as any).submitProof(taskId, "ok");
      await (escrow.connect(poster) as any).approveSubmission(taskId, worker1.address);
      const posterBefore = await (token as any).balanceOf(poster.address);
      await (escrow.connect(poster) as any).cancelTask(taskId);
      expect(await (token as any).balanceOf(poster.address) - posterBefore).to.equal(bounty * 2n);
      expect((await escrow.getTask(taskId)).status).to.equal(3);
    });

    it("non-poster cannot cancel", async function () {
      const { escrow, poster, worker1, token } = await deployAll();
      const { taskId } = await createPaidTask(escrow, poster, token);
      await expect((escrow.connect(worker1) as any).cancelTask(taskId))
        .to.be.revertedWithCustomError(escrow, "NotPoster");
    });
  });

  describe("ArbitrationPool", function () {
    async function reachTier2(escrow: TaskEscrow, poster: any, worker: any, token: any) {
      for (let i = 0; i < 20; i++) {
        const { taskId } = await createPaidTask(escrow, poster, token, { maxWorkers: 1 });
        await (escrow.connect(worker) as any).joinTask(taskId);
        await (escrow.connect(worker) as any).submitProof(taskId, `proof-${i}`);
        await (escrow.connect(poster) as any).approveSubmission(taskId, worker.address);
      }
    }

    it("worker with Tier >= 2 can self-register as arbitrator", async function () {
      const { escrow, arbitration, poster, worker1, token } = await deployAll();
      await reachTier2(escrow, poster, worker1, token);
      await (arbitration.connect(worker1) as any).registerArbitrator();
      expect(await arbitration.isArbitrator(worker1.address)).to.be.true;
    });

    it("worker below Tier 2 cannot register as arbitrator", async function () {
      const { arbitration, worker1 } = await deployAll();
      await expect((arbitration.connect(worker1) as any).registerArbitrator())
        .to.be.revertedWithCustomError(arbitration, "InsufficientTier");
    });

    it("dispute resolves in favour of worker after QUORUM votes", async function () {
      const { escrow, arbitration, poster, worker1, token, arb1, arb2, arb3, owner } = await deployAll();
      await (arbitration.connect(owner) as any).addArbitrator(arb1.address);
      await (arbitration.connect(owner) as any).addArbitrator(arb2.address);
      await (arbitration.connect(owner) as any).addArbitrator(arb3.address);
      const { taskId } = await createPaidTask(escrow, poster, token, { maxWorkers: 1 });
      await (escrow.connect(worker1) as any).joinTask(taskId);
      await (escrow.connect(worker1) as any).submitProof(taskId, "proof");
      await (escrow.connect(poster) as any).raiseDispute(taskId, worker1.address);
      const disputeId = await arbitration.taskDispute(taskId);
      const before = await (token as any).balanceOf(worker1.address);
      await (arbitration.connect(arb1) as any).vote(disputeId, true);
      await (arbitration.connect(arb2) as any).vote(disputeId, true);
      await (arbitration.connect(arb3) as any).vote(disputeId, true);
      expect(await (token as any).balanceOf(worker1.address)).to.be.gt(before);
      expect((await arbitration.getDispute(disputeId)).outcome).to.equal(1);
    });

    it("non-arbitrator cannot vote", async function () {
      const { escrow, arbitration, poster, worker1, token, owner, arb1, arb2, arb3 } = await deployAll();
      await (arbitration.connect(owner) as any).addArbitrator(arb1.address);
      await (arbitration.connect(owner) as any).addArbitrator(arb2.address);
      const { taskId } = await createPaidTask(escrow, poster, token, { maxWorkers: 1 });
      await (escrow.connect(worker1) as any).joinTask(taskId);
      await (escrow.connect(worker1) as any).submitProof(taskId, "proof");
      await (escrow.connect(poster) as any).raiseDispute(taskId, worker1.address);
      const disputeId = await arbitration.taskDispute(taskId);
      await expect((arbitration.connect(arb3) as any).vote(disputeId, true))
        .to.be.revertedWithCustomError(arbitration, "NotArbitrator");
    });

    it("arbitrator cannot vote twice", async function () {
      const { escrow, arbitration, poster, worker1, token, owner, arb1 } = await deployAll();
      await (arbitration.connect(owner) as any).addArbitrator(arb1.address);
      const { taskId } = await createPaidTask(escrow, poster, token, { maxWorkers: 1 });
      await (escrow.connect(worker1) as any).joinTask(taskId);
      await (escrow.connect(worker1) as any).submitProof(taskId, "proof");
      await (escrow.connect(poster) as any).raiseDispute(taskId, worker1.address);
      const disputeId = await arbitration.taskDispute(taskId);
      await (arbitration.connect(arb1) as any).vote(disputeId, true);
      await expect((arbitration.connect(arb1) as any).vote(disputeId, false))
        .to.be.revertedWithCustomError(arbitration, "AlreadyVoted");
    });
  });

  describe("Platform Fees", function () {
    it("collects 6 % fee on task creation and owner can withdraw", async function () {
      const { escrow, poster, token, owner } = await deployAll();
      const bounty = parseEther("100"); const maxWorkers = 4;
      const expectedFee = (bounty * BigInt(maxWorkers) * 600n) / 10_000n;
      await createPaidTask(escrow, poster, token, { bountyPerWorker: bounty, maxWorkers });
      const tokenAddr = await token.getAddress();
      expect(await escrow.feesCollected(tokenAddr)).to.equal(expectedFee);
      const ownerBefore = await (token as any).balanceOf(owner.address);
      await (escrow.connect(owner) as any).withdrawFees(tokenAddr);
      expect(await (token as any).balanceOf(owner.address) - ownerBefore).to.equal(expectedFee);
      expect(await escrow.feesCollected(tokenAddr)).to.equal(0n);
    });

    it("non-owner cannot withdraw fees", async function () {
      const { escrow, poster, token } = await deployAll();
      await createPaidTask(escrow, poster, token);
      await expect((escrow.connect(poster) as any).withdrawFees(await token.getAddress()))
        .to.be.revertedWithCustomError(escrow, "NotOwner");
    });
  });
});