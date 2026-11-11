#!/usr/bin/env python3
"""ec2-capacity.py <refused|launches|judge|said|earlier|streak> - what EC2
gave the AWS run's GPU node group and what it refused (ADR 19, 2026-11-11).

scripts/aws.sh asks AWS and GitHub and hands the answers over as files;
nothing here calls out, so tests/static/aws-gpu-capacity.sh runs every part
against files alone.

  refused <hours> <events.json>...
            CloudTrail's RunInstances and CreateFleet events of the last
            <hours>: every launch EC2 refused in the account, by day, zone,
            type and reason. For the record, never a gate.
  launches <dir> [<type> <zone>]
            the GPU node group's state and health as EKS gives them, and its
            Auto Scaling group's launch attempts by zone and type. With the
            type and zone of the node the run got, the line the results keep
            for it.
  judge <dir>
            exit 0 only when the node group failed for want of capacity and
            nothing else: EKS gave it up (CREATE_FAILED), every health issue
            is AsgInstanceLaunchFailures naming InsufficientInstanceCapacity,
            its Auto Scaling group has launches on record, and every one of
            them was refused, for capacity. A launch that was not refused
            is an instance that may exist: not a miss. Writes
            <dir>/no-capacity.json. Anything else is the run's own failure:
            exit 1, with what it was.
  said <dir>
            the miss, said where a reader looks: a paragraph and a table in
            $GITHUB_STEP_SUMMARY, a warning on the run's page, and a
            measured line in $E2E_RESULTS.
  earlier <runs.json> <run number> <how many>
            the ids of the scheduled runs before this one, newest first.
  streak <dir> <run number> <limit> <how many>
            exit 1 when this scheduled run is the <limit>th in a row to be
            given no GPU. A scheduled run before it that was given a GPU
            node clears the count; one that asked for none, stopped before
            it asked, or whose GPU apply failed for another reason neither
            counts nor clears it. <dir> holds GitHub's list of the
            workflow's scheduled runs (runs.json) and the jobs of the
            <how many> before this one (jobs-<id>.json); one that is
            missing fails the rule, unread.

<dir> holds nodegroup.json (aws eks describe-nodegroup), subnets.json (aws
ec2 describe-subnets) and activities.json (aws autoscaling
describe-scaling-activities, every group's in one list).
"""
import collections
import json
import os
import re
import sys

# The names GitHub's API gives the job and its steps (.github/workflows/
# aws.yml); static check "aws" holds the workflow to them.
JOB = "Apply, load, check"
ASKED = "The GPU node, for the minutes it is measured"
MISSED = "No GPU, EC2 had none to give"

CAPACITY = re.compile(r"InsufficientInstanceCapacity|do not have sufficient \S+ capacity")
TYPE = re.compile(r"sufficient (\S+) capacity")
ZONE = re.compile(r"Availability Zone you requested \(([a-z0-9-]+)\)")


def load(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        if default is not None:
            return default
        raise


def clock(stamp):
    """HH:MM of an AWS timestamp, which the CLI prints as ISO 8601."""
    m = re.search(r"T(\d\d:\d\d)", str(stamp or ""))
    return m.group(1) if m else "?"


def attempt(activity):
    """One of the Auto Scaling group's activities, as a launch attempt."""
    text = "%s %s" % (activity.get("StatusMessage") or "", activity.get("Description") or "")
    try:
        details = json.loads(activity.get("Details") or "{}")
    except ValueError:
        details = {}
    zone = ZONE.search(text)
    itype = TYPE.search(text)
    reason = re.search(r"\b([A-Z][A-Za-z]+(?:Exceeded|Capacity|Operation|NotFound|Unsupported|Malformed|Invalid\w*))\b", text)
    return {
        "launch": (activity.get("Description") or "").startswith("Launching"),
        "status": activity.get("StatusCode") or "?",
        "zone": details.get("Availability Zone") or (zone.group(1) if zone else "?"),
        "type": itype.group(1) if itype else details.get("InstanceType") or "?",
        "capacity": bool(CAPACITY.search(text)),
        "reason": "InsufficientInstanceCapacity" if CAPACITY.search(text) else (reason.group(1) if reason else "another reason"),
        "at": activity.get("StartTime") or "",
        "text": " ".join(text.split()),
    }


def read(d):
    ng = load(os.path.join(d, "nodegroup.json"))["nodegroup"]
    subnets = load(os.path.join(d, "subnets.json"), [])
    activities = load(os.path.join(d, "activities.json"), [])
    launches = sorted((a for a in map(attempt, activities) if a["launch"]), key=lambda a: str(a["at"]))
    zones = sorted({s.get("AvailabilityZone", "?") for s in subnets})
    return ng, zones, launches


def by_pool(launches):
    """(zone, type, outcome) -> how many, the zones in order."""
    pools = collections.Counter()
    for a in launches:
        outcome = "launched" if a["status"] == "Successful" else (
            "refused, %s" % a["reason"] if a["status"] == "Failed" else a["status"])
        pools[(a["zone"], a["type"], outcome)] += 1
    return sorted(pools.items())


def refused_words(pools):
    """us-east-1a g6.xlarge x14, us-east-1b g6.xlarge x18"""
    return ", ".join("%s %s x%d" % (z, t, n) for (z, t, o), n in pools if o.startswith("refused"))


def results_line(line):
    """Append one measured line to $E2E_RESULTS, as the checks' scripts do."""
    out = os.environ.get("E2E_RESULTS")
    if not out:
        return
    d = load(out, {"checks": [], "measured": []})
    d.setdefault("measured", []).append(line)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=1)


def summary(text):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(text)


def cmd_launches(d, got_type=None, got_zone=None):
    ng, zones, launches = read(d)
    print("== the GPU node group %s is %s: asked %s, in %s" % (
        ng.get("nodegroupName", "?"), ng.get("status", "?"),
        " then ".join(ng.get("instanceTypes") or ["?"]), ", ".join(zones) or "no subnet it could read"))
    for issue in (ng.get("health") or {}).get("issues") or []:
        print("== EKS: %s: %s" % (issue.get("code"), " ".join((issue.get("message") or "").split())[:400]))
    pools = by_pool(launches)
    if launches:
        print("== %d launch attempt(s) by its Auto Scaling group, %s to %s UTC:" % (
            len(launches), clock(launches[0]["at"]), clock(launches[-1]["at"])))
        for (zone, itype, outcome), n in pools:
            print("   %-12s %-11s %s x%d" % (zone, itype, outcome, n))
    else:
        print("== its Auto Scaling group has no launch attempt on record")
    if got_type and got_zone:
        before = refused_words(pools)
        n = sum(n for (_, _, o), n in pools if o.startswith("refused"))
        line = "GPU node: %s in %s (%s)" % (got_type, got_zone, (
            "after %d launch(es) EC2 refused: %s" % (n, before) if n else "the first launch asked, none refused"))
        print("== " + line)
        results_line(line)
        summary("%s, of the zones %s.\n" % (line, ", ".join(zones) or "?"))
    return 0


def cmd_judge(d):
    try:
        ng, zones, launches = read(d)
    except (OSError, ValueError, KeyError):
        print("the GPU node group could not be read from EKS: the apply failed before or apart from it", file=sys.stderr)
        return 1
    why = []
    if ng.get("status") != "CREATE_FAILED":
        why.append("the node group is %s, not CREATE_FAILED" % ng.get("status", "in no state EKS names"))
    issues = (ng.get("health") or {}).get("issues") or []
    if not issues:
        why.append("EKS names no health issue for it")
    for issue in issues:
        message = " ".join((issue.get("message") or "").split())
        if issue.get("code") != "AsgInstanceLaunchFailures" or "InsufficientInstanceCapacity" not in message:
            why.append("EKS's health issue is %s: %s" % (issue.get("code"), message[:300]))
    refused = [a for a in launches if a["status"] == "Failed"]
    if not refused:
        why.append("its Auto Scaling group has no refused launch on record")
    for a in [a for a in refused if not a["capacity"]][:3]:
        why.append("a launch in %s was refused for %s: %s" % (a["zone"], a["reason"], a["text"][:300]))
    for a in [a for a in launches if a["status"] != "Failed"][:3]:
        why.append("a launch in %s at %s is %s, not refused: an instance may exist" % (a["zone"], clock(a["at"]), a["status"]))
    if why:
        print("the GPU node group did not fail for want of capacity alone: " + "; ".join(why), file=sys.stderr)
        return 1
    pools = by_pool(launches)
    record = {
        "gpu": "no capacity",
        "node_group": ng.get("nodegroupName"),
        "asked": ng.get("instanceTypes") or [],
        "zones": zones,
        "attempts": len(launches),
        "refused": [{"zone": z, "type": t, "times": n} for (z, t, o), n in pools if o.startswith("refused")],
        "first": refused[0]["at"],
        "last": refused[-1]["at"],
        "eks": [{"code": i.get("code"), "message": " ".join((i.get("message") or "").split())} for i in issues],
    }
    with open(os.path.join(d, "no-capacity.json"), "w", encoding="utf-8") as f:
        json.dump(record, f, indent=1)
    print("== no GPU capacity: EC2 refused all %d launch(es) of the GPU node for want of capacity, %s to %s UTC (%s), "
          "and EKS gave the node group up for that alone" % (
              len(refused), clock(record["first"]), clock(record["last"]), refused_words(pools)))
    return 0


def cmd_said(d):
    rec = load(os.path.join(d, "no-capacity.json"))
    times = sum(r["times"] for r in rec["refused"])
    where = ", ".join(rec["zones"]) or "?"
    asked = " then ".join(rec["asked"]) or "?"
    span = "%s to %s UTC" % (clock(rec["first"]), clock(rec["last"]))
    short = ("EC2 refused all %d launches of the GPU node (%s, in %s) for want of capacity, %s. No GPU node was made, "
             "nothing was measured on a GPU, and no GPU is billed. Every check before it stands." % (times, asked, where, span))
    rows = "".join("| %s | %s | %d |\n" % (r["zone"], r["type"], r["times"]) for r in rec["refused"])
    summary("\n### GPU: no capacity\n\n%s\n\n| Zone | Type | Launches EC2 refused (InsufficientInstanceCapacity) |\n|---|---|---|\n%s\n" % (short, rows))
    # One line: GitHub reads an annotation to the end of its line.
    print("::warning title=GPU: no capacity::%s" % short)
    results_line("GPU node: none, EC2 had no capacity (%d launches of %s refused in %s, %s; nothing was measured on a GPU in this run)" % (
        times, asked, where, span))
    return 0


def scheduled_before(runs_path, number):
    runs = load(runs_path).get("workflow_runs") or []
    return sorted((r for r in runs if r.get("event") == "schedule" and int(r.get("run_number", 0)) < int(number)),
                  key=lambda r: -int(r["run_number"]))


def cmd_earlier(runs_path, number, count):
    for r in scheduled_before(runs_path, number)[:int(count)]:
        print(r["id"])
    return 0


def cmd_streak(d, number, limit, count):
    limit = int(limit)
    misses, given, read_runs = [], None, 0
    for r in scheduled_before(os.path.join(d, "runs.json"), number)[:int(count)]:
        try:
            jobs = load(os.path.join(d, "jobs-%s.json" % r["id"])).get("jobs") or []
        except (OSError, ValueError):
            print("GitHub's word on scheduled run %s is not among its answers: the rule on runs in a row cannot be held, "
                  "and the run fails" % r["id"], file=sys.stderr)
            return 1
        steps = {}
        for job in jobs:
            if job.get("name") == JOB:
                steps = {s.get("name"): s.get("conclusion") for s in job.get("steps") or []}
        read_runs += 1
        if steps.get(MISSED) in ("success", "failure"):
            misses.append(r["id"])  # it was given none; "failure" is a run this rule already failed
        elif steps.get(ASKED) == "success":
            given = r["id"]  # the apply made a GPU node: EC2 had one
            break
        # Otherwise it asked EC2 for no GPU, stopped before it asked, or its
        # GPU apply failed for another reason: no GPU was measured, and EC2
        # was not shown to be out of one. Neither a miss nor a GPU.
    in_a_row = len(misses) + 1
    if in_a_row >= limit:
        print("the %s scheduled run in a row to be given no GPU, after %s: one week is EC2's weather, %d in a row leave the "
              "GPU unmeasured for as many weeks, and the run fails for it" % (
                  {2: "second", 3: "third"}.get(in_a_row, "%dth" % in_a_row), ", ".join(str(m) for m in misses), limit),
              file=sys.stderr)
        return 1
    print("== the first scheduled run in a row to be given no GPU: %s; the run fails at %d in a row" % (
        "the one before that asked for one, %s, was given one" % given if given
        else "none of the %d scheduled run(s) before it was given none" % read_runs, limit))
    return 0


def cmd_refused(hours, *paths):
    rows = collections.defaultdict(lambda: [0, "99:99", "00:00"])
    events = unread = 0
    for path in paths:
        try:
            batch = load(path)
        except (OSError, ValueError):
            unread += 1
            continue
        for raw in batch or []:
            try:
                e = json.loads(raw) if isinstance(raw, str) else raw
            except ValueError:
                continue
            events += 1
            stamp = e.get("eventTime") or ""
            found = []
            if e.get("errorCode"):
                found.append((e["errorCode"], e.get("errorMessage") or ""))

            # CreateFleet answers 200 and lists what it could not launch.
            def walk(node):
                if isinstance(node, dict):
                    if node.get("errorCode") and "errorMessage" in node:
                        found.append((node["errorCode"], node.get("errorMessage") or ""))
                    for v in node.values():
                        walk(v)
                elif isinstance(node, list):
                    for v in node:
                        walk(v)
            walk(e.get("responseElements"))
            for code, message in found:
                zone, itype = ZONE.search(message), TYPE.search(message)
                key = (stamp[:10], zone.group(1) if zone else "?", itype.group(1) if itype else "?", code.replace("Server.", "").replace("Client.", ""))
                row = rows[key]
                row[0] += 1
                row[1], row[2] = min(row[1], clock(stamp)), max(row[2], clock(stamp))
    if unread == len(paths):
        print("== CloudTrail could not be read: nothing to say about what EC2 refused")
        return 0
    print("== launches EC2 refused in the account in the last %s h, of %d launch call(s) CloudTrail holds (for the record):" % (hours, events))
    for (day, zone, itype, code), (n, first, last) in sorted(rows.items()):
        print("   %s  %-12s %-11s %-28s x%-3d %s to %s UTC" % (day, zone, itype, code, n, first, last))
    if not rows:
        print("   none")
    return 0


def main(argv):
    commands = {"refused": cmd_refused, "launches": cmd_launches, "judge": cmd_judge, "said": cmd_said,
                "earlier": cmd_earlier, "streak": cmd_streak}
    if len(argv) < 2 or argv[1] not in commands:
        print(__doc__.split("\n\n")[0], file=sys.stderr)
        return 2
    return commands[argv[1]](*argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
