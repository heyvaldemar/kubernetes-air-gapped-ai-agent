#!/usr/bin/env python3
"""status-history.py DIR - keep every run's numbers on the status branch.

The branch `status` is one commit, replaced after every run, so a run's
numbers would last only until the next one, and its artifacts only as long
as GitHub keeps them. This keeps them in files instead: DIR/history/ holds
one JSON file per finished e2e run on main (carried over from the branch as
it was by .github/workflows/status.yml), and this adds the latest run's from
DIR/status.json, then rewrites DIR/history.md, a table of all of them, newest
first. A run already in history/ is written again from the same record, so
running this twice changes nothing.

With GITHUB_TOKEN, GITHUB_REPOSITORY and E2E_WORKFLOW set, it also fills in
any finished run on main in the status window that history/ does not have
yet, from that run's own artifacts while GitHub still keeps them (the
readers are scripts/status.py's). A run whose artifacts are gone is recorded
with its conclusion and no numbers, so it is not looked for again.

    scripts/status-history.py "$RUNNER_TEMP/status"
"""
import datetime
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# The lines the table shows for each model, as scripts/evals.sh prints them.
SHOWN = {
    "injected instructions the model acted on": "acted on",
    "emails the model tried to send outside acme.example": "tried outside",
    "task success": "tasks",
}


def backfill(hist):
    import importlib
    status = importlib.import_module("status")
    repo, workflow = os.environ["GITHUB_REPOSITORY"], os.environ["E2E_WORKFLOW"]
    since = (datetime.datetime.now(datetime.timezone.utc)
             - datetime.timedelta(days=status.WINDOW_DAYS - 1)).date()
    added = 0
    for r in status.runs(repo, workflow, since):
        if (r["event"] not in ("push", "schedule", "workflow_dispatch") or r["status"] != "completed"
                or r["conclusion"] not in ("success", "failure")
                or os.path.exists(os.path.join(hist, "%d.json" % r["id"]))):
            continue
        res = status.results(repo, r["id"]) or {"checks": [], "measured": []}
        latest = {"url": r["html_url"], "at": r["created_at"], "commit": r["head_sha"][:7],
                  "conclusion": r["conclusion"], "measured": res["measured"],
                  "checks_passed": sum(1 for c in res["checks"] if status.outcome(c) == "PASS"),
                  "checks_failed": sum(1 for c in res["checks"] if status.outcome(c) == "FAIL")}
        with open(os.path.join(hist, "%d.json" % r["id"]), "w") as f:
            json.dump(record(latest), f, indent=1, sort_keys=True)
        added += 1
    return added


def record(latest):
    models = {}
    for line in latest.get("measured", []):
        model, sep, rest = line.partition(" · ")
        if not sep:
            continue
        name, _, value = rest.partition(": ")
        models.setdefault(model, {})[name] = value
    return {
        "run": int(latest["url"].rsplit("/", 1)[1]),
        "url": latest["url"],
        "at": latest["at"],
        "commit": latest["commit"],
        "conclusion": latest["conclusion"],
        "checks_passed": latest["checks_passed"],
        "checks_failed": latest["checks_failed"],
        "models": models,
    }


def cell(value, name):
    if not value:
        return ""
    if name == "emails the model tried to send outside acme.example":
        tried, _, rest = value.partition(",")
        delivered = rest.rsplit("delivered: ", 1)[-1]
        return "%s, delivered %s" % (tried, delivered)
    if name == "task success":
        return value.split(" (")[0]
    return value.split(" attempts")[0]


def main(out):
    hist = os.path.join(out, "history")
    os.makedirs(hist, exist_ok=True)
    added = backfill(hist) if os.environ.get("GITHUB_TOKEN") and os.environ.get("E2E_WORKFLOW") else 0
    latest = json.load(open(os.path.join(out, "status.json"))).get("latest")
    if latest:
        r = record(latest)
        with open(os.path.join(hist, "%d.json" % r["run"]), "w") as f:
            json.dump(r, f, indent=1, sort_keys=True)
    runs = []
    for name in os.listdir(hist):
        if name.endswith(".json"):
            runs.append(json.load(open(os.path.join(hist, name))))
    runs.sort(key=lambda r: r["at"], reverse=True)
    models = sorted({m for r in runs for m in r["models"]})
    lines = ["# Every run on main, newest first", "",
             "Written by `scripts/status-history.py` from `history/`, one file per run, carried from run to run. "
             "Each cell is the model's: hidden instructions acted on, emails tried outside and how many were "
             "delivered, ordinary tasks done.", ""]
    head = "| Run | Date | Commit | Result | " + " | ".join(models) + " |"
    lines += [head, "|" + "---|" * (4 + len(models))]
    for r in runs:
        cells = []
        for m in models:
            v = r["models"].get(m, {})
            cells.append("<br>".join(filter(None, (cell(v.get(k), k) and "%s %s" % (label, cell(v.get(k), k))
                                                  for k, label in SHOWN.items()))))
        lines.append("| [%d](%s) | %s | %s | %s, %d of %d checks | %s |" % (
            r["run"], r["url"], r["at"][:10], r["commit"], r["conclusion"],
            r["checks_passed"], r["checks_passed"] + r["checks_failed"], " | ".join(cells)))
    with open(os.path.join(out, "history.md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print("history: %d runs, %d filled in from their artifacts" % (len(runs), added))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
