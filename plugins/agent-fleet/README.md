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
| `skills/agent-fleet` | the pattern — topology, briefing lanes, prioritisation, merge discipline, teardown |
| `scripts/herd.sh` | the manager CLI |
| `agents/lane-reviewer` | independent pre-merge review; returns MERGE / FIX / ESCALATE |
| `hooks/` | `PreToolUse` guard — no `Edit`/`Write` in the main checkout on the default branch |
| `commands/fleet-init` | bootstraps a repository (idempotent) |
| `commands/fleet-schedule` | optional recurring local task that refills the fleet |

## The manager CLI

```bash
./.claude/herd.sh status            # lifecycle + git state for every lane
./.claude/herd.sh launch <n> <slug> # create a lane for issue <n>, end to end
./.claude/herd.sh watch             # event stream of lane state changes
./.claude/herd.sh report [since]    # what the fleet did, for a human catching up
./.claude/herd.sh archive <agent>   # snapshot a lane's transcript, no teardown
./.claude/herd.sh recycle <agent>   # archive, then retire a fully-pushed lane
./.claude/herd.sh read <agent> [n]  # last n lines of an agent's transcript
./.claude/herd.sh say <agent> <txt> # prompt an agent
./.claude/herd.sh check <agent>     # lint + test + build that agent's worktree
./.claude/herd.sh land <agent>      # check, then stage a squash merge
```

`launch` takes optional `--model` (`opus`/`sonnet`/`fable`) and `--effort`
(`low`…`max`) so a lane is sized to its problem rather than inheriting the session
default for everything — match reasoning demand, not diff size, and never size
down security, migration or user-facing-data work.

`launch` does the whole thing: worktree on a fresh branch, `.env` copied in, a real
dependency install, the agent started, and an opening brief that asks the lane to
declare which files it intends to touch before it writes any code.

`check` runs `CHECK_CMD` from `<repo>/.claude/fleet.conf` if present, otherwise
detects npm, cargo or make.

## A typical cycle

```bash
./.claude/herd.sh launch 42 add-export     # open a lane
./.claude/herd.sh watch                    # arm with the Monitor tool, persistent
```

`watch` emits one line per transition into `idle`, `done`, `blocked` or `vanished`,
so finished lanes announce themselves instead of waiting to be noticed. When one
lands, the manager re-runs the checks itself, opens a PR carrying that evidence,
records what could not be verified, and picks the next issue.

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
- **Derive the collision surface; do not guess it.** Ask each lane to declare the
  files it will touch. Guessing sent three lanes to watch a schema file while they
  actually collided on the seed file.
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
