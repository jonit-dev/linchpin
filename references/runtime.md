# Linchpin runtime contract

This file is the only source of model, effort, role, and delegation pins for the
plugin. Skills refer here; they do not copy these values into their own bodies.

## Role pins

| Role | Model | Effort | Mechanism | Responsibility |
|---|---|---|---|---|
| Manager | `gpt-5.6-sol` | `medium` | current Codex session | intake, briefs, scheduling, evidence, integration |
| Worker | `gpt-5.6-luna` | `max` | `codex exec` | implementation, repair, tests, conflict resolution |
| Reviewer | `gpt-5.6-sol` | `medium` | `codex exec --sandbox read-only` | one independent review per lane |

## Delegation rules

1. Luna runs only as a `codex exec` subprocess. It is never launched through a
   native subagent mechanism: `agent_type:` and `fork_turns:` are forbidden for
   Luna because the model reports `multi_agent_version: "v1"` while native
   spawning speaks v2.
2. The manager reads this table when launching a worker; it must not substitute
   a different model, effort, or tier. Terra and any third tier are out of scope.
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
<codex> exec --model <Worker.Model> -c 'model_reasoning_effort="<Worker.Effort>"' -C <lane> <brief>
<codex> exec --model <Reviewer.Model> -c 'model_reasoning_effort="<Reviewer.Effort>"' --sandbox read-only -C <lane> <review>
<codex> exec resume <session-id>
```

The reviewer is never the worker's continuation. There is exactly one fresh
review per PRD; Luna repairs findings and the manager verifies closure.

## Capability preflight

The preflight reads `$CODEX_HOME/models_cache.json` (or the explicitly supplied
test cache) and looks up the Worker model. It must confirm the model exists and
has the capability required by the Worker row. A missing cache, model, or
capability is a hard refusal with no fallback.
