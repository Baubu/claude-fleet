---
description: Set up the agent-fleet manager in the current repository
argument-hint: [--check-cmd "<command>"]
---

Bootstrap this repository so it can run an agent fleet. Be idempotent — running
this twice must not duplicate anything.

## 1. Preconditions — check, do not assume

```bash
test "${HERDR_ENV:-}" = 1 && echo "herdr: inside a managed pane" || echo "herdr: NOT inside Herdr"
command -v herdr >/dev/null && herdr --version || echo "herdr: not on PATH"
git rev-parse --show-toplevel
```

If not inside Herdr, say so and stop — the fleet needs it. If not a git
repository, stop; worktrees are the isolation mechanism.

## 2. Install the manager CLI

Copy `${CLAUDE_PLUGIN_ROOT}/scripts/herd.sh` to `<repo>/.claude/herd.sh` and
`chmod +x` it. Keep it **byte-identical** to the plugin copy — never edit the
repo copy directly; fix the plugin and re-copy, or the two drift and a fix reaches
only one side.

If `.gitignore` ignores `.claude/` with an allowlist (a `.claude/*` line followed
by `!.claude/...` exceptions), add `!.claude/herd.sh` so the script stays
versioned. Also add `.claude/fleet-archive/` to `.gitignore` — lane transcript
archives are local artifacts, not source.

## 3. Detect how this project runs its checks

The script falls back to npm, cargo, then make. If none fits, write
`<repo>/.claude/fleet.conf`:

```bash
CHECK_CMD="<the project's lint + test + build command>"
```

Use the `--check-cmd` argument if the user supplied one. Otherwise infer from the
repo (`package.json` scripts, `Makefile` targets, `pyproject.toml`, CI workflow)
and state what you chose.

## 4. The guard hook needs no per-project setup

This plugin ships a `PreToolUse` hook that refuses `Edit`/`Write` into the main
checkout while HEAD is on the default branch. It activates on install. Do **not**
copy a hook into the repo or add one to `.claude/settings.json` — that would run
it twice.

Tell the user the hook is active and what it does: the manager sits in the main
checkout on the default branch and is therefore structurally unable to edit
feature code, only review and merge it.

## 5. Document it where the next session will look

Append an "Agent Fleet" section to `CLAUDE.md` (or `AGENTS.md`), creating the file
if absent. Do not duplicate a section that already exists — update it instead. It
must cover: the topology, the `herd.sh` commands, that `herdr worktree create`
needs explicit `--path` and `--branch`, that each lane needs its **own**
dependency install, and that recycling is opt-in.

Read the `agent-fleet` skill and mirror its guidance rather than reinventing it.

## 6. Verify, then report

```bash
bash .claude/herd.sh status
```

Report: what was written, what was already present and skipped, the `CHECK_CMD`
chosen and why, and the exact next command to open a first lane —
`./.claude/herd.sh launch <issue> <slug>`.

If anything could not be set up, say which part and why. A half-configured fleet
that reports success is worse than one that reports a gap.
