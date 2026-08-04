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
any preflight or delegation. The executable checks live in
`scripts/linchpin.sh`.

The manager is the current session's Sol/medium role. Workers, repair workers,
integration workers, and conflict workers use the Luna/max role only through
the `codex exec` subprocess shape in `references/runtime.md`. The reviewer is a
fresh Sol/medium `codex exec --sandbox read-only` process. Never use a native
subagent for Luna, never change tier after a failed attempt, and use
`codex exec resume <session-id>` only for a recorded continuation.

This skill does not support generic non-PRD swarm requests, and it does not arm
the optional goal loop.

Use the referenced documents and `scripts/linchpin.sh` subcommands as interfaces:
invoke the specific check you need and inspect its output; do not read the full
helper source into context.

## Intake branch

1. Read the complete input artifact. Do not summarize it, and do not rewrite it.
2. **Execute the PRD the user pointed at, as written.** A missing
   `prd_contract: v1` marker, a legacy heading, a prose file list, or an absent
   ledger does not block execution and is not a reason to migrate, re-author, or
   draft a replacement. `scripts/linchpin.sh brief <prd>` transfers whatever
   sections exist verbatim and marks the rest `NOT DECLARED`; the worker follows
   the PRD's own phases and file lists from there. Standardize only when the user
   asks. The only blocker is a path that is not on disk.
3. Preserve whatever the artifact does declare — Integration Ledger, Negative
   Controls, Acceptance Criteria, Checkpoint Protocol — verbatim. Do not
   re-derive a shorter checklist, and do not add a gate the author never asked
   for to compensate for a section the PRD does not have.
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

Generate each brief with the resolved lane metadata, writing it to a file:
`scripts/linchpin.sh brief <prd> <lane-id> <lane-mode> <delivery-mode> --out <brief-file>`,
then verify it with `scripts/linchpin.sh brief-check <prd> <brief-file>` and
pass that file's contents as the worker prompt. The brief is the handoff; a
prompt you compose yourself instead is a dropped ledger and a dropped scope rule.
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
- a PRD with no `Files (N)` list has its set derived from its prose `**Files:**`
  paragraphs, for grouping only — the file on disk is never rewritten;
- a PRD that declares no file set at all takes its own group with its isolation
  announced as unproven; it never drags the rest of the batch into its queue;
- explicit sequential mode makes all groups sequential;
- explicit parallel mode fails loudly on intersection or worktree failure;
- auto mode degrades only the affected group and announces the reason;
- `max_lanes` is a real concurrency bound; each group reports `active=` and
  `queued=` lanes when capacity is exceeded;
- one lane uses the same output, gate, review, and delivery fields as any other
  group and has no special branch.

When a group must degrade, run `scripts/linchpin.sh schedule auto <status>
[--config-dir <target-repo>] ...` with the status that actually happened —
`worktree-fail`, `dirty-tree`, `unparsed-files`, or `config`. Attempt the real
`git worktree add` before you claim it failed; the announcement the user reads
must name the true reason. Announce the sequential fallback before starting the
first lane, and preserve the same brief and gates. The schedule output identifies active and queued
lanes under `max_lanes`. Never abort a normal auto run for unavailable
isolation. For a forced parallel run, fail with the exact capability error so
the user can correct the environment.

Mode is per group. A colliding pair may be sequential while an independent pair
remains parallel. A worker never receives a weaker gate because its group is
sequential.

## Lane lifecycle

Run `scripts/linchpin.sh workspace <target-repo>` **before the first write to
`.linchpin/`**, including the ledger. It creates the directory and adds
`.linchpin/` and `.worktrees/` to that repository's `.git/info/exclude` unless
they are already ignored. Run output is Linchpin's scratch space, not the
user's work: it must never appear in `git status`, never be staged into a lane
commit, and never force a manual cleanup after the batch. The entries go in
`.git/info/exclude` rather than `.gitignore` on purpose — ignoring our own
output must not itself leave a modified tracked file behind. If the user asks
for the ignore to be committed instead, add `.linchpin/` to `.gitignore` and
say so; do not do it unasked.

Keep a run ledger at `.linchpin/run-<timestamp>.md` in the target repository,
written before the first worker starts and updated as each lane changes state.
For every lane record the PRD, slug, baseline, branch, worktree or shared-tree
mode, file set, overlap group, dependencies, process id, subprocess session id,
brief path, verification commands, review state, repair rounds, delivery mode,
and terminal evidence. A run with no ledger file on disk is not resumable, and
an unresumable run is not a run.

1. **Every lane gets its own branch**, sequential ones included:
   `git switch -c linchpin/<lane-slug>` from the same detected base branch.
   Never branch a lane from another lane, and never let a worker commit onto the
   branch the user had checked out. Sequential means one lane at a time in the
   shared tree; it never means committing onto the user's working branch.
   Branch from the **remote** base after a fetch (`origin/<base>`), not from the
   local branch of the same name. A local base that sits ahead of its remote
   carries the user's unrelated committed work into every lane, and delivery
   then merges that work under a PR title that never mentions it. If local and
   remote have diverged, say so before the first lane starts; whose commits
   those are is the user's call, not a detail to resolve silently.
2. **Make the worktree able to run the gates before the worker starts.** A fresh
   worktree has source but no build state: no installed dependencies, and none
   of the repository's local tooling. Every lane that discovers this alone
   discovers it again in parallel, and reports a gate it could not run as if
   that were a verification result. Once per run, resolve the bootstrap for this
   repository — its lockfile install, its pinned runtime version, and whether
   dependencies can be shared across lanes rather than installed per lane — then
   apply it to each worktree and state in the ledger which gate commands are
   actually runnable there. Check the repository's own test configuration for
   path exclusions that would silently match your worktree directory and match
   zero tests; if one does, resolve the override once and put it in every brief
   rather than letting each lane rediscover it.
3. Launch workers using only the Worker row in `references/runtime.md`. Pin the
   required effort and working directory in the subprocess invocation, and pass
   the generated brief file as the prompt. Do not inherit session defaults, do
   not retype the brief into a prompt of your own, and do not route code edits
   through another runtime.
4. Require a worker commit, exact test output, caller census, revert check, and
   gate evidence before manager verification. The commit is evidenced by the
   commit itself, never by a worker's summary claiming one. A lane recorded as
   committed whose sha the worker never created is a false ledger row.
5. Keep a partial lane and its worktree. A timeout or worker summary is not a
   delivery result; inspect the actual diff and resume from the recorded state.
6. A lane that ends `PARTIAL` or `BLOCKED` releases its group's queue. The next
   queued lane starts; the batch does not stall behind a lane that is done
   failing.

### Awaiting a lane

A lane takes minutes, and its progress prose is not evidence you will act on.
Record the session id at launch and redirect worker output to a log. Then wait
on process exit itself — block on the process, or sleep in one long interval
sized to the lane, so that waiting costs turns in proportion to the number of
lanes rather than to their duration. A keepalive poll every few seconds spends
the whole run restating that a lane is still running, which is neither evidence
nor progress. Process exit and the real diff are the only two signals worth a
turn; announce a lane's status when it changes, not on a timer.

### Ending the run

The run is over when the workspace looks the way it did before it started. For
every lane, after its delivery state is terminal and recorded: remove the
worktree, prune the worktree list, and delete the lane branch that was merged.
Keep the worktree and branch of any lane that ended `PARTIAL` or `BLOCKED` —
those are resumable state — and name in the final report exactly what was kept
and the command that resumes or removes it. Leave `.linchpin/` in place as the
run record; `workspace` has already kept it out of `git status`. Check the
target repository's status at the end and account for anything Linchpin added
that is still there. Cleanup is part of delivery, not an optional courtesy.

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

When the PRD declares no Negative Controls, `gate` reports
`GATES-NOT-DECLARED` and delivery proceeds on the verification the PRD *does*
declare. Do not invent controls the author never wrote, and do not hold a lane
because a section is absent. The inherited-gate rule binds the controls a PRD
declares; it never manufactures new ones.

The reviewer packet must contain the negative-control table even when all
functional tests are green. The manager records the exact red command and its
non-zero result; a verbal claim is not evidence.

## One review and repair rule

Two preconditions come before the reviewer, in this order. A lane that fails
either is not ready for review, and launching a reviewer anyway produces a
rejection that says nothing about the code:

1. **The lane is committed.** An uncommitted working tree is `PARTIAL`. Get the
   worker's own commit first; a missing commit is a worker-contract failure that
   no review round can fix.
2. **You have run the gates yourself.** The reviewer is `--sandbox read-only`:
   it cannot install dependencies, write a cache, bind a port, or run the
   repository's suites. Run them in a writable tree and produce the Gate
   Evidence table before the reviewer starts.

Generate the review brief with the helper; it refuses to emit without both:

```sh
scripts/linchpin.sh review-brief <prd> <lane-id> --gates <gate-evidence.md> --commit <sha> --out <review>
```

Then launch exactly one fresh Sol/medium reviewer per lane through this shape,
with all role values resolved from `references/runtime.md`:

```text
codex exec --model <Reviewer.Model> -c 'model_reasoning_effort="<Reviewer.Effort>"' --sandbox read-only -C <lane> <review>
```

Record `review_used: true` before launch. The reviewer cannot edit. The manager
closes findings after Luna repair; no second reviewer is started after repair.

Every finding is labelled `DEFECT` or `EVIDENCE-GAP`. Only a `DEFECT` blocks
delivery. An `EVIDENCE-GAP` is recorded in the ledger and delivered past — a
reviewer reporting what it was structurally unable to run is describing its own
sandbox, not a fault in the lane.

State facts in the brief without classifying them. A brief that says "treat the
missing commit as a finding" has already written the verdict, and the review
that comes back is an echo. `APPROVE` with zero findings is a valid review.

What this review is for is the class of defect only a reader reaches: a negative
control that stays green when the feature is deleted, a field the code accepts
and never maps, a document asserting behavior the code contradicts. Narrow the
question to that; never trade away the rigor.

When a worker or reviewer exposes a failure, treat it first as specification
evidence. Before re-delegating, write a corrected or narrowed handoff naming the
exact file, line, expected behavior, failing command, and newly required test.
The handoff must differ from the failed prompt. Never repeat an unchanged
prompt, and never change the model tier or effort to escape a failed gate.
Use the recorded `codex exec resume <session-id>` only when the corrected
continuation is explicit.

A repair round is for a `DEFECT`. Spawning a fresh worker whose entire scope is
"commit the diff that already exists" is not repair — it is manager integration
work, and it costs a full model run to reach a `git commit` you could have made
directly. If a lane arrives uncommitted, fix it as integration and record the
worker-contract failure; do not dress it up as a repair round. A lane whose PRD
requires that nothing be committed is already correct and never gets one.

Repair, integration, and conflict work face the same inherited gates. Ordinary
overlap and merge conflicts are manager-directed integration work; preserve the
accepted intent of both PRDs and add a regression test when resolution combines
behavior. A semantic conflict that would require violating a PRD is a named
`BLOCKED` decision, not a silent rewrite.

## Delivery and terminal states

Resolve delivery from `.linchpin.toml`: `pr` by default, `branch` when selected,
and `branch` after an announced missing-remote or missing-client fallback. A
delivery fallback does not remove review, gate evidence, or verification.

Probe the PR path once, at preflight, rather than discovering it lane by lane at
the moment of delivery. Confirm which client actually works against this remote,
and which merge methods the repository permits, before the first merge — a
repository that forbids merge commits rejects the merge after the PR is already
open. Record the working client and the permitted method in the ledger and use
them for every lane.

**Merging to a shared base branch is the one stop-and-confirm point.** Opening
PRs, pushing lane branches, and reporting are all Linchpin's to do. Merging
another lane's work into a branch other people build on is the user's decision,
and an autonomous run is exactly the situation where nobody is watching. Ask
once, before the first merge, and carry the answer across the remaining lanes.
If the run was told not to stop, deliver every lane as an open PR and say that
the merges are waiting — an unmerged PR is recoverable, a merge is not.

Use only these terminal forms:

- `DELIVERED(pr)` or `DELIVERED(branch)` after the full evidence packet passes;
- `BLOCKED <named external reason> <resumable command>` with preserved state;
- `PARTIAL` while implementation or evidence is incomplete.

Never label a lane `MERGED` as its product state. Never call a lane delivered
because a process exited, a summary said done, or a green-only test suite ran.

## Final controller verification

Before handing off, inspect the real branch or shared-tree diff and run the
gates the **target repository** names — its own test, lint, typecheck, and build
commands, discovered from that repository. Linchpin's own repository scripts
(`scripts/verify.sh`, its shellcheck and jq checks) are for developing this
plugin; never run them inside a user's repository.

Confirm the diff contains only the files the PRD's scope covers. An unrelated
deletion, an unrelated dependency bump, or an unrelated doc edit that arrived
inside a lane commit is a finding, not a bonus: name it, and get the worker's
own commit narrowed before delivery.

The final report maps every PRD criterion and every ledger row to a command,
file:line, or captured result. It names observed-red failures, unresolved
external gates, and a resumable command. It never claims the external install
swap or live post-swap resolution without owner evidence.
