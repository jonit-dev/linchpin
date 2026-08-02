# Linchpin intake and execution mode

The router reads this document before it chooses a skill. Intent is the primary
signal; files already present in a repository are only a tiebreaker. The router
must not turn an incidental PRD on disk into an execution request.

## Intent routing table

The router skill copies this table exactly. The route ids are the parity key used
by the verification tests.

| Route id | User intent | Precondition | Dispatch |
|---|---|---|---|
| `ROUTE-WRITE-PRD` | "write a PRD for X" | none | `prd-creator` |
| `ROUTE-BUILD-SMALL` | "build/implement X" | complexity score <= 2 | refuse pipeline; offer direct edit |
| `ROUTE-BUILD-LARGE` | "build/implement X" | complexity score >= 3 | `prd-creator`, then stop for confirmation |
| `ROUTE-EXECUTE-CONFORMING` | "run/execute" | one or more conforming PRDs | `prd-swarm-coordinator` |
| `ROUTE-EXECUTE-UPGRADE` | any execute intent | at least one PRD is non-conforming | `prd-creator` upgrade mode, then re-route |
| `ROUTE-EXECUTE-NONE` | "run/execute" | no PRD supplied or found | ask once for the PRD path |
| `ROUTE-AMBIGUOUS` | intent cannot be classified | any | ask one short question; never guess |

Intent wins over repository state: three conforming files on disk do not change
`ROUTE-WRITE-PRD` into an execution route.

## Complexity floor

Use the creator's additive complexity score. Scores 1 and 2 are below the
pipeline floor. Refuse the swarm and offer to make the direct edit; do not write
a PRD for a trivial request. Scores 3 through 6 use the creator's low/medium
planning path. Scores 7 and above use its high path. A configured `prd_floor`
may raise the floor, but it may not lower the built-in refusal for scores <= 2.

## Non-conforming PRDs and confirmation

An execute request with a missing or invalid `prd_contract: v1` marker enters
creator upgrade mode. Upgrade mode writes a durable conforming artifact, keeps
the original available for audit, and returns to intake. It never normalizes a
legacy PRD inside the coordinator. After creator output, execution stops at an
explicit confirmation point. Creator output never auto-starts workers.

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
