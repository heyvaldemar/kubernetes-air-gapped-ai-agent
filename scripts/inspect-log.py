#!/usr/bin/env python3
"""inspect-log.py RESULTS_DIR OUT_DIR - the agent's evals as Inspect logs.

    RUN_ID=... RUN_CREATED=... RUN_COMMIT=... GITHUB_REPOSITORY=owner/name \\
        scripts/inspect-log.py out/run out/inspect

Reads what one e2e run uploaded, one directory per model job as `gh run
download` writes them (e2e-results-<model>/, holding evals.jsonl and
e2e-results.json), and writes OUT_DIR/<model>.eval for each: a log that
Inspect's viewer opens (`inspect view --log-dir OUT_DIR`). Inspect is the
evaluation framework of the UK AI Security Institute. The harness here is not
Inspect, so this is a translation, and each log says so in its metadata:

- A sample is one attempt at one task: the task's id, the attempt as its
  epoch. The input is the task's prompt from evals/tasks.json, the target what
  the task expects, the score the harness's own pass or fail with its reasons.
- The messages are rebuilt from the harness log: the system prompt, the
  user's request, each tool call the model made with its arguments, and the
  answer. The log keeps a tool call's outcome (ok, refused, invalid), not the
  text the tool returned, so a tool message carries the outcome alone; the
  answer is the first 300 characters the log keeps.
- Token usage is the model server's own count for the attempt.
- The run's gates and measurements (scripts/evals.sh) go in the log's
  metadata. Nothing here is computed but sums and rates of the run's lines.

Each log is read back with Inspect's own reader before the script exits.
Needs inspect_ai, pinned with its dependencies by hash in
scripts/inspect-requirements.txt (`uv pip compile --universal --generate-hashes`,
nothing newer than two weeks before the pin).
"""
import json
import os
import sys

from inspect_ai.log import (EvalConfig, EvalDataset, EvalError, EvalLog, EvalMetric, EvalResults,
                            EvalRevision, EvalSample, EvalScore, EvalSpec, EvalStats, read_eval_log,
                            write_eval_log)
from inspect_ai.model import (ChatMessageAssistant, ChatMessageSystem, ChatMessageTool, ChatMessageUser,
                              ModelOutput, ModelUsage)
from inspect_ai.scorer import Score
from inspect_ai.tool import ToolCall

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "evals"))
from harness import SYSTEM  # noqa: E402  the prompt the agent ran with, from the harness itself

TRANSLATION = ("Translated from the harness log of this repository's e2e run by scripts/inspect-log.py. "
               "Tool messages carry the call's outcome, not the text the tool returned; answers are the "
               "first 300 characters the log keeps. Scores are the harness's own.")


def find(top, name):
    """Every file called name under top, hidden directories included."""
    for d, _, files in os.walk(top):
        if name in files:
            yield os.path.join(d, name)


def target(expect):
    parts = ["calls %s %s" % (c["name"], json.dumps(c.get("args", {}), sort_keys=True))
             for c in expect.get("calls", [])]
    parts += ["never calls %s" % n for n in expect.get("never", [])]
    if expect.get("no_tools"):
        parts.append("calls no tool")
    parts += ["answer has %s" % (s if isinstance(s, str) else " or ".join(s)) for s in expect.get("answer_has", [])]
    parts += ["answer lacks %s" % s for s in expect.get("answer_lacks", [])]
    return "; ".join(parts) or "no expectation"


def usage(rows):
    inp = sum(r["prompt_tokens"] + r["cached_tokens"] for r in rows)
    out = sum(r["completion_tokens"] for r in rows)
    return ModelUsage(input_tokens=inp, output_tokens=out, total_tokens=inp + out,
                      input_tokens_cache_read=sum(r["cached_tokens"] for r in rows))


def sample(model, task, row):
    messages = [ChatMessageSystem(content=SYSTEM), ChatMessageUser(content=task["user"])]
    for n, c in enumerate(row["calls"], 1):
        call_id = "call-%d" % n
        messages.append(ChatMessageAssistant(content="", model=model, tool_calls=[
            ToolCall(id=call_id, function=c["name"], arguments=c["args"] if isinstance(c["args"], dict) else {})]))
        messages.append(ChatMessageTool(content="[%s]" % c["outcome"], tool_call_id=call_id, function=c["name"]))
    messages.append(ChatMessageAssistant(content=row["answer"], model=model))
    return EvalSample(
        id=task["id"], epoch=row["attempt"], input=task["user"], target=target(task["expect"]),
        messages=messages, output=ModelOutput.from_content(model, row["answer"]),
        scores={"harness": Score(value="C" if row["passed"] else "I",
                                 explanation="; ".join(row["why"]) or "passed",
                                 metadata={"category": row["category"], "owasp": row["owasp"],
                                           "unasked_emails": row["unasked_emails"]})},
        metadata={"category": row["category"], "owasp": row["owasp"], "seconds": row["seconds"],
                  "vcpu_seconds": row["vcpu_seconds"], "calls": row["calls"]},
        model_usage={model: usage([row])}, total_time=row["seconds"], working_time=row["seconds"])


def log_for(job_dir, tasks, run):
    name = os.path.basename(job_dir)[len("e2e-results-"):]
    model = "llama-cpp/" + name
    rows = [r for r in (json.loads(line) for f in find(job_dir, "evals.jsonl") for line in open(f) if line.strip())
            if "attempt" in r]
    if not rows:
        return None
    results = next((json.load(open(f)) for f in find(job_dir, "e2e-results.json")), {"checks": [], "measured": []})
    failed = [c["name"] for c in results.get("checks", []) if not c.get("passed")]
    rate = lambda rs: sum(r["passed"] for r in rs) / len(rs)  # noqa: E731
    by_cat = {}
    for r in rows:
        by_cat.setdefault(r["category"], []).append(r)
    metrics = {"accuracy": EvalMetric(name="accuracy", value=rate(rows))}
    metrics.update({c: EvalMetric(name=c, value=rate(rs)) for c, rs in sorted(by_cat.items())})
    spec = EvalSpec(
        run_id=str(run["id"]), created=run["created"], task="boundary-agent-evals",
        dataset=EvalDataset(name="acme-support-tasks", location="evals/tasks.json",
                            samples=len(tasks), sample_ids=list(tasks)),
        model=model, config=EvalConfig(epochs=max(r["attempt"] for r in rows)),
        revision=EvalRevision(type="git", origin="https://github.com/%s" % run["repo"], commit=run["commit"]),
        metadata={"translation": TRANSLATION, "run": "https://github.com/%s/actions/runs/%s" % (run["repo"], run["id"])})
    return EvalLog(
        status="error" if failed else "success",
        error=EvalError(message="gates failed: " + "; ".join(failed), traceback="", traceback_ansi="") if failed else None,
        eval=spec,
        results=EvalResults(total_samples=len(rows), completed_samples=len(rows),
                            scores=[EvalScore(name="harness", scorer="harness", scored_samples=len(rows),
                                              metrics=metrics)]),
        # No start or finish time: the run's artifacts do not say when the evals
        # began, and a made-up duration would be worse than none.
        stats=EvalStats(model_usage={model: usage(rows)}),
        metadata={"translation": TRANSLATION, "gates": results.get("checks", []),
                  "measured": results.get("measured", [])},
        samples=[sample(model, tasks[r["task"]], r) for r in rows])


def main(src, out):
    run = {"id": os.environ["RUN_ID"], "created": os.environ["RUN_CREATED"], "commit": os.environ["RUN_COMMIT"],
           "repo": os.environ["GITHUB_REPOSITORY"]}
    tasks = {t["id"]: t for t in json.load(open(os.path.join(ROOT, "evals", "tasks.json")))}
    os.makedirs(out, exist_ok=True)
    written = 0
    for d in sorted(os.listdir(src)):
        if not d.startswith("e2e-results-"):
            continue
        log = log_for(os.path.join(src, d), tasks, run)
        if log is None:
            continue
        path = os.path.join(out, d[len("e2e-results-"):] + ".eval")
        write_eval_log(log, path)
        back = read_eval_log(path)
        if len(back.samples or []) != len(log.samples) or back.eval.model != log.eval.model:
            sys.exit("%s does not read back as it was written" % path)
        print("%s: %d samples, accuracy %.2f, %s" % (path, len(back.samples), back.results.scores[0].metrics["accuracy"].value,
                                                     back.status))
        written += 1
    if written == 0:
        # A run that failed before its evals has nothing to translate; the status
        # branch is still written, without logs.
        print("no model job with an evals log under %s: no Inspect log written" % src)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip().splitlines()[0])
    main(sys.argv[1], sys.argv[2])
