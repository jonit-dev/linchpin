# Implementation checkpoints: deterministic execution, trustworthy evidence, selective auditing

Source PRD: `docs/PRDs/runner-evidence-auditor.md` (complexity 7 → HIGH, so a
checkpoint is mandatory after every phase).

Each phase below records the exact commands and exit codes, the resolved
Integration Ledger callers, the phase's revert check, the replaced-path census,
and the observed-red evidence for that phase's gate. Planned rows in the PRD's
Negative Controls table are not reported here until they were actually run.

## Phase 1: A user can see why a PRD will or will not be audited

**Commands**

| Command | Exit | Result |
|---|---|---|
| `sh tests/audit-policy.sh` | 0 | `PASS audit eligibility is a decision table over the declared complexity, with malformed declarations sent to bootstrap assessment` |
| `sh tests/subcommand-help.sh` | 0 | `PASS every subcommand answers --help, and the bare invocation prints usage alone` |
| `sh tests/config-optional.sh` | 0 | `PASS missing configuration uses defaults; prd_floor and max_lanes are enforced` |
| `sh tests/run-all.sh` | 0 | `ALL-TESTS-PASS positive paths and observed-red controls` (47 tests, `audit-policy.sh` registered) |
| `sh scripts/verify.sh` | 0 | `VERIFY-PASS contract references, runtime safety, manifest, delegation, and model preflight` |

**Collected test names**

- `should select only HIGH PRDs when mode is auto` — covered by the score-6/score-7
  pair, the mixed batch, the bold and plain declaration forms, the label-only
  PRD, the score-beats-label case, and the three unresolved declarations.

**Ledger row 1 caller census**

```sh
grep -rn 'audit-policy.sh\|audit_policy\|audit_decision' scripts/ skills/ references/
```

| Consumer | Line | What it consumes |
|---|---|---|
| `scripts/linchpin.sh:849` | `load_config` | `audit` mode out of resolved configuration |
| `scripts/linchpin.sh:1283` | `config_values` | `audit` key parse, validation, and `audit_source` provenance |
| `scripts/linchpin.sh:1351` | `audit_policy` | subcommand call into `scripts/audit-policy.sh` |
| `scripts/linchpin.sh:1428` | `audit_decision` | `declaration` — score, class, source, discrepancy |
| `scripts/linchpin.sh:1447` | `audit_decision` | `assess` — bootstrap assessment validation |
| `scripts/linchpin.sh:1480` | `audit_decision` | `eligible` — the mode decision table |
| `scripts/linchpin.sh:3316` | dispatch | `linchpin.sh audit` public command |

No consumer is a test-only path: the module is reached through the `audit`
subcommand, which `tests/audit-policy.sh` exercises as a public CLI rather than
by calling internal functions.

**Replaced-path census.** There was no incumbent implementation to delete: audit
eligibility had no code path at all, only manager judgement. What is now removed
is the *absence* — `references/intake.md` documents the mode table, precedence,
and the bootstrap-assessment route, so a manager has nothing left to improvise.
`grep -rn 'risk' references/intake.md` returns nothing: no `risk` enum,
probability slider, or sampling mode ships.

**Revert check.** Disabling the wired policy breaks the public CLI flow:

```sh
cp -R . /tmp/red1/repo && rm -f /tmp/red1/scripts/audit-policy.sh
sh /tmp/red1/repo/scripts/linchpin.sh audit docs/PRDs/runner-evidence-auditor.md
# sh: .../scripts/audit-policy.sh: No such file or directory
# exit=127
```

**Observed red for gate `policy`.** Two controls, both inside
`tests/audit-policy.sh` against isolated copies of the repository:

| Control | Broken production command | Observed |
|---|---|---|
| Policy dispatch removed | `sh <copy>/scripts/linchpin.sh audit <HIGH PRD>` | non-zero; no decision is printed |
| Dispatch ignores the requested mode (`audit_policy eligible on`) | `sh <copy>/scripts/linchpin.sh audit <HIGH PRD> --mode off` | prints `eligible=yes` for a run the user turned off |

The second control is the one that matters: a wrong answer there spends a paid
audit the user declined. `tests/audit-policy.sh` fails if that patched copy
still refuses the audit, so the control cannot silently stop proving anything.

## Phase 2: A user can select the auditor and turn it off for one run

**Commands**

| Command | Exit | Result |
|---|---|---|
| `sh tests/auditor-runtime.sh` | 0 | `PASS the auditor resolves through the shared registry, is probed only when eligible, and its run-local selection never touches repository config` |
| `sh tests/provider-preflight.sh` | 0 | unchanged: one probe per distinct claude slug, and still exactly one |
| `sh tests/assign-natural-language.sh` | 0 | unchanged worker/reviewer sentence behavior |
| `sh tests/router-matches-intake.sh` | 0 | `ROUTE-AUDIT-RUN-LOCAL` present in both the router and intake |
| `sh tests/run-all.sh` | 0 | `ALL-TESTS-PASS` (48 tests, `auditor-runtime.sh` registered) |
| `sh scripts/verify.sh` | 0 | `VERIFY-PASS` |

**Collected test names**

- `should avoid auditor cost when a sentence disables it` — covered by the
  zero-config `auditor[not-eligible...]` cell, the byte-identical config after
  three run-local sentences, and the cache-without-astra pair (ineligible passes,
  eligible refuses by name).

**Ledger rows 2–3 caller census**

```sh
grep -n 'auditor_provider\|preflight_audit_eligible\|assign_audit_request' scripts/linchpin.sh
grep -n 'ROUTE-AUDIT-RUN-LOCAL' skills/linchpin/SKILL.md references/intake.md
```

| Consumer | Line | What it consumes |
|---|---|---|
| `scripts/linchpin.sh:2473` | `preflight_model` | eligibility, then the auditor's provider/model — `--bootstrap` reads the frozen decision |
| `scripts/linchpin.sh:2565` | `preflight_model` role loop | the auditor row, only when the run is eligible |
| `scripts/linchpin.sh:2234` | `assign_audit_request` | the audit mode a sentence asks for |
| `scripts/linchpin.sh:2312` | `assign` | the run-local scope that refuses to persist |
| `scripts/linchpin.sh:1608` | `route_announce_audit` | the `ROUTE-AUDIT-RUN-LOCAL` announcement |
| `skills/linchpin/SKILL.md:36` | router dispatch table | routes the sentence to `audit --mode`, not to a config write |

**Replaced-path census.** There was no auditor role to replace. What is removed
is the persistent-only assignment path for a transient request: `assign` used to
write every resolved role into `.linchpin.toml` unconditionally, and an
`ASSIGN` line now carries `scope=`, with `run-local` lines excluded from the
write set. `assign --write` with nothing persistable no longer writes the file
at all. Worker and reviewer keep the persistent behavior they had; only the
auditor and the audit mode are run-local by default.

One fix fell out of the sentence path and is worth naming: `assign_model_shaped`
treated `prd-007` and a bare `007` as model terms, so "execute PRD-007 ... but
leave auditor off" spent a live probe on a fragment of the PRD path and then
refused the whole request with `ASSIGN-UNRESOLVED`. A PRD reference is not a
model name, and a model name is never only digits.

**Revert check.** Removing the router's override transfer breaks the `off` test:
with `preflight_audit_eligible` defaulting to `yes` in an isolated copy, the
ineligible run reports a checked auditor, and on a cache without `gpt-6-astra`
that copy fails a run that should have passed.

**Observed red for gate `auditor-runtime`.** Four controls, all in
`tests/auditor-runtime.sh`:

| Control | Broken production command | Observed |
|---|---|---|
| Force auditor preflight despite off | `sh <copy>/scripts/linchpin.sh preflight <cache>` | reports a checked auditor for an ineligible run |
| The same copy against a cache without the auditor model | `sh <copy>/scripts/linchpin.sh preflight <cache-with-luna>` | non-zero: a run stopped by a role it never launches |
| Auditor row deleted from `runtime.md` | `sh <copy>/scripts/linchpin.sh preflight <cache> --audit-eligible yes` | non-zero: the role does not resolve |
| Contradictory sentence | `sh scripts/linchpin.sh assign 'use an auditor but leave the auditor off'` | non-zero, one clarification, nothing launched |
