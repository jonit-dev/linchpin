# Linchpin: recent Codex session audit

Linchpin launches real worker, reviewer, and auditor models, but **v0.13.0 does not reliably enforce the complete role workflow**. Auditor eligibility is implemented; automatic audit execution, budget enforcement across retries, and final evidence validation remain incomplete. Five findings below distinguish reproduced implementation bugs from observed orchestration deviations.

> **Status: all five findings are fixed as of v0.14.0.** Each finding carries a
> **Resolved** paragraph naming the change and the regression test that fails
> without it. The findings themselves are left exactly as they were observed —
> a fix note is not a licence to rewrite the evidence that motivated it. See
> [Resolution summary](#resolution-summary) for the whole set at a glance.

Audit completed September 6, 2026. Repository revision: `661a9c8` (`Publish 0.13.0`). The installed v0.13.0 scripts match the repository scripts byte-for-byte. This audit changed no plugin implementation or target-project files.

## Scope and confidence

Screened 151 session files in the September 5–6 local session directories, excluding this audit session, with September 4 sessions used for context. Directory dates are session-storage dates, not necessarily UTC event dates. Inspected role prompts, launch calls, `session_meta`, `turn_context`, provider logs, and 12 saved ThreeNative runner states. Active sessions may continue after this snapshot.

The role sample below contains sessions identifiable from their initial worker/reviewer/auditor handoff. It excludes unrelated sessions, unclassifiable handoffs, and repair prompts that merely mention an auditor. Counts are observed samples, not an exhaustive billing census.

| Role | Observed sample | Actual recorded runtime | Assessment |
|---|---:|---|---|
| Worker | 11 generated-brief sessions | All include Luna/max; one also includes Astra/medium | Initial selection works; continuation is not consistently pinned. |
| Reviewer | 30 generated-brief sessions | All Sol/medium, `read-only` | Strong evidence the reviewer role and its sandbox actually ran. |
| Auditor | 8 identified sessions | All Astra/medium; 5 `codex exec` read-only, 3 native agents with full access | Model selection works in this sample; mechanism and frequency do not consistently comply. |
| Manager | 19 matched orchestration sessions | All include Luna/max; one also includes Astra/medium | The documented Sol/medium manager pin is not the actual session model. |

“Actual” here means what Codex records in the executing session, corroborated where possible by subprocess headers. This is stronger than a preflight declaration, but does not independently attest backend inference or billing. No Claude-provider execution was validated in this sample.

588 lines across 48 screened files were invalid JSON and skipped. Some visible logs contain pre-existing redactions. Consequently, missing events do not establish that an action never happened, and this report does not claim a complete invocation or token count. Positive launch/context records and retained artifacts support the findings below.

## 1. High: runner completion bypasses the required audit and gates

**Location:** [runner.sh:262](../scripts/runner.sh#L262), [runner.sh:433](../scripts/runner.sh#L433), [runner.sh:602](../scripts/runner.sh#L602).

The runner stores audit eligibility and gate commands, launches each supplied lane command, and declares the run `complete` when no lane is pending/running or blocked. It never schedules a reviewer or auditor, never executes the stored gate list, and never increments `completed_reviews`, `failed_repairs`, or `audit_attempts`. A nonzero lane exit becomes `PARTIAL`, which still permits run completion.

All 12 inspected ThreeNative states say `complete` with zero review/audit counters. Seven are audit-eligible. This **does not mean seven batches had no auditor**: several managers launched auditors outside the runner. It means the durable state neither requires nor records that work.

Concrete examples:

| Saved state | Evidence |
|---|---|
| [PRD-358 run](../../threenative/threenative-engine/.linchpin/runs/run-20260905T183759Z-3528845/state.json) | `complete`, auto/eligible=yes, zero audit attempts; independent audit logs exist elsewhere. |
| [Native stabilization run](../../threenative/threenative-engine/.linchpin/runs/run-20260906T055720Z-1798221/state.json) | `complete`, on/eligible=yes, zero reviews/audits; an actual Astra audit is separately retained. |
| [Failed FOLLOWUP run](../../threenative/threenative-engine/.worktrees/batch-2026-09-05/.linchpin/runs/run-20260906T055328Z-1780288/state.json) | Run `complete` despite lane `PARTIAL`, exit 1. |

**Reproduced without a model call:** a bootstrap with audit on/eligible=yes, a `/bin/true` worker, and a required `/bin/false` gate reaches `complete`, with zero reviews/audits. A `/bin/false` worker also reaches run `complete` with a `PARTIAL` lane.

A related bug at [runner.sh:273](../scripts/runner.sh#L273): `run --audit on` updates only `mode`, retaining the old eligibility and reason. Reproduction from an off bootstrap produced:

```json
{"mode":"on","eligible":"no","reason":"audit disabled","mode_source":"run-option"}
```

**Cause:** the shipped runner implements process lifecycle, while its status and surrounding workflow imply broader readiness. The [implementation checkpoint](checkpoints/runner-evidence-auditor.md) ends at phase 3. The [PRD](PRDs/runner-evidence-auditor.md#L279) places evidence validation, actual review accounting, audit checkpoints, usage reporting, and end-to-end proof in phases 4–8; their corresponding test files are absent.

**Fix:** introduce explicit worker-finished, verification, review, integration, audit, and delivery-readiness states. Eligible runs must require audit/closure receipts for the final snapshot. Treat nonzero exits as unfinished or blocked. Recompute eligibility when the run override changes, or reject overrides inconsistent with the frozen plan. Until that exists, report process completion separately from task readiness.

**Resolved (v0.14.0).** `runner_settle` in [runner.sh](../scripts/runner.sh) now decides readiness in order and refuses each step rather than assuming it: any `PARTIAL` lane blocks the run, then the bootstrap's `gates` are executed once through `runner_run_gates` with each exit code and log recorded under `evidence/gates/` and in `.gate_results`, then an audit-eligible batch stops at the new `awaiting_audit` status until `linchpin.sh audit-receipt RUN_ID --session ID --verdict pass|fail` closes it. `run --audit` recomputes eligibility from the frozen PRD classifications through `audit-policy.sh eligible` instead of rewriting `mode` beside a stale `eligible`. Guarded by [tests/runner-completion-requires-evidence.sh](../tests/runner-completion-requires-evidence.sh), which reproduces all four original cases without a model call.

## 2. High: run-local auditor selection is printed but not consumed

**Location:** [linchpin.sh:1401](../scripts/linchpin.sh#L1401), [linchpin.sh:1570](../scripts/linchpin.sh#L1570), [linchpin.sh:2505](../scripts/linchpin.sh#L2505).

The router tells the manager to carry a run-local auditor model/effort into bootstrap state. However, `audit` has no model/effort input, its JSON contains only policy and PRD metadata, and `preflight --bootstrap` reads only `.audit.eligible`. Runtime resolution then uses repository config/defaults. There is no supported end-to-end transfer of the run-local assignment.

**Reproduced:**

```text
assign 'use Sol high as auditor for this run'
→ ASSIGN role=auditor alias=sol effort=high ... scope=run-local

preflight --bootstrap <eligible bootstrap containing model=Sol, effort=high>
→ auditor[provider=codex model=gpt-6-astra ...]
```

The manually added model fields are not a documented schema; their being ignored confirms that the instruction to “carry” the assignment has no implemented consumer. Without manual fields, `audit --out` drops the selection entirely.

**Impact:** a manager can preflight Astra while subsequently launching a different requested auditor by hand, or silently fall back to Astra. The observed auditors used the default Astra, so this sample does not demonstrate a real custom-auditor request being executed incorrectly. The disconnected path itself is reproduced.

**Fix:** serialize resolved provider/model/effort/mechanism for every role into a validated bootstrap schema. Preflight and launch must consume that same object. Add an assignment → bootstrap → preflight → fake launch test for a nondefault run-local auditor, verifying the repository config remains unchanged.

**Resolved (v0.14.0).** `audit --out` takes `--auditor ALIAS` and `--auditor-effort EFFORT` and writes a `roles` object holding provider, model, effort, mechanism, and scope for worker, reviewer, and auditor. `preflight --bootstrap` consumes that object in preference to repository config and refuses an incomplete or unverifiable frozen role; `role-command --bootstrap` reads the same object at launch. `assign` prints the exact flags as `ASSIGN-RUN-LOCAL audit --auditor <alias> --auditor-effort <effort>`, so the carriage the router asked for has a command rather than a sentence. Guarded by [tests/run-local-auditor-carried.sh](../tests/run-local-auditor-carried.sh), which also asserts `.linchpin.toml` is never written.

## 3. High: three auditors ran with full access through native spawning

**Location:** [coordinator role boundary](../skills/prd-swarm-coordinator/SKILL.md#L8) and [runtime delegation rules](../references/runtime.md#L132).

The FOLLOWUP manager session `01a07542-4ad5-7fe0-9fb9-94ce350c2424` launched three Astra/medium auditors using native `explorer` agents. Their metadata identifies that parent and native spawning; their first turn contexts explicitly say `danger-full-access`:

| Auditor session ID | Context line | Requested scope |
|---|---:|---|
| `01a07566-06da-7373-b0b9-f8f6403c0a39` | 7 | Initial FOLLOWUP audit |
| `01a07577-089a-7101-9a25-212cea5d1774` | 7 | Final task-state audit |
| `01a07591-b954-75f1-9cc5-4931b551ae8f` | 7 | Updated retained-proof audit at `731825eb` |

The parent's launch at JSONL line 865 explicitly uses `multi_agent_v1__spawn_agent`, `fork_context: true`, Astra, and medium effort. The prompt says read-only, but the enforced sandbox does not. This violates both the subprocess-only rule and the auditor read-only mechanism. No unauthorized auditor write is established by this finding; the defect is the missing enforcement and inherited context.

**Working comparison:** [native-stabilization-audit.log](../../threenative/threenative-engine/.linchpin/native-stabilization-audit.log) records `codex exec`, Astra/medium, and `read-only`, with session `01a07620-c2c3-7490-a05d-ea86a200f18e`. Its final verdict is present. Auditors are therefore real, but their launch path depends on the manager following prose.

**Fix:** launch reviewers/auditors through a role-aware command builder that enforces their sandbox and records their session identity. Reject native/full-access review receipts. Do not equate a read-only instruction in a prompt with a read-only process.

**Resolved (v0.14.0).** `linchpin.sh role-command worker|reviewer|auditor` is now the only thing that turns a role into argv. The sandbox is a property of the role — worker `danger-full-access`, reviewer and auditor `read-only` — and there is no flag that changes it; the command emits the enforced sandbox on its `ROLE-COMMAND` line and the exact argv as JSON on an `ARGV` line. `audit-receipt --session` records the auditor's session identity, so a recorded audit is checkable rather than remembered. `scripts/verify.sh` fails on `fork_context`, `spawn_agent`, and `multi_agent_v<n>` appearing in a skill, alongside the `agent_type`/`fork_turns` terms it already caught — the exact call the FOLLOWUP manager made was not in the old list. Guarded by [tests/role-command-enforces-sandbox.sh](../tests/role-command-enforces-sandbox.sh).

## 4. High: changing lane identity resets review budgets; audit ordering is manual

**Location:** [linchpin.sh:1157](../scripts/linchpin.sh#L1157), [runtime review rule](../references/runtime.md#L197), [audit checkpoint contract](PRDs/runner-evidence-auditor.md#L179).

The review limit is stored per ledger/lane row and consumed when generating a brief. It is not keyed to the logical PRD/batch or actual completed model invocation.

The [AutopilotRank ledger](../../autopilotrank.com/.linchpin/run-20260906-011046.md) has five successive lanes for the same source PRD. Their review rounds are **2 + 2 + 1 + 2 + 1 = 8**, corroborated by eight distinct Sol/medium reviewer sessions. The lane descriptions identify repair/supersession work, not five independent PRDs. Each individual lane passes the local cap while the same task receives eight reviews.

The three FOLLOWUP auditors above also show that the one-batch audit allowance is not mechanically enforced. Available evidence is incomplete, so this audit does not claim to have ruled out every possible user-authorized budget extension. The implementation lacks a batch-level extension check regardless.

Ordering also deviated: PRD-350 manager session `01a07339-9e9c-73e3-aeec-408c93986c33`, line 2626, launched its first reviewer and auditor together with `Promise.all`. A later second reviewer session exists. The initial audit therefore could not incorporate the first review's completed findings. PRD-358's first auditor launched against the owning repository and was retried against the lane worktree; two actual Astra sessions exist, so these must not be counted as one paid launch.

**Fix:** tie allowances to stable batch/PRD identity across lane renames and repairs. Count launch attempts and completed reviews separately. Require final gates and lane reviews before the normal audit checkpoint; permit early diagnosis only as an explicitly recorded use of the same allowance. Bind findings and closure evidence to commit identities.

**Resolved (v0.14.0).** `review-brief` now sums `review_rounds` across every ledger row naming the same PRD (`run_ledger_prd_rounds`) rather than reading the current lane's row, and records the PRD with the round so the next lane can find the budget this one spent. A repair lane under a new id is refused with a message naming the PRD and the lanes that spent it, which is the AutopilotRank rename five times over. On the audit side, `audit-receipt` refuses a second receipt for the same batch unless `--extend` says it is deliberate, and the runner reaches its audit checkpoint only after every lane exited zero and every required gate passed — so the audit can no longer run before the reviews it is supposed to read. Guarded by [tests/review-budget-per-batch.sh](../tests/review-budget-per-batch.sh) and the extension case in [tests/runner-completion-requires-evidence.sh](../tests/runner-completion-requires-evidence.sh).

## 5. Medium: manager pin is descriptive; worker model can drift on continuation

**Location:** [runtime role pins](../references/runtime.md#L9), [continuation shape](../references/runtime.md#L172), [preflight role list](../scripts/linchpin.sh#L2525).

The runtime table specifies manager Sol/medium, but the inspected orchestration sessions run predominantly Luna/max. Preflight validates worker/reviewer and an eligible auditor, never the current manager model. Since the manager is the existing interactive session, this is a contract/reporting mismatch; it does not prove the plugin overrode a user-selected model. Authoring also deliberately uses the current session and should not be judged against a nonexistent Author pin.

More materially, worker session `01a072dc-fc3f-7443-91be-8bdf59b7d42a` records:

| JSONL line | Actual worker runtime | Context |
|---:|---|---|
| 6 | Luna/max | Initial generated worker brief |
| 6366 | Astra/medium | Resumed implementation after final audit defects |
| 7554 | Luna/max | Subsequent actionlint repair |

The Astra interval includes implementation and commits, not an independent auditor. This establishes model drift within one worker identity. Incomplete launch history prevents confidently attributing it to an omitted flag, explicit override, or user intervention.

The documented resume shape supplies sandbox settings but omits explicit model/effort. The runner accepts arbitrary command arrays and records no comparison between expected role and resumed session runtime. Those gaps allow drift to go unflagged even if the original preflight passed.

**Fix:** declare the manager as “current session” and report its observed runtime, or validate a required manager model without silently switching it. Persist worker runtime and pass model/effort explicitly on continuation; compare resumed session metadata against the expected role and surface discrepancies.

**Resolved (v0.14.0).** The Manager row in `references/runtime.md` names the current session in place of `gpt-5.6-sol`/`medium`, with a paragraph saying why a role nothing launches cannot carry an enforceable pin, and `PREFLIGHT-PASS` now opens with `manager[current session; reported, not pinned]`. `role-command --resume` emits `-c model=` and `-c model_reasoning_effort=` beside `-c sandbox_mode=`, and the documented continuation shape carries all three, so a continued lane cannot silently finish as a different runtime than the one preflight verified. Guarded by [tests/manager-is-the-current-session.sh](../tests/manager-is-the-current-session.sh) and the resume case in [tests/role-command-enforces-sandbox.sh](../tests/role-command-enforces-sandbox.sh).

## Verification performed

| Check | Result |
|---|---|
| `sh tests/auditor-runtime.sh` | PASS; validates policy/preflight and assignment output, not actual end-to-end custom auditor launch. |
| `sh tests/one-review-per-lane.sh` | PASS; refuses a third review under the same lane identity, not a renamed repair lane. |
| `sh tests/runner-lifecycle.sh` | PASS; lifecycle/deduplication controls pass, but the suite has no eligible-audit completion scenario. |
| Isolated audit-required and failed-worker runs | Both incorrectly reach `complete`; no model/provider invocation was used. |
| Isolated run-local selection and `--audit on` override | Preflight ignores run-local model fields; override leaves stale eligibility. |

Reproduction inputs and state are retained at `/tmp/linchpin-session-audit.8vBfRU/`. The two inputs are `on.json` and `off.json`; the commands were:

```sh
LINCHPIN_RUNNER_INTERVAL=1 sh scripts/linchpin.sh run --bootstrap /tmp/linchpin-session-audit.8vBfRU/on.json
LINCHPIN_RUNNER_INTERVAL=1 sh scripts/linchpin.sh run --bootstrap /tmp/linchpin-session-audit.8vBfRU/off.json --audit on
sh scripts/linchpin.sh assign 'use Sol high as auditor for this run' --config-dir /tmp/linchpin-session-audit.8vBfRU
LINCHPIN_CONFIG_DIR=/tmp/linchpin-session-audit.8vBfRU sh scripts/linchpin.sh preflight tests/fixtures/models-cache-multi-provider.json --bootstrap /tmp/linchpin-session-audit.8vBfRU/on.json
```

Session evidence is under `/home/joao/.codex/sessions/2026/09/{05,06}/rollout-<timestamp>-<session-id>.jsonl`; use the full IDs and line numbers above to locate the exact records. No external messages, PR changes, deployments, or new paid model probes were performed.

## Resolution summary

Fixed in v0.14.0. Every row's test fails against v0.13.0 and passes after the change; none of them spends a model call.

| Finding | Change | Regression test |
|---|---|---|
| 1. Completion bypasses gates and audit | `runner_settle` orders lane exits, gate execution, and the audit checkpoint; `awaiting_audit` status; `audit-receipt`; `run --audit` recomputes eligibility | `tests/runner-completion-requires-evidence.sh` |
| 2. Run-local auditor not consumed | `audit --out` freezes `.roles`; `preflight`/`role-command` consume it; `assign` prints the flags | `tests/run-local-auditor-carried.sh` |
| 3. Auditors with full access | `role-command` owns every launch and its sandbox; verifier catches the native spawn terms | `tests/role-command-enforces-sandbox.sh` |
| 4. Lane rename refills review budget | Budget keyed to the PRD across lanes; one audit per batch unless extended | `tests/review-budget-per-batch.sh` |
| 5. Manager pin, worker drift | Manager row and preflight say "current session"; resume carries model and effort | `tests/manager-is-the-current-session.sh` |

One thing this audit reported that the fixes do **not** claim to have settled: the finding-3 defect was missing enforcement and inherited context, and no unauthorized auditor write was ever established. Enforcing the sandbox at the launch does not retroactively prove anything about the three sessions observed.

The original next-action line is kept for the record: *review finding 1 and the failed FOLLOWUP state; it identifies the first regression test needed before claiming reliable end-to-end auditing.* That test is now `tests/runner-completion-requires-evidence.sh`.
