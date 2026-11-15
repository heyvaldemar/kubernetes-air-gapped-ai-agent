#!/usr/bin/env python3
"""tests/static/status-scheduled.py - what scripts/status.py says of the schedule's own runs, against a GitHub made of lists.

No token, no network. Each case is the list of runs GitHub would give for
the window, newest first as its API lists them, and what the first attempt
of a run came to where somebody ran it again. A page says "weekly" or
"daily" on scheduled_streak (ADR 18, 2026-11-15), so each case is a way
that word could be said of something the schedule did not do. Run by static
check "status".

  A  the latest scheduled run failed: nothing in a row
  B  two scheduled runs passed in a row after one that failed: two, named
     newest first, and GitHub is asked nothing more
  C  runs by hand between them and after them, green and red: the same count
  D  a push's run between them: the same count
  E  the latest scheduled run was cancelled: a run, not a pass, nothing in a row
  F  the latest scheduled run was skipped by its own guard: the same
  G  a scheduled run that timed out between two that passed: one in a row
  H  a scheduled run that failed and was run again to green: read by its
     first attempt, and GitHub is asked for that attempt alone
  I  a scheduled run that passed and was run again to red: still the
     schedule's pass
  J  a scheduled run still going: not counted, and it stops nothing
  K  no scheduled run in the window: zero of zero, nothing in a row
  L  the record status.py writes carries the counts, the runs in a row and
     what started the latest run, beside what it carried before; and a
     scheduled run EC2 gave no GPU (ADR 19) counts as GitHub concluded it
"""
import contextlib
import importlib.util
import io
import json
import os
import re
import shutil
import sys
import tempfile
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REPO = "heyvaldemar/kubernetes-air-gapped-ai-agent"
spec = importlib.util.spec_from_file_location("status", os.path.join(ROOT, "scripts", "status.py"))
status = importlib.util.module_from_spec(spec)
spec.loader.exec_module(status)
results, failed = [], 0


def check(ok, what):
    global failed
    results.append(("PASS  " if ok else "FAIL  ") + what)
    failed |= not ok


def run(n, day, event, conclusion="success", attempt=1, state="completed"):
    return {"id": n, "event": event, "status": state, "conclusion": conclusion if state == "completed" else None,
            "run_attempt": attempt, "created_at": "2026-11-%02dT02:47:00Z" % day,
            "html_url": "https://example.invalid/runs/%d" % n, "head_sha": "%040x" % n}


class GitHub:
    """What GitHub answers beyond the list: a run's first attempt, and for
    case L the latest run's results. Anything else it is asked fails the
    case."""

    def __init__(self, first=None, measured=None):
        self.first = first or {}
        self.measured = measured
        self.asked = []

    def get(self, url, raw=False):
        self.asked.append(url)
        attempt = re.fullmatch(r"/repos/%s/actions/runs/(\d+)/attempts/1" % re.escape(REPO), url)
        if attempt and int(attempt.group(1)) in self.first:
            return {"conclusion": self.first[int(attempt.group(1))]}
        if self.measured is not None and re.fullmatch(r"/repos/%s/actions/runs/\d+/artifacts" % re.escape(REPO), url):
            return {"artifacts": [{"name": "e2e-results-aws", "expired": False, "archive_download_url": "zip"}]}
        if self.measured is not None and raw and url == "zip":
            buf = io.BytesIO()
            with zipfile.ZipFile(buf, "w") as z:
                z.writestr("e2e-results.json", json.dumps({"checks": [{"name": "the boundary", "passed": True}],
                                                           "measured": self.measured}))
            return buf.getvalue()
        raise AssertionError("GitHub was asked for " + url)


def counts(oldest_first, first=None):
    gh = GitHub(first)
    status.get = gh.get
    c = status.scheduled_counts(REPO, list(reversed(oldest_first)))
    return (c["scheduled_runs"], c["scheduled_passed"], c["scheduled_streak"]), [r["id"] for r in c["scheduled_in_a_row"]], gh.asked


def case(letter, what, body):
    try:
        check(body(), "%-2s %s" % (letter, what))
    except Exception as e:  # a case that cannot be read is a case that failed
        check(False, "%-2s %s (%s: %s)" % (letter, what, type(e).__name__, e))


def record():
    """Case L: the whole of status.py's main, its GitHub made of the same lists."""
    listed = [run(1, 5, "schedule"), run(2, 8, "workflow_dispatch", "failure"), run(3, 12, "schedule")]
    gh = GitHub(measured=["GPU node: none, EC2 had no capacity (5 launches refused)"])
    status.get = gh.get
    status.runs = lambda repo, workflow, since: list(reversed(listed))
    tmp = tempfile.mkdtemp(prefix="status-scheduled-")
    os.environ.update(GITHUB_REPOSITORY=REPO, E2E_WORKFLOW="aws.yml", BADGE_LABEL="on AWS")
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            status.main(tmp)
        with open(os.path.join(tmp, "status.json")) as f:
            s = json.load(f)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return ((s["scheduled_runs"], s["scheduled_passed"], s["scheduled_streak"]) == (2, 2, 2)
            and [r["id"] for r in s["scheduled_in_a_row"]] == [3, 1]
            and s["scheduled_in_a_row"][0] == {"id": 3, "at": "2026-11-12T02:47:00Z",
                                               "url": "https://example.invalid/runs/3", "commit": "0000000"}
            and all(type(s[k]) is int for k in ("scheduled_runs", "scheduled_passed", "scheduled_streak"))
            and s["latest"]["event"] == "schedule" and s["latest"]["conclusion"] == "success"
            and s["latest"]["measured"] == ["aws · GPU node: none, EC2 had no capacity (5 launches refused)"]
            and (s["runs"], s["runs_passed"], s["days_with_runs"], s["green_days"], s["streak_days"]) == (3, 2, 3, 2, 1)
            and (s["latest"]["checks_passed"], s["latest"]["checks_failed"]) == (1, 0))


def main():
    two = [run(1, 5, "schedule", "failure"), run(2, 12, "schedule"), run(3, 19, "schedule")]
    case("A", "the latest scheduled run failed: nothing in a row",
         lambda: counts([run(1, 5, "schedule"), run(2, 12, "schedule"), run(3, 19, "schedule", "failure")])
         == ((3, 2, 0), [], []))
    case("B", "two scheduled runs passed in a row after one that failed: two, newest first, and GitHub is asked nothing more",
         lambda: counts(two) == ((3, 2, 2), [3, 2], []))
    case("C", "runs by hand between them and after them, green and red, do not change the count",
         lambda: counts([two[0], run(4, 6, "workflow_dispatch"), two[1], run(5, 14, "workflow_dispatch"),
                         run(6, 15, "workflow_dispatch", "failure"), two[2], run(7, 20, "workflow_dispatch", "failure")])
         == ((3, 2, 2), [3, 2], []))
    case("D", "a push's run between them does not change the count",
         lambda: counts([two[0], two[1], run(4, 13, "push", "failure"), run(5, 14, "push"), two[2]])
         == ((3, 2, 2), [3, 2], []))
    case("E", "the latest scheduled run was cancelled: a run, not a pass, nothing in a row",
         lambda: counts([run(1, 5, "schedule"), run(2, 12, "schedule"), run(3, 19, "schedule", "cancelled")])
         == ((3, 2, 0), [], []))
    case("F", "the latest scheduled run was skipped by its own guard: a run, not a pass, nothing in a row",
         lambda: counts([run(1, 5, "schedule"), run(2, 12, "schedule"), run(3, 19, "schedule", "skipped")])
         == ((3, 2, 0), [], []))
    case("G", "a scheduled run that timed out between two that passed: one in a row",
         lambda: counts([run(1, 5, "schedule"), run(2, 12, "schedule", "timed_out"), run(3, 19, "schedule")])
         == ((3, 2, 1), [3], []))
    case("H", "a scheduled run that failed and was run again to green is read by its first attempt, and GitHub is asked for that alone",
         lambda: counts([run(1, 12, "schedule"), run(2, 19, "schedule", "success", attempt=2)], first={2: "failure"})
         == ((2, 1, 0), [], ["/repos/%s/actions/runs/2/attempts/1" % REPO]))
    case("I", "a scheduled run that passed and was run again to red is still the schedule's pass",
         lambda: counts([run(1, 12, "schedule"), run(2, 19, "schedule", "failure", attempt=3)], first={2: "success"})
         == ((2, 2, 2), [2, 1], ["/repos/%s/actions/runs/2/attempts/1" % REPO]))
    case("J", "a scheduled run still going is not counted and stops nothing",
         lambda: counts([run(1, 12, "schedule"), run(2, 19, "schedule"), run(3, 26, "schedule", state="in_progress")])
         == ((2, 2, 2), [2, 1], []))
    case("K", "no scheduled run in the window: zero of zero, nothing in a row",
         lambda: counts([run(1, 12, "workflow_dispatch"), run(2, 19, "push")]) == ((0, 0, 0), [], []))
    case("L", "the record carries the counts, the runs in a row and what started the latest run, beside what it carried; "
              "a scheduled run EC2 gave no GPU counts as GitHub concluded it", record)
    print("\n".join(results))
    print(f"{sum(r.startswith('PASS') for r in results)} of {len(results)} cases passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
