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
copy in whatever is gitignored but required (`.env`, credentials), and give the
lane its **own** dependency install — `npm ci`, `cargo fetch`, `uv sync`. Do not
link or symlink a shared dependency tree; see "Isolation is weaker than it looks"
below for why that fails in practice. Assert the install actually produced
executables (`node_modules/.bin`, or the equivalent) before starting the agent, so
a half-install fails loudly here instead of silently three lanes later.

Then start the agent in the pane that `worktree create` returned:

```bash
herdr agent start <name> --kind claude --pane <wN:p1> --timeout 90000
```

## Size the lane to the problem

Lanes inherit the user's default model unless told otherwise, which usually means
every lane runs the largest one — including the lane writing a document. Choose
per lane:

```bash
./.claude/herd.sh launch 42 slug --model sonnet --effort medium
```

`--model` takes `opus`, `sonnet` or `fable` (or a full model name); `--effort`
takes `low`, `medium`, `high`, `xhigh` or `max`. Omit either to inherit the
session default.

Match **reasoning demand, not diff size**. A 2,000-line generated dataset is
mechanical; a 40-line change to a security header is not.

| shape of work | suggested |
|---|---|
| security, auth, data-model or migration work | `opus`, `high`+ |
| cross-cutting change touching many files at once | `opus`, `high` |
| a subtle policy change — CSP, caching, access control | `opus`, `high` |
| feature build against an existing reference implementation | `opus` or `sonnet`, `medium` |
| scraper or transform with a worked example to copy | `sonnet`, `medium` |
| tests, mechanical refactor, docs, research write-up | `sonnet`, `low`–`medium` |

Two cautions from practice. **Do not size down anything that touches security,
money, migrations or user-visible data** — the cost of a missed subtlety there
dwarfs the saving, and audits are exactly where the expensive model earns its
keep. And **a "documentation" issue often is not one**: a lane briefed to write a
marketing strategy shipped 24 files including a blog engine and an embeddable
widget, because the issue implied the build. Read what the issue actually asks for
before sizing it.

State the model and effort you chose, and why, when you report the lane. It is a
spend decision the user may want to overrule.

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
- **Merge authority is the user's to set, and worth asking about once.** Default to
  staging squashes and letting a person land `main`; if the user grants merge
  rights, use them and land lanes one at a time, re-running checks after each, so a
  conflict has one obvious author. Either way, keep a human gate on the genuinely
  irreversible: applying migrations, reseeding live data, anything that changes what
  users see. Say what the change will look like to a user before doing it.
- **Prefer waiting to polling.** `herdr agent wait <name> --until blocked` and
  `--wait` on prompts are event-driven. A status loop on a short timer burns tokens
  across every lane at once for no new information.

This plugin ships a `PreToolUse` hook that denies `Edit`/`Write` in the main
checkout while HEAD is on the repository's default branch, which makes the
review-only role **structural rather than advisory** — the manager cannot write
feature code even by mistake. It activates on install; a target repo needs no hook
file and no settings entry of its own. Work inside `.claude/worktrees/` and files
outside the repository are unaffected.

When that guard blocks you, it is telling you the work belongs in a lane. Open one,
or ask the user — do not look for an equivalent action it does not cover.

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

Rank by **value first, then feasibility**. The failure mode is picking issues
because they cannot collide — that optimises for the manager's convenience and
fills lanes with low-value work while the thing the user actually cares about sits
untouched. If the highest-value issue needs a clear field, give it one: run it
alone rather than running three cheap issues around it.

Score each candidate on:

- **Value** — what the user has said matters, what a review or audit has flagged as
  actually broken, what unblocks other work. Their stated priorities outrank your
  sense of tidiness.
- **Dependency** — does one issue's output define another's input? A scraper
  rewrite that depends on an unmerged schema is not ready, however attractive.
- **Parallelism** — do the candidates touch disjoint files? This is a *tiebreaker
  among comparable issues*, not the primary axis.
- **Shape** — a research issue, a refactor and a UI overhaul have very different
  lane lengths. Mixing lengths is fine; mixing a repo-wide refactor with anything
  else is not.

Say out loud why you picked what you picked, and re-rank when the user pushes
back — they can see value you cannot.

### Keeping the fleet fed

Lanes finish at different times, so the fleet drains unless something refills it.
Three mechanisms, in order of how much they actually deliver:

- **Event-driven refill (best).** `herd.sh watch` armed with the Monitor tool wakes
  you when a lane settles; review it, land it, and launch the next issue in the
  same turn. This keeps the fleet full while a session is alive.
- **A local scheduled task** (cron, or Windows Task Scheduler) that starts a fresh
  manager session on an interval. This is the only mechanism that survives the
  session ending, because it can open a real terminal. Give it an explicit lane cap.
- **A scheduled cloud agent** can work the *repository* on a schedule — claim an
  issue, open a PR — but it **cannot drive a local multiplexer**: it has its own
  sandbox and cannot see the machine. Do not promise a cloud routine will refill
  local lanes. Coordinate it with the local fleet through a claim label on the
  issue tracker so the two never pick the same issue.

There is no API for "how much quota is left", so nothing can literally wait for a
reset. An interval task fires and either works or fails cheaply.

**The fleet multiplies token spend**, roughly linearly in lane count — that is the
trade you make for wall-clock parallelism. If the account allows billable usage
beyond its plan, an unattended refill loop is exactly the shape that runs into it.
Cap the lanes, and say plainly what the fleet is costing when the user asks.

### Verify what lanes tell you

A lane agent's summary is evidence, not testimony. Re-run its checks yourself —
it takes seconds and it occasionally catches a lane that reported success it did
not have. More importantly, lanes reason from stale premises: one reported that it
had corrupted a shared dependency tree, from documentation describing a design that
had already been replaced; it had not. Another wrote that stale premise into shared
project memory, where it would have misled every future session.

So: **check a lane's factual claims against the repository before acting on them,
and before repeating them to the user.** If lanes can write to shared memory or
docs, audit what they wrote — a confidently-worded wrong memory outlives the lane
that created it.

Convergence is the opposite signal and worth acting on: when two lanes reach the
same conclusion from different evidence, that is strong, and worth filing as a bug
rather than a note.

### Keep working; escalate rarely

The manager's default is to **continue**, not to check in. A manager that pauses
after every landed PR to confirm the next obvious step has moved the work back
onto the user, which is the opposite of the point. Land what is green, rebase what
conflicts, open the next lane, and keep going until the queue is empty or
something genuinely blocks.

Escalate only these, and say plainly why:

- **Irreversible and user-visible.** Applying a migration, reseeding live data,
  changing figures people will read, anything that spends money. Describe what it
  will look like to a user, then do it once told.
- **A `blocked` lane.** It is sitting on an approval dialog. Read it, report it,
  never answer on its behalf.
- **A genuine product decision** with no defensible default — which of two
  legitimate behaviours the user wants, not which of two implementations you
  prefer.
- **A safety layer refused you.** Report the refusal; never route around it.

Everything else is yours: merging green PRs, resolving conflicts, rebasing,
filing issues, opening lanes, fixing bugs you find on the way. Asking permission
for reversible work is not caution, it is offloading.

When you do have a real question, do not stop the world for it. Ask it, then keep
working on everything that does not depend on the answer.

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

**Leave an end-of-day trail.** Working without check-ins only works if the user
can reconstruct what happened afterwards. `herd.sh report` builds that from git
and the forge rather than a hand-kept file, so it cannot drift from reality: what
landed, what merged, what is still open, what each lane is doing, and every "needs
a human decision" item collected out of the lane archives. Run it when you stop,
and whenever the user asks what has been going on.

The report is a summary, not the record. The record is the PR bodies, the issues
you filed, and the lane archives — write those as though the only person reading
them arrives tomorrow with no memory of the session, because that is the case.

File follow-up issues for findings that are real but out of a lane's scope. When two
lanes independently reach the same conclusion, that convergence is strong evidence
and worth filing as a bug rather than a note.

**Working through the issue tracker.** The tracker, not the terminal, is the fleet's
shared state:

- **Claim before working.** Add a label (`fleet:in-progress`) to an issue the moment
  a lane takes it, and skip anything already claimed or already carrying an open PR.
  This is what stops two lanes — or a local lane and a scheduled cloud agent — from
  doing the same work twice. Release the claim if a lane fails.
- **Close through the commit.** Have lanes end their commit message with the
  tracker's closing keyword, so merging the PR closes the issue with no extra step.
- **Record decisions where they survive.** Every "needs a human decision" item goes
  in the PR body, not just the lane's pane. The pane is ephemeral; a reviewer coming
  back tomorrow reads the PR.
- **Comment on every issue you land.** `land` refuses a lane that has not written
  `.claude/lane-summary.md`, and `document <agent>` posts it to the issue. Three
  headings, always: **What was done** (concrete, naming the change rather than the
  intention), **Still needs a human** (every open decision, or the literal word
  `nothing` — never blank, because blank and "nothing" read identically and usually
  mean "never considered"), and **Verified** (the checks actually run, and what
  could not be checked). The summary is captured *before* the merge, while the agent
  that knows the answers is still alive and holding its context.

  Do not treat this as paperwork. A fleet that closes seventeen issues in a week and
  comments on none of them has produced a repository its owner cannot read: the work
  is invisible, and "what needs my attention?" has no answer anywhere. That is a real
  failure, and it is the default outcome unless landing enforces otherwise.
- **Sequence conflicting PRs explicitly.** When two lanes touch the same file, say in
  both PR bodies which lands first and why, then rebase the second rather than
  letting a merge queue guess.

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

## Frictions worth knowing before they cost an hour

Each of these was diagnosed the slow way once.

**Tools glob into your worktrees.** Worktrees living inside the repo
(`.claude/worktrees/`) are visible to every tool with a default include pattern.
A test runner will collect each lane's test files and run them against the main
checkout, where their mocks do not resolve — phantom failures with nothing wrong
in either tree. Linters do the same. Exclude the worktree directory in every such
config (`**/.claude/**`), and suspect this first when the main checkout fails
tests that pass inside every lane.

**Codegen is per-worktree.** Anything that generates into the dependency tree —
ORM clients, protobuf, OpenAPI — must be re-run in each lane. A fresh worktree
whose typecheck explodes with hundreds of missing-type errors usually needs the
generator run, not debugging.

**Line-ending churn breaks dirty checks.** On a repo with `core.autocrlf` and no
`.gitattributes`, `git status --porcelain` reports files as modified with zero
content change. That blocks rebases and makes every "is this tree clean?" gate
unreliable. Use `git diff --numstat`, which compares content after normalisation,
and fix the root cause with `* text=auto` in `.gitattributes`.

**Decode subprocess output explicitly.** On Windows, Python defaults to the ANSI
codepage, so reading multiplexer JSON crashes on the first non-ASCII agent title.
Decode UTF-8 with a replacement policy.

**Tear the lane down before deleting its branch.** A worktree holds a checkout of
its branch, so `--delete-branch` on a merge fails while the lane exists. Recycle
first, then delete.

**CI may not fire on a push to an existing PR branch.** Where pushes authenticate
with an automation token, the forge deliberately suppresses workflow triggers to
avoid recursion — so a PR opened by CLI gets a run, but a later push to the same
branch silently gets none, even though the PR head advanced. Check that a run
actually exists rather than assuming; if it does not, your local verification is
the evidence, and say so.

**Permission rules match a whole command.** A rule allowing one command will not
match it chained after another with `&&`. Run privileged commands standalone.

**A safety layer denying an action is information, not an obstacle.** If a merge
or a settings write is refused, do not reach for an equivalent that happens not to
be covered — that defeats the purpose of the denial. Report what you were trying
to do and let the user decide.

## Teardown

```bash
herdr worktree remove --workspace <wN> --force   # drops worktree + workspace
git branch -D <branch>                           # branch survives; remove it too
git worktree prune                               # after any repo move or rename
```

## Where the manager script lives

The plugin ships `scripts/herd.sh` and it is the **single source of truth**.
`/fleet-init` copies it to `<repo>/.claude/herd.sh`; that copy is disposable.

- Never edit the repo copy. Fix the plugin, `/plugin update agent-fleet`, re-copy.
- Never fork it per project. If a project needs different checks, that belongs in
  `<repo>/.claude/fleet.conf` as `CHECK_CMD`, not in a modified script.
- If the repo's `.gitignore` allowlists paths under `.claude/`, add the script so it
  stays versioned, and ignore `.claude/fleet-archive/`.

An earlier version of this pattern kept two hand-synced copies. They drifted, and a
bug fix reached only one side — which is the whole reason the script is packaged
rather than pasted.

`herd.sh` provides: `status`, `launch`, `watch`, `report`, `archive`, `recycle`,
`read`, `say`, `check`, `document`, `land`. Run it with no arguments for usage.

`launch` takes `--model opus|sonnet|fable` and `--effort low|medium|high|xhigh|max`.
Choose both from the issue rather than by habit: a one-file mechanical fix does not
need Opus at `xhigh`, and a design or data-modelling issue is badly served by less.

`report` reconstructs the window from git and the forge — **not** from lane
archives. It once read only archives, which are written on teardown, and since
lanes are deliberately not torn down it reported "(none recorded)" while twenty
open decisions sat unread. The general rule: never source status from an artefact
that only exists after cleanup.

Use `git diff --numstat`, not `git status --porcelain`, for "is this tree dirty".
On repos with mixed line endings `status` reports line-ending-only churn as
modified and every gate built on it will refuse to run.
