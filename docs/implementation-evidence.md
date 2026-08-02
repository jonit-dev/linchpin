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
| 16 | goal-loop status driver | optional/unbuilt: no Phase 1-6 merge checkpoint exists in this local run | prose goal judging | no dangling reference; optional phase deliberately not started |

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
stray pins, native task delegation, manifest drift, route drift, and duplicate
incumbents. A green-only result is not recorded as a gate pass.
