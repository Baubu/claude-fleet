#!/usr/bin/env bash
# Manager-side control for a Herdr agent fleet.
# Identical to ~/.claude/skills/agent-fleet/herd.sh -- sync with a plain copy so
# the two cannot drift. Set CHECK_CMD in <repo>/.claude/fleet.conf for non-npm
# projects. See the agent-fleet skill for the surrounding pattern.
#
# Topology: one Herdr workspace per git worktree, one Claude agent per workspace.
# The manager runs in w1 (the main checkout, on `main`). Pair it with a PreToolUse
# hook that denies Edit/Write there so the review-only role is enforced, not just
# intended -- the manager then cannot edit feature code even by mistake.
#
#   ./.claude/herd.sh status            # lifecycle + git state for every lane
#   ./.claude/herd.sh launch <n> <slug> [name] [--model opus|sonnet|fable]
#                                       [--effort low|medium|high|xhigh|max]
#   ./.claude/herd.sh report [since]    # what the fleet did, for a human catching up
#   ./.claude/herd.sh archive <agent>   # snapshot a lane's transcript, no teardown
#   ./.claude/herd.sh recycle <agent>   # archive, then retire a fully-pushed lane
#   ./.claude/herd.sh watch             # event stream of lane state changes
#   ./.claude/herd.sh read <agent> [n]  # last n lines of an agent's transcript
#   ./.claude/herd.sh say <agent> <txt> # prompt an agent
#   ./.claude/herd.sh check <agent>     # lint+test+build that agent's worktree
#   ./.claude/herd.sh land <agent>      # check, squash-merge to main, tear down
#
# Agent names are set at `herdr agent start` time and follow the pane.
set -uo pipefail

REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
WT="$REPO/.claude/worktrees"
ARCHIVE="$REPO/.claude/fleet-archive"

die() { printf 'herd: %s\n' "$*" >&2; exit 1; }

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
  printf '
%-30s %-26s %s
' "WORKTREE" "BRANCH" "AHEAD/DIRTY"
  for d in "$WT"/*/; do
    [ -e "$d/.git" ] || continue
    local n b ahead dirty
    n="$(basename "$d")"
    b="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)" || continue
    ahead="$(git -C "$d" rev-list --count origin/main..HEAD 2>/dev/null || echo '?')"
    dirty="$(content_dirty "$d")"
    printf '%-30s %-26s +%s commits, %s dirty
' "$n" "$b" "$ahead" "$dirty"
  done
}

# Event stream for Monitor: one line per lane transition into a settled state.
# Silence must never mean "still fine" -- blocked, vanished and exited lanes all
# emit, otherwise a crashed lane is indistinguishable from a working one.
cmd_watch() {
  python -u -c '
import json, subprocess, time

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
        return {a["name"]: a for a in json.loads(out)["result"]["agents"] if a.get("name")}
    except Exception:
        return None

def head(cwd):
    return sh(["git", "-C", cwd, "rev-parse", "--short", "HEAD"]) or "?"

SETTLED = {"idle", "done", "blocked"}
# Announce a (lane, state, commit) combination at most once. A pane that settles,
# wakes and settles again with no new commit is noise, and the fleet generates a
# lot of it after a restart -- but a lane that settles again ON A NEW COMMIT has
# genuinely done more work and must still be heard.
seen = set()
prev = set()
first = True
while True:
    cur = poll()
    if cur is not None:
        for name, a in sorted(cur.items()):
            st = a["agent_status"]
            if st not in SETTLED:
                continue
            h = head(a.get("cwd") or ".")
            key = (name, st, h)
            if key in seen:
                continue
            seen.add(key)
            # blocked always speaks: it means a human is being waited on.
            if first and st == "idle":
                continue
            print("LANE %s -> %s @%s (pane %s)" % (name, st, h, a["pane_id"]))
        for name in sorted(prev - set(cur)):
            print("LANE %s -> vanished (pane closed or agent exited)" % name)
        prev = set(cur)
        first = False
    time.sleep(20)
'
}

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
    echo "~/.claude/projects/$(echo "$d" | sed 's|[:/\.]|-|g')/${sid:-<session-id>}.jsonl"
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

# launch <issue> <slug> [agent-name] -- create a lane end to end.
# Worktree, provisioning, agent, opening brief. Idempotent enough to re-run after
# a failure: it refuses rather than half-building over an existing lane.
cmd_launch() {
  local issue="$1" slug="$2"; shift 2
  local name="" model="" effort=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --model)  model="$2"; shift 2 ;;
      --effort) effort="$2"; shift 2 ;;
      --model=*)  model="${1#*=}"; shift ;;
      --effort=*) effort="${1#*=}"; shift ;;
      -*) die "unknown launch option: $1" ;;
      *)  name="$1"; shift ;;
    esac
  done
  name="${name:-$slug}"
  case "${effort:-medium}" in low|medium|high|xhigh|max) ;; *) die "effort must be low|medium|high|xhigh|max" ;; esac
  local branch="issue-${issue}-${slug}" dir
  dir="$WT/issue-${issue}-${slug}"
  [ -e "$dir" ] && die "lane already exists at $dir"

  local pane
  pane=$(herdr worktree create --cwd "$REPO" --branch "$branch" --base origin/main       --path "$dir" --label "${issue} ${slug}" --no-focus     | python -c 'import sys,json;print(json.loads(sys.stdin.buffer.read().decode("utf-8","replace"))["result"]["root_pane"]["pane_id"])')
  [ -n "$pane" ] || die "worktree create returned no pane"

  # A worktree carries tracked files only, so copy in what is gitignored but needed.
  [ -f "$REPO/.env" ] && cp "$REPO/.env" "$dir/.env"

  # Give each lane a REAL dependency install. Linking one node_modules across
  # worktrees was tried and failed: any lane running an install writes through the
  # link, and the shared tree ended up a partial install with no .bin and missing
  # transitive scopes, breaking lint and test everywhere including the main
  # checkout. Slower per launch, but lanes are then genuinely independent.
  if [ -f "$dir/package.json" ]; then
    echo "installing dependencies for $name (this takes a minute)..." >&2
    if [ -f "$dir/package-lock.json" ]; then
      ( cd "$dir" && npm ci --no-audit --no-fund >/dev/null 2>&1 )         || ( cd "$dir" && npm install --no-audit --no-fund >/dev/null 2>&1 )         || die "dependency install failed in $dir"
    else
      ( cd "$dir" && npm install --no-audit --no-fund >/dev/null 2>&1 )         || die "dependency install failed in $dir"
    fi
    [ -d "$dir/node_modules/.bin" ] || die "install left no node_modules/.bin in $dir"
  fi

  local -a args=()
  [ -n "$model" ]  && args+=(--model "$model")
  [ -n "$effort" ] && args+=(--effort "$effort")
  if [ ${#args[@]} -gt 0 ]; then
    echo "starting $name (${model:-default model}, ${effort:-default effort})" >&2
    herdr agent start "$name" --kind claude --pane "$pane" --timeout 120000 -- "${args[@]}" >/dev/null       || die "agent start failed for $name"
  else
    herdr agent start "$name" --kind claude --pane "$pane" --timeout 120000 >/dev/null       || die "agent start failed for $name"
  fi

  # First action is a file-intent declaration: the collision surface has to be
  # derived from what lanes actually plan to touch, not guessed up front.
  herdr agent prompt "$name" "You are working solo in a git worktree on branch $branch. Never leave this directory, never checkout or commit to main. FIRST ACTION, before writing any code: run 'gh issue view $issue', then reply with the list of files you expect to modify. Other agents are working in parallel worktrees on this same repo and the manager needs that list to detect collisions. Then continue without waiting for a reply. Read CLAUDE.md and follow it strictly. Implement issue $issue. If you must touch a file that looks shared (schema, seed, lockfile, layout, config), keep the change minimal and additive and flag it prominently in your closing summary. Commit to this branch with a conventional commit message ending in 'Closes #$issue'. When done, reply with a short summary: what you built, files changed, which shared files you touched, what you could NOT verify, and anything needing a human decision." >/dev/null     || die "opening prompt failed for $name"
  echo "launched $name -> $pane ($branch)"
}

# recycle <agent> -- retire a finished lane. Refuses to discard unpushed work.
cmd_recycle() {
  local a="$1" d b ws
  # Deliberately NOT part of the normal flow. A finished lane costs only disk,
  # and while its pane lives you can still ask it a follow-up. Recycle when disk
  # or clutter actually demands it, not as routine hygiene after every merge.
  d="$(wt_of "$a")"; [ -n "$d" ] && [ -d "$d" ] || die "no worktree for agent '$a'"
  b="$(git -C "$d" rev-parse --abbrev-ref HEAD)"

  # Have the agent write its own summary before teardown. `agent read` recovers
  # only what is still on screen, and a long closing summary has usually scrolled
  # off the alternate screen by now.
  #
  # The target must be INSIDE the agent's own worktree: a lane agent is scoped to
  # its cwd and cannot write elsewhere without an approval prompt, which is what
  # made an archive-directory path fail silently. .claude/ is gitignored in the
  # worktree, and `git diff` ignores untracked files anyway, so this cannot dirty
  # the tree the checks below require clean.
  mkdir -p "$ARCHIVE"
  local dump="$d/.claude/lane-summary.md"
  local final="$ARCHIVE/${a}-${b}-summary.md"
  mkdir -p "$d/.claude"
  herdr agent prompt "$a" "Before this session is closed, write a COMPLETE summary of your work to .claude/lane-summary.md (relative to your current directory) as Markdown. Include: what you built, every file changed, which shared files you touched, exactly what you could NOT verify, and every item that needs a human decision. This file is the durable record after your session ends, so omit nothing a reviewer would need. Reply with only the word DONE." --wait --timeout 180000 >/dev/null 2>&1     || echo "warning: '$a' did not answer the summary request" >&2
  if [ -s "$dump" ]; then
    cp "$dump" "$final"
    echo "captured agent summary ($(wc -l < "$dump") lines)"
  else
    echo "warning: '$a' wrote no summary at $dump -- archiving pane read only" >&2
  fi
  [ "$b" = main ] && die "'$a' is on main -- refusing"
  [ "$(content_dirty "$d")" = 0 ] || die "'$a' has uncommitted changes -- refusing"
  git -C "$d" rev-parse --verify --quiet "origin/$b" >/dev/null     || die "'$b' has never been pushed -- refusing to discard it"
  git -C "$d" diff --quiet "origin/$b" HEAD     || die "'$b' has commits not on origin -- push first"
  ws="$(herdr agent get "$a" | python -c 'import sys,json;print(json.loads(sys.stdin.buffer.read().decode("utf-8","replace"))["result"]["agent"]["workspace_id"])')"

  echo "archived transcript -> $(archive_lane "$a" "$d" "$b")"

  herdr worktree remove --workspace "$ws" --force >/dev/null 2>&1
  git -C "$REPO" worktree prune
  git -C "$REPO" branch -D "$b" >/dev/null 2>&1
  echo "recycled $a (workspace $ws, branch $b -- origin copy retained)"
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
      gh pr list --repo "$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"         --state merged --limit 40         --json number,title,mergedAt         -q ".[] | select(.mergedAt > \"$(date -u -d "$since" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT00:00:00Z)\") | \"- #\(.number) \(.title)\"" 2>/dev/null || echo "_(none, or gh unavailable)_"
      echo
      echo "## Still open"
      echo
      gh pr list --state open --limit 40 --json number,title,mergeable         -q '.[] | "- #\(.number) \(.title) — \(.mergeable)"' 2>/dev/null || echo "_(none)_"
      echo
      echo "## Issues opened"
      echo
      gh issue list --state all --limit 40 --json number,title,createdAt,state         -q ".[] | select(.createdAt > \"$(date -u +%Y-%m-%dT00:00:00Z)\") | \"- #\(.number) \(.title) [\(.state)]\"" 2>/dev/null || echo "_(none)_"
      echo
    fi
    echo "## Lanes"
    echo
    printf '%-16s %-9s %s
' "AGENT" "STATE" "BRANCH / COMMITS AHEAD"
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
    echo "## Needs a human"
    echo
    echo "From merged pull requests and any lane archives. PR bodies are the primary"
    echo "source: lanes are not recycled by default, so their decisions live there."
    echo
    {
      if command -v gh >/dev/null 2>&1; then
        for n in $(gh pr list --state merged --limit 25 --json number,mergedAt                      -q ".[] | select(.mergedAt > \"$(date -u +%Y-%m-%dT00:00:00Z)\") | .number" 2>/dev/null); do
          gh pr view "$n" --json body -q .body 2>/dev/null             | sed -n '/^#\+ *\(Needs a human\|Open decisions\|Not verified\|Could not verify\|Worth deciding\|Your decision\)/,/^#\+ /p'             | grep -E '^[0-9]+\. |^- |^\*\*' | sed "s|^|#$n |"
        done
      fi
      grep -h -A6 -iE '^#+ *(needs a human|open decisions)' "$ARCHIVE"/*.md 2>/dev/null         | grep -E '^[0-9]+\.|^- '
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

cmd_check() {
  local d; d="$(wt_of "$1")"
  [ -n "$d" ] && [ -d "$d" ] || die "no worktree for agent '$1'"
  echo "== $1 -> $d"
  local conf="$REPO/.claude/fleet.conf"
  # shellcheck disable=SC1090
  [ -f "$conf" ] && . "$conf"
  if [ -n "${CHECK_CMD:-}" ]; then ( cd "$d" && eval "$CHECK_CMD" )
  elif [ -f "$d/package.json" ]; then ( cd "$d" && npm run lint && npm test && npm run build )
  elif [ -f "$d/Cargo.toml" ]; then ( cd "$d" && cargo clippy -- -D warnings && cargo test )
  elif [ -f "$d/Makefile" ]; then ( cd "$d" && make check )
  else die "no CHECK_CMD in .claude/fleet.conf and no known project type in $d"; fi
}

cmd_land() {
  local a="$1" d b
  d="$(wt_of "$a")"; [ -n "$d" ] && [ -d "$d" ] || die "no worktree for agent '$a'"
  b="$(git -C "$d" rev-parse --abbrev-ref HEAD)"
  [ "$b" = main ] && die "'$a' is on main -- refusing"
  [ "$(content_dirty "$d")" = 0 ] || die "'$a' has uncommitted changes; commit or stash first"
  cmd_check "$a" || die "checks failed for '$a' -- not landing"
  git -C "$REPO" rev-parse --abbrev-ref HEAD | grep -qx main || die "manager checkout is not on main"
  [ "$(content_dirty "$REPO")" = 0 ] || die "main checkout has uncommitted content changes"
  git -C "$REPO" merge --squash "$b" || die "squash merge hit conflicts -- resolve in the main checkout"
  echo "Staged squash of '$b'. Review with: git -C \"$REPO\" diff --cached"
  echo "Then commit, and tear the lane down with:"
  echo "  herdr worktree remove --workspace <wN> --force && git -C \"$REPO\" branch -D $b"
}

case "${1:-status}" in
  status) cmd_status ;;
  watch)  cmd_watch ;;
  launch) shift; [ $# -ge 2 ] || die "launch needs <issue> <slug> [name] [--model M] [--effort L]"; cmd_launch "$@" ;;
  report) shift; cmd_report "$@" ;;
  archive) shift; [ $# -ge 1 ] || die "archive needs an agent"; cmd_archive "$1" ;;
  recycle) shift; [ $# -ge 1 ] || die "recycle needs an agent"; cmd_recycle "$1" ;;
  read)   shift; [ $# -ge 1 ] || die "read needs an agent"; cmd_read "$@" ;;
  say)    shift; [ $# -ge 1 ] || die "say needs an agent"; cmd_say "$@" ;;
  check)  shift; [ $# -ge 1 ] || die "check needs an agent"; cmd_check "$1" ;;
  land)   shift; [ $# -ge 1 ] || die "land needs an agent"; cmd_land "$1" ;;
  *)      sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \?//' ;;
esac
