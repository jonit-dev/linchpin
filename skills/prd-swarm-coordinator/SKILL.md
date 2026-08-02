---
name: prd-swarm-coordinator
description: Execute a batch of PRDs through isolated worktrees to merged pull requests. Use when two or more implementation-ready PRDs in one repository should run as parallel Codex lanes with independent review, CI, and merge.
license: MIT
---

# PRD Swarm Coordinator

## Overview

Own a batch of PRDs from intake to merged pull requests. One PRD gets one branch, one linked Git worktree, and one GPT-5.6 Luna/max Codex implementation process. Independent PRDs run concurrently in bounded waves. Every lane must close the full PRD, verify itself against real project gates, open a PR, pass a fresh GPT-5.6 Sol/medium review, route findings back to Luna for repair, satisfy CI, merge without bypassing branch protections, and clean up safely.

The controller owns the outcome. Luna and Sol summaries are evidence leads, not proof. Inspect diffs, commands, test output, PR state, CI, merge state, and cleanup directly before declaring a lane complete.

## Runtime Split — Sol Medium Manager, Luna Max Workers

The coordinating manager must run on **GPT-5.6 Sol at `medium` reasoning effort**. Before creating worktrees, confirm the active session is `gpt-5.6-sol` / `medium`. If it is not, do not coordinate from it — start a manager session that is:

```bash
"${CODEX_BIN:-$HOME/.local/bin/codex}" --model gpt-5.6-sol -c 'model_reasoning_effort="medium"'
```

The manager owns orchestration rather than bulk implementation: read and normalize PRDs, map dependencies/overlap, create lanes, write worker prompts, monitor progress, inspect evidence, synthesize the single review, decide merge order, direct conflict resolution, run final gates, merge, and clean up. It must not abandon a PRD merely because a worker stalls, returns partial work, or needs another focused handoff.

Every implementation, repair, test-gap correction, integration, and merge-conflict worker must run through the **Codex CLI** using **GPT-5.6 Luna** at `max` reasoning effort. Never pin a lower effort such as `xhigh`. Use `${CODEX_BIN:-$HOME/.local/bin/codex}` explicitly and require `--version` ≥ 0.146.0; a stale `codex` may still be first on `PATH`. Pin every Luna invocation explicitly:

```bash
"${CODEX_BIN:-$HOME/.local/bin/codex}" exec --model gpt-5.6-luna \
  -c 'model_reasoning_effort="max"' \
  --dangerously-bypass-approvals-and-sandbox \
  -C "<worktree>" \
  -o "<run-dir>/reports/<slug>.md" \
  "$(cat <prompt-file>)"
```

Run long lanes as background processes, tee'd to a log under the run directory; `-o` captures the final message for manager inspection. Record the PID and Codex session ID in the ledger. Never inherit the session's default model or effort, and never route code changes through another runtime. If `gpt-5.6-luna` or `max` is unavailable, fail the execution pre-flight gate rather than silently falling back.

Review runs on the same CLI, one model tier down and sandboxed read-only so the critic role is enforced rather than merely requested:

```bash
"${CODEX_BIN:-$HOME/.local/bin/codex}" exec --model gpt-5.6-sol \
  -c 'model_reasoning_effort="medium"' \
  --sandbox read-only \
  -C "<worktree>" \
  -o "<run-dir>/reports/<slug>-review.md" \
  "$(cat <review-prompt>)"
```

Reviewers inspect the PRD, diff, tests, and verification evidence, run non-mutating checks, and return structured findings. They never edit, commit, push, merge, or fix. The manager turns their findings into an exact repair prompt for a Luna/max process.

The manager remains orchestrator and verifier. Luna performs code edits; Sol reviews surface defects; the manager controls prompts, lane ownership, merge order, repair handoffs, verification, and integration decisions.

This is an execution skill, not a planning-only skill. Loading it does not authorize work by itself; an explicit request to run a named PRD batch authorizes creating branches/worktrees, pushing those branches, opening PRs, and merging approved PRs for that batch. It never authorizes production deployment, credential/security changes, purchases, public announcements, or bypassing repository protections.

## When to Use

Use when:

- the user points to two or more implementation-ready PRDs in one repository;
- each PRD can own a coherent branch and PR;
- the goal is full autonomous execution through review and merge;
- parallel worktrees reduce elapsed time without uncontrolled file conflicts.

Do not use when the user only asks whether parallelization is possible, PRDs are materially ambiguous, all lanes modify the same core files, the repository baseline is unclassifiably red, or merge authorization is absent. Collapse tightly coupled lanes or order them as dependencies instead of manufacturing parallelism.

## Non-Negotiable Invariants

1. **One full PRD per lane.** Never silently implement only Phase 1 or the easiest criteria.
2. **One worktree and branch per PRD.** Codex implementation processes never share a working directory.
3. **Bounded concurrency.** Respect the configured safe concurrent-process capacity; schedule larger batches in waves.
4. **Exactly one fresh-context review per PRD.** A single Sol/medium reviewer surfaces findings; Luna fixes them and the manager verifies closure. Never spawn a second review for that PRD.
5. **Evidence over summaries.** The controller verifies commits, diffs, tests, PR state, CI, and merge state.
6. **No protection bypass.** No admin merge, force push, disabled checks, or skipped hooks.
7. **No production deployment.** Merge is the end state unless deployment was separately authorized.
8. **No destructive cleanup by assumption.** Require a clean worktree, fresh fetch, and ancestry proof.
9. **The upstream default branch is integration authority.** Refresh it before branching and merging.
10. **Escalate material ambiguity.** Make harmless defaults; stop for product, security, migration, or data-contract decisions.

## Controller Run Ledger

Create operational state outside the repository:

`~/.codex/swarm-runs/<repo>-<UTC-run-id>/manifest.md`

Record repository root, remote, detected default branch, baseline SHA/results, and per lane: PRD, slug, branch, worktree, dependencies, conflict risk, status, Codex process/session ID, final commit, verification evidence, PR URL, reviewer verdict, repair rounds, CI, merge SHA, and cleanup result. Use session todos for the active queue. This ledger is execution evidence, not durable memory.

## Phase 1 — Pre-flight Gate

### 1. Confirm repository and GitHub readiness

From the primary worktree:

```bash
git rev-parse --show-toplevel
git status --short --branch
git remote -v
git fetch --prune origin
git remote show origin
git worktree list --porcelain
gh auth status
gh repo view --json nameWithOwner,defaultBranchRef,url
```

Detect the default branch from GitHub/remote metadata; never assume `main`. Run controller Git operations from the primary worktree, not a linked worktree that may later be removed.

Abort or escalate if the primary worktree is dirty in relevant files, fetch/auth/push is unavailable, no upstream default resolves, a branch/worktree collides, or repository instructions forbid the workflow.

### 2. Read instructions and every PRD

Inspect `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, package manifests, CI workflows, and test/build scripts. Read each PRD fully once. Extract:

- every acceptance criterion and named self-verification requirement;
- files/surfaces, migrations, generated artifacts, docs/status updates, and compatibility constraints;
- dependencies on other PRDs and likely file overlap.

Do not delegate “read this PRD and figure it out.” Give implementers a normalized full acceptance checklist plus the source PRD path.

### 3. Build dependency and collision maps

Classify pairs:

- **Independent:** same wave.
- **Partial overlap:** run in parallel by default. Give each lane clear ownership, record the overlap, choose merge order, and make the controller responsible for integrating both intents when the later branch is updated.
- **Hard dependency:** downstream starts after upstream merges, or must update and fully re-verify.
- **Full-blown conflict:** the PRDs require mutually exclusive behavior, incompatible data contracts, or effectively rewrite the same implementation surface. Collapse, serialize, or escalate before implementation.

Partial file overlap is not a reason to stop or collapse a PRD. Parallelize unless the overlap makes the product requirements mutually incompatible or leaves no meaningful ownership boundary. Prefer artifact ownership over flat task counts, and document the expected integration work for the controller.

### 4. Establish a green baseline

On the freshly fetched default branch, run repository-prescribed checks. Use the strongest practical set among install/lockfile validation, lint, typecheck, unit/integration tests, build, secret/security scan, and smoke/E2E checks. Capture exact commands and output. Reproduce and classify pre-existing failures before starting.

Before creating worktrees, smoke-test the exact worker runtime rather than trusting local defaults or login status:

```bash
"${CODEX_BIN:-$HOME/.local/bin/codex}" exec --ephemeral --model gpt-5.6-luna \
  -c 'model_reasoning_effort="max"' \
  --dangerously-bypass-approvals-and-sandbox \
  'Reply exactly LUNA_MAX_OK and do not use tools.'
```

The run must complete successfully and identify the requested model/effort in Codex output or session metadata. Do not proceed on an auth error, unsupported model/effort, or silent fallback.

**Pre-flight PASS:** clean primary worktree, successful fetch/auth, verified GPT-5.6 Luna/max Codex smoke test, resolved default, parsed PRDs, dependency map, collision-safe first wave, and green or explicitly classified baseline.

## Phase 2 — Create Isolated Lanes

Use deterministic names:

- branch: `swarm/<run-id>/<prd-slug>`;
- worktree: sibling directory or `~/.codex/worktrees/<repo>/<run-id>/<prd-slug>`.

Create each ready lane from the exact fetched upstream SHA:

```bash
git worktree add -b "swarm/<run-id>/<slug>" "<worktree>" "origin/<default>"
git -C "<worktree>" status --short --branch
git -C "<worktree>" rev-parse HEAD
```

Verify branch and baseline SHA. Never reuse a dirty or stale worktree.

## Phase 3 — Parallel Codex Implementation Waves

Write one complete prompt file per ready lane under the run ledger directory, then launch the Luna/max `codex exec` invocation from the Runtime Split section once per lane, concurrently, each with `-C "<worktree>"`:

```bash
nohup "${CODEX_BIN:-$HOME/.local/bin/codex}" exec --model gpt-5.6-luna \
  -c 'model_reasoning_effort="max"' \
  --dangerously-bypass-approvals-and-sandbox \
  -C "<worktree>" \
  -o "<run-dir>/reports/<slug>.md" \
  "$(cat <run-dir>/prompts/<slug>.md)" \
  > "<run-dir>/logs/<slug>.log" 2>&1 &
echo "$!" >> "<run-dir>/pids"
```

Record each PID and Codex session ID in the ledger. Bound concurrency to safe capacity and schedule larger batches in waves. Poll the logs and PIDs; when a wave completes, verify its actual repository state before launching newly unblocked lanes.

Each Codex implementer brief includes:

- absolute repository/worktree path, branch, and immutable baseline SHA;
- PRD path and normalized complete acceptance checklist;
- repository instructions and architecture context;
- file ownership/collision boundaries;
- environment setup and verification commands;
- inspect-existing-patterns-first and TDD/regression-test requirements;
- authentic UI/CLI/API/runtime proof when the PRD names those surfaces;
- prohibitions on deploy, merge, force push, secrets, unrelated refactors, and editing other worktrees;
- required commit SHA, changed files, commands/results, criterion evidence, risks, and gaps.

### Implementer completion contract

The agent must:

1. implement the complete PRD;
2. add or correct tests for happy paths, edge cases, regressions, and meaningful failures;
3. run targeted tests while iterating;
4. run repository lint/typecheck/tests/build and required smoke/E2E gates;
5. self-review the diff for accidental files, debug code, secrets, weak assertions, and scope creep;
6. map every acceptance criterion to evidence;
7. commit all verified work on the lane branch;
8. return `DONE`, `BLOCKED`, or `PARTIAL` honestly.

`PARTIAL` is not completion. Launch a focused GPT-5.6 Luna/max Codex follow-up in the same worktree with the exact gaps and evidence.

## Phase 4 — Controller Verification and PR Creation

Inspect every returned lane directly:

```bash
git -C "<worktree>" status --short --branch
git -C "<worktree>" log -1 --oneline --decorate
git -C "<worktree>" diff --check "origin/<default>...HEAD"
git -C "<worktree>" diff --stat "origin/<default>...HEAD"
git -C "<worktree>" diff "origin/<default>...HEAD"
```

Re-run required targeted and repository-level gates. For UI/runtime behavior, run the actual harness and capture browser/screenshot/video evidence where practical. Functional claims need prod-like proof appropriate to the project.

If gaps appear, launch a GPT-5.6 Luna/max Codex repair run in the same worktree with exact failures, then re-verify. Only after passing:

```bash
git -C "<worktree>" push -u origin "<branch>"
gh pr create --repo "<owner/repo>" --head "<branch>" --base "<default>" \
  --title "<PRD title>" --body-file "<prepared body>"
```

The PR body includes PRD path/link, summary, acceptance checklist, exact test commands, manual evidence, migration/rollback notes, and known limitations.

## Phase 5 — Single-Pass Sol-Medium Independent Review

After PR creation, run exactly one fresh **Sol/medium `codex exec --sandbox read-only`** review for the PRD, using the invocation from the Runtime Split section. It must be a new session with its own prompt, never the one that implemented the lane. Provide repository/worktree, PR URL/number, base/head SHAs, original PRD, full criteria, conventions, and output contract.

Record `review_used: true` in the run ledger as soon as it is launched. This is a hard cardinality limit: never launch a second review for that PRD, even after Luna repairs the branch.

The Sol reviewer inspects the actual diff/tests and independently checks:

1. spec and acceptance compliance;
2. correctness, edge cases, and integration/regression risk;
3. test quality, missing negatives, and false-positive tests;
4. security, privacy, data integrity, and migration safety;
5. maintainability and conventions;
6. accidental scope, generated/debug artifacts;
7. docs, observability, and operational requirements.

Verdict must be `APPROVED` or `REQUEST_CHANGES`. Findings require severity, file/line evidence, reproduction/command, and concrete fix.

For `REQUEST_CHANGES`, normalize the review into a Luna repair brief — severity, exact file/line evidence, reproduction command, expected behavior, required tests — and launch one Luna/max repair process in the same lane, requiring tests and a commit before pushing. The manager verifies every finding against the repaired diff, reruns the required targeted and full gates, and records each finding as `closed` or `blocked` with evidence. If repair remains incomplete, give Luna one focused continuation from the same consolidated findings. Sol surfaces findings once; Luna fixes them; the manager owns closure. Escalate only when a critical finding cannot be closed safely.

## Phase 6 — Integration and Merge Queue

Parallel implementation does not mean blind parallel merging. Merge one PR at a time in dependency/risk order.

Before each merge:

1. fetch and read current upstream default SHA;
2. confirm PR open, not draft, correct base;
3. confirm exactly one Sol/medium review was completed for the PRD and all findings are either approved or manager-verified closed on the current head;
4. confirm required GitHub checks succeeded, not merely queued;
5. update the branch with latest default using project strategy;
6. have the **controller/manager resolve merge conflicts directly** in the lane worktree, preserving the accepted intent of both the already-merged PRD and the current PRD;
7. add or adjust integration/regression tests when the resolution combines overlapping behavior;
8. rerun targeted and full required gates;
9. inspect the resolved diff against both PRDs and push the updated head;
10. require CI again whenever conflict resolution or the base update changes the head SHA, but do not launch another review process. The manager verifies final-head integration and closes the gate.

Merge conflicts are normal integration work and belong to the manager, not a reason to stop a partially overlapping PRD. The manager must inspect the conflicting intents, write the integration instructions, and run a dedicated GPT-5.6 Luna/max Codex conflict-resolution process in the affected worktree. The manager then inspects the resolved diff, supplies missing test cases, re-runs verification, and makes the final integration call. Escalate only for a full-blown semantic conflict: mutually exclusive requirements, incompatible contracts/migrations, or a resolution that requires choosing which PRD to violate.

Prefer a normal merge commit because it preserves ancestry and enables deterministic cleanup. Respect repository-required strategy, but never claim squash/rebase ancestry is equivalent.

```bash
timeout 30m gh pr checks "<pr-number>" --watch || {
  echo "CI did not reach success within 30 minutes; do not merge"
  exit 124
}
gh pr merge "<pr-number>" --merge --delete-branch
```

Never use `--admin`. If merge commits are forbidden, use the allowed strategy after all gates. If it prevents proving the original head is an ancestor of upstream, merge may proceed but destructive cleanup must stop and be reported.

After merge:

```bash
git fetch --prune origin
gh pr view "<pr-number>" --json state,mergedAt,mergeCommit,url
git rev-parse "origin/<default>"
```

Verify merged state and upstream change before the next PR. Update the next queued lane on the newly advanced default and repeat verification.

## Phase 7 — Safe Cleanup

Only clean after a successful fresh fetch from the primary worktree:

```bash
git -C "<worktree>" status --porcelain
git fetch --prune origin
git merge-base --is-ancestor "<branch>" "origin/<default>"
git worktree list --porcelain
```

Also ensure the candidate is not locked, used by another process, primary/default, or a parent containing another registered worktree. If all checks pass:

```bash
git worktree remove "<worktree>"
git worktree prune
git branch -d "<branch>"
```

Never use `git worktree remove --force` or `git branch -D` normally. Never delete an unregistered directory as a worktree. Process nested candidates deepest first. If ancestry cannot be proven, retain the branch/worktree and record why.

Final rescan:

```bash
git worktree list
git branch --list 'swarm/*'
git status --short --branch
git fetch --prune origin
```

## Simple No-Hang, No-Abandonment Rules

Keep the control loop small. Timeouts prevent silent waiting; they do **not** authorize dropping a PRD.

1. **A PRD stays owned.** A worker returning `PARTIAL`, timing out, crashing, or stalling leaves its worktree and ledger state intact. The Sol/medium manager inspects what exists and gives Luna/max the smallest useful continuation. A lane becomes `BLOCKED` only for a concrete external blocker or a material decision the manager cannot safely make—not because an arbitrary retry count was reached.
2. **Require progress between retries.** Never repeat the identical prompt or failing command. Each continuation must add evidence: current diff/commit, exact failure, narrowed remaining criteria, and the next verification target. If repeated attempts make no progress, the manager changes strategy, reduces scope to the next stable slice without reducing final PRD scope, or uses a fresh Luna worker in the same worktree.
3. **Bound waiting, not completion.** A silent Codex process gets inspected after 15 minutes and restarted with preserved state if genuinely stalled. CI waits at most 30 minutes per observation; pending external checks are parked while other lanes continue, then revisited. No lane holds the whole swarm hostage.
4. **One review only.** Sol/medium reviews each PRD once. Luna/max fixes the findings; the manager verifies closure. Never create a review ping-pong loop.
5. **Manager owns integration.** Partial overlap and ordinary Git conflicts do not stop a PRD. The manager directs Luna conflict resolution, verifies both PRD intents and tests, and serializes merges when main keeps moving.
6. **Finish honestly.** The run ends with every PRD either merged or tied to a specific real blocker with preserved work, exact remaining criteria, and a resumable next command. `PARTIAL`, timeout, flaky CI, or worker exhaustion alone are never acceptable terminal outcomes.

## Gates and Failure Behavior

### Revision gate

Failed tests, incomplete criteria, Sol review findings, attributable CI failure, or conflict repairs return the lane to Luna implementation/repair. The manager preserves the worktree, narrows the next handoff, and repeats controller verification on the new head, but never launches a second Sol review for that PRD.

### Escalation gate

Stop only the affected lane and request a concrete decision when:

- PRD ambiguity changes behavior or contracts;
- destructive migration or security/permission changes lack authorization;
- broken baseline invalidates verification;
- branches encode irreconcilable product choices;
- required external access, secrets, or paid services are missing;
- branch protection requires unavailable human approval.

Continue unrelated safe lanes where possible.

### Abort gate

Abort only for suspected secret exposure, corrupted repository/worktree state, an unsafe force-push or destructive requirement, or inability to establish what code was actually tested. Repeated worker failure or lack of progress is not itself an abort condition: preserve the lane, change the Luna handoff strategy, and continue from the existing worktree. Every abort must preserve evidence and a resumable state unless safety requires isolation.

## Final Verification Checklist

The run completes only when:

- [ ] Every PRD is `MERGED`, or has a concrete external/material `BLOCKED`/safety `ABORTED` reason with preserved work, exact remaining criteria, and a resumable next command; none are silently partial or dropped.
- [ ] Every merged PR maps all criteria to evidence.
- [ ] Controller verification passed before PR creation and after final base update.
- [ ] Exactly one fresh Sol/medium review ran for each merged PRD; no PRD received a second review.
- [ ] Any Sol findings were repaired by Luna and manager-verified closed on the final head SHA.
- [ ] Required CI passed without bypasses.
- [ ] Upstream default contains every merged lane as expected.
- [ ] Safe worktrees/branches were removed; retained ones have explicit reasons.
- [ ] Primary worktree is clean.
- [ ] Final report lists PR URLs, merge SHAs, commands/results, blockers, and cleanup.

## Common Pitfalls

Failure modes not already covered by the invariants and checklist:

1. Launching all PRDs before dependency/collision analysis.
2. Giving Codex only filenames instead of normalized full-scope criteria.
3. Trusting “tests pass” instead of controller reruns, or treating CI as sufficient when the PRD names runtime/UI/CLI proof.
4. Opening PRs before checking diffs for secrets and scope creep.
5. Merging green PRs against stale main without updating and re-verifying.
6. Squash-merging and then force-cleaning without ancestry proof.
7. Deploying merely because merge succeeded.
8. Dumping raw worker or review reports instead of controller synthesis.
9. Letting a process inherit session defaults. Implementation pins Luna/`max`; review pins Sol/`medium` with `--sandbox read-only`.
10. Letting a reviewer edit code, or letting implementation self-review stand in for the fresh review.

## Invocation Contract

A strong invocation gives repository path/URL, PRD directory or paths, optional concurrency and merge order, required verification/environment commands, and explicit merge authorization.

Example:

> Use prd-swarm-coordinator on `/repo`. Execute PRDs `docs/prds/a.md`, `b.md`, and `c.md` with max 3 lanes. Open PRs, independently review and repair them, merge approved PRs to the detected default branch, and safely clean up. Do not deploy.

If repository and PRD batch are obvious from active context, act without redundant questions. Otherwise retrieve them from local/session context before asking the user to repeat information.
