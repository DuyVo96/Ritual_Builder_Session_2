# Privacy-Preserving AI Bounty Judge — Homework Submission

Full write-up (lifecycle, test plan, architecture note, reflection question) is in [`SUBMISSION.md`](SUBMISSION.md).

## Contracts

- `hardhat/contracts/AIJudge.sol` — Required Track: commit-reveal bounty judging.
- `hardhat/contracts/AIJudgeEncrypted.sol` — Advanced Track: Ritual TEE-encrypted submissions, no reveal phase.
- `hardhat/contracts/AIJudge.t.sol`, `hardhat/contracts/AIJudgeEncrypted.t.sol` — Foundry test suites (26 tests total).

## Running the tests

```bash
cd hardhat
pnpm install   # or npm install
npx hardhat test solidity
```
