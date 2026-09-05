# agent-fleet

Run parallel feature work as a fleet of coding agents: **one git worktree per
feature, one Claude agent per worktree**, and a manager in the main checkout that
reviews the work, sequences merges, and files follow-up issues.

```
w1  <repo>    [main]           MANAGER   reviews, merges, files issues
w2  <lane-a>  [issue-NN-slug]  lane agent
w3  <lane-b>  [issue-NN-slug]  lane agent
w4  <lane-c>  [issue-NN-slug]  lane agent
```

Requires [Herdr](https://herdr.dev) (`HERDR_ENV=1`) and a git repository.

## Install

```bash
/plugin marketplace add Baubu/claude-fleet
/plugin install agent-fleet
/fleet-init                       # in each repository
```

## What it ships

| | |
|---|---|
| `skills/agent-fleet` | the pattern — topology, planning, briefing lanes, prioritisation, merge discipline, teardown |
| `scripts/herd.sh` | the manager CLI |
| `scripts/fleet-portfolio.sh` | `status` / `report` across several fleet repositories |
| `agents/lane-reviewer` | independent pre-merge review; returns MERGE / FIX / ESCALATE. Run by `herd.sh review` headlessly, or as a subagent |
| `hooks/` | `PreToolUse` guard — no `Edit`/`Write` in the main checkout on the default branch |
| `commands/fleet-init` | bootstraps a repository (idempotent) |
| `commands/fleet-schedule` | optional recurring local task that refills the fleet |

## The manager CLI

```bash
./.claude/herd.sh status            # lifecycle + git state for every lane
./.claude/herd.sh plan <n> <file>   # post the manager's plan for issue <n> to the issue
./.claude/herd.sh deps <n>          # are issue <n>'s dependencies closed?
./.claude/herd.sh collisions [n..]  # files two or more planned issues both touch
./.claude/herd.sh launch <n> <slug> # create a lane for issue <n>, end to end
./.claude/herd.sh watch             # event stream of lane state changes (incl. stale)
./.claude/herd.sh report [since]    # what the fleet did, for a human catching up
./.claude/herd.sh archive <agent>   # snapshot a lane's transcript, no teardown
./.claude/herd.sh recycle <agent>   # archive, then retire a fully-pushed lane
./.claude/herd.sh read <agent> [n]  # last n lines of an agent's transcript
./.claude/herd.sh say <agent> <txt> # prompt an agent
./.claude/herd.sh check <agent>     # lint + test + build that agent's worktree
./.claude/herd.sh review <agent>    # independent headless review; verdict to the issue
./.claude/herd.sh document <agent>  # post the lane's summary to its issue
./.claude/herd.sh pr <agent>        # check, review, push, open a PR with evidence
./.claude/herd.sh land <agent>      # check, review, summary, then squash (or --pr)
```

**The manager plans, the lane implements.** `plan` posts a six-heading plan
(approach, files, interfaces, tests, out of scope, lane sizing) as an issue comment;
`launch` refuses an unplanned issue by default, sizes the lane from the plan's
`model:`/`effort:` line, checks the issue's declared dependencies are closed, and
computes the collision surface from every live lane's plan before the brief is
written. Lanes then run on the cheap model against contracts the expensive model
wrote.

`launch` does the rest: worktree on a fresh branch, `.env` copied in, a real
dependency install for every toolchain it detects (npm, uv or venv, wally, cargo),
codegen, the agent started, and an opening brief that names the plan, the shared
files, and the exact check command to run before reporting done.

`land` runs the checks, then an independent headless review on a cheaper model,
then requires the lane's closing summary, then stages a squash — or, with
`LAND_MODE=pr` in `.claude/fleet.conf`, pushes and opens a PR whose body carries the
summary, the manager's re-run check output and the review verdict.

`.claude/fleet.conf` keys: `CHECK_CMD`, `INSTALL_CMD`, `CODEGEN_CMD`,
`REQUIRE_PLAN`, `LAND_MODE`, `REVIEW_MODEL`, `STALE_MIN`, `LANE_MODEL`,
`LANE_EFFORT`. All optional; see the skill for each.

## A typical cycle

```bash
./.claude/herd.sh plan 42 /tmp/plan-42.md   # manager writes the contract
./.claude/herd.sh launch 42 add-export      # open a lane against it
./.claude/herd.sh watch                     # arm with the Monitor tool, persistent
./.claude/herd.sh land add-export           # check, review, summary, squash or PR
```

`watch` emits one line per transition into `idle`, `done`, `blocked`, `vanished`
or `stale` (idle for `STALE_MIN` minutes with no new commit), so finished and
stuck lanes both announce themselves. When one lands, the manager re-runs the
checks itself, has the branch reviewed, records what could not be verified, and
picks the next issue.

Minding several repositories from one seat:

```bash
scripts/fleet-portfolio.sh status           # every repo in ~/.claude/fleet-portfolio.conf
scripts/fleet-portfolio.sh report yesterday
```

## Why the guard hook matters

The manager sits in the main checkout on the default branch. The hook denies edits
there, so the review-and-merge role is **enforced rather than intended** — the
manager cannot write feature code even by mistake. Work inside
`.claude/worktrees/` and files outside the repository are unaffected.

The protected branch is resolved from `origin/HEAD`, so `master` and `develop`
repos work without configuration. Hooks register at session start: after
installing or updating, restart before relying on it.

## Things this gets wrong if you let it

Each of these cost real time before it was written down.

- **Prioritise by value, not by what cannot collide.** Filling lanes with cheap
  disjoint issues while the thing you actually care about sits untouched optimises
  for the manager's convenience.
- **Plan before launching.** A lane briefed only with the issue text solves the
  easier problem next to it. The manager writes the files and interfaces; the lane
  fills them in.
- **Derive the collision surface; do not guess it.** The plans' Files sections give
  it before any lane starts; without plans, ask each lane to declare the files it
  will touch. Guessing sent three lanes to watch a schema file while they actually
  collided on the seed file.
- **Give every lane its own dependency install.** Linking one `node_modules` across
  worktrees fails the moment any lane runs an install, leaving a partial tree that
  breaks lint and test everywhere — silently.
- **`idle` does not mean finished.** A lane can settle between phases and resume. One
  produced a second commit answering its own open question *after* its PR was
  merged. Gate on git evidence, not lifecycle state.
- **Verify what lanes tell you.** One reported corrupting a shared dependency tree,
  reasoning from documentation describing a design that had already been replaced.
  It had not.
- **Recycle only when something forces it.** The transcript survives teardown; the
  live pane, where you can still ask a follow-up, does not.
- **Keep working; escalate rarely.** Merging green PRs, rebasing, filing issues and
  opening lanes are the manager's job, not requests. Escalate only what is
  irreversible and user-visible, a blocked lane, a real product decision, or a
  safety refusal. Run `herd.sh report` when you stop, so the day is reconstructable.
- **`blocked` escalates to the human.** A blocked lane is sitting on an approval or
  question dialog. Read it and ask — never answer it on the lane's behalf.

## Cost

The fleet multiplies token spend roughly linearly in lane count. That is the trade
for wall-clock parallelism. If the account bills beyond its plan, an unattended
refill loop is exactly the shape that runs into it — cap the lanes.
