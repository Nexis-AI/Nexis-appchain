# Nexis Agents Base L3 — RetroPGF Submission Template

## Project Summary
- **Project Name:** Nexis Agents Base L3
- **Category:** AI + Infrastructure for the Superchain
- **Team:** Nexis Network core protocol contributors (multi-sig listed in `.agents-devnet/agents-deployment.json`)
- **Description:** Production-ready OP Stack L3 specialized for AI agent coordination with staking, delegation, proof-of-inference verification, and on-chain treasury management. Ships as a reproducible devnet, deploy scripts, and audited-ready contracts.

## Problem & Solution
- AI agents lack credibly neutral infrastructure for reputation-weighted coordination.
- Existing registries do not couple staking, inference proofs, and slashing pipelines.
- Nexis Agents delivers upgradeable agents, task marketplace, treasury redistribution, and streaming subscriptions with governance hooks.

## Impact Metrics
1. `AgentRegistered`, `TaskCreated`, `InferenceRecorded`, and `InferenceAttested` event counts surfaced via LangGraph indexers.
2. Total bonded stake (`aggregatedStats.totalStakedPerAsset`) and slashed/penalty volume routed through `Treasury.sol`.
3. Number of governance reward payouts (`RewardPaid` events) and multi-dimensional reputation updates.
4. Devnet adoption tracked through Docker pulls and clones of `scripts/agents-devnet`.
5. Integrations deploying with `deployAgents.ts` (addresses recorded in `.agents-devnet/agents-deployment.json`).

## Proof of Work
- Foundry + Hardhat suites covering registration, staking, delegation, proof-of-inference workflows, treasury flows, and governance upgrades (`packages/contracts-bedrock/test`).
- Docker-based devnet auto-deploying the full contract stack (`pnpm dev`).
- Treasury distribution formulas and dispute resolution flows implemented in `Treasury.sol` and `Tasks.sol`.
- Documentation in `README.md` describing lifecycle, governance, LangGraph integration, and funding milestones.

## Use of Funding
- Security audits for Agents, Tasks, Treasury, and Subscriptions contracts.
- Incentivized verifier operators and LangGraph indexing bounties.
- Grants for ecosystem teams to publish open-source agents leveraging delegation and subscription primitives.
- Operational runway for maintaining devnet infrastructure and governance processes.

## Requested Amount
- **RetroPGF Points:** _TBD by reviewers_
- **Justification:** Completes the AI agent coordination layer for the Optimism Superchain, aligning with impact=profit by rewarding verifiable inference contributions.

## Contact
- **Point of Contact:** hello@nexis.network
- **Links:**
  - Repository: `https://github.com/nexis-network/nexis-base-appchain`
  - Deployment manifest: `.agents-devnet/agents-deployment.json`
  - LangGraph reference pipelines: (add during submission)
