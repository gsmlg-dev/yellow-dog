---
name: cmd-sync-abyss
description: Reconcile the Yellow Dog umbrella Abyss app with its standalone sibling for publishable releases. Use only when explicitly asked to synchronize the two repositories.
disable-model-invocation: true
---

# Synchronize Abyss

Synchronize the first-development copy at `apps/abyss` with the standalone Abyss project. The umbrella copy is the primary development source because Yellow Dog uses `in_umbrella` for fast iteration; the standalone project is the distributable project. This skill is manual-only: an explicit invocation authorizes reconciliation, but does not authorize publishing.

## Discover repositories safely

- Resolve this skill directory and run `git -C <skill-directory> rev-parse --show-toplevel` to find the active Yellow Dog checkout. Its `apps/abyss` directory is the source app for this invocation; do not silently switch to another worktree.
- Run `git -C <active-yellow-dog-root> worktree list --porcelain`. The first `worktree` record is Git's primary checkout. Default the standalone repository to an `abyss` directory beside that primary checkout, not beside a linked worktree. An explicit standalone path supplied by the user overrides this default.
- Verify the standalone path rather than creating or cloning it. If it is missing or is not a Git worktree, report the path and stop.
- Verify both paths are Git worktrees and identify their branches, remotes, and commit IDs. Read each repository's `AGENTS.md`, `CLAUDE.md`, and relevant Abyss app/project instructions before editing.
- Capture each worktree's initial status. Preserve unrelated or user-owned changes; stop if an existing change overlaps the files or behavior being reconciled and ownership is unclear.

## Reconcile with history

Compare the shared Abyss library, tests, native sources/configuration, and relevant documentation in both repositories. Exclude `.git`, dependencies, build output, generated artifacts, and repository-specific release metadata from mirroring.

Do not assume the repositories share a usable Git ancestor. Use each repository's file history, commits, and matching historical snapshots to classify divergence. In particular, distinguish a genuinely new file on one side from a file intentionally deleted on the other. Treat the umbrella implementation as the current development baseline, but first bring standalone-only improvements into that baseline when they are compatible; then export the reconciled shared implementation to standalone. Preserve intentional deletions: for example, do not resurrect a removed `RateLimiter` merely because an older standalone copy still has it. Preserve standalone additions such as dispatcher behavior when they are compatible with the umbrella design. Combine compatible edits; stop and report an unresolved semantic conflict rather than guessing.

Keep project-specific boundaries intact:

- Yellow Dog retains umbrella dependency declarations, `in_umbrella` usage, and umbrella build/configuration paths.
- Standalone retains its package metadata, version, release workflow, development environment, examples, and other distribution-only files.
- Reconcile dependency or package-file changes selectively. Never copy an entire manifest or lockfile between repositories.
- Compatible public API improvements are in scope when history and tests show that they are intended Abyss evolution. Follow Yellow Dog's confirmation requirement before applying a material change to a shared protocol or public contract. Package versions and release metadata remain out of scope unless separately requested.
- Update documentation affected by reconciled public APIs or behavior while preserving repository-specific prose and setup instructions.

After changes, report the files and behavior reconciled in each direction, intentional differences, validation evidence, and unresolved items. Do not commit, push, tag, publish, or bump the version by default.

## Required validation

Run Mix and package commands inside each repository's Nix devenv context. Run the following check matrix before editing to establish the baseline, then run it again after reconciliation.

From the active Yellow Dog checkout root, use the Abyss app as the Mix project so root aliases cannot run unrelated applications:

```sh
devenv shell -- bash -lc 'cd apps/abyss && mix compile --warnings-as-errors'
devenv shell -- bash -lc 'cd apps/abyss && mix format --check-formatted'
devenv shell -- bash -lc 'cd apps/abyss && mix test.all'
devenv shell -- bash -lc 'cd apps/abyss && mix credo --strict'
devenv shell -- bash -lc 'cd apps/abyss && mix dialyzer --halt-exit-status'
```

From the standalone repository root, run separate commands without changing into `apps/abyss`:

```sh
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix format --check-formatted
devenv shell -- mix test.all
devenv shell -- mix credo --strict
devenv shell -- mix dialyzer --halt-exit-status
```

Do not substitute `mix lint`: the standalone project has no `lint` alias, and the direct Credo and Dialyzer commands make both scopes explicit. After the standalone checks pass, run `devenv shell -- mix hex.build`, inspect the resulting archive contents for required native sources and accidental generated files, confirm the package version is unchanged, and remove only the generated archive created by this validation.

Report command failures accurately. If a baseline or final failure is outside the synchronization scope, list it and stop without fixing it. Report environment or dependency blockers separately. Never weaken tests, coverage, Credo, or Dialyzer settings to make a check pass.

The synchronization itself is complete only when shared implementation convergence and all applicable checks are evidenced. If a required check cannot run, report it as pending or blocked with the actual command and error.

## Boundaries

This skill creates no synchronization script or bookkeeping file and does not execute automatically. It does not perform the sync merely by being loaded. Do not modify files outside the two Abyss repositories and their explicitly required synchronization documentation. Do not use blanket directory mirroring or automatic deletion. If a conflict, dirty worktree, missing repository, or dependency issue prevents safe progress, stop and report the exact blocker. Finish with verified local changes only; do not commit, push, tag, publish, or bump a version unless separately requested.
