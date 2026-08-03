# PRD Contract: `prd_contract: v1`

This file is the canonical artifact contract shared by the creator, the intake
router, and the swarm coordinator. It defines the parts of a PRD that can be
checked without asking a worker to reinterpret the author's intent.

## Conformance marker

A conforming PRD begins with this exact front matter. The marker is emitted only
when every required section in this document is present and structurally valid.

```yaml
---
prd_contract: v1
---
```

Additional front-matter keys are allowed; the exact `prd_contract: v1` line is
not optional.

The marker is not a license to repair an incomplete document in the coordinator.
When it is absent or malformed, intake runs `scripts/linchpin.sh migrate` and
waits for a durable replacement artifact. Migration writes the marker only when
the migrated artifact already satisfies every rule below; a document with gaps is
written without the marker and reports `MIGRATION-INCOMPLETE`.

## Required sections

A conforming artifact contains these headings, in this order:

1. `## Integration Ledger`
2. `## 4. Execution Phases` (or an equivalent `## Execution Phases` heading)
3. `## Negative Controls`
4. `## Acceptance Criteria`
5. `## Checkpoint Protocol`

A heading may carry a leading number (`## 4. Execution Phases`) and trailing
context (`## Acceptance Criteria (consumer-scoped)`), but the named sections
cannot be omitted, renamed, or replaced by an in-flight coordinator summary.
`## Acceptance` is a rename, not trailing context; `scripts/linchpin.sh migrate`
repairs that mechanically.

## Integration Ledger

The ledger is the source of truth for wiring. Its table header is:

```markdown
| # | New thing | Live caller (`file:line`, non-test) | Replaces | Old path removed? | Negative control |
```

Every data row has a numeric id, a real non-test `file:line` caller, and a
negative control. A row that is intentionally not built says
`optional/unbuilt: <reason>` in the caller or old-path cell. `TBD` is never a
valid final value. The coordinator transfers the complete table verbatim into
every worker brief, including the Live caller and Negative control cells.

## Execution Phases and file lists

Each phase uses one machine-readable file declaration immediately followed by
exactly the declared number of bullet entries:

```markdown
### Phase 1: Contract

**Files (2):**

- `references/prd-contract.md` - NEW: canonical contract
- `skills/prd-swarm-coordinator/SKILL.md` - EDIT: contract consumer
```

The parser accepts `### Phase N:` or `#### Phase N:` headings. A file entry must
start with `- `, contain one backtick-delimited repository-relative path, and
declare exactly one of `NEW`, `EDIT`, or `DELETE`. Provenance for a newly
created file belongs in the description after `NEW`; it is not a fourth file
kind. A missing, extra, malformed, or duplicated entry fails conformance.
Unparseable lists must never be treated as disjoint.

## Negative Controls

The section is a table with one row per gate. Each row names the gate, the
intentional failure action, the expected red observation, and the exact command
and result that proves the control was observed:

```markdown
| Gate | Negative control | Expected red | Exact command/result |
|---|---|---|---|
| contract | remove the marker | parser exits non-zero | `command: sh tests/contract-conformance.sh`; result: RED observed: removed marker; exit: 1 |
```

The fourth column is machine-checked. Its value must contain one exact
`command: ...`, a `result: RED observed: ...`, and a non-zero `exit: N`. The
worker report must repeat the exact command string for the same gate.

The creator records the control specification here. During implementation the
worker and reviewer add observed-red evidence to the review packet in this
format:

```markdown
## Gate Evidence
| Gate | Result | Observed-red evidence | Exact command/result |
|---|---|---|---|
| contract | PASS | RED observed: removed marker | `command: sh tests/contract-conformance.sh`; result: RED observed: removed marker; exit: 1 |
```

`PASS` without an observed-red line is `UNVERIFIED` and cannot deliver. The
negative-control table is copied into the reviewer packet alongside the ledger.

## Acceptance Criteria

The acceptance section contains the author's consumer-facing checklist. The
coordinator preserves its wording and checked state verbatim in the worker
brief; it does not derive a shorter checklist from prose.

## Checkpoint Protocol

The checkpoint section names the automated and any required manual checks, their
evidence format, and the condition that blocks delivery. A checkpoint may not
declare a gate passed from a green-only run.

## Coordinator transfer rule

The coordinator performs these checks before delegation:

1. verify the marker and required sections;
2. parse every `Files (N)` list;
3. validate every ledger row has a caller and negative control;
4. copy the ledger, negative controls, acceptance criteria, and checkpoint
   protocol without normalization into the worker brief;
5. reject a brief if any source row is missing.

This contract has no legacy-normalize branch. The only non-conforming path is
the migration and creator upgrade mode described in `references/intake.md`, and
it always leaves the original artifact untouched on disk.
