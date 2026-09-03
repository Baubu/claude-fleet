---
description: Set up a recurring local task that refills the agent fleet on an interval
argument-hint: [interval, e.g. 6h] [max-lanes, e.g. 3]
---

Create a **local** scheduled task that periodically starts a manager session to
land finished lanes and open new ones. Local, because only a task on this machine
can open a real terminal — a scheduled cloud agent cannot drive a multiplexer.

## Set expectations before building anything

Tell the user plainly, and get agreement:

- **Nothing can read remaining quota.** There is no API for it. The task fires on
  its interval and either works or fails cheaply. Aligning it to a quota-reset
  cadence is a reasonable heuristic, not a guarantee.
- **This spends money if the account bills beyond its plan.** An unattended loop
  opening lanes is precisely the shape that runs into overage. The lane cap is the
  control; default to a small one and confirm the number.
- **It runs whether or not there is anything worth doing.** The prompt must make
  "nothing to do — stop" a normal, cheap outcome, not something the agent works
  around by inventing tasks.

If the user has not asked for unattended operation specifically, ask before
creating it. A recurring task that spends money is not a sensible default.

## Build it

Ask for the interval and lane cap if not given. Default: 6 hours, 3 lanes.

Write a small launcher script under the repo's `.claude/` that:

1. `cd`s to the repository.
2. Refuses to run if the fleet is already at the cap — `herd.sh status` gives the
   live lane count. This is the guard that keeps the task idempotent.
3. Starts one manager session with a standing prompt (below).

Register it with the platform's scheduler:

- **Windows** — `schtasks /Create /SC HOURLY /MO <hours> /TN "claude-fleet-<repo>" /TR "<launcher>"`.
  Confirm with `schtasks /Query /TN "claude-fleet-<repo>"`.
- **macOS / Linux** — a `crontab` entry, or a launchd/systemd user unit.

Show the exact command before running it, and tell the user how to remove it
(`schtasks /Delete /TN ...`, or `crontab -e`).

## The standing prompt

It must be self-contained — the session starts with no memory of this one:

> Read CLAUDE.md and the agent-fleet skill. Run `./.claude/herd.sh status`.
> First, land what is finished: for each lane that is done, verify it yourself
> (re-run the project's checks), open or update its PR with evidence, and record
> anything you could not verify. Then, only if the fleet is below <cap> lanes,
> pick the highest-value unclaimed issue — value first, not whichever is easiest
> to isolate — claim it with the `fleet:in-progress` label, and open a lane.
> If there is nothing to land and nothing worth starting, say so and stop. Do not
> invent work. Escalate rather than answering any approval prompt on a lane's
> behalf.

## Verify and report

Run the launcher once by hand and confirm it behaves — including that it refuses
to exceed the cap. Then report: the schedule created, the cap, the exact removal
command, and what the task will and will not do. If you could not register it, say
which step failed rather than reporting success.
