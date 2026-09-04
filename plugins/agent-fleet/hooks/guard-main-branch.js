#!/usr/bin/env node
/**
 * PreToolUse guard: refuse Edit/Write into the main checkout while HEAD is on the
 * repository's default branch.
 *
 * CLAUDE.md is advisory — a model can forget it. This is deterministic: the
 * harness runs it before every Edit/Write and honours the deny. It matters most
 * under bypass-permissions mode, where no permission prompt remains as a
 * backstop.
 *
 * Exits 0 silently (allow) for anything it is not sure about — a guard that
 * blocks unrelated work gets disabled, which is worse than a narrow guard.
 */
"use strict";

const { execFileSync } = require("child_process");
const path = require("path");
const fs = require("fs");

const allow = () => process.exit(0);

let input;
try {
  input = JSON.parse(fs.readFileSync(0, "utf8"));
} catch {
  allow();
}

const file = input && input.tool_input && input.tool_input.file_path;
if (!file || typeof file !== "string") allow();

const norm = (p) => p.replace(/\\/g, "/").toLowerCase();
const target = norm(file);

// Work inside a worktree is the thing we are steering toward — never block it.
if (target.includes("/.claude/worktrees/")) allow();

// Walk up to the nearest directory that exists (the file itself may be new).
let dir = path.dirname(file);
for (let i = 0; i < 64 && dir && !fs.existsSync(dir); i++) {
  const parent = path.dirname(dir);
  if (parent === dir) break;
  dir = parent;
}
if (!dir || !fs.existsSync(dir)) allow();

const git = (...args) =>
  execFileSync("git", ["-C", dir, ...args], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  }).trim();

let root, branch;
try {
  root = git("rev-parse", "--show-toplevel");
  branch = git("rev-parse", "--abbrev-ref", "HEAD");
} catch {
  allow(); // not a git repo — none of our business
}

// Only guard files that live inside this repository.
if (!root || !target.startsWith(norm(root) + "/")) allow();

// ...and only inside the repository this session is actually managing. Without
// this the guard fires on ANY git repo that happens to sit on its default
// branch — a sibling project, a dotfiles repo, or this plugin's own marketplace
// checkout — none of which are the manager's seat. It cost a real edit: writing
// to the plugin was refused on the grounds that the plugin was "the main
// checkout". When CLAUDE_PROJECT_DIR is unset we cannot tell, so we keep
// guarding rather than silently becoming a no-op.
const projectDir = process.env.CLAUDE_PROJECT_DIR;
if (projectDir) {
  let projectRoot = null;
  try {
    projectRoot = execFileSync("git", ["-C", projectDir, "rev-parse", "--show-toplevel"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {}
  if (projectRoot && norm(projectRoot) !== norm(root)) allow();
}
// The protected branch is whatever this repo calls its default -- main, master,
// develop -- not a hardcoded name. origin/HEAD is authoritative when present.
let base = null;
try {
  base = git("symbolic-ref", "--short", "refs/remotes/origin/HEAD").replace(/^origin\//, "");
} catch {
  for (const cand of ["main", "master"]) {
    try {
      git("rev-parse", "--verify", "--quiet", cand);
      base = cand;
      break;
    } catch {}
  }
}
if (!base || branch !== base) allow();

process.stdout.write(
  JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason:
        `Blocked by the agent-fleet guard: this edit targets the main checkout while HEAD is on \`${base}\`. ` +
        "That is the manager's seat — it reviews and merges, it does not write feature code. " +
        "Isolate the work first: open a lane (./.claude/herd.sh launch <issue> <slug>), call EnterWorktree, " +
        "or create a feature branch. If this genuinely belongs directly on the default branch (a one-line " +
        "fix, or repo tooling), say so and ask the user to confirm rather than retrying.",
    },
  })
);
