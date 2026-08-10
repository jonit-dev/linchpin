# Linchpin runtime contract

This file is the only source of model, effort, role, and delegation pins for the
plugin. Skills refer here; they do not copy these values into their own bodies.

## Role pins

| Role | Model | Effort | Mechanism | Responsibility |
|---|---|---|---|---|
| Manager | `gpt-5.6-sol` | `medium` | current Codex session | intake, briefs, scheduling, evidence, integration |
| Author | `gpt-5.6-sol` | `high` | `codex exec` | authoring a new PRD in `prd-creator` |
| Worker | `gpt-5.6-luna` | `max` | `codex exec --sandbox danger-full-access` | implementation, repair, tests, conflict resolution |
| Reviewer | `gpt-5.6-sol` | `high` | `codex exec --sandbox read-only` | one independent review per lane |

Writing a PRD is the decision that every lane inherits, so it runs at the
Author row's higher effort rather than the manager's. Upgrade mode and any
gap-filling pass use the same row.

## Model aliases

A repository selects a model by alias, never by raw slug. The alias is the
stable name; the slug moves when the class does, and a slug typed into a config
file is a pin that silently goes stale.

| Alias | Model | Native spawning |
|---|---|---|
| `luna` | `gpt-5.6-luna` | forbidden — reports `multi_agent_version: "v1"` |
| `sol` | `gpt-5.6-sol` | permitted by the model; linchpin still uses `codex exec` |
| `terra` | `gpt-5.6-terra` | permitted by the model; linchpin still uses `codex exec` |

This table is the only place a slug appears. `worker` and `reviewer` in
`.linchpin.toml` accept these aliases, and an alias with no row here is a
configuration failure rather than a model request that reaches the API.

Every role runs through `codex exec` regardless of alias, so the native-spawn
hazard in the Luna row never arises from a supported path. The row is recorded
because the constraint belongs to the model, not to the way linchpin happens to
launch it today.

## Delegation rules

1. Luna runs only as a `codex exec` subprocess. It is never launched through a
   native subagent mechanism: `agent_type:` and `fork_turns:` are forbidden for
   Luna because the model reports `multi_agent_version: "v1"` while native
   spawning speaks v2.
2. The manager reads this table when launching a worker; it must not substitute
   a different model, effort, or tier of its own accord. The legitimate change
   is a repo-local `worker`, `reviewer`, `worker_effort`, or `reviewer_effort`
   in `.linchpin.toml`, declared by the user before the run starts and applied
   uniformly to every lane. That is configuration, and preflight verifies the
   resolved worker model before any branch is created. What this rule forbids is
   the manager moving a model or tier *during* a run — above all to get past a
   gate that failed. A run reports the models it actually used.
3. Sol review is launched with `codex exec --sandbox read-only`, so the reviewer
   cannot edit, commit, push, merge, or repair the lane.
4. Worker, repair, integration, and conflict processes all use the Worker row.
   A failed attempt changes the specification or narrows the handoff; it never
   changes the model tier.
5. The sanctioned continuation is `codex exec resume <session-id>`. A manager
   records the session id and the corrected handoff before continuing.

## Invocation shapes

The role values above are substituted into these shapes at runtime:

```text
<codex> exec --sandbox danger-full-access --model <Worker.Model> -c 'model_reasoning_effort="<Worker.Effort>"' -C <lane> "$(cat <brief-file>)"
<codex> exec --model <Author.Model> -c 'model_reasoning_effort="<Author.Effort>"' -C <repo> "$(cat <creator-brief>)"
<codex> exec --model <Reviewer.Model> -c 'model_reasoning_effort="<Reviewer.Effort>"' --sandbox read-only -C <lane> "$(cat <review-file>)"
<codex> exec resume <session-id> -c sandbox_mode="danger-full-access"
```

`exec resume` has no `--sandbox` flag, so a continued worker takes the same
access through `-c sandbox_mode`. Resuming without it drops the worker back into
the default sandbox mid-lane, where its next commit fails.

Every prompt is a file read at invocation time, the reviewer's included. The
worker prompt is what `scripts/linchpin.sh brief ... --out <brief-file>` wrote
and the reviewer prompt is what `scripts/linchpin.sh review-brief ... --out
<review-file>` wrote. Do not retype or summarize either into a prompt of your
own: a hand-written prompt drops the ledger, the controls, and the scope rule
the brief exists to carry. Do not interpolate the text into the command line
either — a review packet contains backticks, quotes, and pipes, and a manager
that shell-escaped one by hand sent it to `codex` as a mangled argument and then
read `Reading additional input from stdin...` as a model response.

The reviewer is never the worker's continuation. There is exactly one fresh
review per PRD; Luna repairs findings and the manager verifies closure.

## Why the worker is not sandboxed

The worker row carries `--sandbox danger-full-access` because the two things a
lane is *defined* by — a git worktree and a commit — are both impossible under
`codex exec`'s default `workspace-write` sandbox. That sandbox makes the working
directory writable; a worktree's git metadata does not live there. It lives in
the parent repository at `<repo>/.git/worktrees/<slug>/`, which is outside the
writable root, so every lane ends the same way:

```text
fatal: Unable to create '<repo>/.git/worktrees/<slug>/index.lock': Read-only file system
```

The same sandbox denies `bind`/`listen` on a unix socket, including one under
`/tmp`, which is how `tsx` and other Node toolchains talk to their own child
processes:

```text
SOCK_FAIL EPERM listen EPERM: operation not permitted /tmp/probe-5.sock
```

Both were reproduced directly, not inferred: the same probe under
`--sandbox danger-full-access` commits and binds successfully. A worker that
cannot commit produces `PARTIAL` on every lane it is given, and a worker whose
gate commands cannot start reports setup failures where the run needs
verification results. Widening `sandbox_workspace_write.writable_roots` fixes
neither: the socket denial is not a path rule.

The bound on the worker is therefore the lane, not the sandbox — its own
worktree, its own branch, the file list in its brief, and a reviewer that runs
`--sandbox read-only` and cannot edit what it judges. Do not "harden" a lane by
putting the worker back under `workspace-write`; that does not make the run
safer, it makes it fail later and less honestly.

## Capability preflight

The preflight reads `$CODEX_HOME/models_cache.json` (or the explicitly supplied
test cache) and looks up the Worker model. It must confirm the model exists and
has the capability required by the Worker row. A missing cache, model, or
capability is a hard refusal with no fallback.

Preflight also confirms `$CODEX_HOME` is writable. Every `codex exec` child
writes its own session state there before the model is contacted, so a
read-only `$CODEX_HOME` kills the reviewer with `failed to initialize
in-process app-server client` — at the end of a lane, after all the worker time
is already spent. `--sandbox read-only` bounds what the reviewer may do to the
*repository*; it never means the reviewer can run without a writable
`$CODEX_HOME`.
