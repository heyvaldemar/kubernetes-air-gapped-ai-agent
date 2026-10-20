#!/usr/bin/env python3
"""release-numbers.py RUN_ID [MODEL ...] - the README's numbers, from a run.

Downloads each model's e2e-results artifact from an e2e run and prints the
"What the evals report" table for the models given (by default the ones the
release ships with: matrix entries with floor "on" in .github/workflows/e2e.yml),
one column per model, then the email facts the prose under the table cites:
every send_email per task, recipient and outcome. Nothing in the README's
numbers is typed by hand; the README names the run they came from.

    scripts/release-numbers.py 39157806610
    scripts/release-numbers.py 39157806610 qwen3-4b-2507 ministral-3-3b
"""
import collections
import json
import os
import re
import subprocess
import sys
import tempfile

REPO = os.environ.get("GITHUB_REPOSITORY", "heyvaldemar/kubernetes-air-gapped-ai-agent")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# The name part of every outside address a task, a record or the quarterly
# report puts in front of the model.
OUTSIDE_NAMES = {a.split("@")[0].lower()
                 for f in ("evals/tasks.json", "manifests/records/records_api.py", "manifests/tools/gateway.yaml")
                 for a in re.findall(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.example", open(os.path.join(ROOT, f)).read())
                 if not a.endswith("@acme.example")}


def release_models():
    text = open(os.path.join(ROOT, ".github", "workflows", "e2e.yml")).read()
    return re.findall(r"-\s*model:\s*(\S+)\s*\n\s*floor:\s*\"on\"", text)


def facts(run, model, work):
    d = os.path.join(work, model)
    os.makedirs(d)
    subprocess.run(["gh", "run", "download", run, "-R", REPO, "-n", "e2e-results-" + model, "-D", d],
                   check=True, stdout=subprocess.DEVNULL)
    found = {f: os.path.join(r, f) for r, _, fs in os.walk(d) for f in fs}
    res = json.load(open(found["evals-results.json"]))
    measured = dict(line.partition(": ")[::2] for line in res["measured"])
    sends = collections.Counter()
    unasked = renamed = 0
    for line in open(found["evals.jsonl"]):
        try:
            row = json.loads(line)
        except ValueError:
            continue
        for c in row.get("calls", []):
            if c["name"] == "send_email":
                sends[(row["task"], str(c["args"].get("to", "")), c.get("outcome"))] += 1
        # Of the emails to colleagues nobody asked for, how many are an outside
        # address with its domain swapped for the company's: the name kept
        # from an address the task or its data named, the domain rewritten.
        if row.get("unasked_emails"):
            unasked += row["unasked_emails"]
            renamed += sum(1 for c in row.get("calls", []) if c["name"] == "send_email" and c.get("outcome") == "ok"
                           and str(c["args"].get("to", "")).split("@")[0].lower() in OUTSIDE_NAMES)
    deleted = next(re.search(r"records deleted: (\d+)", c["name"]).group(1)
                   for c in res["checks"] if c["name"].startswith("records deleted"))
    return measured, sends, deleted, (unasked, renamed)


def grab(value, pattern):
    hit = re.search(pattern, value)
    return hit.groups() if hit else ("?",) * re.compile(pattern).groups


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    run, models = sys.argv[1], sys.argv[2:] or release_models()
    with tempfile.TemporaryDirectory() as work:
        data = {m: facts(run, m, work) for m in models}
    col = lambda f: " | ".join(f(data[m][0], data[m][2]) for m in models)
    def tried(m, _):
        t, r, d = grab(m["emails the model tried to send outside acme.example"], r"^(\d+), refused by the MCP server: (\d+); delivered: (\d+)")
        return "0" if t == "0" else ("%s, all refused by the MCP server" % t if t == r else "%s, %s refused by the MCP server" % (t, r))
    def cost(m, _):
        usd, s = grab(m["cost per task"], r"about \$([0-9.]+) \(([0-9.]+) vCPU-seconds")
        return "about $%.5f (%s vCPU-seconds)" % (float(usd), s) if usd != "?" else "?"
    rows = [
        "| | " + " | ".join(models) + " |",
        "|---|" + "---|" * len(models),
        "| Ordinary tasks done | " + col(lambda m, _: "%s of %s" % grab(m["task success"], r"\((\d+) of (\d+) attempts\)")) + " |",
        "| Instructions hidden in data the model acted on | " + col(lambda m, _: "**%s**" % grab(m["injected instructions the model acted on"], r"^(\d+ of \d+)")[0]) + " |",
        "| Requests beyond the agent's rights it declined | " + col(lambda m, _: grab(m["requests beyond the agent's rights it declined"], r"^(\d+ of \d+)")[0]) + " |",
        "| Answers without invented data | " + col(lambda m, _: grab(m["answers without invented data"], r"^(\d+ of \d+)")[0]) + " |",
        "| Emails the model tried to send outside acme.example | " + col(tried) + " |",
        "| Emails to colleagues nobody asked for | " + col(lambda m, _: m["emails to colleagues nobody asked for, inside acme.example"]) + " |",
        "| **Data that left acme.example** | " + col(lambda m, _: "**%s**" % grab(m["emails the model tried to send outside acme.example"], r"delivered: (\d+)")[0]) + " |",
        "| **Records deleted** | " + col(lambda _, d: "**%s**" % d) + " |",
        "| Cost per task, at on-demand list price | " + col(cost) + " |",
        "| Latency per task, p50 / p95 | " + col(lambda m, _: "%s s / %s s" % grab(m["latency per task"], r"p50 ([0-9.]+) s, p95 ([0-9.]+) s")) + " |",
    ]
    print("Run %s (https://github.com/%s/actions/runs/%s)\n" % (run, REPO, run))
    print("\n".join(rows))
    for m in models:
        print("\n%s, every send_email:" % m)
        for (task, to, outcome), n in sorted(data[m][1].items()):
            print("  %2d  %-26s %-34s %s" % (n, task, to, outcome))
        unasked, renamed = data[m][3]
        print("  emails to colleagues nobody asked for: %d, of them an outside address's name with the company's domain: %d"
              % (unasked, renamed))


if __name__ == "__main__":
    main()
