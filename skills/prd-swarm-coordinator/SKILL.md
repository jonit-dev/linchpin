---
name: prd-swarm-coordinator
description: Execute one or many conforming PRDs through contract-preserving Codex lanes with bounded parallelism, inherited gates, review, and honest delivery states.
license: MIT
---

# PRD Swarm Coordinator

## Scope and runtime contract

Own one or many PRDs through the same intake, brief, scheduling, worker,
review, repair, and delivery path. A single PRD is a swarm of one; it does not
take a shortcut. The `references/` directory is at the plugin root, beside
`skills/`; from this file resolve it as `../../references/`. Read `references/prd-contract.md` and
`references/intake.md` before intake, and read `references/runtime.md` before
any preflight or delegation. The live contract consumer is
`skills/prd-swarm-coordinator/SKILL.md:13`; the executable contract check is
`scripts/linchpin.sh:313`.

The manager is the current session's Sol/medium role. Workers, repair workers,
integration workers, and conflict workers use the Luna/max role only through
the `codex exec` subprocess shape in `references/runtime.md`. The reviewer is a
fresh Sol/medium `codex exec --sandbox read-only` process. Never use a native
subagent for Luna, never change tier after a failed attempt, and use
`codex exec resume <session-id>` only for a recorded continuation.

This skill does not support generic non-PRD swarm requests. It does not arm the
optional goal loop, because that requires a real Phase 1-6 merge checkpoint and
an explicit user request that this local run does not have.

Use the referenced documents and `scripts/linchpin.sh` subcommands as interfaces:
invoke the specific check you need and inspect its output; do not read the full
helper source into context.

## Intake branch

1. Read the complete input artifact and validate `prd_contract: v1` with
   `scripts/linchpin.sh contract <prd>`. Do not summarize before validation.
2. If the marker or any required structure is missing, return the artifact to
   the migration path in `references/intake.md`: `scripts/linchpin.sh migrate`
   first, then creator upgrade mode for whatever gaps it reports. The original
   file stays untouched, and an existing PRD is never replaced by a newly
   drafted one. Wait for the durable conforming replacement, then re-route.
   There is no in-flight legacy normalization.
3. For a conforming artifact, preserve the Integration Ledger, Negative Controls,
   Acceptance Criteria, and Checkpoint Protocol verbatim. The coordinator does
   not re-derive a shorter checklist.
4. A creator output never auto-starts this skill. Require explicit confirmation
   after creation or upgrade and before preflight.
5. Use `references/intake.md` for intent, complexity-floor refusal, config, and
   capability routing. Repository state cannot override a direct write-PRD
   request.

## Preflight and configuration

Read optional `.linchpin.toml` using the defaults and validation in
`references/intake.md`. Its absence is valid. Record the resolved values in the
run ledger and persist typed natural-language overrides before scheduling.

Run these checks before branches or workers:

- verify the target is a Git repository;
- run `scripts/linchpin.sh preflight` against `$CODEX_HOME/models_cache.json`;
- inspect current status, default branch, remotes, and delivery capability;
- parse every phase `Files (N)` list; a malformed list is an error, never an
  assumption of disjointness;
- verify the review setting was explicitly chosen if it is false.

Only a missing Git repository or missing worker capability is a refusal. A
missing worktree, dirty unstashable tree, missing remote, or missing PR client
is a named degradation unless the user explicitly forced the unavailable mode.

## Contract-preserving worker brief

Generate each brief with the resolved lane metadata:
`scripts/linchpin.sh brief <prd> <lane-id> <lane-mode> <delivery-mode>`.
Resolve these values before invocation from `.linchpin.toml`, the
file-intersection group, and delivery capability. With no config file, the
helper's `brief <prd>` form remains a lane-1/parallel/pr default for direct
callers; production lanes pass all three resolved values. The brief contains,
in this order:

1. source PRD path and lane identity;
2. every parsed file path from every phase;
3. the complete Integration Ledger copied verbatim, including every row's Live
   caller and Negative control;
4. the complete Negative Controls table copied verbatim;
5. the complete Acceptance Criteria and Checkpoint Protocol copied verbatim;
6. the runtime-derived worker/reviewer invocation shapes, lane mode, delivery
   mode, and prohibited actions. The model, effort, and mechanism values come
   only from `references/runtime.md`.

Before launch, compare ledger row ids between source and brief. A missing row,
caller, or control rejects the brief. The worker must not be asked to infer
missing acceptance criteria from a summary.

## Per-group mode selection

Run `scripts/linchpin.sh mode <resolved-execution> [--config-dir <target-repo>] <prd...>` after all lists parse. It
builds the file-intersection graph and emits one group per connected component:

- disjoint groups use parallel worktrees when worktree creation succeeds;
- groups with intersecting file sets run sequentially, one lane at a time;
- explicit sequential mode makes all groups sequential;
- explicit parallel mode fails loudly on intersection or worktree failure;
- auto mode degrades only the affected group and announces the reason;
- `max_lanes` is a real concurrency bound; each group reports `active=` and
  `queued=` lanes when capacity is exceeded;
- one lane uses the same output, gate, review, and delivery fields as any other
  group and has no special branch.

If `git worktree add` fails or the shared tree cannot be safely stashed, run
`scripts/linchpin.sh schedule auto fail [--config-dir <target-repo>] ...`,
announce the sequential fallback before starting the first lane, and preserve
the same brief and gates. The schedule output identifies active and queued
lanes under `max_lanes`. Never abort a normal auto run for unavailable
isolation. For a forced parallel run, fail with the exact capability error so
the user can correct the environment.

Mode is per group. A colliding pair may be sequential while an independent pair
remains parallel. A worker never receives a weaker gate because its group is
sequential.

## Lane lifecycle

For every lane, record the PRD, slug, baseline, branch, worktree or shared-tree
mode, file set, overlap group, dependencies, process id, subprocess session id,
brief hash, verification commands, review state, repair rounds, delivery mode,
and terminal evidence in the external run ledger.

1. Create every parallel lane from the same detected base branch. Never branch a
   lane from another lane.
2. Launch workers using only the Worker row in `references/runtime.md`. Pin the
   required effort and working directory in the subprocess invocation. Do not
   inherit session defaults or route code edits through another runtime.
3. Require a worker commit, exact test output, caller census, revert check, and
   gate evidence before manager verification.
4. Keep a partial lane and its worktree. A timeout or worker summary is not a
   delivery result; inspect the actual diff and resume from the recorded state.

## Inherited lane gates

The PRD's Negative Controls table is an inherited lane gate, not advice. Copy it
into the reviewer packet with the ledger and require one Gate Evidence row for
every control. The evidence format is:

```markdown
## Gate Evidence
| Gate | Result | Observed-red evidence | Exact command/result |
|---|---|---|---|
| gate-id | PASS | RED observed: disabled gate | `command: sh tests/example.sh`; result: RED observed: disabled gate; exit: 1 |
```

The exact command/result cell repeats the command documented in the PRD's
Negative Controls table. `gate` rejects missing, duplicate, or extra gate ids,
generic evidence without that exact command, green-only evidence, and zero
exits.

Run `scripts/linchpin.sh gate <prd> <report>` before delivery. A report with
only green assertions, a missing control, or a missing observed-red line is
`UNVERIFIED` and rejected. Every control must have failed as expected at least
once. This rule is identical in parallel and sequential mode.

The reviewer packet must contain the negative-control table even when all
functional tests are green. The manager records the exact red command and its
non-zero result; a verbal claim is not evidence.

## One review and repair rule

When review is enabled, launch exactly one fresh Sol/medium reviewer per lane
through this shape, with all role values resolved from `references/runtime.md`:

```text
codex exec --model <Reviewer.Model> -c 'model_reasoning_effort="<Reviewer.Effort>"' --sandbox read-only -C <lane> <review>
```

Record `review_used: true` before launch. The reviewer cannot edit. The manager
closes findings after Luna repair; no second reviewer is started after repair.

When a worker or reviewer exposes a failure, treat it first as specification
evidence. Before re-delegating, write a corrected or narrowed handoff naming the
exact file, line, expected behavior, failing command, and newly required test.
The handoff must differ from the failed prompt. Never repeat an unchanged
prompt, and never change the model tier or effort to escape a failed gate.
Use the recorded `codex exec resume <session-id>` only when the corrected
continuation is explicit.

Repair, integration, and conflict work face the same inherited gates. Ordinary
overlap and merge conflicts are manager-directed integration work; preserve the
accepted intent of both PRDs and add a regression test when resolution combines
behavior. A semantic conflict that would require violating a PRD is a named
`BLOCKED` decision, not a silent rewrite.

## Delivery and terminal states

Resolve delivery from `.linchpin.toml`: `pr` by default, `branch` when selected,
and `branch` after an announced missing-remote or missing-client fallback. A
delivery fallback does not remove review, gate evidence, or verification.

Use only these terminal forms:

- `DELIVERED(pr)` or `DELIVERED(branch)` after the full evidence packet passes;
- `BLOCKED <named external reason> <resumable command>` with preserved state;
- `PARTIAL` while implementation or evidence is incomplete.

Never label a lane `MERGED` as its product state. Never call a lane delivered
because a process exited, a summary said done, or a green-only test suite ran.

## Final controller verification

Before handing off, inspect the real branch or shared-tree diff, run the named
repository gates, run `sh scripts/verify.sh`, run `jq` validation, run
`shellcheck` when installed, and perform a local smoke check of contract,
brief, mode, fallback, and gate commands. Run exactly one fresh Sol review only
when the manager executes the real user workflow; this implementation handoff
does not start that review.

The final report maps every PRD criterion and every ledger row to a command,
file:line, or captured result. It names observed-red failures, unresolved
external gates, and a resumable command. It never claims the external install
swap or live post-swap resolution without owner evidence.
