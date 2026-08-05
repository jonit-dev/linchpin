# Implementation evidence for the current linchpin PRD

The named PRD is `docs/PRDs/linchpin-plugin.md`; this lane upgraded it in place
to the `prd_contract: v1` contract. This repository-side evidence records the
resulting Integration Ledger callers. Every caller below is a non-test path;
Phase 7 is explicitly optional and unbuilt.

## Integration Ledger caller census

| # | New thing | Live caller (`file:line`, non-test) | Replaces | Negative-control evidence |
|---|---|---|---|---|
| 1 | `references/prd-contract.md` | `skills/prd-creator/SKILL.md:14`; `skills/prd-swarm-coordinator/SKILL.md:13` | ad-hoc normalization | `tests/contract-conformance.sh` removes the marker and observes non-zero |
| 2 | ledger transfer into worker brief | `skills/prd-swarm-coordinator/SKILL.md:67` | derived checklist | `tests/brief-contains-ledger.sh` removes a row and rejects the brief |
| 3 | parseable `Files (N)` lists | `skills/prd-swarm-coordinator/SKILL.md:85`; `scripts/linchpin.sh:45` | prose-only file lists | `tests/files-list-parseable.sh` changes a count and observes non-zero |
| 4 | `references/intake.md` | `skills/linchpin/SKILL.md:8`; `skills/prd-swarm-coordinator/SKILL.md:42` | undefined intake behavior | `tests/router-matches-intake.sh` rejects an intake-only route |
| 5 | unified one-to-many execution path | `skills/prd-swarm-coordinator/SKILL.md:11` | separate executor path | `tests/single-is-swarm-of-one.sh` rejects an omitted single-lane ledger row |
| 6 | mode selector and sequential fallback | `scripts/linchpin.sh:273`; `skills/prd-swarm-coordinator/SKILL.md:96` | unconditional worktree assumption | `tests/mode-selection.sh` and `tests/worktree-fallback.sh` observe forced failures |
| 7 | `.linchpin.toml` reader | `scripts/linchpin.sh:202`; `skills/prd-swarm-coordinator/SKILL.md:48` | hardcoded defaults | `tests/config-optional.sh` runs with no file and with overrides |
| 8 | complexity-floor refusal | `skills/linchpin/SKILL.md:27`; `scripts/linchpin.sh:246` | no floor | `tests/intent-routing.sh` routes score 2 to direct edit |
| 9 | creator upgrade mode | `skills/prd-creator/SKILL.md:40`; `skills/linchpin/SKILL.md:31` | in-flight normalization | `tests/intent-routing.sh` routes a non-conforming PRD to upgrade |
| 10 | inherited negative-control gates | `skills/prd-swarm-coordinator/SKILL.md:123`; `scripts/linchpin.sh:360` | invented coordinator gates | `tests/gate-evidence.sh` rejects an all-green report |
| 11 | corrected-spec repair rule | `skills/prd-swarm-coordinator/SKILL.md:152` | unchanged retry | `tests/no-model-escalation.sh` rejects a tier-changing repair |
| 12 | centralized runtime pins | `skills/prd-creator/SKILL.md:49`; `skills/prd-swarm-coordinator/SKILL.md:14`; `skills/linchpin/SKILL.md:9` | inline pins | `tests/no-stray-pins.sh` rejects a skill-local model slug |
| 13 | runtime verifier | `.github/workflows/verify.yml:18`; `scripts/verify.sh:50` | no safety rail | `tests/luna-never-native.sh` reports the offending file and line |
| 14 | Codex plugin manifest | `.codex-plugin/plugin.json:5` | live incumbent discovery | `tests/manifest-valid.sh` rejects an invented key |
| 15 | `linchpin` router | `skills/linchpin/SKILL.md:13`; `.codex-plugin/plugin.json:7` | no narrow entry point | `tests/router-not-a-gate.sh` keeps direct skills usable |
| 16 | run-ledger writer and status reader | `skills/prd-swarm-coordinator/SKILL.md:161,428`; `scripts/linchpin.sh:1729,1888` | a ledger typed from memory and a prose "done" summary | `tests/run-ledger.sh` rejects a `DELIVERED` row whose commit sha does not resolve, and `status` exits non-zero while a lane is open |
| 16a | goal loop armed on that status driver | optional/unbuilt: Phase 7 deliberately not started | prose goal judging | n/a — the status command exists, the loop that would consume it does not |

## Caller census commands

```sh
grep -n 'references/prd-contract.md' skills/prd-creator/SKILL.md skills/prd-swarm-coordinator/SKILL.md
grep -n 'references/intake.md' skills/linchpin/SKILL.md skills/prd-swarm-coordinator/SKILL.md
grep -n 'references/runtime.md' skills/prd-creator/SKILL.md skills/prd-swarm-coordinator/SKILL.md skills/linchpin/SKILL.md
grep -n 'scripts/verify.sh' .github/workflows/verify.yml
```

## Observed-red record

`sh tests/run-all.sh` records red results for marker removal, ledger omission,
malformed file counts, forced parallelism, worktree failure, missing model
capability, all-green gate evidence, tier escalation, native Luna references,
stray pins, native task delegation, manifest drift, route drift, duplicate
incumbents, and unverifiable run-ledger rows. A green-only result is not
recorded as a gate pass.
