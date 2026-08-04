# linchpin

`linchpin` is a Codex-only v1 plugin that runs one or many conforming PRDs
through one contract-preserving swarm path. The current session is the manager;
workers run in isolated lanes where possible, and each lane receives one
read-only review before delivery.

## Install from GitHub

Register the GitHub repository as a marketplace, then install the plugin:

```sh
codex plugin marketplace add https://github.com/jonit-dev/linchpin.git --ref main
codex plugin add linchpin@linchpin
```

Start a fresh Codex task after installation. Invoke `$linchpin` for intake, or
invoke `$prd-creator` and `$prd-swarm-coordinator` directly. The router is a
convenience entry point, not a prerequisite for either direct skill.

For a local checkout, replace the GitHub URL with the checkout path after the
repository's `.agents/plugins/marketplace.json` is present.

## Use

1. Ask for a PRD, an implementation, or execution of one or more PRDs.
2. Intake reads `references/intake.md`, applies the complexity floor, and checks
   the local capability preflight.
3. Creator output stops for explicit confirmation. Non-conforming PRDs go
   through durable migration and creator upgrade mode; the original file is
   never edited or replaced.
4. The coordinator preserves the Integration Ledger, acceptance criteria,
   negative controls, and checkpoint protocol in every worker brief.

"start", "begin", "launch", and "resume" are execution verbs. Naming PRDs you
already wrote never triggers PRD authoring.

Point Linchpin at whatever you already have. A PRD that predates the contract
runs as written: its file set is read from the prose paragraphs that name it, a
section it never declared is reported absent instead of invented, and delivery
is gated on the controls it does declare. One missing path asks about that path;
the rest of the batch still runs. Run `sh scripts/linchpin.sh help` for the
subcommands.

## Bring an existing PRD up to the contract

```sh
sh scripts/linchpin.sh migrate docs/PRDs/PRD-007-example.md
```

Migration reads the original and never writes to it. It produces
`PRD-007-example.v1.md` with the required headings renamed, prose `**Files:**`
paragraphs rewritten as parseable `Files (N)` lists, and any missing section
scaffolded, then reports one of:

- `MIGRATED` — the artifact carries `prd_contract: v1` and is ready to route;
- `MIGRATION-INCOMPLETE` — the marker was withheld and every remaining gap is
  listed, including each `MIGRATION-TODO` line. Gaps that need real evidence
  (a gate's exact command, a caller's `file:line`) belong to an author, not to
  the parser.

`sh scripts/linchpin.sh contract <prd>` reports every problem in one run.

## Customizing a run

Everything tunable lives in one optional file, `.linchpin.toml`, in the target
repository. Omit it for zero-config defaults:

```toml
execution = "auto"       # auto | parallel | sequential
delivery = "pr"          # pr | branch
base = "auto"            # auto = repository default branch
review = true
max_lanes = 4
prd_floor = 3
worker_effort = ""       # "" = shipped pin; low | medium | high | max
reviewer_effort = ""     # "" = shipped pin; low | medium | high | max
```

`sh scripts/linchpin.sh config .` prints the resolved values, including which
defaults are in force. An invalid key or value fails there, before a run starts,
rather than once per lane in the middle of one.

Effort is configurable per repository so that raising a role does not mean
editing `references/runtime.md`, which ships inside the plugin and is
overwritten on upgrade. The model is not configurable: preflight verifies the
worker model's declared capability, so substituting one produces a run that was
never checked. Nothing in the file weakens review, gate evidence, or the
inherited controls — those follow the PRD, not the config.

## What a run leaves behind

A run writes its ledger, briefs, and lane logs to `.linchpin/` in the target
repository, and its worktrees to `.worktrees/`. Neither belongs to you, so
neither should land in your `git status`:

```sh
sh scripts/linchpin.sh workspace .
```

The coordinator runs this before its first write. It creates `.linchpin/` and
adds both paths to `.git/info/exclude` unless the repository already ignores
them. `.git/info/exclude` rather than `.gitignore` is deliberate: ignoring
Linchpin's own scratch output must not leave a modified tracked file behind, or
sweep into a lane commit. If you would rather commit the ignore rule for your
team, add `.linchpin/` to `.gitignore` yourself.

`.linchpin/` is the run record — keep it to resume or audit a run, delete it
when you are done. Worktrees and merged lane branches are removed at the end of
the run. A lane that ended `PARTIAL` or `BLOCKED` keeps its worktree and branch
on purpose; the final report names each one and the command that resumes it.

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

Claude Code support, patch delivery, cross-lane dependency ordering, and the
optional goal loop are not shipped.
