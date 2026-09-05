#!/usr/bin/env bash
# Manager-side control for a Herdr agent fleet.
# The plugin copy is the single source of truth; /fleet-init copies it to
# <repo>/.claude/herd.sh. Never edit the repo copy. Per-repo settings live in
# <repo>/.claude/fleet.conf (see "fleet.conf keys" below). See the agent-fleet
# skill for the surrounding pattern.
#
# Topology: one Herdr workspace per git worktree, one Claude agent per workspace.
# The manager runs in w1 (the main checkout, on `main`). Pair it with a PreToolUse
# hook that denies Edit/Write there so the review-only role is enforced, not just
# intended -- the manager then cannot edit feature code even by mistake.
#
#   ./.claude/herd.sh status            # lifecycle + git state for every lane
#   ./.claude/herd.sh plan <n> <file>   # post the manager's plan for issue <n> to the issue
#   ./.claude/herd.sh deps <n>          # are issue <n>'s dependencies closed?
#   ./.claude/herd.sh collisions [n..]  # files two or more planned issues both touch
#   ./.claude/herd.sh launch <n> <slug> [name] [--model M] [--effort L] [--force] [--no-plan]
#   ./.claude/herd.sh brief <agent>     # (re)send the opening brief to an idle lane
#   ./.claude/herd.sh watch             # event stream of lane state changes (incl. stale)
#   ./.claude/herd.sh report [since]    # what the fleet did, for a human catching up
#   ./.claude/herd.sh archive <agent>   # snapshot a lane's transcript, no teardown
#   ./.claude/herd.sh recycle <agent>   # archive, then retire a fully-pushed lane (chat is kept)
#   ./.claude/herd.sh resume <agent>    # reopen a recycled lane's chat in a new pane, context intact
#   ./.claude/herd.sh read <agent> [n]  # last n lines of an agent's transcript
#   ./.claude/herd.sh say <agent> <txt> # prompt an agent
#   ./.claude/herd.sh check <agent>     # lint+test+build that agent's worktree
#   ./.claude/herd.sh review <agent>    # independent headless review; verdict to the issue
#   ./.claude/herd.sh document <agent>  # post the lane's summary to its issue
#   ./.claude/herd.sh pr <agent>        # check, review, push, open a PR with evidence, merge when CI is green
#   ./.claude/herd.sh merge <agent>     # wait for the PR's checks, squash-merge it, update main
#   ./.claude/herd.sh land <agent> [--pr] [--no-review] [--no-merge]   # check, review, summary, then squash (or PR + merge)
#
# fleet.conf keys (all optional):
#   CHECK_CMD      lint + test + build command run inside a lane
#   INSTALL_CMD    dependency install; overrides toolchain detection
#   CODEGEN_CMD    per-worktree codegen (ORM clients etc.)
#   REQUIRE_PLAN   1 (default): launch refuses an issue that has no fleet plan comment
#   LAND_MODE      squash (default) | pr
#   AUTO_MERGE     1 (default): in pr mode, land/pr wait for CI and merge -- the manager merges, not a person
#   AUTO_RECYCLE   1 (default): merge then recycles the lane (archive, remove worktree + pane, drop local branch)
#   REVIEW_MODEL   model for `review` (default sonnet)
#   STALE_MIN      minutes idle with no new commit before `watch` says stale (default 30)
#   LANE_MODEL / LANE_EFFORT   defaults for launch when the plan and flags say nothing
#
# Agent names are set at `herdr agent start` time and follow the pane.
set -uo pipefail

# Every python helper below prints text that came from the forge or from an
# agent: plans, issue bodies, titles. On Windows, Python's stdout defaults to
# the ANSI code page, and the first character outside it (an arrow in a plan,
# a Hebrew title) raises UnicodeEncodeError inside a helper whose failure is
# swallowed -- which surfaced as "no fleet plan on #2" for a plan that was
# plainly there. Force UTF-8 in both directions for every child process.
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8

REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
WT="$REPO/.claude/worktrees"
ARCHIVE="$REPO/.claude/fleet-archive"
PLAN_MARK='<!-- fleet:plan -->'
REVIEW_MARK='<!-- fleet:review -->'

die() { printf 'herd: %s\n' "$*" >&2; exit 1; }
warn() { printf 'herd: %s\n' "$*" >&2; }

# Source <repo>/.claude/fleet.conf once and apply defaults. Every command that
# reads a setting goes through here, so a key added to the conf reaches all of
# them rather than only the one that happened to source the file.
load_conf() {
  local conf="$REPO/.claude/fleet.conf"
  # shellcheck disable=SC1090
  [ -f "$conf" ] && . "$conf"
  REQUIRE_PLAN="${REQUIRE_PLAN:-1}"
  LAND_MODE="${LAND_MODE:-squash}"
  AUTO_MERGE="${AUTO_MERGE:-1}"
  AUTO_RECYCLE="${AUTO_RECYCLE:-1}"
  REVIEW_MODEL="${REVIEW_MODEL:-sonnet}"
  STALE_MIN="${STALE_MIN:-30}"
  LANE_MODEL="${LANE_MODEL:-}"
  LANE_EFFORT="${LANE_EFFORT:-}"
  CHECK_CMD="${CHECK_CMD:-}"
  INSTALL_CMD="${INSTALL_CMD:-}"
  CODEGEN_CMD="${CODEGEN_CMD:-}"
}

# Resolve an agent name to the worktree path its pane is sitting in.
wt_of() {
  herdr agent get "$1" 2>/dev/null | python -c '
import sys, json
try: print(json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))["result"]["agent"]["cwd"])
except Exception: pass'
}

# Content-level dirty check. `git status --porcelain` flags CRLF-only churn as
# modified, which on this repo is ~20 files at rest -- numstat compares content
# after eol normalization, so it stays empty for pure line-ending noise.
content_dirty() {
  local n
  n=$(git -C "$1" diff --numstat 2>/dev/null | grep -c . || true)
  n=$((n + $(git -C "$1" diff --cached --numstat 2>/dev/null | grep -c . || true)))
  echo "$n"
}

issue_of_branch() { printf '%s' "$1" | sed -n 's/^issue-\([0-9][0-9]*\)-.*/\1/p'; }

# gh resolves the repository from the working directory. The manager usually
# runs this script from the repo root, but not always (a portfolio wrapper, a
# scheduled task, a lane's own worktree) -- so every forge call runs from $REPO.
ghr() { ( cd "$REPO" && gh "$@" ); }

# ---------------------------------------------------------------------------
# Plans. The manager plans; the lane implements. The plan is an issue comment
# (durable, visible to the owner, readable by the lane with `gh issue view
# --comments`) that starts with PLAN_MARK. The Files section is what makes
# the collision surface derivable instead of guessed.
# ---------------------------------------------------------------------------

# plan_of <issue> -- the latest plan comment body, or nothing.
plan_of() {
  command -v gh >/dev/null 2>&1 || return 0
  ghr issue view "$1" --json comments 2>/dev/null | PLAN_MARK="$PLAN_MARK" python -c '
import sys, json, os
mark = os.environ["PLAN_MARK"]
try:
    d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
    bodies = [c["body"] for c in d.get("comments", []) if mark in c.get("body", "")]
    if bodies:
        print(bodies[-1])
except Exception:
    pass'
}

# plan_section <heading> -- read a plan on stdin, print the body of "## <heading>".
plan_section() {
  H="$1" python -c '
import sys, os, re
want = os.environ["H"].strip().lower()
out, on = [], False
for line in sys.stdin.buffer.read().decode("utf-8", "replace").splitlines():
    m = re.match(r"^\s*##\s+(.*?)\s*$", line)
    if m:
        on = (m.group(1).strip().lower() == want)
        continue
    if on:
        out.append(line)
print("\n".join(out).strip())'
}

# plan_files <issue> -- one path per line from the plan's Files section.
plan_files() {
  plan_of "$1" | plan_section "Files" | sed -n 's/^[[:space:]]*[-*]\{0,1\}[[:space:]]*\(create\|modify\|delete\):[[:space:]]*`\{0,1\}\([^` ]*\)`\{0,1\}.*$/\2/p'
}

# plan_lane <issue> <key> -- "model" or "effort" from the plan's Lane section.
plan_lane() {
  plan_of "$1" | plan_section "Lane" | sed -n "s/.*$2:[[:space:]]*\([A-Za-z0-9._-]*\).*/\1/p" | head -1
}

# plan <issue> <file> -- validate and post the manager's plan for an issue.
# The manager writes the file OUTSIDE the repo (the guard hook blocks Write in
# the main checkout); this command posts it and keeps a mirror in the archive.
cmd_plan() {
  local issue="$1" file="$2" h missing=""
  [ -s "$file" ] || die "plan file '$file' is missing or empty"
  command -v gh >/dev/null 2>&1 || die "gh is not available"
  for h in Approach Files Interfaces Tests "Out of scope" Lane; do
    grep -qiE "^[[:space:]]*##[[:space:]]+$h[[:space:]]*$" "$file" || missing="$missing '## $h'"
  done
  [ -z "$missing" ] || die "plan is missing required headings:$missing"
  local nfiles
  nfiles="$(plan_section "Files" < "$file" | grep -cE '^[[:space:]]*[-*]?[[:space:]]*(create|modify|delete):' || true)"
  [ "$nfiles" -gt 0 ] || die "plan's '## Files' must list at least one 'create:' or 'modify:' path"
  if [ "$nfiles" -gt 8 ]; then
    warn "plan lists $nfiles files -- consider splitting the issue before launching (see the skill: 'Plan before launch')"
  fi
  mkdir -p "$ARCHIVE/plans"
  local tmp; tmp="$(mktemp)"
  { echo "$PLAN_MARK"; echo; cat "$file"; } > "$tmp"
  ghr issue comment "$issue" --body-file "$tmp" >/dev/null || { rm -f "$tmp"; die "failed to comment on issue #$issue"; }
  cp "$tmp" "$ARCHIVE/plans/issue-${issue}.md"; rm -f "$tmp"
  # The forge is read-after-write eventually consistent: a launch issued right
  # after this returned once saw no plan. Wait until the comment reads back.
  local i
  for i in $(seq 1 10); do
    [ -n "$(plan_of "$issue")" ] && break
    sleep 2
  done
  [ -n "$(plan_of "$issue")" ] || warn "plan posted to #$issue but not yet readable through the API; retry launch in a few seconds"
  echo "planned #$issue ($nfiles files) -> issue comment + $ARCHIVE/plans/issue-${issue}.md"
}

# collisions [issue..] -- paths two or more planned issues both intend to touch.
# Issues come from the live lanes plus any numbers given. Exit 1 if any overlap,
# so launch can fold the result into the lane's brief.
cmd_collisions() {
  local issues="" d n st
  for d in "$WT"/issue-*/; do
    [ -e "$d/.git" ] || continue
    n="$(issue_of_branch "$(basename "$d")")"
    [ -n "$n" ] || continue
    # Lanes are not recycled by default, so a merged lane's worktree lingers.
    # Its issue is closed; its files are on main, not a live collision.
    st="$(ghr issue view "$n" --json state -q .state 2>/dev/null || echo OPEN)"
    [ "$st" = "CLOSED" ] && continue
    issues="$issues $n"
  done
  issues="$issues $*"
  local tmp; tmp="$(mktemp)"
  for n in $(printf '%s\n' $issues | sort -un); do
    plan_files "$n" | sed "s/\$/\t#$n/" >> "$tmp"
  done
  python - "$tmp" <<'PY'
import sys, collections
by = collections.defaultdict(set)
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.rstrip("\n")
    if "\t" not in line: continue
    path, issue = line.rsplit("\t", 1)
    by[path.strip()].add(issue)
hits = {p: sorted(i) for p, i in by.items() if len(i) > 1}
for p in sorted(hits):
    print("%s\t%s" % (p, " ".join(hits[p])))
sys.exit(1 if hits else 0)
PY
  local rc=$?
  rm -f "$tmp"
  return $rc
}

# deps <issue> -- exit 1 if the issue's "## Depends on" section names an open
# issue by number. Titles without numbers are reported but cannot be checked.
cmd_deps() {
  local issue="$1" body sec rc=0 n st line
  command -v gh >/dev/null 2>&1 || die "gh is not available"
  body="$(ghr issue view "$issue" --json body -q .body 2>/dev/null)" || die "cannot read issue #$issue"
  sec="$(printf '%s\n' "$body" | plan_section "Depends on")"
  [ -n "$sec" ] || { echo "#$issue: no dependencies declared"; return 0; }
  for n in $(printf '%s\n' "$sec" | grep -oE '#[0-9]+' | tr -d '#' | sort -un); do
    st="$(ghr issue view "$n" --json state -q .state 2>/dev/null || echo UNKNOWN)"
    if [ "$st" = "OPEN" ]; then echo "#$issue depends on #$n which is still OPEN"; rc=1
    else echo "#$issue depends on #$n ($st)"; fi
  done
  while IFS= read -r line; do
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*[-*]\{0,1\}[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$line" ] || continue
    printf '%s' "$line" | grep -qE '#[0-9]+' && continue
    printf '%s' "$line" | grep -qiE '^(none|nothing)' && continue
    warn "#$issue depends on '$line' -- named by title, cannot check; confirm it is merged"
  done <<< "$sec"
  return $rc
}

# ---------------------------------------------------------------------------
# Status and watch
# ---------------------------------------------------------------------------

cmd_status() {
  herdr agent list 2>/dev/null | python -c '
import sys, json
rows = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))["result"]["agents"]
print("AGENT          PANE    STATE     TITLE")
for a in sorted(rows, key=lambda r: r["pane_id"]):
    name = a.get("name") or "(manager)"
    print("%-14s %-7s %-9s %s" % (
        name, a["pane_id"], a["agent_status"],
        a.get("terminal_title_stripped", "")[:46]))'
  printf '\n%-30s %-26s %s\n' "WORKTREE" "BRANCH" "AHEAD/DIRTY"
  for d in "$WT"/*/; do
    [ -e "$d/.git" ] || continue
    local n b ahead dirty
    n="$(basename "$d")"
    b="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)" || continue
    ahead="$(git -C "$d" rev-list --count origin/main..HEAD 2>/dev/null || echo '?')"
    dirty="$(content_dirty "$d")"
    printf '%-30s %-26s +%s commits, %s dirty\n' "$n" "$b" "$ahead" "$dirty"
  done
}

# Event stream for Monitor: one line per lane transition into a settled state.
# Silence must never mean "still fine" -- blocked, vanished, exited AND stale
# lanes all emit, otherwise a crashed or quietly-given-up lane is
# indistinguishable from a working one.
cmd_watch() {
  HERD_STALE_MIN="$STALE_MIN" HERD_WT="$WT" HERD_REPO="$REPO" python -u -c '
import json, subprocess, time, os

STALE = float(os.environ.get("HERD_STALE_MIN") or 30) * 60
# Herdr lists every agent in the session, across repositories. Only lanes whose
# cwd is under THIS repo'"'"'s worktree directory are ours to report.
WT = os.path.normcase(os.path.abspath(os.environ.get("HERD_WT") or ".")).replace("\\", "/").rstrip("/") + "/"

def ours(a):
    cwd = (a.get("cwd") or "")
    return os.path.normcase(os.path.abspath(cwd)).replace("\\", "/").startswith(WT)

def sh(args, cwd=None):
    try:
        r = subprocess.run(args, capture_output=True, timeout=30, cwd=cwd)
        return r.stdout.decode("utf-8", "replace").strip()
    except Exception:
        return None

def poll():
    out = sh(["herdr", "agent", "list"])
    if out is None:
        return None  # transient: never kill the watch over one bad poll
    try:
        return {a["name"]: a for a in json.loads(out)["result"]["agents"] if a.get("name") and ours(a)}
    except Exception:
        return None

def head(cwd):
    return sh(["git", "-C", cwd, "rev-parse", "--short", "HEAD"]) or "?"

# A landed lane is not recycled by default, so it sits idle forever and would
# be reported stale every STALE window. Its issue is closed; check that at most
# once per ten minutes per lane and stop treating it as a live lane.
import re as _re
REPO = os.environ.get("HERD_REPO") or "."
_closed = {}
def landed(name, cwd):
    m = _re.search(r"issue-(\d+)-", os.path.basename(cwd.rstrip("/\\")))
    if not m:
        return False
    st, t = _closed.get(name, (None, 0))
    if time.time() - t > 600:
        out = sh(["gh", "issue", "view", m.group(1), "--json", "state", "-q", ".state"], cwd=REPO)
        st = (out or st or "OPEN").strip()
        _closed[name] = (st, time.time())
    return st == "CLOSED"

SETTLED = {"idle", "done", "blocked"}
# Announce a (lane, state, commit) combination at most once. A pane that settles,
# wakes and settles again with no new commit is noise, and the fleet generates a
# lot of it after a restart -- but a lane that settles again ON A NEW COMMIT has
# genuinely done more work and must still be heard.
seen = set()
prev = set()
# idle_since[name] = (head, time first seen idle at that head). A lane idle for
# STALE seconds with no new commit has probably given up without saying so.
idle_since = {}
last_cwd = {}
first = True
while True:
    cur = poll()
    if cur is not None:
        now = time.time()
        for name, a in sorted(cur.items()):
            st = a["agent_status"]
            if st not in SETTLED:
                idle_since.pop(name, None)
                continue
            if landed(name, a.get("cwd") or "."):
                continue  # merged and closed; nothing it does now is fleet news
            h = head(a.get("cwd") or ".")
            key = (name, st, h)
            if key not in seen:
                seen.add(key)
                # blocked always speaks: it means a human is being waited on.
                if not (first and st == "idle"):
                    print("LANE %s -> %s @%s (pane %s)" % (name, st, h, a["pane_id"]))
            if st == "idle" and not landed(name, a.get("cwd") or "."):
                ph, t0 = idle_since.get(name, (None, now))
                if ph != h:
                    idle_since[name] = (h, now)
                elif now - t0 > STALE and (name, "stale", h) not in seen:
                    seen.add((name, "stale", h))
                    print("LANE %s -> stale (idle %d min, no new commit @%s, pane %s)"
                          % (name, int((now - t0) // 60), h, a["pane_id"]))
        for name in sorted(prev - set(cur)):
            idle_since.pop(name, None)
            # Re-check the issue: it was open when the lane settled and has
            # usually been closed by the merge that recycled the lane since.
            _closed.pop(name, None)
            if landed(name, last_cwd.get(name, ".")):
                continue  # recycled after merge; expected
            print("LANE %s -> vanished (pane closed or agent exited)" % name)
        for name, a in cur.items():
            last_cwd[name] = a.get("cwd") or "."
        prev = set(cur)
        first = False
    time.sleep(20)
'
}

# ---------------------------------------------------------------------------
# Archive, summary, document
# ---------------------------------------------------------------------------

# archive_lane <agent> <worktree> <branch> -- durable snapshot of a lane.
# A lane's closing summary carries its "needs a human decision" items, and the
# pane is the only place they exist until someone copies them out. Recycling must
# never be how that gets lost.
archive_lane() {
  local a="$1" d="$2" b="$3" stamp out sid
  mkdir -p "$ARCHIVE"
  # The Claude session id makes a torn-down lane resumable: the transcript lives
  # on under ~/.claude/projects/ keyed by the worktree path, and survives both
  # the pane and the directory.
  sid="$(herdr agent get "$a" 2>/dev/null | python -c '
import sys, json
try: print(json.loads(sys.stdin.buffer.read().decode("utf-8","replace"))["result"]["agent"]["agent_session"]["value"])
except Exception: pass')"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  out="$ARCHIVE/${a}-${b}-${stamp}.md"
  {
    echo "# Lane archive: $a"
    echo
    echo "- agent: \`$a\`"
    echo "- branch: \`$b\`"
    echo "- worktree: \`$d\`"
    echo "- archived: $stamp"
    echo "- head: \`$(git -C "$d" rev-parse --short HEAD 2>/dev/null)\`"
    echo "- claude session: \`${sid:-unknown}\`"
    echo
    echo "## Resume this conversation"
    echo
    echo "The transcript outlives the pane and the worktree. To reopen it:"
    echo
    echo '```bash'
    echo "# recreate the worktree if it is gone, then:"
    echo "git worktree add \"$d\" $b"
    echo "cd \"$d\" && claude --resume ${sid:-<session-id>}"
    echo '```'
    echo
    echo "Transcript on disk (readable without resuming):"
    echo '```'
    echo "~/.claude/projects/$(echo "$d" | sed 's|[:/\\._]|-|g')/${sid:-<session-id>}.jsonl"
    echo '```'
    echo
    echo "## Commits"
    echo '```'
    git -C "$d" log --oneline origin/main..HEAD 2>/dev/null
    echo '```'
    echo
    echo "## Files changed"
    echo '```'
    git -C "$d" diff --numstat origin/main...HEAD 2>/dev/null
    echo '```'
    echo
    if [ -s "$ARCHIVE/${a}-${b}-summary.md" ]; then
      echo "## Agent's own closing summary"
      echo
      cat "$ARCHIVE/${a}-${b}-summary.md"
      echo
    fi
    echo "## Transcript (tail)"
    echo '```'
    herdr agent read "$a" --source recent-unwrapped --lines 400 2>/dev/null
    echo '```'
  } > "$out"
  echo "$out"
}

cmd_archive() {
  local a="$1" d b
  d="$(wt_of "$a")"; [ -n "$d" ] && [ -d "$d" ] || die "no worktree for agent '$a'"
  b="$(git -C "$d" rev-parse --abbrev-ref HEAD)"
  echo "archived -> $(archive_lane "$a" "$d" "$b")"
}

# Ask a lane to write its own closing summary, and leave it at
# <worktree>/.claude/lane-summary.md. Returns non-zero if nothing was written.
#
# The target must be INSIDE the agent's own worktree: a lane agent is scoped to
# its cwd and cannot write elsewhere without an approval prompt, which is what
# made an archive-directory path fail silently. .claude/ is gitignored in the
# worktree, and `git diff` ignores untracked files anyway, so this cannot dirty
# the tree the landing checks require clean.
#
# `agent read` is not a substitute: it recovers only what is still on screen,
# and a long closing summary has usually scrolled off the alternate screen.
capture_summary() {
  local a="$1" d="$2" dump
  dump="$d/.claude/lane-summary.md"
  mkdir -p "$d/.claude"
  [ -s "$dump" ] && return 0
  herdr agent prompt "$a" "Write a COMPLETE summary of your work to .claude/lane-summary.md (relative to your current directory) as Markdown, with these headings exactly: '## What was done', '## Deviations from plan', '## Still needs a human', '## Verified'. Under 'What was done' be concrete and name the change, not the intention. Under 'Deviations from plan' list every file or interface that differs from the plan comment on the issue, with the reason, or write 'none'. Under 'Still needs a human' list every open decision, or write 'nothing' -- do not leave it empty. Under 'Verified' name the checks you actually ran and their results; if you could not verify something, say so rather than omitting it. This file becomes the issue comment and the durable record after your session ends. Reply with only the word DONE." --wait --timeout 180000 >/dev/null 2>&1 \
    || echo "warning: '$a' did not answer the summary request" >&2
  [ -s "$dump" ]
}

# document <agent> -- post the lane's closing summary to its GitHub issue.
#
# Landing work without saying what landed makes the forge useless as a status
# view: the decisions live in a pane that nobody reads and that eventually goes
# away. `land` calls this, so an undocumented merge takes deliberate effort.
cmd_document() {
  local a="$1" d b issue dump
  d="$(wt_of "$a")"; [ -n "$d" ] && [ -d "$d" ] || die "no worktree for agent '$a'"
  b="$(git -C "$d" rev-parse --abbrev-ref HEAD)"
  issue="$(issue_of_branch "$b")"
  [ -n "$issue" ] || die "cannot derive an issue number from branch '$b' (expected issue-<n>-<slug>)"
  command -v gh >/dev/null 2>&1 || die "gh is not available"
  capture_summary "$a" "$d" || die "'$a' wrote no summary -- nothing to post"
  dump="$d/.claude/lane-summary.md"
  ghr issue comment "$issue" --body-file "$dump" >/dev/null \
    || die "failed to comment on issue #$issue"
  mkdir -p "$ARCHIVE"
  cp "$dump" "$ARCHIVE/${a}-${b}-summary.md"
  echo "documented #$issue from $a ($(wc -l < "$dump") lines)"
}

# ---------------------------------------------------------------------------
# Provisioning and checks
# ---------------------------------------------------------------------------

# provision_lane <dir> -- give the lane its OWN dependency install.
# Linking one node_modules across worktrees was tried and failed: any lane
# running an install writes through the link, and the shared tree ended up a
# partial install with no .bin and missing transitive scopes, breaking lint and
# test everywhere including the main checkout. Slower per launch, but lanes are
# then genuinely independent. Every detected toolchain runs -- a repo can carry
# package.json AND pyproject.toml -- and each asserts it produced something.
provision_lane() {
  local dir="$1" py
  if [ -n "$INSTALL_CMD" ]; then
    echo "installing dependencies (INSTALL_CMD)..." >&2
    ( cd "$dir" && eval "$INSTALL_CMD" >/dev/null 2>&1 ) || die "INSTALL_CMD failed in $dir"
    return 0
  fi
  if [ -f "$dir/package.json" ]; then
    echo "installing npm dependencies (this takes a minute)..." >&2
    if [ -f "$dir/package-lock.json" ]; then
      ( cd "$dir" && npm ci --no-audit --no-fund >/dev/null 2>&1 ) \
        || ( cd "$dir" && npm install --no-audit --no-fund >/dev/null 2>&1 ) \
        || die "npm install failed in $dir"
    else
      ( cd "$dir" && npm install --no-audit --no-fund >/dev/null 2>&1 ) || die "npm install failed in $dir"
    fi
    [ -d "$dir/node_modules/.bin" ] || die "install left no node_modules/.bin in $dir"
  fi
  if [ -f "$dir/pyproject.toml" ]; then
    if command -v uv >/dev/null 2>&1; then
      echo "installing python dependencies (uv sync)..." >&2
      ( cd "$dir" && uv sync >/dev/null 2>&1 ) || die "uv sync failed in $dir"
    else
      echo "installing python dependencies (venv + pip; uv not on PATH)..." >&2
      ( cd "$dir" && python -m venv .venv >/dev/null 2>&1 ) || die "python -m venv failed in $dir"
      py="$dir/.venv/bin/python"; [ -f "$dir/.venv/Scripts/python.exe" ] && py="$dir/.venv/Scripts/python.exe"
      ( cd "$dir" && "$py" -m pip install -e . >/dev/null 2>&1 ) || die "pip install -e . failed in $dir"
    fi
    [ -d "$dir/.venv" ] || die "python install left no .venv in $dir"
  fi
  if [ -f "$dir/wally.toml" ]; then
    command -v wally >/dev/null 2>&1 || die "wally.toml present but wally is not on PATH (install rokit/aftman + wally)"
    echo "installing wally packages..." >&2
    ( cd "$dir" && wally install >/dev/null 2>&1 ) || die "wally install failed in $dir"
    [ -d "$dir/Packages" ] || die "wally install left no Packages/ in $dir"
  fi
  if [ -f "$dir/Cargo.toml" ]; then
    command -v cargo >/dev/null 2>&1 || die "Cargo.toml present but cargo is not on PATH"
    echo "fetching cargo dependencies..." >&2
    ( cd "$dir" && cargo fetch >/dev/null 2>&1 ) || die "cargo fetch failed in $dir"
  fi
}

# check_cmd_for <dir> -- the lint+test+build command for a worktree, as text.
# CHECK_CMD wins; otherwise detect. Printed into the lane's brief so the lane can
# run the same thing the manager will.
check_cmd_for() {
  local d="$1"
  if [ -n "$CHECK_CMD" ]; then printf '%s' "$CHECK_CMD"
  elif [ -f "$d/package.json" ]; then printf '%s' "npm run lint && npm test && npm run build"
  elif [ -f "$d/pyproject.toml" ]; then printf '%s' "uv run ruff check . && uv run pytest"
  elif [ -f "$d/wally.toml" ]; then printf '%s' "selene src && stylua --check src"
  elif [ -f "$d/Cargo.toml" ]; then printf '%s' "cargo clippy -- -D warnings && cargo test"
  elif [ -f "$d/Makefile" ]; then printf '%s' "make check"
  fi
}

cmd_check() {
  local d cmd; d="$(wt_of "$1")"
  [ -n "$d" ] && [ -d "$d" ] || die "no worktree for agent '$1'"
  echo "== $1 -> $d"
  cmd="$(check_cmd_for "$d")"
  [ -n "$cmd" ] || die "no CHECK_CMD in .claude/fleet.conf and no known project type in $d"
  echo "== $cmd"
  ( cd "$d" && eval "$cmd" )
}

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------

# launch <issue> <slug> [agent-name] [--model M] [--effort L] [--force] [--no-plan]
# Create a lane end to end: dependency gate, plan gate, worktree, provisioning,
# codegen, agent, brief. Refuses rather than half-building over an existing lane.
cmd_launch() {
  local issue="$1" slug="$2"; shift 2
  local name="" model="" effort="" force="" noplan=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --model)  model="$2"; shift 2 ;;
      --effort) effort="$2"; shift 2 ;;
      --model=*)  model="${1#*=}"; shift ;;
      --effort=*) effort="${1#*=}"; shift ;;
      --force)  force=1; shift ;;
      --no-plan) noplan=1; shift ;;
      -*) die "unknown launch option: $1" ;;
      *)  name="$1"; shift ;;
    esac
  done
  name="${name:-$slug}"
  # Agent names are unique across the whole Herdr session, not per repository.
  # Two fleets that both launch a "docs" lane collide: the second start fails
  # and every later command addressed to "docs" lands on the first repo's lane.
  # Prefer the plain slug; fall back to slug-issue, then to repo-slug.
  if agent_name_taken "$name"; then
    if ! agent_name_taken "${slug}-${issue}"; then name="${slug}-${issue}"
    elif ! agent_name_taken "$(basename "$REPO" | tr -cd 'a-z0-9-' | cut -c1-12)-${slug}"; then name="$(basename "$REPO" | tr -cd 'a-z0-9-' | cut -c1-12)-${slug}"
    else die "agent name '$name' is taken in this Herdr session; pass a unique [name]"; fi
    warn "agent name '$slug' is taken in this Herdr session; using '$name'"
  fi
  local branch="issue-${issue}-${slug}" dir
  dir="$WT/issue-${issue}-${slug}"
  [ -e "$dir" ] && die "lane already exists at $dir"

  # Gate 1: dependencies. An issue whose input is another lane's unmerged output
  # is not ready, however attractive.
  if ! cmd_deps "$issue"; then
    [ -n "$force" ] || die "#$issue has open dependencies -- land them first, or pass --force"
    warn "launching #$issue over open dependencies (--force)"
  fi

  # Gate 2: the plan. The manager plans on the expensive model; the lane
  # implements on the cheap one. Without a plan the lane guesses the approach,
  # the files and the interfaces -- which is exactly how lanes solve the wrong
  # problem and collide.
  local plan i; plan="$(plan_of "$issue")"
  if [ -z "$plan" ] && [ "$REQUIRE_PLAN" = 1 ] && [ -z "$noplan" ]; then
    # A plan posted seconds ago may not read back yet; give the forge a moment.
    for i in 1 2 3 4 5; do sleep 3; plan="$(plan_of "$issue")"; [ -n "$plan" ] && break; done
  fi
  if [ -z "$plan" ]; then
    if [ "$REQUIRE_PLAN" = 1 ] && [ -z "$noplan" ]; then
      die "no fleet plan on #$issue -- write one (see the skill: 'Plan before launch') and post it with: ./.claude/herd.sh plan $issue <file>   (or pass --no-plan)"
    fi
    warn "launching #$issue without a plan; the lane will declare its own files"
  fi
  [ -n "$model" ]  || model="$(plan_lane "$issue" model)"
  [ -n "$effort" ] || effort="$(plan_lane "$issue" effort)"
  [ -n "$model" ]  || model="$LANE_MODEL"
  [ -n "$effort" ] || effort="$LANE_EFFORT"
  case "${effort:-medium}" in low|medium|high|xhigh|max) ;; *) die "effort must be low|medium|high|xhigh|max (got '$effort')" ;; esac

  # Collision surface, derived from the plans of the live lanes plus this issue.
  local surface; surface="$(cmd_collisions "$issue" 2>/dev/null || true)"

  local pane
  pane=$(herdr worktree create --cwd "$REPO" --branch "$branch" --base origin/main \
      --path "$dir" --label "${issue} ${slug}" --no-focus \
    | python -c 'import sys,json;print(json.loads(sys.stdin.buffer.read().decode("utf-8","replace"))["result"]["root_pane"]["pane_id"])')
  [ -n "$pane" ] || die "worktree create returned no pane"

  # A worktree carries tracked files only, so copy in what is gitignored but needed.
  [ -f "$REPO/.env" ] && cp "$REPO/.env" "$dir/.env"

  provision_lane "$dir"

  # Codegen, per worktree. `npm ci` does NOT do this unless the project happens
  # to have a postinstall hook, and a lane with an ungenerated client fails its
  # checks for reasons that have nothing to do with its work -- which, now that
  # landing is gated on checks, silently blocks a lane that did nothing wrong.
  # Diagnosing it is worse than it sounds: the symptom surfaces as an unrelated
  # assertion (`Prisma.join is not a function` -> HTTP 500 -> "expected 200"),
  # so it reads as a real product bug in whatever test happens to touch it first.
  if [ -n "$CODEGEN_CMD" ]; then
    ( cd "$dir" && eval "$CODEGEN_CMD" >/dev/null 2>&1 ) || die "codegen failed in $dir"
  elif [ -f "$dir/prisma/schema.prisma" ]; then
    ( cd "$dir" && npx prisma generate >/dev/null 2>&1 ) || die "prisma generate failed in $dir"
  fi

  start_lane_agent "$name" "$pane" "$model" "$effort" \
    || die "agent start failed for $name -- the lane exists; once the agent is idle, send the brief with: ./.claude/herd.sh brief $name"

  herdr agent prompt "$name" "$(build_brief "$issue" "$branch" "$dir")" >/dev/null \
    || die "opening prompt failed for $name -- resend with: ./.claude/herd.sh brief $name"
  echo "launched $name -> $pane ($branch${model:+, $model}${effort:+ $effort}${plan:+, planned}${surface:+, collisions flagged})"
}

# start_lane_agent <name> <pane> [model] [effort] -- start claude in the pane and
# get it to an idle prompt. A brand-new worktree is a directory Claude Code has
# never seen, so its first screen is the folder-trust dialog and `agent start`
# returns agent_not_ready. That dialog is answered here -- the worktree is a
# checkout of the manager's own repository -- and nothing else is: any other
# blocking UI is left for a human, per manager discipline.
start_lane_agent() {
  local name="$1" pane="$2" model="${3:-}" effort="${4:-}" rc=0 st
  shift 4 2>/dev/null || shift $#
  local -a args=()
  [ -n "$model" ]  && args+=(--model "$model")
  [ -n "$effort" ] && args+=(--effort "$effort")
  [ $# -gt 0 ] && args+=("$@")   # extra claude args, e.g. --resume <session>
  [ ${#args[@]} -gt 0 ] || args=()
  echo "starting $name (${model:-default model}, ${effort:-default effort})" >&2
  if [ ${#args[@]} -gt 0 ]; then
    herdr agent start "$name" --kind claude --pane "$pane" --timeout 120000 -- "${args[@]}" >/dev/null 2>&1 || rc=$?
  else
    herdr agent start "$name" --kind claude --pane "$pane" --timeout 120000 >/dev/null 2>&1 || rc=$?
  fi
  [ $rc -eq 0 ] && return 0
  # `agent start` can return before the dialog has rendered, so poll for it
  # rather than reading the screen once.
  local i
  local screen
  for i in $(seq 1 20); do
    screen="$(herdr agent read "$name" --source detection --lines 40 2>/dev/null)"
    if printf '%s' "$screen" | grep -qi "trust this folder"; then
      echo "answering the folder-trust prompt for $name (worktree of this repository)" >&2
      herdr agent send-keys "$name" down >/dev/null 2>&1
      herdr agent send-keys "$name" enter >/dev/null 2>&1
      herdr agent wait "$name" --timeout 120000 >/dev/null 2>&1 || true
      continue
    fi
    if printf '%s' "$screen" | grep -qi "New MCP server found"; then
      # A project .mcp.json (e.g. a template's dev MCP) prompts on first start.
      # Lanes run on the manager-approved toolset only; the highlighted default
      # is "Continue without using this MCP server".
      echo "declining the project MCP server prompt for $name" >&2
      herdr agent send-keys "$name" enter >/dev/null 2>&1
      sleep 2
      continue
    fi
    st="$(agent_state "$name")"
    case "$st" in idle|done) return 0 ;; esac
    sleep 2
  done
  st="$(agent_state "$name")"
  case "$st" in idle|done) return 0 ;; esac
  warn "$name is '$st' after start; screen follows"
  herdr agent read "$name" --source visible --lines 30 2>/dev/null | grep -v '^[[:space:]]*$' | tail -15 >&2
  return 1
}

agent_name_taken() {
  herdr agent list 2>/dev/null | N="$1" python -c '
import sys, json, os
try:
    names = {a.get("name") for a in json.loads(sys.stdin.buffer.read().decode("utf-8","replace"))["result"]["agents"]}
except Exception:
    names = set()
sys.exit(0 if os.environ["N"] in names else 1)'
}

agent_state() {
  herdr agent get "$1" 2>/dev/null | python -c '
import sys, json
try: print(json.loads(sys.stdin.buffer.read().decode("utf-8","replace"))["result"]["agent"]["agent_status"])
except Exception: print("unknown")'
}

# build_brief <issue> <branch> <dir> -- the lane's opening prompt, as text.
# With a plan, the lane's first action is to read it and confirm the file list;
# without one, it declares its own so the manager can still derive the
# collision surface.
build_brief() {
  local issue="$1" branch="$2" dir="$3" plan surface checkcmd brief
  plan="$(plan_of "$issue")"
  surface="$(cmd_collisions "$issue" 2>/dev/null || true)"
  checkcmd="$(check_cmd_for "$dir")"
  brief="You are working solo in a git worktree on branch $branch. Never leave this directory, never checkout or commit to main. Other agents are working in parallel worktrees on this same repo. Read CLAUDE.md and follow it strictly."
  if [ -n "$plan" ]; then
    brief="$brief FIRST ACTION, before writing any code: run 'gh issue view $issue --comments'. The comment that begins '$PLAN_MARK' is your plan, written by the manager. Follow its Files and Interfaces exactly: create and modify only the paths it lists, and expose the interfaces it names, so that sibling lanes can build against them. State in one line the files you will touch, as the first line of your work, and keep going in the same turn -- do not end your turn until the issue is implemented, checked and committed. If you must deviate from the plan, do so minimally and explain it in your closing summary under '## Deviations from plan'."
  else
    brief="$brief FIRST ACTION, before writing any code: run 'gh issue view $issue', then state in one line the files you expect to modify -- the manager needs that list to detect collisions -- and keep going in the same turn; do not end your turn until the issue is implemented, checked and committed."
  fi
  if [ -n "$surface" ]; then
    brief="$brief SHARED COLLISION SURFACE -- files another lane also plans to touch: $(printf '%s' "$surface" | awk -F'\t' '{printf "%s (%s); ", $1, $2}'). Keep any change there minimal and additive, and flag it in your summary."
  else
    brief="$brief If you must touch a file that looks shared (schema, seed, lockfile, layout, config), keep the change minimal and additive and flag it prominently in your closing summary."
  fi
  brief="$brief Implement issue $issue."
  if [ -n "$checkcmd" ]; then
    brief="$brief Before you write your summary, run the project's checks yourself: $checkcmd -- and record the exact result under '## Verified'. Do not report done with failing checks; fix them first."
  fi
  brief="$brief Commit to this branch with a conventional commit message ending in 'Closes #$issue'. When done, write your closing summary to .claude/lane-summary.md in this worktree, with the headings '## What was done', '## Deviations from plan', '## Still needs a human' and '## Verified' -- that file is posted verbatim as a comment on issue #$issue, so write it for the repository owner rather than for me. Say what you could NOT verify rather than omitting it; write 'none' under 'Deviations from plan' and 'nothing' under 'Still needs a human' if that is genuinely true. Then reply with the same summary in the pane."
  printf '%s' "$brief"
}

# resume <agent> -- reopen a recycled lane's conversation. The pane was closed
# to give the memory back; the chat was never deleted. This recreates the
# worktree from the retained origin branch, opens a pane on it, and starts
# claude with --resume on the session id the archive recorded, so the agent
# comes back with all its context.
cmd_resume() {
  local a="$1" arch sid b d pane
  arch="$(ls -t "$ARCHIVE"/"$a"-*-[0-9]*T[0-9]*Z.md 2>/dev/null | head -1)"
  [ -n "$arch" ] || die "no archive for '$a' under $ARCHIVE (was it ever recycled?)"
  sid="$(sed -n 's/^- claude session: `\(.*\)`$/\1/p' "$arch" | head -1)"
  b="$(sed -n 's/^- branch: `\(.*\)`$/\1/p' "$arch" | head -1)"
  d="$(sed -n 's/^- worktree: `\(.*\)`$/\1/p' "$arch" | head -1)"
  [ -n "$sid" ] && [ "$sid" != unknown ] || die "archive $arch records no session id"
  [ -n "$b" ] && [ -n "$d" ] || die "archive $arch is missing branch or worktree"
  d="$(printf '%s' "$d" | sed 's|\\|/|g')"
  if [ ! -d "$d" ]; then
    git -C "$REPO" fetch -q origin
    if git -C "$REPO" rev-parse --verify --quiet "$b" >/dev/null; then
      git -C "$REPO" worktree add -q "$d" "$b" || die "could not recreate worktree $d"
    else
      git -C "$REPO" worktree add -q -b "$b" "$d" "origin/$b" || die "could not recreate worktree $d from origin/$b"
    fi
  fi
  agent_name_taken "$a" && die "agent name '$a' is in use; recycle or rename it first"
  pane=$(herdr worktree open --cwd "$REPO" --path "$d" --label "resumed $a" --no-focus 2>/dev/null \
    | python -c 'import sys,json;print(json.loads(sys.stdin.buffer.read().decode("utf-8","replace"))["result"]["root_pane"]["pane_id"])')
  [ -n "$pane" ] || die "herdr worktree open returned no pane for $d"
  start_lane_agent "$a" "$pane" "" "" --resume "$sid" \
    || die "claude did not come up in $pane; open it and run: claude --resume $sid"
  echo "resumed $a -> $pane ($b, session $sid). Recycle it again when you are done: ./.claude/herd.sh recycle $a"
}

# brief <agent> -- (re)send the opening brief to a lane whose launch was
# interrupted after the worktree existed. Refuses while the agent is blocked.
cmd_brief() {
  local a="$1" d b issue st
  d="$(wt_of "$a")"; [ -n "$d" ] && [ -d "$d" ] || die "no worktree for agent '$a'"
  b="$(git -C "$d" rev-parse --abbrev-ref HEAD)"
  issue="$(issue_of_branch "$b")"
  [ -n "$issue" ] || die "cannot derive an issue number from branch '$b'"
  st="$(agent_state "$a")"
  case "$st" in idle|done) ;; *) die "'$a' is '$st' -- unblock it first (herdr agent read $a)" ;; esac
  herdr agent prompt "$a" "$(build_brief "$issue" "$b" "$d")" >/dev/null || die "prompt failed for $a"
  echo "briefed $a for #$issue"
}

# ---------------------------------------------------------------------------
# Review, PR, land
# ---------------------------------------------------------------------------

# reviewer_prompt -- the lane-reviewer agent text with its frontmatter stripped.
# fleet-init copies it to <repo>/.claude/fleet-reviewer.md; fall back to the
# newest installed plugin copy so a repo initialised before 1.1 still reviews.
reviewer_prompt() {
  local f="$REPO/.claude/fleet-reviewer.md" cand
  if [ ! -s "$f" ]; then
    cand="$(ls -d "$HOME"/.claude/plugins/cache/claude-fleet/agent-fleet/*/agents/lane-reviewer.md 2>/dev/null | sort -V | tail -1)"
    [ -s "${cand:-}" ] && f="$cand"
  fi
  [ -s "$f" ] || die "no reviewer prompt: run /fleet-init to install .claude/fleet-reviewer.md"
  awk 'BEGIN{fm=0} NR==1 && /^---[[:space:]]*$/ {fm=1; next} fm && /^---[[:space:]]*$/ {fm=0; next} !fm {print}' "$f"
}

# review <agent> [--no-post] -- independent, headless, read-only review of a
# lane by a different session on a cheaper model. Exit 0 MERGE, 2 FIX,
# 3 ESCALATE (or no verdict). The verdict is posted to the issue so it
# survives the pane.
cmd_review() {
  local a="$1"; shift
  local nopost=""; [ "${1:-}" = "--no-post" ] && nopost=1
  local d b issue sha sys plan surface task out verdict rc
  d="$(wt_of "$a")"; [ -n "$d" ] && [ -d "$d" ] || die "no worktree for agent '$a'"
  b="$(git -C "$d" rev-parse --abbrev-ref HEAD)"
  issue="$(issue_of_branch "$b")"
  sha="$(git -C "$d" rev-parse --short HEAD)"
  command -v claude >/dev/null 2>&1 || die "claude CLI is not on PATH"
  sys="$(reviewer_prompt)"
  plan="$(plan_of "${issue:-0}")"
  surface="$(cmd_collisions "${issue:-}" 2>/dev/null || true)"
  task="Review the lane at $d (branch $b) against base origin/main${issue:+ for issue #$issue}. Work from inside that directory. Run the git commands from your instructions, read the issue with 'gh issue view $issue', read CLAUDE.md, and run the project's checks if they are cheap."
  [ -n "$plan" ] && task="$task The manager's plan for this issue follows between the markers. Only files that appear in the diff against the base count as touched by the lane; a file that exists on the base branch untouched is not a deviation. Files in the diff, or interfaces, that differ from the plan without a '## Deviations from plan' explanation in .claude/lane-summary.md are a FIX. <<<PLAN
$plan
PLAN>>>"
  [ -n "$surface" ] && task="$task Shared collision surface (report every hunk touching these): $(printf '%s' "$surface" | awk -F'\t' '{printf "%s (%s); ", $1, $2}')"
  task="$task End your reply with exactly one line containing only the verdict word: MERGE, FIX or ESCALATE."
  mkdir -p "$ARCHIVE"
  out="$ARCHIVE/review-${a}-${sha}.md"
  echo "reviewing $a @$sha with $REVIEW_MODEL..." >&2
  # The prompt is the positional argument and must precede the variadic
  # --allowedTools, or it is swallowed as a tool name. stdin is closed so the CLI
  # does not wait on it.
  ( cd "$d" && claude -p "$task" --model "$REVIEW_MODEL" --allowedTools Read Grep Glob Bash --append-system-prompt "$sys" < /dev/null ) > "$out" 2>"$out.err"
  verdict="$(grep -oE '^(MERGE|FIX|ESCALATE)[[:space:]]*$' "$out" | tail -1 | tr -d '[:space:]')"
  case "$verdict" in MERGE) rc=0 ;; FIX) rc=2 ;; ESCALATE) rc=3 ;; *) verdict="NO VERDICT"; rc=3 ;; esac
  if [ -z "$nopost" ] && [ -n "$issue" ] && command -v gh >/dev/null 2>&1; then
    { echo "$REVIEW_MARK"; echo "**Independent review** of \`$b\` @$sha (herd.sh review, $REVIEW_MODEL): **$verdict**"; echo; cat "$out"; } \
      | ghr issue comment "$issue" --body-file - >/dev/null || warn "could not post the review to #$issue"
  fi
  echo "review $a @$sha: $verdict ($out)"
  return $rc
}

# rebase_onto_main <agent> <worktree> <branch> -- a lane that finished after
# sibling lanes merged is behind main, and its PR will be CONFLICTING on the
# forge no matter how green it is locally. Rebase here, before the checks, so
# the checks run on what will actually merge. A clean rebase is silent; a
# conflicting one is aborted and handed to the lane that wrote the code, since
# it holds the context to resolve it.
rebase_onto_main() {
  local a="$1" d="$2" b="$3" behind conflicts
  git -C "$d" fetch -q origin 2>/dev/null
  behind="$(git -C "$d" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
  [ "${behind:-0}" -gt 0 ] || return 0
  echo "rebasing '$b' onto origin/main ($behind commits behind)..." >&2
  if git -C "$d" rebase -q origin/main >/dev/null 2>&1; then return 0; fi
  conflicts="$(git -C "$d" diff --name-only --diff-filter=U | tr '\n' ' ')"
  git -C "$d" rebase --abort >/dev/null 2>&1
  herdr agent prompt "$a" "Your branch $b is $behind commits behind origin/main and rebasing it conflicts in: $conflicts. Run 'git fetch origin && git rebase origin/main', resolve every conflict keeping both sides' intent (regenerate lockfiles with the toolchain instead of hand-merging them), re-run the project's checks, finish the rebase, and update .claude/lane-summary.md. Do not force-push; the manager will. Reply with what you resolved." >/dev/null 2>&1
  die "rebase of '$b' conflicts in: $conflicts -- sent to the lane; land again when it reports done"
}

# gate_for_landing <agent> <worktree> <branch> [--no-review]
# Everything both `land` and `pr` require before touching main or the forge.
gate_for_landing() {
  local a="$1" d="$2" b="$3" noreview="${4:-}" rc
  [ "$b" = main ] && die "'$a' is on main -- refusing"
  [ "$(content_dirty "$d")" = 0 ] || die "'$a' has uncommitted changes; commit or stash first"
  rebase_onto_main "$a" "$d" "$b"
  cmd_check "$a" || die "checks failed for '$a' -- not landing"
  if [ -z "$noreview" ]; then
    cmd_review "$a"; rc=$?
    case $rc in
      0) ;;
      2) herdr agent prompt "$a" "An independent review of your branch returned FIX. Read the latest comment on issue $(issue_of_branch "$b") that begins '$REVIEW_MARK', address every finding, commit, re-run the checks, and update .claude/lane-summary.md. Then reply with what you changed." >/dev/null 2>&1
         die "review returned FIX for '$a' -- findings sent to the lane; land again when it has addressed them" ;;
      *) die "review returned ESCALATE (or no verdict) for '$a' -- read $ARCHIVE/review-${a}-*.md and decide" ;;
    esac
  fi
  # Documentation is a landing requirement, not a later cleanup. Captured BEFORE
  # the merge because the agent that knows the answers is still alive.
  capture_summary "$a" "$d" || die "'$a' wrote no closing summary -- not landing an undocumented merge"
}

# merge <agent> [--no-wait] -- wait for the lane's PR checks, squash-merge it,
# and fast-forward the manager's main checkout.
#
# The manager merges. Landing that stops at "PR open, someone please click" has
# moved the last step back onto the person, which is the opposite of the point.
# The gates are the checks re-run here, the independent review, the closing
# summary and CI; once those are green there is nothing left for a human to add.
cmd_merge() {
  local a="$1"; shift
  local nowait=""; [ "${1:-}" = "--no-wait" ] && nowait=1
  local d b n rc nchecks
  d="$(wt_of "$a")"; [ -n "$d" ] && [ -d "$d" ] || die "no worktree for agent '$a'"
  b="$(git -C "$d" rev-parse --abbrev-ref HEAD)"
  command -v gh >/dev/null 2>&1 || die "gh is not available"
  n="$(ghr pr list --head "$b" --state open --json number -q '.[0].number' 2>/dev/null)"
  [ -n "$n" ] || die "no open PR for '$b' (open one with: ./.claude/herd.sh pr $a)"
  if [ -z "$nowait" ]; then
    nchecks="$(ghr pr checks "$n" --json name -q 'length' 2>/dev/null || echo 0)"
    # CI registers its checks a few seconds after the push. Do not mistake that
    # gap for "this repository has no CI": poll for up to 90 s first.
    local t
    for t in $(seq 1 9); do
      [ "${nchecks:-0}" -gt 0 ] && break
      sleep 10
      nchecks="$(ghr pr checks "$n" --json name -q 'length' 2>/dev/null || echo 0)"
    done
    if [ "${nchecks:-0}" -gt 0 ]; then
      echo "waiting for $nchecks check(s) on #$n..." >&2
      ghr pr checks "$n" --watch --fail-fast >/dev/null 2>&1; rc=$?
      [ $rc -eq 0 ] || die "checks failed on #$n -- not merging (gh pr checks $n); send the failure to the lane and land again"
    else
      warn "#$n has no CI checks; merging on the manager's local verification and the review"
    fi
  fi
  ghr pr merge "$n" --squash >/dev/null 2>&1 || die "gh pr merge #$n failed -- branch protection or a conflict; see: gh pr view $n"
  if [ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" = main ] && [ "$(content_dirty "$REPO")" = 0 ]; then
    git -C "$REPO" pull -q --ff-only origin main 2>/dev/null || warn "could not fast-forward the main checkout; run git pull"
  fi
  echo "merged #$n ($b) into main"
  # The feature is on main; the lane has nothing left to do. Its pane costs
  # real memory (about 200 MB per agent on the owner's machine) for as long as
  # it stays open, and its transcript and summary survive teardown regardless.
  if [ "$AUTO_RECYCLE" = 1 ]; then
    cmd_recycle "$a" || warn "could not recycle '$a' after merge; run: ./.claude/herd.sh recycle $a"
  fi
}

# pr <agent> [--no-review] [--no-merge] -- push the lane and open a pull request
# whose body carries the lane's summary plus the manager's own verification, so
# CI is a second gate. With AUTO_MERGE=1 (default) it then waits for CI and
# merges. Nothing touches the main checkout directly.
cmd_pr() {
  local a="$1"; shift
  local noreview="" nomerge=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-review) noreview=1; shift ;;
      --no-merge)  nomerge=1; shift ;;
      *) die "unknown pr option: $1" ;;
    esac
  done
  local d b issue title body checkout verdict url
  d="$(wt_of "$a")"; [ -n "$d" ] && [ -d "$d" ] || die "no worktree for agent '$a'"
  b="$(git -C "$d" rev-parse --abbrev-ref HEAD)"
  issue="$(issue_of_branch "$b")"
  command -v gh >/dev/null 2>&1 || die "gh is not available"
  # A previous landing attempt may already have merged this branch (for
  # example when the manager's process was killed between merge and recycle):
  # nothing ahead of main plus a merged PR means the only thing left is teardown.
  local merged ahead
  git -C "$d" fetch -q origin main 2>/dev/null || true
  ahead="$(git -C "$d" rev-list --count origin/main..HEAD 2>/dev/null || echo 1)"
  merged="$(ghr pr list --head "$b" --state merged --json number -q '.[0].number' 2>/dev/null)"
  if [ "${ahead:-1}" = 0 ] && [ -n "$merged" ]; then
    echo "#$merged for '$b' is already merged and the branch has nothing ahead of main" >&2
    if [ "$AUTO_RECYCLE" = 1 ]; then cmd_recycle "$a"; fi
    return 0
  fi
  gate_for_landing "$a" "$d" "$b" "$noreview"
  # --force-with-lease because the gate may have rebased the branch; the lease
  # still refuses to overwrite anything pushed by someone else since our fetch.
  git -C "$d" push -u --force-with-lease origin "$b" >/dev/null 2>&1 || die "push of '$b' failed"
  title="$(git -C "$d" log --reverse --format=%s origin/main..HEAD | head -1)"
  [ -n "$title" ] || title="$b"
  mkdir -p "$ARCHIVE"
  body="$ARCHIVE/pr-${a}.md"
  checkout="$(cmd_check "$a" 2>&1 | tail -25)"
  verdict="$(ls -t "$ARCHIVE"/review-"$a"-*.md 2>/dev/null | head -1 | xargs -r grep -oE '^(MERGE|FIX|ESCALATE)[[:space:]]*$' | tail -1 | tr -d '[:space:]')"
  {
    cat "$d/.claude/lane-summary.md"
    echo
    echo "## Manager verification"
    echo
    echo "Re-run by the manager, not copied from the lane:"
    echo
    echo '```'
    echo "$checkout"
    echo '```'
    echo
    [ -n "$verdict" ] && echo "Independent review verdict: **$verdict** (see the issue comment)."
    echo
    [ -n "$issue" ] && echo "Closes #$issue"
  } > "$body"
  # Reuse an open PR from an earlier attempt rather than failing on a duplicate.
  url="$(ghr pr list --head "$b" --state open --json url -q '.[0].url' 2>/dev/null)"
  if [ -n "$url" ]; then
    ghr pr edit "$url" --body-file "$body" >/dev/null 2>&1 || true
    echo "reusing open PR $url"
  else
    url="$(ghr pr create --base main --head "$b" --title "$title" --body-file "$body" 2>/dev/null)" \
      || die "gh pr create failed for '$b' (see: gh pr view $b)"
    echo "opened $url"
  fi
  [ -n "$issue" ] && cmd_document "$a" >/dev/null 2>&1 && echo "documented #$issue"
  if [ "$AUTO_MERGE" = 1 ] && [ -z "$nomerge" ]; then
    cmd_merge "$a"
    return $?
  fi
  return 0
}

# land <agent> [--pr] [--no-review] [--no-merge] -- check, review, require a
# summary, then either stage a squash onto main (default) or open a PR and merge
# it when CI is green (LAND_MODE=pr / --pr).
cmd_land() {
  local a="$1"; shift
  local mode="$LAND_MODE" noreview="" nomerge=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr) mode=pr; shift ;;
      --squash) mode=squash; shift ;;
      --no-review) noreview=1; shift ;;
      --no-merge) nomerge=1; shift ;;
      *) die "unknown land option: $1" ;;
    esac
  done
  if [ "$mode" = pr ]; then
    cmd_pr "$a" ${noreview:+--no-review} ${nomerge:+--no-merge}
    return $?
  fi
  local d b
  d="$(wt_of "$a")"; [ -n "$d" ] && [ -d "$d" ] || die "no worktree for agent '$a'"
  b="$(git -C "$d" rev-parse --abbrev-ref HEAD)"
  git -C "$REPO" rev-parse --abbrev-ref HEAD | grep -qx main || die "manager checkout is not on main"
  [ "$(content_dirty "$REPO")" = 0 ] || die "main checkout has uncommitted content changes"
  gate_for_landing "$a" "$d" "$b" "$noreview"
  git -C "$REPO" merge --squash "$b" || die "squash merge hit conflicts -- resolve in the main checkout"
  echo "Staged squash of '$b'. Review with: git -C \"$REPO\" diff --cached"
  echo "Then commit, and post the summary to the issue with:"
  echo "  ./.claude/herd.sh document $a"
  echo "Tear the lane down (only when disk or clutter demands it) with:"
  echo "  herdr worktree remove --workspace <wN> --force && git -C \"$REPO\" branch -D $b"
}

# ---------------------------------------------------------------------------
# Recycle, report, read, say
# ---------------------------------------------------------------------------

# recycle <agent> -- retire a finished lane. Refuses to discard unpushed work.
# Runs automatically after merge (AUTO_RECYCLE=1): an open pane is a running
# agent process, and a finished one still holds its memory.
cmd_recycle() {
  local a="$1" d b ws
  d="$(wt_of "$a")"; [ -n "$d" ] && [ -d "$d" ] || die "no worktree for agent '$a'"
  b="$(git -C "$d" rev-parse --abbrev-ref HEAD)"
  mkdir -p "$ARCHIVE"
  local dump="$d/.claude/lane-summary.md"
  local final="$ARCHIVE/${a}-${b}-summary.md"
  if capture_summary "$a" "$d"; then
    cp "$dump" "$final"
    echo "captured agent summary ($(wc -l < "$dump") lines)"
  else
    echo "warning: '$a' wrote no summary at $dump -- archiving pane read only" >&2
  fi
  [ "$b" = main ] && die "'$a' is on main -- refusing"
  [ "$(content_dirty "$d")" = 0 ] || die "'$a' has uncommitted changes -- refusing"
  git -C "$d" rev-parse --verify --quiet "origin/$b" >/dev/null \
    || die "'$b' has never been pushed -- refusing to discard it"
  git -C "$d" diff --quiet "origin/$b" HEAD \
    || die "'$b' has commits not on origin -- push first"
  ws="$(herdr agent get "$a" | python -c 'import sys,json;print(json.loads(sys.stdin.buffer.read().decode("utf-8","replace"))["result"]["agent"]["workspace_id"])')"

  echo "archived transcript -> $(archive_lane "$a" "$d" "$b")"

  # Teardown, in an order that survives partial failure. `herdr worktree
  # remove` unregisters the checkout but has been seen to fail with "not a
  # working tree" and leave the workspace -- and its shell, whose cwd is the
  # lane directory -- alive. That shell is the memory the owner wanted back and
  # the lock that stops the directory from being deleted. So: close the
  # workspace explicitly, prune, then delete the directory ourselves.
  herdr worktree remove --workspace "$ws" --force >/dev/null 2>&1 || true
  herdr workspace close "$ws" >/dev/null 2>&1 || true
  git -C "$REPO" worktree prune
  if [ -d "$d" ]; then
    local i
    for i in 1 2 3 4 5; do
      rm -rf "$d" 2>/dev/null && break
      sleep 2   # the closed shell can take a moment to release the directory
    done
    [ -d "$d" ] && warn "could not delete $d (still locked); remove it by hand"
  fi
  git -C "$REPO" branch -D "$b" >/dev/null 2>&1
  echo "recycled $a (workspace $ws closed, branch $b -- origin copy retained, worktree dir removed)"
}

# report [since] -- what the fleet actually did, for a human catching up.
# Default window is today. Reads git and the forge rather than any hand-kept
# file, so it cannot drift from what really happened.
cmd_report() {
  local since="${1:-midnight}" out
  out="$ARCHIVE/report-$(date -u +%Y%m%d).md"
  mkdir -p "$ARCHIVE"
  {
    echo "# Fleet report — $(date +'%Y-%m-%d %H:%M')"
    echo
    echo "Window: since $since. Repository: $(basename "$REPO")."
    echo
    echo "## Landed on $(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
    echo
    git -C "$REPO" log --since="$since" --first-parent --pretty='- %s' 2>/dev/null || true
    echo
    if command -v gh >/dev/null 2>&1; then
      echo "## Pull requests merged"
      echo
      ghr pr list --repo "$(ghr repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" \
        --state merged --limit 40 \
        --json number,title,mergedAt \
        -q ".[] | select(.mergedAt > \"$(date -u -d "$since" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT00:00:00Z)\") | \"- #\(.number) \(.title)\"" 2>/dev/null || echo "_(none, or gh unavailable)_"
      echo
      echo "## Still open"
      echo
      ghr pr list --state open --limit 40 --json number,title,mergeable \
        -q '.[] | "- #\(.number) \(.title) — \(.mergeable)"' 2>/dev/null || echo "_(none)_"
      echo
      echo "## Issues opened"
      echo
      ghr issue list --state all --limit 40 --json number,title,createdAt,state \
        -q ".[] | select(.createdAt > \"$(date -u +%Y-%m-%dT00:00:00Z)\") | \"- #\(.number) \(.title) [\(.state)]\"" 2>/dev/null || echo "_(none)_"
      echo
    fi
    echo "## Lanes"
    echo
    printf '%-16s %-9s %s\n' "AGENT" "STATE" "BRANCH / COMMITS AHEAD"
    herdr agent list 2>/dev/null | python -c '
import sys, json, subprocess, os
try:
    rows = json.loads(sys.stdin.buffer.read().decode("utf-8","replace"))["result"]["agents"]
except Exception:
    rows = []
for a in sorted(rows, key=lambda r: r["pane_id"]):
    n = a.get("name")
    if not n:
        continue
    cwd = a.get("cwd") or "."
    def sh(*c):
        try: return subprocess.run(c, capture_output=True, timeout=20).stdout.decode("utf-8","replace").strip()
        except Exception: return "?"
    br = sh("git","-C",cwd,"rev-parse","--abbrev-ref","HEAD")
    ahead = sh("git","-C",cwd,"rev-list","--count","origin/main..HEAD")
    print("%-16s %-9s %s (+%s)" % (n, a["agent_status"], br, ahead))'
    echo
    echo "## Plans and reviews on file"
    echo
    ls "$ARCHIVE"/plans/issue-*.md 2>/dev/null | sed 's|.*/|- plan: |' || true
    ls "$ARCHIVE"/review-*.md 2>/dev/null | sed 's|.*/|- review: |' || true
    echo
    echo "## Needs a human"
    echo
    echo "From merged pull requests and any lane archives. PR bodies are the primary"
    echo "source: lanes are not recycled by default, so their decisions live there."
    echo
    {
      if command -v gh >/dev/null 2>&1; then
        for n in $(ghr pr list --state merged --limit 25 --json number,mergedAt \
                     -q ".[] | select(.mergedAt > \"$(date -u +%Y-%m-%dT00:00:00Z)\") | .number" 2>/dev/null); do
          ghr pr view "$n" --json body -q .body 2>/dev/null \
            | sed -n '/^#\+ *\(Needs a human\|Still needs a human\|Open decisions\|Not verified\|Could not verify\|Worth deciding\|Your decision\)/,/^#\+ /p' \
            | grep -E '^[0-9]+\. |^- |^\*\*' | sed "s|^|#$n |"
        done
      fi
      grep -h -A6 -iE '^#+ *(needs a human|still needs a human|open decisions)' "$ARCHIVE"/*.md 2>/dev/null \
        | grep -E '^[0-9]+\.|^- '
    } | sed 's/[[:space:]]\+$//' | grep -v '^$' | head -40 || true
    echo
    echo "_Full detail is in each PR body; this is only the index._"
  } > "$out"
  echo "$out"
}

cmd_read() { herdr agent read "$1" --source recent-unwrapped --lines "${2:-80}"; }

cmd_say() {
  local a="$1"; shift
  [ $# -gt 0 ] || die "say needs a message"
  herdr agent prompt "$a" "$*"
}

usage() { grep -E '^#   \./' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

load_conf
case "${1:-status}" in
  status) cmd_status ;;
  watch)  cmd_watch ;;
  plan)   shift; [ $# -ge 2 ] || die "plan needs <issue> <file>"; cmd_plan "$1" "$2" ;;
  deps)   shift; [ $# -ge 1 ] || die "deps needs <issue>"; cmd_deps "$1" ;;
  collisions) shift; cmd_collisions "$@" ;;
  launch) shift; [ $# -ge 2 ] || die "launch needs <issue> <slug> [name] [--model M] [--effort L] [--force] [--no-plan]"; cmd_launch "$@" ;;
  brief)  shift; [ $# -ge 1 ] || die "brief needs an agent"; cmd_brief "$1" ;;
  resume) shift; [ $# -ge 1 ] || die "resume needs an agent"; cmd_resume "$1" ;;
  report) shift; cmd_report "$@" ;;
  archive) shift; [ $# -ge 1 ] || die "archive needs an agent"; cmd_archive "$1" ;;
  recycle) shift; [ $# -ge 1 ] || die "recycle needs an agent"; cmd_recycle "$1" ;;
  read)   shift; [ $# -ge 1 ] || die "read needs an agent"; cmd_read "$@" ;;
  say)    shift; [ $# -ge 1 ] || die "say needs an agent"; cmd_say "$@" ;;
  check)  shift; [ $# -ge 1 ] || die "check needs an agent"; cmd_check "$1" ;;
  review) shift; [ $# -ge 1 ] || die "review needs an agent"; cmd_review "$@" ;;
  document) shift; [ $# -ge 1 ] || die "document needs an agent"; cmd_document "$1" ;;
  pr)     shift; [ $# -ge 1 ] || die "pr needs an agent"; cmd_pr "$@" ;;
  merge)  shift; [ $# -ge 1 ] || die "merge needs an agent"; cmd_merge "$@" ;;
  land)   shift; [ $# -ge 1 ] || die "land needs an agent"; cmd_land "$@" ;;
  -h|--help|help) usage ;;
  *)      die "unknown command '$1'"; ;;
esac
