---
name: prd-swarm-coordinator
description: Execute one or many conforming PRDs through contract-preserving Codex lanes with bounded parallelism, inherited gates, review, and honest delivery states.
license: MIT
---

# PRD Swarm Coordinator

You are the Manager. Workers and reviewers are `codex exec` subprocesses; you
never edit lane code yourself and never spawn a native subagent.

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

`preflight` resolves both role models and confirms `$CODEX_HOME` is writable —
every subprocess needs that before its model starts. `workspace` must run before
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

Only a missing Git repository or missing worker capability is a refusal.
Everything else — no worktree, dirty tree, no remote, no PR client — is a named
degradation announced before it takes effect.

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
  && sh $S lane "$L" "$LANE" --set state=RUNNING --set prd="$PRD" --set branch="linchpin/$SLUG" \
  && sh $S launch --pid "$REPO/.linchpin/$LANE.pid" --log "$REPO/.linchpin/$LANE.log" \
     -- codex exec --sandbox danger-full-access \
        --model <Worker.Model> -c 'model_reasoning_effort="<Worker.Effort>"' \
        -C "$REPO/.worktrees/$SLUG" "$(cat "$REPO/.linchpin/$LANE.brief")"
```

`--sandbox danger-full-access` is not optional and not a shortcut. Under the
default sandbox a worker cannot write `<repo>/.git/worktrees/<slug>/`, which is
where a worktree keeps its git metadata, so it cannot commit and the lane can
only end `PARTIAL`; it also cannot bind the unix socket Node toolchains use, so
declared gates fail as setup errors. `references/runtime.md` records the
reproduction. The lane's bound is its worktree, its branch, its file list and a
read-only reviewer — not the worker's sandbox.

Pass `--config-dir` to both `brief` and `brief-check`; a brief emitted with the
repository's config but checked without it fails on a stale runtime pin. The
brief is the handoff — it carries the file list, the Integration Ledger, the
Negative Controls, the Acceptance Criteria, and the Checkpoint Protocol
verbatim. A prompt you compose yourself instead is a dropped ledger.

Model, effort, and mechanism come only from `references/runtime.md` (or a repo's
`.linchpin.toml` overrides, which `brief --config-dir` already resolved). Read
them out of the brief rather than restating a pin from memory. Never change
model or tier during a run, above all to get past a failed gate.

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

## Run ledger

Keep `.linchpin/run-<timestamp>.md` in the target repository, written before the
first worker and updated as each lane changes state. Write every row with
`sh $S lane "$L" <lane-id> --set key=value ...`, never by hand. Each call
upserts and keeps earlier fields, so record what you know when you know it: PRD,
slug, baseline, branch, isolation mode, file set, group, process id, subprocess
session id, brief path, gate commands, review state, delivery mode, evidence.

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
sh $S review-brief "$PRD" "$LANE" --gates <gate-evidence.md> --commit <sha> --ledger "$L" --out <review> \
  && codex exec --model <Reviewer.Model> -c 'model_reasoning_effort="<Reviewer.Effort>"' \
       --sandbox read-only -C "$REPO/.worktrees/$SLUG" "$(cat <review>)"
```

Pass the file `--out` wrote; never interpolate the packet's text into the
command line — it contains backticks, quotes, and table pipes, and a manager
that hand-escaped one read `Reading additional input from stdin...` as a review.
A reviewer that exits before its model starts is an environment failure, not a
verdict; report the lane unreviewed.

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
failing command, newly required test. Never repeat an unchanged prompt. Use
`codex exec resume <session-id> -c sandbox_mode="danger-full-access"` only for a
recorded continuation — `resume` takes no `--sandbox` flag, so without that
config the continued worker cannot commit. Committing a
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
