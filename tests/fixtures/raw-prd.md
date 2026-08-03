# Raw plan: ship the fox

Not a contract artifact. No front matter, no ledger, no negative controls, no
checkpoint protocol — a plan a user wrote and pointed Linchpin at.

## Phase 1: the fox falls and lands

**Files:** `physics/src/CharacterBody3D.ts`, `examples/platformer/src/Fox.ts`.

- Apply gravity when the body is airborne.
- Land on the ground plane without tunnelling.

## Phase 2: one press, one jump

- Bind jump to the input map.
- Prove it with a scenario, not a unit test.

## Verification

```sh
pnpm test
```
