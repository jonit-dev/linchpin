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
- a PRD with no machine-readable `Files (N)` list still named its paths
  somewhere. `mode` derives the set from its prose `**Files:**` paragraphs for
  grouping only, announces that it did, and never rewrites the file. A PRD that
  names no paths at all takes its own group with unproven isolation rather than
  putting the whole batch in one queue behind it;
- gates, acceptance, and checkpoints come from the PRD. Do not invent a gate the
  author did not ask for, and do not refuse delivery for a section the author
  never wrote.

Say nothing about conformance unless the user asks. Never answer an execution
request with a standards complaint.

The only execution blocker is a path that is not on disk, and it blocks that one
path rather than the batch beside it: report `MISSING-PRD-PATH` for it, run the
paths that do exist, and ask once about the missing one. `ROUTE-EXECUTE-NONE`
means *nothing* the user named was found.

Normalize the argv before routing. A user pastes real invocations: a bare `.`
for "here", quoted paths that ran together without a separating space, a
trailing directory. Split concatenated paths, read a directory as the target
repository rather than a missing PRD, and hand the survivors to `route`. Do not
answer a messy argv with a question you could have answered by reading it.

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
worker = ""           # "" = use the runtime.md pin; luna | sol | terra
worker_effort = ""    # "" = use the runtime.md pin; low | medium | high | max
reviewer = ""         # "" = use the runtime.md pin; luna | sol | terra
reviewer_effort = ""  # "" = use the runtime.md pin; low | medium | high | max
```

These four keys are how a repository changes which model runs a role, and at
what effort, without editing `references/runtime.md` — that file ships inside
the plugin and an upgrade overwrites it. An unrecognized value fails
configuration validation rather than reaching a `codex exec` once per lane.

`worker` and `reviewer` take an **alias** from the Model aliases table in
`references/runtime.md`, never a raw slug. That table is the single place a slug
appears, so adding a model is one edit. An alias with no row is a configuration
failure, not a model request that reaches the API.

Preflight then verifies both resolved models against the local cache before any
branch exists. A configured model missing from the cache is a hard refusal with
no fallback, exactly as a missing default would be.

Unknown keys and invalid values fail configuration validation. Natural-language
overrides are written to this file before scheduling so the conversational and
file paths converge. `delivery = "pr"` degrades to `branch` when a remote or
the required PR client is unavailable, with an announcement. `review = false`
is never inferred from a missing service.

The helper resolves `.linchpin.toml` from the target repository directory. For
isolated helper tests or an explicitly supplied target, set
`LINCHPIN_CONFIG_DIR=/path/to/repo` or pass `--config-dir /path/to/repo` to
`route`, `mode`, `schedule`, `brief`, or `brief-check`. A brief and its check
must resolve the same config, or the check reads a stale runtime pin and
rejects a brief that is correct. The file remains optional.

## Ownership of the rest

Preflight checks, per-group mode selection, gates, review, delivery, and the
terminal vocabulary belong to `skills/prd-swarm-coordinator/SKILL.md`; role and
effort pins belong to `references/runtime.md`; PRD structure belongs to
`references/prd-contract.md`. This file does not restate them — a rule written
twice goes stale in one place first.

The goal-loop phase is not part of Codex-only v1 and no goal hook is armed.
