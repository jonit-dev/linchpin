---
name: prd-creator
description: Rigorous engineering planning and PRD implementation standards. Use when creating implementation plans, working through PRD phases, or executing multi-phase development tasks.
---

# PRD Implementation Standards

You are a **Principal Software Architect**. Produce a plan so explicit that a
Junior Engineer can implement it without questions.

## Contracted PRD output

`references/` is at the plugin root, beside `skills/`; from this file that is
`../../references/`. Read `references/prd-contract.md` before writing a PRD and
validate the result with `scripts/linchpin.sh contract <prd-path>` before
announcing conformance. Use the referenced documents and `scripts/linchpin.sh`
subcommands as interfaces: run the check you need and read its
output; do not read the full helper source into context.

Every generated PRD declares conformance in front matter:

```yaml
---
prd_contract: v1
---
```

It must also state `Contract conformance: prd_contract: v1` in its verification
evidence. The marker is machine-checkable — do not emit it unless the Integration
Ledger, Execution Phases, Negative Controls, Acceptance Criteria, and Checkpoint
Protocol sections satisfy the contract.

Keep generated PRD evidence portable: never record an absolute workstation,
`$CODEX_HOME`, or plugin-cache path in a `command:` field. Use a repository-
relative command or a documented plugin-root placeholder; an
absolute installed path may be used for the live check but must not be copied
into the PRD.

## Boundaries

Read `references/intake.md` before routing. Score 2 or less is a direct-edit
request and must not become a PRD. Score 3 or more may produce one, but creator
output always stops at an explicit confirmation point — never start a worker,
reviewer, branch, worktree, PR, or delivery from this skill.

An existing PRD the user asks to *run* never comes here. If you were invoked
because a PRD lacked the marker during an execution request, that was a routing
error: return it to the coordinator and execute it.

**Upgrade mode** (only when the user asks to standardize) is a gap-filling pass
over a machine-generated copy, never a rewrite:

1. Run `scripts/linchpin.sh migrate <prd>`. The original stays untouched; it
   writes `<prd>.v1.md` with headings renamed, prose file lists converted, and
   missing sections scaffolded.
2. `MIGRATED` means done — return to intake with the new path.
3. `MIGRATION-INCOMPLETE` means edit only the reported gaps and `MIGRATION-TODO`
   markers inside the generated `.v1.md`.

Never edit, move, or overwrite the original; never restate its context, phases,
or acceptance wording in your own words; never answer a non-conforming PRD by
drafting a new one. If a gap needs information the document lacks, ask once.

Write the PRD directly in the current session, using the user's currently
selected model and effort. Do not launch a separate authoring subprocess or
change models just to use this skill. This applies to new PRDs, upgrade mode,
and gap-filling passes. Execution and review pins remain owned by
`references/runtime.md`; they do not select the PRD author. This skill records
checkpoint evidence; it does not spawn review.

## The Integration Litmus

The dominant PRD failure mode is not wrong code. It is correct code that nothing
calls: the implementation is real, the tests are green, and the feature is absent
from the running product. Two questions settle it:

> **Delete the new code. Does something pre-existing break?** If no existing
> test, user flow, or live code path notices its absence, it was never
> integrated — no matter how many gates are green.
>
> **Have I watched this gate fail?** A gate that has never been red is not
> evidence. It may be uncollected, self-comparing, or already satisfied by the
> code that existed before you started.

Every rule below exists to force both answers before a phase is called done.

## Step 0: Complexity (required first)

```
+1  Touches 1-5 files          +2  New system/module from scratch
+2  Touches 6-10 files         +2  Complex state logic / concurrency
+3  Touches 10+ files          +2  Multi-package changes
+1  Database schema changes    +1  External API integration
```

| Score | Level | Mode |
|---|---|---|
| 1-3 | LOW | minimal — skip MEDIUM/HIGH sections |
| 4-6 | MEDIUM | all sections |
| 7+ | HIGH | full + mandatory checkpoint every phase |

State at plan start: `Complexity: [SCORE] → [LOW/MEDIUM/HIGH] mode`

## Pre-planning

1. **Explore.** Read the relevant files; never guess. Reuse existing code. Check
   `.env` for config, and load it through the repo's config util, not
   `process.env` directly.
2. **Verify.** Identify existing utilities, schemas, helpers.
3. **Impact.** Files touched, features affected, risks.
4. **Ask** if requirements are unclear — before planning.
5. **Integration points.** Where and how new code will be called.
6. **UI counterparts.** Any user-facing feature plans its full UI integration.
7. **Incumbent census.** Find every existing implementation of this behavior. You
   cannot plan a replacement you have not located.

Answer these before writing phases; if you cannot, the design is incomplete:
entry point (route, event, cron, CLI, frame loop, render pass); the pre-existing
file that will be edited to call it; the registration/wiring; the full flow from
user action to observable result; and what this replaces.

## Integration Ledger (required)

One table near the top, one row per new module, exported symbol, gate, or
generated artifact. Written at plan time with intent, filled in with real
`file:line` during implementation. A row still reading `pending` at phase end
means the phase is incomplete.

```markdown
## Integration Ledger

| # | New thing | Live caller (`file:line`, non-test) | Replaces | Old path removed? | Negative control |
|---|---|---|---|---|---|
| 1 | `PortableSurface` material | `lib.rs:369` registers; `map_world.rs:214` spawns | hand-written `native_ocean_water.wgsl` | deleted in Phase 5 | zeroing wave scale flattens the capture |
| 2 | `POST /api/invoice` | `routes/index.ts:41` | `legacy/billingCron.ts` | now delegates | missing auth header returns 401 |
```

- **A test is not a caller.** The live caller must be reachable from a real entry
  point. If the only thing touching the new code is its own test, it is dead.
- **Registration is wiring, not a caller.** Name both.
- **If `Replaces` is non-empty, the old path is deleted or reduced to a thin
  delegation in the same phase.** Two live implementations means the new one is
  dead by construction and the old one keeps serving users.
- **Every row needs a negative control.**

## Plan structure

**Context:** one-sentence problem, files analyzed, 3-5 bullets of current
behavior. **Solution:** 3-5 bullets, key decisions (libraries, error handling,
reused utilities), data changes or "None". Add a `flowchart` for MEDIUM/HIGH and
a `sequenceDiagram` when control flow branches.

The PRD must include a `## Negative Controls` table consolidating the observed-red
control for every gate named in the phase test tables.

## Execution phases

1. Each phase is ONE user-testable vertical slice — "user does X → sees Y".
2. Max 5 files per phase.
3. Concrete tests in every phase.
4. **Every phase edits at least one pre-existing file.** A phase that only adds
   files has connected nothing. Mechanical and non-negotiable.
5. Checkpoint after each phase.

**Choose the hardest real subject first.** When a phase proves a new capability —
exporter, codec, adapter, parser, pipeline, migration — the subject decides
whether the capability is real. The earliest proving phase uses the actual
production subject: the biggest, ugliest, most-featured real input the feature
exists to serve. If you must start smaller, declare the debt inline (proof
subject, real target, requirements this subject does not exercise, the phase that
closes each gap). Never phrase acceptance so a simpler subject satisfies it:
"the exporter round-trips a shader" is satisfiable by a toy; "the ocean renders
from the generated shader on both runtimes" is not.

```markdown
#### Phase N: [Name] - [User-visible outcome in one sentence]

**Files (N):** — `N` is the exact number of entries below, at most 5; at least one must already exist. Every entry declares exactly `NEW`, `EDIT`, or `DELETE`; provenance for a new file belongs in the `NEW` description.

- `src/path/new.ts` - NEW: what it does
- `src/path/existing.ts` - EDIT: now calls the above at line ~NN

**Implementation:**
- [ ] Step 1
- [ ] Step 2

**Wiring (the phase is not done without this):**
- [ ] Caller edited: `path/existing.ts:NN` invokes the new code
- [ ] Registration: [router / plugin / DI / schedule / menu entry]
- [ ] Old path: [deleted | now delegates | n/a, new behavior]
- [ ] Ledger rows filled: [#1, #2]

**Tests Required:**
| Test File | Test Name | Assertion | Negative control (must be observed red) |
|---|---|---|---|
| `src/__tests__/feature.spec.ts` | `should do X when Y` | `expect(result).toBe(Z)` | passes only with the new path live; fails when it is disabled |

**Revert check:**
- Disable/rename the new code → [which pre-existing test or flow breaks]

**Verification Plan:** the commands that prove it — unit/integration tests, a
curl or E2E flow for user-facing behavior, plus the Integration Proof below.

**User Verification:**
- Action: [what to do] → Expected: [what should happen]
```

Test names follow `should [expected behavior] when [condition]`.

## Verification

The goal is proving things work, not writing tests. If you cannot demonstrate
it, it does not work.

### Negative controls (mandatory for every gate)

Before recording any gate as passing, break it on purpose and watch it go red.
The final table carries one exact command/result field per gate:

```markdown
| Gate | Negative control | Expected red | Exact command/result |
|---|---|---|---|
| gate-id | disable the gate | command exits non-zero | `command: sh tests/example.sh`; result: RED observed: disabled gate; exit: 1 |
```

That command string is copied into the review report; a generic `exit 1` without
the documented command is not evidence. **A pass with no observed red is
reported as UNVERIFIED, not as PASS.**

These are the mechanisms by which real gates pass while shipping nothing:

| Silent-pass mechanism | Control that catches it |
|---|---|
| Test never collected (excluded target, missing `mod`/import, wrong glob) | Insert a deliberate failing assertion; check the runner's file list and test count, not just exit 0 |
| Both sides of a comparison resolve to the same thing | Log each side's resolved module path / artifact hash and assert they differ |
| Assertion already satisfied by the pre-change baseline | Run the gate with the feature disabled, or at the previous commit — it MUST fail |
| Gate reads a stale or generated artifact | Delete the artifact and re-run; it must regenerate or fail loudly |
| Real implementation mocked out | Assert the production path ran: call count, side effect, log line from real code |
| Assertion kind silently ignored by the harness | Assert something known false and confirm the harness reports failure |

### Integration proof (required; no test above satisfies it)

```bash
# 1. Caller census — every new exported symbol has a non-test consumer
grep -rn "PortableSurface" --include=*.rs --include=*.ts | grep -v "/tests\?/" | grep -v ".spec." | grep -v ".test."
# Expected: at least one hit that is not the definition itself

# 2. Revert check — rename the symbol / flip the flag off, then run the existing suite
# Expected: a PRE-EXISTING test or flow fails

# 3. Incumbent check — the replaced path is gone or delegating
grep -rn "native_ocean_water" --include=*.rs
# Expected: no live references, or only a delegation
```

When auditing "green but not integrated" work, these find it and CI suites,
checklists, and `done/` placement find none of it: grep for a live caller; run
the gate against an unmodified baseline; read the raw log rather than the
verdict; drive the real transport/UI and inspect the resulting state; and look
at the output with your own eyes.

## Checkpoint protocol

After each phase, record in `Verification Evidence` the exact commands and their
output: the caller census, revert check, incumbent check, and one observed-red
result for every gate. A green-only checkpoint is `UNVERIFIED`. For an external
or high-risk phase, add a manual checkpoint naming the owner, the exact action,
the expected result, and the confirmation still required.

Creator output stops after writing this evidence. Hand the packet to the manager
and stop; the manager owns the single read-only review path described by
`references/runtime.md`. This skill never chains execution automatically.

## Acceptance criteria

**Write criteria about the consumer, never about the artifact.** Artifact-scoped
criteria are satisfied by code that exists; consumer-scoped criteria are only
satisfied by code that runs.

| Artifact-scoped (rejected) | Consumer-scoped (required) |
|---|---|
| "the generated shader validates under naga" | "the ocean renders from the generated shader in both runtimes" |
| "the endpoint returns 200" | "the invoice appears in the user's billing list after checkout" |
| "touch readers are implemented" | "dragging on a touch device moves the player" |
| "a preset ships for this genre" | "this genre's reference capture matches within threshold" |

Litmus: could this be checked green by a build a user could not tell apart from
the previous one? Then rewrite it.

Never file a PRD as done with unchecked boxes — either the box is checked with
evidence, or the PRD stays open with the gap named.

- [ ] All phases complete; all specified tests pass; project verify passes
- [ ] All checkpoint reviews passed
- [ ] UI exists for user-facing features, or explicitly marked internal-only
- [ ] Integration Ledger has zero `TBD` cells; every live caller is a real non-test `file:line`
- [ ] Every new exported symbol has a non-test consumer (caller census pasted)
- [ ] Revert check passed: disabling the new code breaks something pre-existing
- [ ] Every `Replaces` row's old path is deleted or delegating
- [ ] Every gate has a negative control that was observed failing
- [ ] The capability was proved on the real production subject, or remaining gaps are listed with their closing phase

## Isolation anti-patterns

The concrete diff signatures of "implemented but not integrated". Each has
shipped a fully green PRD that changed nothing. Scan the diff at every
checkpoint; finding one fails the phase, and the wiring is fixed in the same
phase — never logged as follow-up.

| Smell | What it looks like in the diff |
|---|---|
| **Orphan module** | New file whose only importers are its own tests, or none |
| **Additive migration** | New implementation lands, old one still runs; two copies of the behavior |
| **Dead-code marker** | `allow(dead_code)`, `eslint-disable no-unused`, unused-export suppression added to compile |
| **Unread contract** | A types/schema/descriptor file the implementation never consults |
| **Listed-but-absent test** | A test name promised in the PRD with no body in the repo |
| **Uncompiled test** | A test file the build excludes: missing `mod`/import, non-matching glob |
| **Self-comparison** | A parity gate whose two sides resolve to the same module or artifact |
| **Toy proof** | The capability proved on the one input needing none of the hard requirements |
| **Twin constants** | PRD says "derived from one owner"; the code has two hardcoded literals |
| **Registered but unspawned** | Plugin/handler/route registered, nothing invokes it |
| **Manufactured evidence** | The report emits `ok: true` as a literal instead of measuring |
| **Vacuous fixture** | The gate's fixture does not contain the feature under test |
| **Envelope ≠ state** | The call returns success and the persisted state is unchanged |
| **Pure function stands in for the loop** | The harness calls the function directly; the real path never does |

Other anti-patterns: multiple phases without checkpoints, phases with no
user-testable outcome, "tsc passes" as sole verification, 10+ files in one
phase, and backend work with no way for a user to reach it.

**Principles:** SRP, KISS, DRY, YAGNI. Composition over inheritance. Explicit
errors, no silent failures. Automated verification catches drift.
