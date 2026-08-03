# Legacy Fixture PRD

A pre-contract artifact: no front matter, prose file lists, and legacy heading
names. Its content is complete; only its shape is legacy.

## 3. Integration Ledger

| # | New thing | Live caller (`file:line`, non-test) | Replaces | Old path removed? | Negative control |
|---|---|---|---|---|---|
| 1 | contract parser | `scripts/linchpin.sh:100` | ad-hoc parsing | deleted | remove marker; parser exits non-zero |
| 2 | brief transfer | `skills/prd-swarm-coordinator/SKILL.md:60` | short checklist | delegated | remove a ledger row; brief exits non-zero |

## 4. Phases

#### Phase 1: Contract

**Files:** `src/alpha.md` NEW (fixture subject) · `src/shared.md` EDIT (fixture caller).

**Implementation:**

- [ ] Add the contract.

#### Phase 2: Runtime

**Files:** `scripts/linchpin.sh` EDIT (run the parser).

**Implementation:**

- [ ] Run the helper.

## 5. Negative Controls

| Gate | Negative control | Expected red | Exact command/result |
|---|---|---|---|
| contract | remove the marker | parser exits non-zero | `command: sh tests/contract-conformance.sh`; result: RED observed: removed marker; exit: 1 |

## 6. Acceptance (consumer-scoped)

- [ ] The marker and required sections parse.

## 7. Checkpoint protocol

Run the contract and gate commands. Record every expected non-zero
negative-control result before declaring the fixture delivered.
