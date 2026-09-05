---
name: prd-swarm-coordinator
description: Execute one or many conforming PRDs through contract-preserving Codex lanes with bounded parallelism, inherited gates, review, and honest delivery states.
license: MIT
---

# PRD Swarm Coordinator

You are the Manager. Workers and reviewers are subprocesses — `codex exec` or
`claude -p`, whichever provider the role resolved to; you never edit lane code
yourself and never spawn a native subagent.

Paths: `references/` and `scripts/` sit at the plugin root, beside `skills/`;
from this file that is `../../`. Read `references/runtime.md` for role pins
before the first subprocess. Read `references/intake.md` for config and routing
and `references/prd-contract.md` only when a PRD's structure is in question.
Use `scripts/linchpin.sh` subcommands as interfaces: run the check you need and
read its output; do not read the full helper source into context.

**Execute the PRD the user pointed at, as written.** A missing `prd_contract:
v1` marker, legacy heading, prose file list, or absent ledger is not a blocker
and not a reason to migrate or re-author. `brief` transfers what exists verbatim
and marks the rest `NOT DECLARED`. The only blocker is a path not on disk.
Standardize only when the user asks.

## Run once, at the top

```sh
S=scripts/linchpin.sh; REPO=<target-repo>; TS=$(date +%Y%m%d-%H%M%S); L=$REPO/.linchpin/run-$TS.md
sh $S preflight && sh $S workspace "$REPO" && sh $S mode auto --config-dir "$REPO" <prd>...
```

`preflight` resolves both roles and verifies each one the way its provider is
verified: a codex role against the local capability cache, a claude role with
one live probe. It also confirms `$CODEX_HOME` is writable whenever a codex role
will run — every `codex exec` subprocess needs that before its model starts.
Read the providers off its `PREFLIGHT-PASS` line; do not assume them. `workspace` must run before
the first write to `.linchpin/`; it keeps run output out of `git status`.
Run these once per batch, not once per lane.

Also resolve once, before any lane: the repository's default branch and whether
it has diverged from its remote; the working PR client and permitted merge
methods; and the repository's bootstrap (lockfile install, pinned runtime, test
path exclusions that would silently match a worktree). A fresh worktree has
source but no build state, and a repository whose commit hooks run out of
`node_modules` rejects every lane commit until dependencies are installed.
Record all of it in the ledger and put the resolved gate commands in every brief
rather than letting each lane rediscover them.

Only a missing Git repository or a role that preflight could not verify is a
refusal. Everything else — no worktree, dirty tree, no remote, no PR client — is
a named degradation announced before it takes effect. A model that cannot be
verified is never swapped for one that can.

If the user's request names a model, a role, or an effort, the router already
ran `sh $S assign "<their words>" --config-dir "$REPO" --write`. If you reached
here without that, run it before `preflight`, because preflight has to verify
the models the run will actually use.

Resolve the audit decision in the same breath, before `preflight`, because
preflight checks the auditor only for a run that will use one:

```sh
sh $S audit <prd>... [--mode <mode from ASSIGN-AUDIT>] --config-dir "$REPO" --out "$REPO/.linchpin/bootstrap-$TS.json"
sh $S preflight --bootstrap "$REPO/.linchpin/bootstrap-$TS.json"
```

Exit `3` with `BOOTSTRAP-NEEDS-COMPLEXITY` is yours to resolve: score that PRD
with the creator rubric and pass `--assess <path>=SCORE:FACTORS`. Do not edit
the PRD, and do not ask the user to classify routine work. `ASSIGN-AUDIT` and
any `scope=run-local` auditor line are run-local — carry them here, never into
`.linchpin.toml`.

## Per-group mode selection

`mode` builds the file-intersection graph and emits one group per connected
component: disjoint groups run parallel worktrees, intersecting groups run
sequentially one lane at a time, a PRD declaring no file set takes its own group
with isolation announced as unproven, and `max_lanes` bounds active lanes.
Explicit `sequential` makes every group sequential; explicit `parallel` fails
loudly on intersection or worktree failure; `auto` degrades only the affected
group.

When a group degrades, attempt the real `git worktree add` first, then run
`sh $S schedule auto <worktree-fail|dirty-tree|unparsed-files|config> --config-dir "$REPO" <lane>...`
with the status that actually happened. Mode is per group: a colliding pair may
be sequential while an independent pair stays parallel. A sequential lane never
gets a weaker gate, and never commits onto the branch the user had checked out.

## Start a lane — one command

Every lane gets its own branch from the **remote** base (`origin/<base>`), never
from another lane and never from a local base that sits ahead of its remote.
Run this as a single chained call, once per lane:

```sh
LANE=lane-1 SLUG=<prd-slug> PRD=<prd-path> BASE=<base> MODE=parallel DELIVERY=pr
sh $S worktree "$REPO" "$SLUG" "$BASE" \
  && sh $S brief "$PRD" "$LANE" "$MODE" "$DELIVERY" --config-dir "$REPO" --out "$REPO/.linchpin/$LANE.brief" \
  && sh $S brief-check "$PRD" "$REPO/.linchpin/$LANE.brief" --config-dir "$REPO" \
  && sh $S lane "$L" "$LANE" --set state=RUNNING --set prd="$PRD" --set branch="linchpin/$SLUG"
```

Then read `Worker provider:` out of the brief and launch that provider's shape.
**codex** takes the lane with `-C` and the brief as an argument:

```sh
sh $S launch --pid "$REPO/.linchpin/$LANE.pid" --log "$REPO/.linchpin/$LANE.log" \
  -- codex exec --sandbox danger-full-access \
     --model <Worker.Model> -c 'model_reasoning_effort="<Worker.Effort>"' \
     -C "$REPO/.worktrees/$SLUG" "$(cat "$REPO/.linchpin/$LANE.brief")"
```

**claude** has no `-C` and reads its prompt from stdin, so the lane is the
process cwd and the brief is a file. Generate the session id *before* launch and
record it, so a continuation is possible even if the process dies:

```sh
SID=$(uuidgen)
sh $S lane "$L" "$LANE" --set session="$SID" \
  && sh $S launch --pid "$REPO/.linchpin/$LANE.pid" --log "$REPO/.linchpin/$LANE.log" \
     --cwd "$REPO/.worktrees/$SLUG" --stdin "$REPO/.linchpin/$LANE.brief" \
     -- claude -p --permission-mode bypassPermissions \
        --model <Worker.Model> --effort <Worker.Effort> --session-id "$SID"
```

Use `--cwd`; never a `cd &&` string. A claude lane started where you stood
commits to the wrong repository.

The worker's write access is not optional and not a shortcut. Under codex's
default sandbox a worker cannot write `<repo>/.git/worktrees/<slug>/`, which is
where a worktree keeps its git metadata, so it cannot commit and the lane can
only end `PARTIAL`; it also cannot bind the unix socket Node toolchains use, so
declared gates fail as setup errors. A claude worker that has to ask before each
write cannot run unattended at all. `references/runtime.md` records the
reproduction. The lane's bound is its worktree, its branch, its file list and a
reviewer that cannot write — not the worker's sandbox.

Pass `--config-dir` to both `brief` and `brief-check`; a brief emitted with the
repository's config but checked without it fails on a stale runtime pin. The
brief is the handoff — it carries the file list, the Integration Ledger, the
Negative Controls, the Acceptance Criteria, and the Checkpoint Protocol
verbatim. A prompt you compose yourself instead is a dropped ledger.

Provider, model, effort, and mechanism come only from `references/runtime.md`
(or a repo's `.linchpin.toml` overrides, which `brief --config-dir` already
resolved). **No skill body names a model id**; every one comes out of the brief's
`Worker provider:`, `Reviewer provider:`, and `Runtime invocation:` lines. Read
them there rather than restating a pin from memory. The two roles resolve
independently, so a run may have a claude worker and a codex reviewer. Never
change provider, model, or tier during a run, above all to get past a failed
gate.

**Never start a worker in the foreground.** `launch` puts the lane in its own
session and records its exit code where `await` reads it; a hand-written
`... & echo $! > pid` is reaped when the tool call returns and reads exactly
like a lane that finished instantly. If detaching genuinely cannot work, run
foreground but **do not stream it** — one run that read a worker on a 30-second
keepalive spent roughly six hundred turns on a single lane.

Then wait on the whole group in one call:

```sh
sh $S await "$REPO"/.linchpin/lane-*.pid --interval 60
```

It blocks until every lane exits and prints one `AWAIT-DONE` per lane. Process
exit and the real diff are the only two signals worth a turn; announce a lane's
status when it changes, never on a timer.

## Hand the lifecycle to the runner

`worktree`, `brief`, `launch`, and `await` above are the primitives, and they
stay. What you should not do is drive them by hand for a whole batch: a manager
reconstructing each launch command, then spending a model turn per interval
restating that a lane is still running, is how one field batch spent 954
thirty-second polls and 739 one-second polls saying nothing. Assemble the plan
once and hand it over:

```sh
sh $S run --bootstrap "$REPO/.linchpin/bootstrap-$TS.json"
# -> RUN-STARTED run=<id> cursor=<n> dir=<repo>/.linchpin/runs/<id>
sh $S events <id> --repo "$REPO" --after <cursor> --wait
```

The bootstrap file is the plan you already resolved — repo, base, delivery,
`max_lanes`, the frozen audit decision, the gate argv, and one entry per lane
carrying its PRD, its working directory, its brief on stdin where the provider
needs it there, and its exact command argv. The runner refuses an incomplete one
rather than guessing a command; that refusal is the point, because a guessed
command is a lane started in the wrong directory.

`events --wait` blocks **inside the runner** until something actually changes,
the run reaches a terminal state, or the timeout. Read what comes back:

- `EVENTS-CURSOR` — new events. Act on them, then call again with the new cursor.
- `EVENTS-HEARTBEAT` — nothing changed. This is a heartbeat, not a question:
  there is nothing to decide, and the correct next action is the same call
  again. Do not read a log, do not summarise the wait, do not announce progress
  that did not happen.
- `EVENTS-TERMINAL` — the run is `complete` or `blocked`. Go read the state.
- `decision_required` — the only event that is genuinely yours. Something needs
  a semantic call: a lane that crashed inside its launch window, an operation
  whose provider session left no exit receipt. The runner will not relaunch out
  of that window, and neither should you: reconcile the provider session first.
  A duplicate paid call is worse than a run that stopped and said what it needs.

`run --resume <id>` reconnects. Two resumes cannot launch the same paid
operation twice — the second finds the first still running and says
`RUN-RECONNECTED` — and a resumed lane keeps its operation id, so nothing is
counted twice. Never work around a blocked run by starting a new one; that
abandons the durable state that made the resume possible.

The runner is not a decision-maker. It owns process lifecycle, bounded
scheduling, receipts, and evidence intake. PRD interpretation, integration
decisions, and repair handoffs stay yours.

## Run ledger

Keep `.linchpin/run-<timestamp>.md` in the target repository, written before the
first worker and updated as each lane changes state. Write every row with
`sh $S lane "$L" <lane-id> --set key=value ...`, never by hand. Each call
upserts and keeps earlier fields, so record what you know when you know it: PRD,
slug, baseline, branch, isolation mode, file set, group, process id, subprocess
session id, brief path, gate commands, review state, delivery mode, evidence.

Record `worker_provider`, `worker_model`, `reviewer_provider`, and
`reviewer_model` on every lane, read off the brief. A finished run has to be
able to say which providers ran it; "the models it actually used" is not
recoverable from a log after the fact.

`lane` refuses a row it cannot verify — an unknown state, `MERGED` as a product
state, a commit sha that does not resolve, a `DELIVERED(...)` row missing its
prd/branch/commit/gates/review, a `gates` path not on disk, a `BLOCKED` row with
no reason and resume. That refusal is the point. `review_rounds` is written by
`review-brief`; do not set it by hand. A run with no ledger on disk is not
resumable, and an unresumable run is not a run.

## Inherited lane gates

The PRD's Negative Controls table is an inherited gate, not advice. One Gate
Evidence row per control:

```markdown
## Gate Evidence
| Gate | Result | Observed-red evidence | Exact command/result |
|---|---|---|---|
| gate-id | PASS | RED observed: disabled gate | `command: sh tests/example.sh`; result: RED observed: disabled gate; exit: 1 |
```

Run `sh $S gate <prd> <report>` before delivery. Green-only assertions, a
missing control, a missing observed-red line, or a zero exit is `UNVERIFIED` and
rejected — every control must have failed as expected at least once. When the
PRD declares no controls, `gate` reports `GATES-NOT-DECLARED` and delivery
proceeds on the verification the PRD *does* declare. Never invent a control the
author did not write. This is identical in parallel and sequential mode.

## One review, two rounds at most

Two preconditions, in order. A lane failing either is not ready, and a reviewer
launched anyway returns a rejection that says nothing about the code:

1. **The lane is committed** by the worker itself. An uncommitted tree is
   `PARTIAL` and a worker-contract failure no review round can fix.
2. **You have run the gates yourself.** The reviewer is `--sandbox read-only`:
   it cannot install dependencies, bind a port, or run the suites.

```sh
sh $S review-brief "$PRD" "$LANE" --gates <gate-evidence.md> --commit <sha> \
  --ledger "$L" --config-dir "$REPO" --out <review>
```

Then launch the reviewer in its own provider's read-only shape, taken from the
packet's `Reviewer provider:` line. **codex**:

```sh
codex exec --model <Reviewer.Model> -c 'model_reasoning_effort="<Reviewer.Effort>"' \
  --sandbox read-only -C "$REPO/.worktrees/$SLUG" "$(cat <review>)"
```

**claude**, which is read-only by having its write tools denied outright:

```sh
sh $S launch --pid "$REPO/.linchpin/$LANE.review.pid" --log "$REPO/.linchpin/$LANE.review.log" \
  --cwd "$REPO/.worktrees/$SLUG" --stdin <review> \
  -- claude -p --permission-mode plan --disallowed-tools "Edit Write NotebookEdit" \
     --model <Reviewer.Model> --effort <Reviewer.Effort> --session-id "$(uuidgen)"
```

Pass the file `--out` wrote; never interpolate the packet's text into the
command line — it contains backticks, quotes, and table pipes, and a manager
that hand-escaped one read `Reading additional input from stdin...` as a review.
`--stdin` removes that hazard for a claude reviewer entirely. A reviewer that
exits before its model starts is an environment failure, not a verdict; report
the lane unreviewed.

**Two reviews per lane is the hard ceiling.** `review-brief` emits round 1 and
refuses round 2 unless you pass `--round 2`; it refuses round 3 outright. A
defect surviving two reviews is a specification problem: one run launched seven
reviewers at one PRD over nine hours, each finding real but *different* defects
because every repair moved the code somewhere the last review had not read.
When the reviews are spent, the lane is `BLOCKED` with a named reason and resume
command, or `DELIVERED` on the evidence it has — not `PARTIAL`, which reads as
an instruction to run one more round.

Every finding is `DEFECT` or `EVIDENCE-GAP`. Only a `DEFECT` blocks delivery; an
`EVIDENCE-GAP` is recorded and delivered past. `APPROVE` with zero findings is
valid. State facts in the brief without classifying them — a brief that says
"treat the missing commit as a finding" gets an echo back.

A repair round is for a `DEFECT`, runs on the Worker row, and needs a handoff
that differs from the failed prompt: exact file, line, expected behavior,
failing command, newly required test. Never repeat an unchanged prompt. Continue only a recorded session, in its own provider's form:
`codex exec resume <session-id> -c sandbox_mode="danger-full-access"` — `resume`
takes no `--sandbox` flag, so without that config the continued worker cannot
commit — or `claude --resume <session-id> -p` for a claude lane, using the
session id you generated and recorded at launch. Committing a
diff that already exists is manager integration work, not a repair round.
Ordinary overlap and merge conflicts are manager-directed integration; a
semantic conflict that would violate a PRD is a named `BLOCKED` decision.

## Delivery and terminal states

Delivery is `pr` by default, `branch` when configured or after an announced
fallback. A fallback never removes review, gates, or verification.

**Merging to a shared base branch is the one stop-and-confirm point.** Opening
PRs, pushing lane branches, and reporting are yours. Ask once before the first
merge and carry the answer across the remaining lanes; if the run was told not
to stop, deliver every lane as an open PR and say the merges are waiting.

Use only these terminal forms:

- `DELIVERED(pr)` or `DELIVERED(branch)` after the evidence packet passes;
- `BLOCKED <named external reason> <resumable command>` with preserved state;
- `PARTIAL` while implementation or evidence is incomplete.

Never label a lane `MERGED` as its product state, and never call it delivered
because a process exited or a summary said done.

## Close the run

Inspect the real diff and run the gates the **target repository** names — never
Linchpin's own `scripts/verify.sh` inside a user's repository. Confirm the diff
contains only files the PRD's scope covers; an unrelated deletion or dependency
bump inside a lane commit is a finding.

Read the ledger back rather than recalling it:

```sh
sh $S status "$L"
```

Exit `0` only when every lane is `DELIVERED(...)`, `1` while any lane is open,
`2` when the only unfinished lanes are `BLOCKED`. Summarizing eight lanes from
memory is where a run starts reporting work it did not do.

Then restore the workspace with the command, not by hand:

```sh
sh $S prune "$L" --repo "$REPO"
```

It removes each delivered lane's worktree and branch, and keeps — naming each
one and what to do about it — every lane that is not delivered, every worktree
holding uncommitted work, and every branch whose commits are neither in the base
nor on the remote. A squash-merged lane counts as merged; `git branch -d` does
not know that, which is why deleting lane branches by hand leaves them behind.
Read its output into the report rather than describing what you intended to
clean. Leave `.linchpin/` as the run record. The final report maps every ledger
row to a command, `file:line`, or captured result.
