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
