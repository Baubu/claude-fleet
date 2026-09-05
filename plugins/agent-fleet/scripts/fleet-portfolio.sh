#!/usr/bin/env bash
# Cross-repository view of several agent fleets. Each repo still runs its own
# manager and its own .claude/herd.sh; this only fans a read-only command out
# across them so one person can mind several fleets from one seat.
#
#   fleet-portfolio.sh status [repo..]     # herd.sh status in every repo, plus a roll-up
#   fleet-portfolio.sh report [since] [repo..]   # herd.sh report in every repo; prints the paths
#
# Repos come from the arguments, else from ~/.claude/fleet-portfolio.conf (one
# absolute path per line; `/fleet-init --portfolio` appends to it).
set -uo pipefail

CONF="$HOME/.claude/fleet-portfolio.conf"

die() { printf 'fleet-portfolio: %s\n' "$*" >&2; exit 1; }

repos_from() {
  if [ $# -gt 0 ]; then printf '%s\n' "$@"
  elif [ -s "$CONF" ]; then grep -vE '^\s*(#|$)' "$CONF"
  else die "no repos given and $CONF is empty"; fi
}

lane_count() { ls -d "$1"/.claude/worktrees/issue-*/ 2>/dev/null | grep -c . || true; }

cmd_status() {
  local r h rc=0 repos
  repos="$(repos_from "$@")" || exit 1
  printf '%-40s %-6s %s\n' "REPO" "LANES" "BRANCH"
  while IFS= read -r r; do
    [ -d "$r" ] || { printf '%-40s %s\n' "$r" "(missing)"; rc=1; continue; }
    printf '%-40s %-6s %s\n' "$(basename "$r")" "$(lane_count "$r")" "$(git -C "$r" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  done <<< "$repos"
  echo
  while IFS= read -r r; do
    h="$r/.claude/herd.sh"
    [ -f "$h" ] || continue
    echo "==== $(basename "$r") ($r)"
    bash "$h" status 2>&1 | sed 's/^/  /'
    echo
  done <<< "$repos"
  return $rc
}

cmd_report() {
  local since="" r h repos
  case "${1:-}" in
    ""|/*|[A-Za-z]:*) ;;            # no arg, or first arg is a path
    *) since="$1"; shift ;;
  esac
  repos="$(repos_from "$@")" || exit 1
  while IFS= read -r r; do
    h="$r/.claude/herd.sh"
    [ -f "$h" ] || { echo "$(basename "$r"): no .claude/herd.sh (run /fleet-init there)"; continue; }
    printf '%s: ' "$(basename "$r")"
    bash "$h" report ${since:+"$since"} 2>&1 | tail -1
  done <<< "$repos"
}

case "${1:-status}" in
  status) shift; cmd_status "$@" ;;
  report) shift; cmd_report "$@" ;;
  -h|--help|help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$1'" ;;
esac
