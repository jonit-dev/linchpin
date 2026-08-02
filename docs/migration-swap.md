# Incumbent install-swap runbook

This runbook is documentation only. The implementation worker does not delete,
move, overwrite, or relink anything under the user's Codex, Claude, or Hermes
directories. A user must confirm the external swap after inspecting the dry run.

## Required order

1. Run the repository helper in read-only mode:

   ```sh
   sh scripts/migration-swap.sh --dry-run
   ```

2. From the primary repository, create a timestamped backup directory outside
   this plugin repository, then copy each incumbent target with metadata
   preserved. Do not use a backup directory that contains an unrelated tree.
3. Compare each backed-up skill with the exact plugin file before any removal.
   A mismatch is a stop condition, not permission to overwrite the incumbent.
4. Ask the owner to confirm the backup and equality report. Only the owner may
   perform the deletions and plugin registration in a fresh Codex session.
5. After registration, resolve the three shipped skills from the plugin and run
   a real single-PRD smoke test. Record the command output and plugin resolution.

## Targets and safety boundary

The dry-run names these expected incumbent targets:

- Codex skill links for the creator and coordinator, plus the retired executor;
- Claude creator and retired executor directories;
- Hermes coordinator directory;
- generic non-PRD swarm directory, which must remain untouched.

The plugin intentionally does not claim equality after its contract and runtime
edits. Equality must be established by the owner against the staged source
copies immediately before a live swap. The dry-run helper never writes backups or
changes targets.

## Manual confirmation gate

Until the owner supplies backup, equality, plugin-resolution, and real smoke-test
evidence, the external install-swap status is `BLOCKED` with the resumable
command `sh scripts/migration-swap.sh --dry-run`. No post-swap resolution or
external deletion is claimed by this repository.
