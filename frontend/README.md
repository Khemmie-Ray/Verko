# Verko

> **Real work. Verified humans. Instant pay.**  
> A verified micro-task marketplace on Celo mainnet where real people complete small tasks and get paid instantly in G$ — face-verified through GoodDollar, zero bots, zero bank accounts required.

**Track:** MiniApps — mobile-first Mini App on MiniPay

---

## Short Description

Verko is a MiniPay Mini App where face-verified humans complete micro-tasks (surveys, photos, translations, field checks) and get paid instantly in G$. Smart contract escrow + GoodDollar identity = the first truly verified, instant-pay task marketplace for emerging markets.

---

## Assets

| Asset | Link |
|---|---|
| Logo & screenshots | _[add link]_ |
| Demo video (4 min) | _[add link]_ |
| Presentation deck (≤10 slides) | _[add link]_ |
| Live app (MiniPay) | _[add link]_ |

---

## Milestones

### Month 1 — Proof of Ship window

- [ ] Deploy `TaskEscrow.sol` to Celo mainnet — _[PR link]_
- [ ] MiniPay Mini App: worker signup + GoodDollar face verification flow — _[PR link]_
- [ ] Task browse, accept, and proof submission UI — _[PR link]_
- [ ] Escrow release on task approval — end-to-end flow tested — _[PR link]_
- [ ] 3–5 real tasks posted with real G$ bounties — _[tx links]_

### Month 2

- [ ] `WorkerReputation.sol` + Verko Score soulbound NFT — _[PR link]_
- [ ] Verko Studio: task poster web dashboard — _[PR link]_
- [ ] Dispute and rejection flow — _[PR link]_
- [ ] 50+ active verified Verkers onboarded

### Month 3

- [ ] `ArbitrationPool.sol` — on-chain community dispute voting — _[PR link]_
- [ ] G$ supertoken streaming for recurring tasks — _[PR link]_
- [ ] Target: 500 tasks completed, 200 verified workers

---

## Problem

Two groups are failing each other across emerging markets.

**Workers** — millions of people with time, skills, and smartphones but no access to legitimate micro-work. Platforms like Microworkers, Appen, and Remotasks either underpay, delay withdrawals for weeks, or require bank accounts that workers don't have. Bots and fake accounts flood these platforms, driving down task quality and worker earnings.

**Task Posters** — NGOs, researchers, startups, and local businesses need small human tasks done at scale: surveys, data labeling, community outreach, content translation, photo verification. They can't trust the results because they can't verify who did the work.

**The core failure:** no verified human identity + no instant local payment rail.

### Competitor Comparison

| Problem | Microworkers / Appen / Remotasks | Verko |
|---|---|---|
| Bot accounts | Rampant, no identity check | Face-verified unique humans via GoodDollar |
| Payment speed | Days to weeks | Instant on-chain, escrow release on approval |
| Payment method | Bank transfer only | MiniPay wallet, G$ native |
| Worker verification | None | On-chain reputation NFT (Verko Score) |
| Dispute resolution | Opaque, poster almost always wins | On-chain community arbitration, majority vote |
| Geographic reach | Limited payout countries | Any MiniPay user globally |

---

## Solution

Verko is a MiniPay Mini App where verified humans complete small tasks and get paid instantly in G$.

- **GoodDollar face verification** at signup — proves each worker is a unique real person, provides Sybil resistance, one person = one account
- **Smart contract escrow** on Celo mainnet — task bounties are locked at creation and released automatically on approval, no human intermediary
- **On-chain reputation (Verko Score)** — every completed task builds a soulbound credential; higher tiers unlock higher-paying work
- **On-chain arbitration** — disputed tasks go to a randomly selected panel of high-reputation workers who vote on-chain, majority rules

### For Workers (Verkers)

1. Sign up via MiniPay → complete GoodDollar face verification (one-time)
2. Browse tasks filtered by category, time required, and G$ reward
3. Accept a task → complete it → submit proof (photo, form, audio clip, screenshot)
4. Task poster reviews and approves → G$ bounty releases instantly to wallet
5. Verko Score NFT updates automatically

### For Task Posters (Builders)

1. Sign up → optional KYB for NGOs/businesses
2. Create a task: title, description, proof requirements, deadline, worker count, G$ bounty per worker
3. Fund task escrow in G$ (or cUSD, auto-converted)
4. Review submissions → approve or reject with a reason
5. Approved workers paid automatically; disputes go to ArbitrationPool

### Task Categories — Launch Focus

| Category | Examples |
|---|---|
| 📋 Surveys & Research | Community opinion data, cost of living, product feedback |
| 📸 Photo Verification | Confirm a shop exists, road damage, billboard is up |
| 🌐 Content & Translation | Translate short text, transcribe audio, tag images in local languages |
| 📣 Community Outreach | Distribute a message in a group, confirm delivery with screenshot |
| 🎙️ AI Voice & Data | Record phrases, describe images, rate sentence pairs for AI training |
| 🔍 Mystery Shopping | Call a business, attempt a purchase, report the experience |

---

## Architecture

### Smart Contracts (Celo Mainnet)

**`TaskEscrow.sol`**
- Task posters deposit `G$ bounty × worker count` into escrow on task creation
- Funds locked until poster approves or deadline passes
- On approval: contract releases G$ directly to worker wallet
- On rejection with reason: funds return to poster
- Disputed tasks routed to `ArbitrationPool.sol`

**`WorkerReputation.sol`**
- Tracks per-worker on-chain history: tasks completed, approval rate, categories, total G$ earned
- Issues a dynamic soulbound NFT (Verko Score) that upgrades tier on milestone completions
- Tiers: Starter → Trusted → Elite
- Higher tiers unlock higher-paying tasks and priority review queues

**`ArbitrationPool.sol`**
- Randomly selects high-reputation workers as arbitrators per disputed task
- Arbitrators review submission + rejection reason, vote on-chain
- Majority rules; arbitrators earn a small G$ fee per case
- Keeps dispute resolution decentralized and tamper-resistant

### Frontend

- **MiniPay Mini App** — React/Next.js, mobile-first
- **Verko Studio** (task poster dashboard) — web-based, React

### GoodDollar Integration

| Integration | Purpose |
|---|---|
| Face verification SDK | Sybil resistance at worker signup — one human = one account |
| G$ as native payment currency | All bounties, fees, and arbitrator rewards denominated in G$ |
| G$ supertoken streaming | Optional for recurring tasks — weekly surveys stream G$ over time rather than lump sum |

### Libraries & Frameworks

| Layer | Stack |
|---|---|
| Smart contracts | Solidity, Hardhat, OpenZeppelin, Celo SDK |
| Frontend | React, Next.js, Tailwind CSS, wagmi, viem |
| Blockchain | Celo mainnet, MiniPay Mini App SDK |
| Identity | GoodDollar Face Verification SDK |
| Payments | G$ (GoodDollar token), cUSD fallback via Mento |

### Implementation Notes

- GoodDollar face verification SDK is integrated at the wallet connection step in MiniPay — workers cannot browse tasks until verification is complete
- Escrow release is fully automated via smart contract event listeners; no manual backend trigger required
- The Verko Score NFT is non-transferable (soulbound, ERC-5192); metadata is stored on-chain and updates dynamically with each completed task
- Arbitration panel selection uses on-chain randomness seeded from block hash to prevent gaming

---

## Contract Addresses

| Contract | Network | Address |
|---|---|---|
| TaskEscrow | Celo Mainnet | _[add after deploy]_ |
| WorkerReputation | Celo Mainnet | _[add after deploy]_ |
| ArbitrationPool | Celo Mainnet | _[add after deploy]_ |

---

## Team

| Name | Role | GitHub | Farcaster |
|---|---|---|---|
| _[add name]_ | _[add role]_ | _[add]_ | _[add]_ |

---

*Built on Celo · Powered by GoodDollar · MiniApps track*