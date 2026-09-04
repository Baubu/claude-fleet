# claude-fleet

A personal Claude Code marketplace. One plugin so far: **agent-fleet**, for
running several coding agents in parallel with a manager coordinating them.

## Add it

```bash
/plugin marketplace add Baubu/claude-fleet
/plugin install agent-fleet
```

Then, in each repository you want to run a fleet in:

```bash
/fleet-init
```

## Plugins

### [`agent-fleet`](plugins/agent-fleet) · 1.0.0

One git worktree per feature, one Claude agent per worktree, and a manager in the
main checkout that reviews the work, sequences merges, and files follow-up issues.

```
w1  <repo>    [main]           MANAGER   reviews, merges, files issues
w2  <lane-a>  [issue-NN-slug]  lane agent
w3  <lane-b>  [issue-NN-slug]  lane agent
w4  <lane-c>  [issue-NN-slug]  lane agent
```

Ships a skill (the pattern), the manager CLI, a pre-merge review agent, a
`PreToolUse` guard that makes the manager structurally unable to write feature
code, and two commands (`/fleet-init`, `/fleet-schedule`).

Requires [Herdr](https://herdr.dev) and a git repository.

## Repository layout

```
.claude-plugin/marketplace.json   the marketplace manifest
plugins/agent-fleet/              the plugin
```

## Working on this repo

Validate before pushing — the CLI checks both manifests:

```bash
claude plugin validate .
claude plugin validate ./plugins/agent-fleet
```

After pushing, refresh an installed copy with `/plugin update agent-fleet`. A
plugin's hooks register at session start, so a hook change needs a restart before
it takes effect.

The plugin's `scripts/herd.sh` is the **single source of truth** for the manager
CLI. `/fleet-init` copies it into a target repository; that copy is disposable and
must never be edited in place. Two hand-synced copies were the original design and
they drifted — a fix reached only one side, which is why this is packaged rather
than pasted.
