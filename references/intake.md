# Linchpin intake and execution mode

The router reads this document before it chooses a skill. Intent is the primary
signal; files already present in a repository are only a tiebreaker. The router
must not turn an incidental PRD on disk into an execution request.

## Intent routing table

The router skill copies this table exactly. The route ids are the parity key used
by the verification tests.

| Route id | User intent | Precondition | Dispatch |
|---|---|---|---|
| `ROUTE-WRITE-PRD` | "write/draft/author a PRD for X" | none | `prd-creator` |
| `ROUTE-BUILD-SMALL` | "build/implement X" | complexity score <= 2 | refuse pipeline; offer direct edit |
| `ROUTE-BUILD-LARGE` | "build/implement X" | complexity score >= 3 | `prd-creator`, then stop for confirmation |
| `ROUTE-EXECUTE-CONFORMING` | "run/execute/start/begin/launch/resume" | every supplied PRD path exists | `prd-swarm-coordinator` |
| `ROUTE-EXECUTE-UPGRADE` | user explicitly asks to standardize a PRD | any | `migrate`, then `prd-creator` upgrade mode |
| `ROUTE-EXECUTE-NONE` | "run/execute/start" | no PRD supplied, or a supplied path is not on disk | ask once for the PRD path |
| `ROUTE-AMBIGUOUS` | intent cannot be classified | any | ask one short question; never guess |

Intent wins over repository state: three conforming files on disk do not change
`ROUTE-WRITE-PRD` into an execution route.

`start`, `begin`, `launch`, and `resume` are execution verbs, not authoring
verbs. "start PRD 007 to 010" names artifacts the user already wrote, so it takes
an execution route. An authoring route requires an explicit authoring verb for a
PRD that does not exist yet. When an execute intent names PRD paths, never draft
a replacement, a companion, or a "corrected" version of them — the user's file is
the input, not a first draft. Confirm the classification with
`scripts/linchpin.sh route "<intent>" <prd-path>...` rather than inferring it.

## Complexity floor

Use the creator's additive complexity score. Scores 1 and 2 are below the
pipeline floor. Refuse the swarm and offer to make the direct edit; do not write
a PRD for a trivial request. Scores 3 through 6 use the creator's low/medium
planning path. Scores 7 and above use its high path. A configured `prd_floor`
may raise the floor, but it may not lower the built-in refusal for scores <= 2.

## Execute the document the user pointed at

**A PRD the user names is executed as written.** The `prd_contract: v1` standard
governs artifacts *Linchpin authors*; it is never an admission gate on a document
the user already wrote. A missing marker, a legacy heading, a prose file list, an
absent ledger or negative-control table: none of these block execution, and none
of them license a rewrite.

When a supplied PRD is non-conforming:

- run it. `scripts/linchpin.sh route` returns `ROUTE-EXECUTE-CONFORMING` plus an
  `ADVISORY` line naming the artifact;
- `scripts/linchpin.sh brief` transfers whatever sections exist verbatim and
  marks the rest `NOT DECLARED`. The worker follows the PRD's own phases;
- a PRD with no machine-readable `Files (N)` list is never treated as disjoint.
  Its lane runs sequentially and the reason is announced;
- gates, acceptance, and checkpoints come from the PRD. Do not invent a gate the
  author did not ask for, and do not refuse delivery for a section the author
  never wrote.

Say nothing about conformance unless the user asks. Never answer an execution
request with a standards complaint.

The only execution blocker is a path that is not on disk: report
`MISSING-PRD-PATH`, ask once, and stop.

## Standardizing a PRD (only when the user asks)

Migration runs when the user explicitly asks to standardize an artifact, or when
a change requires a *new* PRD — that new one goes through `prd-creator` and does
carry the marker. Never start this path on your own initiative in the middle of
an execution request.

The migration path, in this order:

1. Run `scripts/linchpin.sh migrate <prd>` on every non-conforming path. It
   copies nothing over the original, writes `<prd>.v1.md` beside it, renames the
   required headings, rewrites prose `**Files:**` paragraphs into parseable
   `Files (N)` lists, and scaffolds any missing section.
2. On `MIGRATED`, re-route the new `.v1.md` path. Nothing else is required.
3. On `MIGRATION-INCOMPLETE`, the marker was deliberately withheld. Creator
   upgrade mode fills only the reported gaps and the `MIGRATION-TODO` markers in
   the generated artifact.

**The original file is never edited, moved, or rewritten.** Git history is not a
substitute for a preserved file; upgrade mode works on the generated `.v1.md`
copy. Upgrade mode is a gap-filling pass, not a rewrite: it does not restate the
author's context, phases, or acceptance wording in its own words, and it never
replaces a legacy PRD with a freshly drafted one. If a gap needs information the
artifact does not contain — a gate command, a caller `file:line` — ask once
instead of inventing it.

Legacy PRDs are never normalized inside the coordinator. After creator output,
execution stops at an explicit confirmation point. Creator output never
auto-starts workers.

Every execution-mode or delivery degradation is announced before it takes
effect. The user can confirm the announced fallback; the manager records the
choice in the run ledger.

## Optional `.linchpin.toml`

The file is optional. Its absence is a valid zero-config run.

```toml
execution = "auto"    # auto | parallel | sequential
delivery = "pr"       # pr | branch
base = "auto"         # auto = repository default branch
review = true         # false is accepted only when explicitly typed
max_lanes = 4
prd_floor = 3
```

Unknown keys and invalid values fail configuration validation. Natural-language
overrides are written to this file before scheduling so the conversational and
file paths converge. `delivery = "pr"` degrades to `branch` when a remote or
the required PR client is unavailable, with an announcement. `review = false`
is never inferred from a missing service.

The helper resolves `.linchpin.toml` from the target repository directory. For
isolated helper tests or an explicitly supplied target, set
`LINCHPIN_CONFIG_DIR=/path/to/repo` or pass `--config-dir /path/to/repo` to
`route`, `mode`, `schedule`, or `brief`. The file remains optional.

## Capability preflight

Run preflight before making branches or starting workers:

| Check | Result on failure |
|---|---|
| current path is a Git repository | refuse and name the repository error |
| runtime model cache contains the configured worker model with its required capability | refuse; never fall back |
| worktree creation succeeds | announce sequential fallback for that lane group |
| current tree is clean or safely stashable | announce sequential fallback |
| PR remote and client exist | announce branch delivery fallback |

The only refusals are a missing Git repository and a missing worker capability.
Forced parallel mode is an explicit fail-loudly request, not a hidden fallback.

## Per-group mode selection

For every conforming PRD, parse all phase `Files (N)` lists using
`references/prd-contract.md`. Build an intersection graph over the complete file
sets and partition it into connected lane groups:

- disjoint groups use `parallel` with one worktree per lane when worktrees pass;
- intersecting groups use `sequential`, one lane at a time in the shared tree;
- `execution = "sequential"` makes every group sequential;
- `execution = "parallel"` requires every group to be parallel and fails loudly
  if a worktree or disjointness check fails;
- `execution = "auto"` degrades only the affected group and announces the reason;
- a one-PRD input still goes through this same grouping, brief, gate, review, and
  delivery sequence; it has no special single-lane shortcut.
- `max_lanes` is a real active-lane bound. Mode and schedule output name
  `active=` and `queued=` lanes/groups when the batch exceeds the bound.

The worker brief is identical in both modes. Isolation changes where the worker
runs, never the contract, gates, model tier, or review packet.

## Delivery and terminal vocabulary

The manager records one of these exact terminal forms:

- `DELIVERED(pr)` or `DELIVERED(branch)` after all inherited gates pass;
- `BLOCKED <named external reason> <resumable command>` when a real external
  blocker remains and the lane is preserved;
- `PARTIAL` while required work or evidence remains incomplete.

`PARTIAL` is never delivered. A missing PR client changes delivery mode only; it
does not remove review or inherited gate requirements.

## Optional goal loop

The goal-loop phase is not part of Codex-only v1. It may be proposed only after a
real local Phase 1-6 merge checkpoint and an explicit user request. This local
repository has no such checkpoint, so no goal hook or goal reference is armed.
