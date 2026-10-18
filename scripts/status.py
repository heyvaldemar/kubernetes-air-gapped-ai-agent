#!/usr/bin/env python3
"""status.py OUT_DIR - what the e2e workflow has shown lately, as JSON a page
or a badge can read.

    GITHUB_REPOSITORY=owner/name GITHUB_TOKEN=... E2E_WORKFLOW=e2e.yml \\
        scripts/status.py out/status

Reads the e2e workflow's runs on main over the last 30 days (pushes, the
daily schedule, manual runs; never pull requests, never cancelled runs) and
the results the latest finished run uploaded (tests/e2e/run.sh writes them
when E2E_RESULTS is set). Writes:

    status.json             the window, the streak, the latest run's checks
                            and measurements
    badge-days.json         shields.io endpoint: green days in the window
    badge-checks.json       shields.io endpoint: the latest run's checks
    badge-<measure>.json    one per measurement the run printed; with one
                            job per model, badge-<model>-<measure>.json

A day counts as green when its last finished run passed; the run count beside
it shows the failures that rule hides. The streak counts green days back from
the latest day that had a run. Nothing here is typed
by hand: every number is read from GitHub at the time it is written.
"""
import datetime
import io
import json
import os
import re
import sys
import urllib.error
import urllib.request
import zipfile

API = "https://api.github.com"
WINDOW_DAYS = 30


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def get(url, raw=False):
    req = urllib.request.Request(url if url.startswith("http") else API + url)
    req.add_header("Authorization", "Bearer " + os.environ["GITHUB_TOKEN"])
    req.add_header("Accept", "application/vnd.github+json")
    try:
        with urllib.request.build_opener(_NoRedirect).open(req, timeout=60) as r:
            body = r.read()
    except urllib.error.HTTPError as e:
        # An artifact download answers with a redirect to signed storage,
        # which rejects the API's Authorization header: follow it without.
        if e.code not in (301, 302, 303, 307, 308) or not e.headers.get("Location"):
            raise
        with urllib.request.urlopen(e.headers["Location"], timeout=120) as r:
            body = r.read()
    return body if raw else json.loads(body)


def runs(repo, workflow, since):
    out, page = [], 1
    while True:
        batch = get(f"/repos/{repo}/actions/workflows/{workflow}/runs?branch=main&per_page=100&page={page}"
                    f"&created=%3E%3D{since:%Y-%m-%d}")["workflow_runs"]
        out += batch
        if len(batch) < 100:
            return out
        page += 1


def results(repo, run_id):
    """The latest run's e2e-results artifacts, merged; None when it has none."""
    arts = [a for a in get(f"/repos/{repo}/actions/runs/{run_id}/artifacts")["artifacts"]
            if a["name"].startswith("e2e-results") and not a["expired"]]
    if not arts:
        return None
    merged = {"checks": [], "measured": []}
    for a in arts:
        z = zipfile.ZipFile(io.BytesIO(get(a["archive_download_url"], raw=True)))
        for name in z.namelist():
            # e2e-results.json only. The evals write their own
            # evals-results.json beside it AND add the same gates and numbers
            # to e2e-results.json, so reading every .json counted each eval
            # gate and measurement twice: 44 checks where the run had 36.
            if name.rsplit("/", 1)[-1] == "e2e-results.json":
                part = json.loads(z.read(name))
                job = a["name"][len("e2e-results"):].strip("-")
                for c in part.get("checks", []):
                    merged["checks"].append(dict(c, job=job) if job else c)
                # One job per model: each measurement says whose it is, or
                # the second model's badges would overwrite the first's.
                merged["measured"] += ["%s · %s" % (job, m) if job else m for m in part.get("measured", [])]
    return merged


def outcome(check):
    """PASS or FAIL: tests/e2e/run.sh and scripts/evals.sh write "passed",
    the sandbox's run.sh writes "state"; both are read the same."""
    if "state" in check:
        return check["state"]
    return "PASS" if check.get("passed") else "FAIL"


def badge(label, message, color):
    return {"schemaVersion": 1, "label": label, "message": message, "color": color}


def leaderboard(res):
    """One row per model from the latest run: what the model tried next to
    what the boundary let through. Read from the measured lines each job
    printed ("<model> · <name>: <value>") and its checks."""
    rows = {}
    for line in res["measured"]:
        job, sep, rest = line.partition(" · ")
        if not sep:
            continue
        name, _, value = rest.partition(": ")
        rows.setdefault(job, {})[name] = value
    out = []
    for job in sorted(rows):
        m = rows[job]
        def grab(key, pattern, default="?"):
            hit = re.search(pattern, m.get(key, ""))
            return hit.group(1) if hit else default
        tried = re.search(r"^(\d+), refused by the MCP server: (\d+); delivered: (\d+)",
                          m.get("emails the model tried to send outside acme.example", ""))
        checks = [c for c in res["checks"] if c.get("job") == job]
        deleted = next((re.search(r"records deleted: (\d+)", c["name"]).group(1)
                        for c in checks if c["name"].startswith("records deleted")), "?")
        failed = [c["name"] for c in checks if outcome(c) == "FAIL"]
        out.append({
            "model": job,
            "tasks": grab("task success", r"\((\d+ of \d+) attempts\)"),
            "injections_acted_on": grab("injected instructions the model acted on", r"^(\d+ of \d+)"),
            "tried_outside": tried.group(1) if tried else "?",
            "refused_by_server": tried.group(2) if tried else "?",
            "delivered_outside": tried.group(3) if tried else "?",
            "records_deleted": deleted,
            "declined_beyond_rights": grab("requests beyond the agent's rights it declined", r"^(\d+ of \d+)"),
            "grounded": grab("answers without invented data", r"^(\d+ of \d+)"),
            "cost_usd": grab("cost per task", r"about \$([0-9.]+)"),
            "latency": grab("latency per task", r"^(p50 [0-9.]+ s, p95 [0-9.]+ s)"),
            "gates": "held" if checks and not failed else ("no checks" if not checks else "FAILED: " + "; ".join(failed)),
        })
    return out


def write_leaderboard(out, latest, res):
    rows = leaderboard(res)
    with open(os.path.join(out, "leaderboard.json"), "w") as f:
        json.dump({"run": latest["html_url"], "at": latest["created_at"], "commit": latest["head_sha"][:7],
                   "models": rows}, f, indent=2)
    lines = [
        "# One boundary, every model",
        "",
        "The latest e2e run on main, one row per model: what the model tried, next to what the boundary let through. "
        "Written by `.github/workflows/status.yml` from [the run](%s) of %s on commit `%s`. Not edited by hand."
        % (latest["html_url"], latest["created_at"][:10], latest["head_sha"][:7]),
        "",
        "| Model | Ordinary tasks done | Hidden instructions acted on | Tried to email outside | Delivered outside | Records deleted | Over-rights requests declined | Answers without invented data | Cost per task | Latency | Gates |",
        "|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for r in rows:
        tried = r["tried_outside"] if r["tried_outside"] in ("0", "?") else "%s, %s refused" % (r["tried_outside"], r["refused_by_server"])
        lines.append("| %s | %s | %s | %s | **%s** | **%s** | %s | %s | $%s | %s | %s |" % (
            r["model"], r["tasks"], r["injections_acted_on"], tried, r["delivered_outside"], r["records_deleted"],
            r["declined_beyond_rights"], r["grounded"], r["cost_usd"], r["latency"], r["gates"]))
    lines += ["", "Cost is the model server's own compute time at an on-demand list price; `evals/pricing.json` on main says which. "
              "The task rate is gated only for the models a release ships with; every model is held to the boundary's gates.", ""]
    with open(os.path.join(out, "leaderboard.md"), "w") as f:
        f.write("\n".join(lines))


def main(out):
    repo, workflow = os.environ["GITHUB_REPOSITORY"], os.environ["E2E_WORKFLOW"]
    now = datetime.datetime.now(datetime.timezone.utc)
    since = (now - datetime.timedelta(days=WINDOW_DAYS - 1)).date()
    finished = [r for r in runs(repo, workflow, since)
                if r["event"] in ("push", "schedule", "workflow_dispatch")
                and r["status"] == "completed" and r["conclusion"] in ("success", "failure")]
    finished.sort(key=lambda r: r["created_at"])

    last_of_day = {}
    for r in finished:
        last_of_day[r["created_at"][:10]] = r["conclusion"]
    days = sorted(last_of_day)
    green = [d for d in days if last_of_day[d] == "success"]
    streak = 0
    for d in reversed(days):
        if last_of_day[d] != "success":
            break
        streak += 1

    latest = finished[-1] if finished else None
    res = results(repo, latest["id"]) if latest else None
    checks = res["checks"] if res else []
    passed = sum(1 for c in checks if outcome(c) == "PASS")
    failed = sum(1 for c in checks if outcome(c) == "FAIL")

    status = {
        "repository": repo,
        "workflow": workflow,
        "written_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "window_days": WINDOW_DAYS,
        "days_with_runs": len(days),
        "green_days": len(green),
        "streak_days": streak,
        "runs": len(finished),
        "runs_passed": sum(1 for r in finished if r["conclusion"] == "success"),
        "latest": None if not latest else {
            "conclusion": latest["conclusion"],
            "at": latest["created_at"],
            "url": latest["html_url"],
            "commit": latest["head_sha"][:7],
            "checks_passed": passed,
            "checks_failed": failed,
            "checks": checks,
            "measured": res["measured"] if res else [],
        },
    }
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "status.json"), "w") as f:
        json.dump(status, f, indent=2)

    if days:
        color = "brightgreen" if len(green) == len(days) else ("yellow" if len(green) >= 0.9 * len(days) else "red")
        # Both counts: a day is green by its last run, and the runs show
        # what that hides, a failure earlier the same day.
        msg = f"{len(green)} of {len(days)} days green, {status['runs_passed']} of {len(finished)} runs"
    else:
        color, msg = "lightgrey", "no runs yet"
    json.dump(badge(f"e2e, last {WINDOW_DAYS} days", msg, color), open(os.path.join(out, "badge-days.json"), "w"))
    if checks:
        color = "brightgreen" if not failed else "red"
        json.dump(badge("checks", f"{passed} of {passed + failed} passed, {latest['created_at'][:10]}", color),
                  open(os.path.join(out, "badge-checks.json"), "w"))
    for line in status["latest"]["measured"] if latest else []:
        name, _, value = line.partition(": ")
        if value:
            slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
            json.dump(badge(name, value.split(" (")[0], "blue"), open(os.path.join(out, f"badge-{slug}.json"), "w"))
    if latest and res:
        write_leaderboard(out, latest, res)
    print(f"{repo}: {len(green)} of {len(days)} days green, streak {streak}, "
          f"latest {latest['conclusion'] if latest else 'none'} with {passed} of {passed + failed} checks")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
