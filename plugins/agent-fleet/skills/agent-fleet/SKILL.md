---
name: agent-fleet
description: "Run parallel feature work as a fleet of Herdr agents: one git worktree per feature, one Claude agent per worktree, and a manager agent in the main checkout that reviews, sequences merges, and files issues. Use when the user asks to run features in parallel, set up a manager/orchestrator agent, or reuse the fleet pattern in a project. Requires Herdr (HERDR_ENV=1) and a git repo."
---

# Agent fleet

One manager agent, N lane agents, one git worktree per lane. The manager reviews
and merges; it never writes feature code.

```
w1  <repo>        [main]              MANAGER   <- reviews, merges, files issues
w2  <lane-a>      [issue-NN-slug]     lane agent
w3  <lane-b>      [issue-NN-slug]     lane agent
w4  <lane-c>      [issue-NN-slug]     lane agent
```

## Pick the right mechanism first

Two different things are called "agents". Confusing them is the main failure mode.

- **Claude Code subagents** (`~/.claude/agents/*.md`, `.claude/agents/*.md`, spawned
  with the Agent tool) are ephemeral and in-process. They run one task, return one
  report, and die. They cannot be prompted mid-flight, resumed, or watched. Use them
  for bounded, delegatable analysis — reviewing a diff, auditing a schema.
- **Herdr pane agents** (a full `claude` session in a pane) are persistent and
  interactive. They can be prompted mid-flight, inspected, and left running.

Lane workers and the manager must both be Herdr pane agents. A subagent cannot be
a manager: it has no terminal, no lifetime, and nothing to come back to.

## Set up a lane

Always pass `--path` and `--branch`. Herdr otherwise writes to
`~/.herdr/worktrees/<repo>/` on a random `worktree/<name>` branch, which sidesteps
the project's own worktree convention and any `node_modules` linking it configures.

```bash
herdr worktree create --cwd "$PWD" \
  --branch issue-NN-slug --base origin/main \
  --path "$PWD/.claude/worktrees/issue-NN-slug" \
  --label "NN short label" --no-focus
```

Read `.result.workspace.workspace_id` and `.result.root_pane.pane_id` from the JSON.
Never guess IDs.

A worktree holds **tracked files only**. Provision it before starting the agent:
copy in whatever is gitignored but required (`.env`, credentials), and link
dependencies rather than reinstalling them. On Windows use PowerShell
`New-Item -ItemType Junction`; `mklink` through a bash tool gets its arguments
mangled by MSYS path translation.

Then start the agent in the pane that `worktree create` returned:

```bash
herdr agent start <name> --kind claude --pane <wN:p1> --timeout 90000
```

## Brief a lane agent

Every opening prompt states: the branch, that it must not leave the worktree or
touch `main`, where to read the task (`gh issue view NN`), that project convention
files apply, **which files are the shared collision surface**, and what the closing
summary must contain.

**Derive the collision surface; do not guess it.** Guessing from the issue titles
is unreliable — a data-scraping fleet looks like it will collide on the schema and
actually collides on the seed file, because that is where generated rows land. Two
ways to get it right, in order of preference:

- Require each lane, as its *first* action, to post the list of files it intends to
  modify. Compare the lists and re-brief before any of them writes code.
- Failing that, `git log --format= --name-only -n 200 | sort | uniq -c | sort -rn`
  gives the files this repo actually churns, which is a far better prior than the
  issue text.

Then name the real overlap and require minimal additive changes plus a flag in the
closing summary, so the manager can sequence merges instead of resolving conflicts.

## Isolation is weaker than it looks

A worktree isolates *tracked files*. It does not isolate anything a tool generates
into a shared dependency directory. If lanes share a linked `node_modules`, then
`prisma generate`, `openapi-generator`, protobuf codegen and friends all write to
one place: the last lane to run wins, silently, for every sibling and the main
checkout.

**Give each lane a real dependency install.** Linking is tempting and it fails in
practice, not just in theory: the moment any lane runs an install, npm replaces the
link rather than writing through it, and what survives is a partial tree — no
`.bin`, whole transitive scopes missing — which breaks lint and test in every lane
*and* in the main checkout, silently, until something tries to run. The minute per
lane an honest install costs is cheaper than debugging that.

If you link anyway, verify afterwards that `node_modules/.bin` still exists in the
source checkout, and expect any codegen (`prisma generate` and friends) to need a
per-lane re-run.

## Manager discipline

The manager's authority should be broad on everything reversible and gated on
everything that is not.

- **`unknown` is not `done`.** Herdr says so directly. It means an agent is present
  but unclassified. Gate completion on `idle`/`done` **plus** git evidence: commits
  ahead of base, a clean tree, and checks that actually ran.
- **`blocked` escalates to the human.** A blocked agent is sitting on a permission
  or question dialog. Read it and ask. A manager that auto-answers approval prompts
  on behalf of three other agents is a manager that approves something destructive.
- **Merging to `main` is the human's gate.** Let the manager merge freely into an
  integration branch and stage squashes, but require a person for `main`. Land
  lanes one at a time, re-running checks after each, so a conflict has one obvious
  author.
- **Prefer waiting to polling.** `herdr agent wait <name> --until blocked` and
  `--wait` on prompts are event-driven. A status loop on a short timer burns tokens
  across every lane at once for no new information.

If the manager sits in the main checkout on `main`, a `PreToolUse` hook denying
`Edit`/`Write` there makes the review-only role structural rather than advisory.
This is worth setting up; see the project's own hook if it has one.

## Run it autonomously

The manager should not need a human to notice that a lane finished. Emit lane state
changes as an event stream and let the harness wake you:

```bash
./.claude/herd.sh watch   # one line per transition into idle / done / blocked / vanished
```

Arm it with the Monitor tool, `persistent: true`. Two rules from Monitor's own
guidance apply directly here:

- **Silence must never mean "fine".** Emit on `blocked` and on an agent
  disappearing, not just on success. A crashed lane and a working lane look
  identical if you only watch for completion.
- Suppress the initial `idle` snapshot so arming the watch does not replay every
  lane that was already at rest. `done` is worth emitting on the first poll — it
  means finished work nobody has read.

On Windows, decode `herdr` output as UTF-8 explicitly. Python defaults to the ANSI
codepage there (cp1255 on a Hebrew system) and agent titles carry non-ASCII, so a
naive `text=True` subprocess read crashes the watcher on the first Hebrew title.

### Choosing what to work on

Rank open issues by three things, not one: **parallelism** (do the candidate issues
touch disjoint files?), **difficulty** (a research issue and a refactor are very
different lane lengths), and **dependency** (does one issue's output define
another's input?). Prefer a set that is genuinely disjoint over the three
highest-value issues — value you cannot land without conflicts is not value.

### Reporting back

Close the loop on GitHub rather than in the terminal, since that is what survives
the session. Per lane: open a PR whose body carries **evidence you re-ran
yourself**, not the lane agent's claims repeated. Independently re-running
`tsc`/tests takes seconds and occasionally catches a lane that reported success it
did not have. State plainly what you could *not* verify.

For UI work, attach real screenshots via the Chrome MCP tools against a running dev
server. This requires the app to actually boot — if the project cannot start (no
database, missing credentials), say so in the PR instead of substituting a
description of what the UI would look like.

File follow-up issues for findings that are real but out of a lane's scope. When two
lanes independently reach the same conclusion, that convergence is strong evidence
and worth filing as a bug rather than a note.

## `idle` does not mean finished

Herdr's `idle` means the agent is ready for input, not that its work is complete.
An agent can settle briefly between phases, and any prompt you send — including a
request for a closing summary — can wake it into more work.

This is not theoretical: a lane went idle, its PR was opened and merged, and the
agent then produced a second commit answering the very question its own PR had
listed as unverifiable. That work was nearly discarded.

Before treating a lane as done, require **git evidence, not just state**: a commit
that actually addresses the issue, a clean tree, and checks you re-ran. When a lane
goes idle a second time after you thought it was finished, re-read it rather than
assuming it is noise.

## Recycle only when something forces it

Retiring a lane is not routine hygiene after a merge. Keep it.

The transcript survives teardown regardless — it lives under `~/.claude/projects/`
keyed by the worktree path, and outlives both the pane and the directory. What
teardown actually costs you is the **live** session: while the pane is alive you
can ask the agent a follow-up, and it still holds all its context. That is worth
more than the directory it occupies.

So recycle when disk or clutter genuinely demands it, not on a schedule. When you
do, record the Claude session id and the exact resume command in the archive:

```bash
git worktree add "<worktree-path>" <branch>
cd "<worktree-path>" && claude --resume <session-id>
```

The project-directory name is the absolute worktree path with `:` `/` `\` and `.`
each replaced by `-`.

## Never let teardown destroy the reasoning

A lane's closing summary is where its open questions, unverified assumptions and
"needs a human decision" items live. The branch preserves the code; nothing
preserves that. Retiring a lane must not be how it disappears.

`herdr agent read` is not sufficient on its own — a long completed response has
usually scrolled off the terminal's alternate screen, and those rows never enter
Herdr's host scrollback, so the read returns a near-empty pane. Before teardown,
prompt the still-idle agent to write its full summary to an absolute path
**outside its worktree** (writing inside would dirty the tree), wait for it, then
archive that file alongside the pane read.

Put the decisions in the PR body too. The archive is the backstop for everything
that never makes it there.

## Teardown

```bash
herdr worktree remove --workspace <wN> --force   # drops worktree + workspace
git branch -D <branch>                           # branch survives; remove it too
git worktree prune                               # after any repo move or rename
```

## Keeping the skill and the project copy in sync

`herd.sh` here and `<repo>/.claude/herd.sh` are kept **byte-identical**, so syncing
is `cp` in either direction and drift is impossible. An earlier split — where the
project copy hardcoded npm and the template carried a portability block — silently
lost a bug fix that was only applied to one side. If you find yourself
special-casing the project copy, push the behaviour behind `CHECK_CMD` in
`.claude/fleet.conf` instead of forking the file.

Whenever you change the manager's behaviour, change it here too, in the same
commit. `diff -q` the two before you finish.

## Manager helper script

`herd.sh` in this skill directory is a portable manager wrapper: fleet status,
reading a transcript, prompting, running checks, and staging a squash. Copy it to
`<repo>/.claude/herd.sh` and set `CHECK_CMD` in `<repo>/.claude/fleet.conf` if the
project is not npm-based. If the repo allowlists paths in `.gitignore`, add the
script there so it stays versioned.

Use `git diff --numstat`, not `git status --porcelain`, for "is this tree dirty".
On repos with mixed line endings `status` reports CRLF-only churn as modified and
every gate you build on it will refuse to run.
