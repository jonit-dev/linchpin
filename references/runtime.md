# Linchpin runtime contract

This file is the only source of model, effort, role, and delegation pins for the
plugin. Skills refer here; they do not copy these values into their own bodies.

## Role pins

| Role | Model | Effort | Mechanism | Responsibility |
|---|---|---|---|---|
| Manager | `gpt-5.6-sol` | `medium` | current Codex session | intake, briefs, scheduling, evidence, integration |
| Author | `gpt-5.6-sol` | `high` | `codex exec` | authoring a new PRD in `prd-creator` |
| Worker | `gpt-5.6-luna` | `max` | `codex exec` | implementation, repair, tests, conflict resolution |
| Reviewer | `gpt-5.6-sol` | `high` | `codex exec --sandbox read-only` | one independent review per lane |

Writing a PRD is the decision that every lane inherits, so it runs at the
Author row's higher effort rather than the manager's. Upgrade mode and any
gap-filling pass use the same row.

## Delegation rules

1. Luna runs only as a `codex exec` subprocess. It is never launched through a
   native subagent mechanism: `agent_type:` and `fork_turns:` are forbidden for
   Luna because the model reports `multi_agent_version: "v1"` while native
   spawning speaks v2.
2. The manager reads this table when launching a worker; it must not substitute
   a different model, effort, or tier. Terra and any third tier are out of scope.
   The one legitimate change is a repo-local `worker_effort` or
   `reviewer_effort` in `.linchpin.toml`, declared by the user before the run
   starts and applied uniformly to every lane. That is configuration. What this
   rule forbids is the manager moving a tier *during* a run — especially to get
   past a gate that failed. No config key substitutes a model.
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
<codex> exec --model <Worker.Model> -c 'model_reasoning_effort="<Worker.Effort>"' -C <lane> "$(cat <brief-file>)"
<codex> exec --model <Author.Model> -c 'model_reasoning_effort="<Author.Effort>"' -C <repo> "$(cat <creator-brief>)"
<codex> exec --model <Reviewer.Model> -c 'model_reasoning_effort="<Reviewer.Effort>"' --sandbox read-only -C <lane> <review>
<codex> exec resume <session-id>
```

The worker prompt is the generated brief, passed from the file
`scripts/linchpin.sh brief ... --out <brief-file>` wrote. Do not retype or
summarize it into a prompt of your own: a hand-written prompt drops the ledger,
the controls, and the scope rule the brief exists to carry.

The reviewer is never the worker's continuation. There is exactly one fresh
review per PRD; Luna repairs findings and the manager verifies closure.

## Capability preflight

The preflight reads `$CODEX_HOME/models_cache.json` (or the explicitly supplied
test cache) and looks up the Worker model. It must confirm the model exists and
has the capability required by the Worker row. A missing cache, model, or
capability is a hard refusal with no fallback.
