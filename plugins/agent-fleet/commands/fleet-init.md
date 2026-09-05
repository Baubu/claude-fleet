---
description: Set up the agent-fleet manager in the current repository
argument-hint: [--check-cmd "<command>"] [--install-cmd "<command>"] [--portfolio]
---

Bootstrap this repository so it can run an agent fleet. Be idempotent — running
this twice must not duplicate anything.

## 1. Preconditions — check, do not assume

```bash
test "${HERDR_ENV:-}" = 1 && echo "herdr: inside a managed pane" || echo "herdr: NOT inside Herdr"
command -v herdr >/dev/null && herdr --version || echo "herdr: not on PATH"
command -v gh >/dev/null && gh auth status 2>&1 | head -2 || echo "gh: not on PATH"
command -v claude >/dev/null && echo "claude: on PATH" || echo "claude: not on PATH (herd.sh review needs it)"
git rev-parse --show-toplevel
```

If not inside Herdr, say so and stop — the fleet needs it. If not a git
repository, stop; worktrees are the isolation mechanism. `gh` is required for
`plan`, `deps`, `review`, `document` and `pr`; say so if it is missing rather than
continuing silently.

## 2. Install the manager CLI and the reviewer prompt

Copy `${CLAUDE_PLUGIN_ROOT}/scripts/herd.sh` to `<repo>/.claude/herd.sh` and
`chmod +x` it. Copy `${CLAUDE_PLUGIN_ROOT}/agents/lane-reviewer.md` to
`<repo>/.claude/fleet-reviewer.md` — `herd.sh review` reads it headlessly. Keep
both **byte-identical** to the plugin copies — never edit the repo copies directly;
fix the plugin and re-copy, or the two drift and a fix reaches only one side.
If the copies already exist and match, say so and skip; if they exist and differ,
overwrite them and say that you did.

If `.gitignore` ignores `.claude/` with an allowlist (a `.claude/*` line followed
by `!.claude/...` exceptions), add `!.claude/herd.sh` and `!.claude/fleet-reviewer.md`
so they stay versioned. Also add `.claude/fleet-archive/` and `.claude/worktrees/`
to `.gitignore` — lane archives, plans, reviews and worktrees are local artifacts,
not source.

## 3. Detect how this project installs and checks itself

`herd.sh` detects `package.json`, `pyproject.toml`, `wally.toml`, `Cargo.toml` and
`Makefile` and runs the conventional install and check for each. If the project
needs something else, write `<repo>/.claude/fleet.conf`:

```bash
CHECK_CMD="<lint + test + build>"        # e.g. uv run ruff check . && uv run mypy pipeline && uv run pytest
INSTALL_CMD="<dependency install>"       # only if detection is wrong for this repo
CODEGEN_CMD="<per-worktree codegen>"     # only if the project generates into its dependency tree
```

Use `--check-cmd` / `--install-cmd` if the user supplied them. Otherwise infer from
the repo (`package.json` scripts, `Makefile` targets, `pyproject.toml`, CI workflow)
and state what you chose. Also confirm the toolchain the detection will call is
actually on PATH (`uv`, `wally`, `cargo`); a missing one makes `launch` refuse,
which is correct but worth telling the user now.

The other keys are optional and default sensibly; mention them once so the user
knows they exist: `REQUIRE_PLAN` (1), `LAND_MODE` (`squash` or `pr` — suggest `pr`
when the repo has CI on a remote), `REVIEW_MODEL` (`sonnet`), `STALE_MIN` (30),
`LANE_MODEL` / `LANE_EFFORT`.

## 4. The guard hook needs no per-project setup

This plugin ships a `PreToolUse` hook that refuses `Edit`/`Write` into the main
checkout while HEAD is on the default branch. It activates on install. Do **not**
copy a hook into the repo or add one to `.claude/settings.json` — that would run
it twice.

Tell the user the hook is active and what it does: the manager sits in the main
checkout on the default branch and is therefore structurally unable to edit
feature code, only review and merge it. Plans are therefore written to a file
outside the repository and posted with `herd.sh plan`.

## 5. Register in the portfolio (only with `--portfolio`)

Append the repository's absolute path to `~/.claude/fleet-portfolio.conf` if it is
not already there, one path per line. `scripts/fleet-portfolio.sh status` then
includes this repo. Do not add it without the flag.

## 6. Document it where the next session will look

Append an "Agent Fleet" section to `CLAUDE.md` (or `AGENTS.md`), creating the file
if absent. Do not duplicate a section that already exists — update it instead. It
must cover: the topology, the `herd.sh` commands, that the manager plans each issue
with `herd.sh plan` before launching, that `herdr worktree create` needs explicit
`--path` and `--branch`, that each lane needs its **own** dependency install, the
four closing-summary headings, and that recycling is opt-in.

Read the `agent-fleet` skill and mirror its guidance rather than reinventing it.

## 7. Verify, then report

```bash
bash .claude/herd.sh status
bash .claude/herd.sh deps <some open issue number>
```

Report: what was written, what was already present and skipped, the `CHECK_CMD`
(and `INSTALL_CMD`, if any) chosen and why, whether the toolchain is on PATH, and
the exact next two commands — `./.claude/herd.sh plan <issue> <file>` then
`./.claude/herd.sh launch <issue> <slug>`.

If anything could not be set up, say which part and why. A half-configured fleet
that reports success is worse than one that reports a gap.
