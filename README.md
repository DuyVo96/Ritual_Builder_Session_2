# Privacy-Preserving AI Bounty Judge — Homework Submission

## Repo layout

- `hardhat/contracts/AIJudge.sol` — Required Track: commit-reveal bounty judging.
- `hardhat/contracts/AIJudgeEncrypted.sol` — Advanced Track: Ritual TEE-encrypted submissions, no reveal phase.
- `hardhat/contracts/AIJudge.t.sol`, `hardhat/contracts/AIJudgeEncrypted.t.sol` — Foundry test suites (26 tests total).

## Running the tests

```bash
cd hardhat
pnpm install   # or npm install
npx hardhat test solidity
```

---

## Part 1: Bounty Lifecycle

### Overview

This project extends the AI Bounty Judge workshop app so that submitted answers remain hidden during the submission phase. It uses a **commit-reveal scheme** on any EVM chain to prevent participants from reading and copying each other's answers before judging completes.

### Bounty Lifecycle

```
OPEN ──────────────────── submission deadline ──► REVEALING ── reveal deadline ──► READY ──► JUDGED ──► FINALIZED
  │                                                   │
  └── submitCommitment()                              └── revealAnswer()
      (only a hash, answer stays hidden)                  (answer + salt, contract verifies hash)
```

**Phase 1 — Open** (before submission deadline)

Participants call `submitCommitment(bountyId, commitment)` where:

```
commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
```

The plaintext answer never touches the chain. Each participant may submit only one commitment. The frontend generates a random 32-byte salt, computes the hash in-browser, and saves the answer + salt to localStorage for use in the reveal phase.

**Phase 2 — Revealing** (after submission deadline, before reveal deadline)

Participants call `revealAnswer(bountyId, answer, salt)`. The contract recomputes the commitment hash and requires it to match the stored value. Only revealed answers are eligible for judging. Participants who do not reveal forfeit their chance to win.

**Phase 3 — Ready for judging** (after reveal deadline)

The bounty owner calls `judgeAll(bountyId, llmInput)`. The contract sends all revealed answers in a single batch request to the Ritual AI precompile at `0x0802`. No individual per-answer LLM calls are made.

**Phase 4 — Judged**

Ritual AI returns a structured review. The contract stores the raw AI output on-chain. The owner reads the recommended winner index and calls `finalizeWinner(bountyId, winnerIndex)`.

**Phase 5 — Finalized**

The contract transfers the bounty reward to the winner. The state is terminal — no further changes are possible.

### Key Security Properties

- A participant cannot read another's answer during the submission phase (only hashes are stored).
- Including `msg.sender` and `bountyId` in the hash prevents commitment replay attacks (copying someone else's hash and claiming the same answer).
- A zero-value commitment (`bytes32(0)`) is rejected to prevent griefing.
- A participant cannot reveal twice (prevents answer-swapping after seeing other reveals).
- Unrevealed commitments are silently excluded from judging — the contract never punishes non-revelation, it simply ignores those slots.

---

## Part 2: Architecture Note — Commit-Reveal vs Ritual-Native Encrypted Submissions

### Commit-Reveal (Required Track)

**How it works:** Participants hash their answer before submission. The hash is stored on-chain. After the submission deadline, everyone reveals plaintext answers. The contract verifies each reveal against the stored hash.

**What is public and when:**

| Data | During submission | During reveal | After judging |
|---|---|---|---|
| Commitment hash | Public | Public | Public |
| Plaintext answer | Hidden | **Public** | Public |
| AI review | Hidden | Hidden | Public |

**Limitation:** Answers become public during the reveal phase, *before* judging runs. A participant who reveals early could in theory observe other reveals and try to influence the judging outcome — though they cannot change their own already-committed answer. More importantly, a malicious observer can read all revealed answers while the reveal window is still open.

**Strength:** Works on any EVM chain with no off-chain infrastructure. Verifiable entirely on-chain. No trusted third party required.

---

### Ritual-Native Encrypted Submissions (Advanced Track)

**Implemented in `AIJudgeEncrypted.sol` (this repo) plus a client-side encryption/UI layer in the full project (`ritualEncryption.ts`, `EncryptedSubmission.tsx` — not included in this trimmed submission repo); the TEE-side decryption and LLM interpolation behavior is simulated/assumed, not real Ritual infra — this repo has no access to a live Ritual TEE executor.** See "What's real vs simulated" below for the exact split.

**How it works:** Each participant encrypts their answer client-side to a public key controlled by a Ritual TEE executor, using a NaCl sealed box (Curve25519 + XSalsa20-Poly1305, via `tweetnacl`). Only the ciphertext is stored on-chain. No one — not even the contract — can read the plaintext until the TEE decrypts it inside a trusted execution environment during the `judgeAll` call. There is no reveal phase at all: ciphertext sits on-chain from submission until judging.

**What is public and when:**

| Data | During submission | During judgeAll | After judging |
|---|---|---|---|
| Ciphertext + answer commitment | Public (unreadable) | Decrypted inside TEE only | Public |
| Plaintext answer | Hidden | Hidden from chain | Hidden (never published on-chain) |
| Ephemeral encryption secret key | Never persisted (browser-only, used once) | — | — |
| AI review | Hidden | Computed in TEE | Public |

**Flow (as implemented):**

1. The bounty owner supplies a TEE executor public key at bounty creation (`createBounty(title, rubric, deadline, teeExecutorPubKey)`). There is no on-chain discovery/attestation API for a real Ritual TEE pubkey available in this workshop environment, so the frontend defaults this field to a checked-in dev-fixture key (generated once via `nacl.box.keyPair()`) — this is a known simplification, not a claim about how production Ritual key discovery works.
2. Each participant calls `encryptAnswer(answer, teeExecutorPubKey)`, which generates a fresh ephemeral X25519 keypair, seals the answer with `nacl.box`, and submits `submitCiphertext(bountyId, ciphertext, answerCommitment)`. The ephemeral secret key is discarded immediately — nothing needs it again.
3. After the submission deadline, the owner calls `judgeAll()`, which forwards every ciphertext into the `encryptedSecrets` field of the Ritual LLM precompile request (`buildJudgeAllEncryptedLlmInput`), alongside a fresh ephemeral `userPublicKey`.
4. Assumption (unverified locally): the real Ritual TEE node decrypts `encryptedSecrets` inside the enclave, interpolates the plaintext into the LLM's context, judges, and returns only the result (winner index + scores) to the contract.

**Key difference from commit-reveal:** Plaintext answers are *never* visible to any chain observer — not during submission (there's no separate reveal step), and not at judging time. Only the TEE executor sees them, and only transiently, inside the enclave.

**Trade-offs:**

| Dimension | Commit-Reveal | Ritual-Native |
|---|---|---|
| Answer privacy before judging | Hidden | Hidden |
| Answer privacy during judging | **Revealed on-chain** | Stays inside TEE |
| Infrastructure dependency | None (any EVM) | Ritual network required |
| On-chain verifiability | Full (hash check) | Partial (ciphertext + result only) |
| Complexity | Low | High |

**When to choose Ritual-native:** When the rubric or answer content is commercially sensitive and must not leak even after the submission window closes — for example, in a research or IP-sensitive bounty where knowing a competitor's approach (even after losing) is harmful.

**What's real vs simulated:**

- **Real and tested:** `AIJudgeEncrypted.sol`'s full lifecycle (create → submit ciphertext → judge-guard → finalize), enforced entirely with Foundry tests (`AIJudgeEncrypted.t.sol`) — including the load-bearing property that `getSubmission` returns `(address, bytes ciphertext, bytes32 answerCommitment)` with no plaintext field at all, a compile-time guarantee rather than just a runtime one.
- **Simulated/assumed, not verifiable locally:** whether the real Ritual LLM precompile actually decrypts `encryptedSecrets` using `userPublicKey` the way this design assumes; whether the underlying ABI layout for the LLM precompile request is correct at all (already flagged as unconfirmed for the Required Track's plaintext version too); end-to-end "ciphertext in, correct winner out" — this repo has no local Ritual TEE executor to run against, matching the pre-existing situation for the Required Track's `judgeAll` (already only guard-tested, not precompile-output-tested).
- **Known simplification:** the TEE executor public key is owner-supplied at bounty creation rather than discovered from an on-chain Ritual registry, because no such discovery mechanism exists in this repo/environment.

---

## Part 3: Reflection Question

*What should be public, what should stay hidden, and what should be decided by AI versus by a human in a bounty system?*

In a fair bounty system, the bounty's **title, rubric, reward, and deadlines** must be fully public so participants can make an informed decision to compete. The **commitment hashes** (or, in the Advanced Track, **ciphertext and answer commitments**) during the submission phase can be public because they reveal nothing about the underlying answers. What must stay hidden until after judging is complete are the **plaintext answers themselves** — exposing them early breaks the competition's integrity because later participants gain an unfair informational advantage. In the commit-reveal design implemented here, answers become visible during the reveal phase, which is an acceptable trade-off for a fully on-chain solution; the Ritual-native approach, implemented in `AIJudgeEncrypted.sol`, keeps answers hidden even at that stage by confining decryption to a TEE — though, as noted above, the TEE's actual decryption behavior is simulated/assumed here, not verified against live Ritual infrastructure.

**AI is well-suited** to tasks that require consistent, rubric-based evaluation across many submissions at once — exactly what `judgeAll()` does by sending the entire batch to the LLM in a single request. AI scoring removes subjective bias from the ranking step. However, **the final payout decision must remain with a human** (the bounty owner) for two reasons: first, AI output can be misconfigured, hallucinated, or gamed with adversarial prompts, so a human review step prevents automated fund loss; second, the owner carries the economic and reputational accountability for the outcome. The `finalizeWinner` function enforces this human-in-the-loop requirement — the contract never auto-pays from AI output. This split — AI ranks, human confirms — is the right default for any on-chain system where funds move based on an off-chain model's judgment.
