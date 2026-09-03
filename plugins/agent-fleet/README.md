# agent-fleet

Run parallel feature work as a fleet of coding agents: **one git worktree per
feature, one Claude agent per worktree**, and a manager in the main checkout that
reviews, sequences merges and files issues.

```
w1  <repo>    [main]           MANAGER   reviews, merges, files issues
w2  <lane-a>  [issue-NN-slug]  lane agent
w3  <lane-b>  [issue-NN-slug]  lane agent
w4  <lane-c>  [issue-NN-slug]  lane agent
```

Requires [Herdr](https://herdr.dev) (`HERDR_ENV=1`) and a git repository.

## Install

```
/plugin marketplace add <owner>/claude-fleet
/plugin install agent-fleet
/fleet-init
```

## What it ships

| | |
|---|---|
| `skills/agent-fleet` | the pattern — topology, briefing lanes, merge discipline, teardown |
| `scripts/herd.sh` | manager CLI: `status`, `launch`, `watch`, `archive`, `recycle`, `read`, `say`, `check`, `land` |
| `agents/lane-reviewer` | independent pre-merge review; returns MERGE / FIX / ESCALATE |
| `hooks/` | `PreToolUse` guard: no `Edit`/`Write` in the main checkout while on the default branch |
| `commands/fleet-init` | bootstraps a repository |

## Why the guard hook matters

The manager sits in the main checkout on the default branch. The hook denies
edits there, so the review-and-merge role is **enforced rather than intended** —
the manager cannot edit feature code even by mistake. Work inside
`.claude/worktrees/` and files outside the repository are unaffected.

## Running it

```bash
./.claude/herd.sh launch 42 some-slug   # worktree + deps + agent + brief
./.claude/herd.sh watch                 # arm with the Monitor tool, persistent
./.claude/herd.sh status                # lifecycle + git state per lane
./.claude/herd.sh check <agent>         # lint + test + build that lane
```

Arm `watch` with the Monitor tool so finished lanes announce themselves instead
of waiting to be noticed.

## Three things learned the hard way

- **Derive the collision surface, don't guess it.** Ask each lane to declare the
  files it intends to touch before it writes code. Guessing sent three lanes to
  watch a schema file while they actually collided on the seed file.
- **Give every lane its own dependency install.** Linking one `node_modules`
  across worktrees fails the moment any lane runs an install, and leaves a partial
  tree that breaks lint and test everywhere — silently.
- **`idle` does not mean finished.** An agent can settle between phases and resume.
  Gate "done" on git evidence, not lifecycle state.
