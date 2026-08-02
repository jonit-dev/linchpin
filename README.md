# linchpin

`linchpin` is a Codex-only v1 plugin that runs one or many conforming PRDs
through one contract-preserving swarm path. The current session is the manager;
workers run in isolated lanes where possible, and each lane receives one
read-only review before delivery.

## Install

The repository is ready for a user-confirmed local plugin install:

```sh
codex plugin marketplace add /path/to/linchpin-plugin
codex plugin add linchpin@linchpin
```

Start a fresh Codex task after installation. Invoke `$linchpin` for intake, or
invoke `$prd-creator` and `$prd-swarm-coordinator` directly. The router is a
convenience entry point, not a prerequisite for either direct skill.

## Use

1. Ask for a PRD, an implementation, or execution of one or more PRDs.
2. Intake reads `references/intake.md`, applies the complexity floor, and checks
   the local capability preflight.
3. Creator output stops for explicit confirmation. Non-conforming PRDs go
   through durable creator upgrade mode.
4. The coordinator preserves the Integration Ledger, acceptance criteria,
   negative controls, and checkpoint protocol in every worker brief.

Omit `.linchpin.toml` for zero-config defaults. If present, it can set
`execution`, `delivery`, `base`, `review`, `max_lanes`, and `prd_floor` as
documented in `references/intake.md`.

## Runtime boundary

The runtime pins and delegation rule live only in `references/runtime.md`.
Luna is launched only through a `codex exec` subprocess; it is never a native
subagent. Sol performs the manager and read-only reviewer roles at the pinned
effort. Repair changes the specification or handoff, never the model tier.

## Install-swap status

No files under the user's Codex, Claude, or Hermes directories are changed by
this repository. The high-risk incumbent swap remains a manual confirmation
gate. Read [docs/migration-swap.md](docs/migration-swap.md) and run the
read-only `scripts/migration-swap.sh --dry-run` before a user performs any
backup, equality check, or removal. The generic non-PRD swarm remains untouched.

The retired single-PRD executor behavior is represented by the coordinator's
one-to-many path; there is no shipped duplicate executor skill.

## v1 boundary

Claude Code support, patch delivery, a third model tier, cross-lane dependency
ordering, and the optional goal loop are not shipped. The goal loop cannot start
until a real local Phase 1-6 merge checkpoint exists and the user explicitly
requests it; this no-remote implementation run makes no such claim.
