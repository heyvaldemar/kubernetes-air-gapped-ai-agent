#!/usr/bin/env python3
"""capacity.py - what one model server sustains, measured with the agent's own
requests at rising concurrency.

    scripts/capacity.py run URL OUT.json [LEVELS]   LEVELS like 1,2,4,8
    scripts/capacity.py table DIR                   every OUT.json in DIR, as one table

Each request is the first model call of an eval task, exactly as the harness
sends it: the system prompt, the task's user message, and the three tools the
support agent is offered, from the MCP server's own table and policy. The
first call is the heaviest of a task (the whole prompt, no cache yet), so a
call here costs at least what a call costs in the evals. The server is any
OpenAI-compatible one at URL; .github/workflows/capacity.yml runs llama-server
on a runner with a model from models/models.lock under several slot and
thread counts.

At each concurrency C, C workers send 6 x C requests between them, a request
starting as soon as a worker is free. With MIN_SECONDS set, a level goes on
until it has lasted that long as well, and starts with one untimed round of
C calls: a GPU answers 6 x C calls in about a second, too short a window
to read a rate from (ADR 19). Reported per level: calls a minute,
p50 and p95 latency, output tokens a second, and how many failed. A failed
call counts against the level; a level is never reported on its successes
alone. Capacity is in model calls, not tasks: a task takes one to six calls,
and evals/ reports the busiest minute in calls too.
"""
import concurrent.futures
import glob
import json
import os
import statistics
import sys
import threading
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "evals"))
sys.path.insert(0, os.path.join(ROOT, "manifests", "mcp"))


def requests():
    """The first call of every eval task, as the harness makes it."""
    import harness
    import server
    policy = json.load(open(os.path.join(ROOT, "manifests", "mcp", "policy.json")))
    granted = policy["identities"]["system:serviceaccount:agents:support-agent"]["tools"]
    offered = [{"type": "function", "function": {"name": d["name"], "description": d.get("description", ""),
                                                 "parameters": harness.shown(d.get("inputSchema", {"type": "object"}))}}
               for d in (server.TOOLS[n]["definition"] for n in sorted(granted))]
    tasks = json.load(open(os.path.join(ROOT, "evals", "tasks.json")))
    tasks = tasks["tasks"] if isinstance(tasks, dict) else tasks
    return [{"messages": [{"role": "system", "content": harness.SYSTEM}, {"role": "user", "content": t["user"]}],
             "tools": offered, "max_tokens": harness.MAX_TOKENS, "temperature": float(harness.TEMPERATURE)}
            for t in tasks]


def one(url, body, seed):
    data = json.dumps(dict(body, seed=seed)).encode()
    req = urllib.request.Request(url.rstrip("/") + "/v1/chat/completions", data=data,
                                 headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            out = json.loads(r.read())
        usage = out.get("usage") or {}
        return {"ok": True, "s": time.monotonic() - t0, "prompt": usage.get("prompt_tokens"),
                "completion": usage.get("completion_tokens")}
    except Exception as e:
        return {"ok": False, "s": time.monotonic() - t0, "error": type(e).__name__}


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))] if xs else None


def one_level(url, bodies, c, seed, min_s):
    """C workers, 6 x C calls at least, and at least min_s seconds."""
    lock, issued, done = threading.Lock(), [0], []
    t0 = time.monotonic()

    def worker():
        while True:
            with lock:
                i = issued[0]
                if i >= 6 * c and time.monotonic() - t0 >= min_s:
                    return
                issued[0] += 1
            done.append(one(url, bodies[(i + c) % len(bodies)], seed + i))
    workers = [threading.Thread(target=worker) for _ in range(c)]
    for w in workers:
        w.start()
    for w in workers:
        w.join()
    return done, time.monotonic() - t0


def run(url, out, levels):
    bodies = requests()
    min_s = float(os.environ.get("MIN_SECONDS") or 0)
    one(url, bodies[0], 0)  # load the model and warm the cache before anything is timed
    result = {"server": {k: os.environ.get(k) for k in ("MODEL", "SLOTS", "THREADS", "CONTEXT", "RUNNER_CPUS", "ACCELERATOR")},
              "requests": len(bodies), "min_seconds": min_s, "levels": []}
    seed = 1
    for c in levels:
        if min_s:
            with concurrent.futures.ThreadPoolExecutor(max_workers=c) as pool:
                list(pool.map(lambda i: one(url, bodies[i % len(bodies)], 0), range(c)))
        done, wall = one_level(url, bodies, c, seed, min_s)
        n = len(done)
        seed += n
        ok = [d for d in done if d["ok"]]
        lat = [d["s"] for d in ok]
        level = {"concurrency": c, "calls": n, "failed": n - len(ok), "wall_s": round(wall, 1),
                 "calls_per_min": round(len(ok) / wall * 60, 1) if wall else None,
                 "p50_s": round(statistics.median(lat), 2) if lat else None,
                 "p95_s": round(pct(lat, 0.95), 2) if lat else None,
                 "out_tokens_per_s": round(sum(d["completion"] or 0 for d in ok) / wall, 1) if wall else None,
                 "prompt_tokens_mean": round(statistics.mean(d["prompt"] for d in ok if d["prompt"]), 0)
                 if any(d["prompt"] for d in ok) else None}
        result["levels"].append(level)
        print("concurrency %(concurrency)d: %(calls_per_min)s calls/min, p50 %(p50_s)ss, p95 %(p95_s)ss, "
              "%(out_tokens_per_s)s output tokens/s, %(failed)d of %(calls)d failed" % level, flush=True)
    json.dump(result, open(out, "w"), indent=1, sort_keys=True)


def table(directory):
    rows = []
    for f in sorted(glob.glob(os.path.join(directory, "**", "*.json"), recursive=True)):
        r = json.load(open(f))
        s = r["server"]
        for lv in r["levels"]:
            # ACCELERATOR names where the server ran when it was not the
            # runner's CPU (ADR 19); older files have none.
            rows.append((s["MODEL"], s.get("ACCELERATOR") or "CPU", int(s["SLOTS"]), int(s["THREADS"]), lv))
    rows.sort(key=lambda x: (x[0], x[1], x[2], x[4]["concurrency"]))
    print("| Model | On | Slots x threads | Concurrency | Calls a minute | p50 | p95 | Output tokens/s | Failed |")
    print("|---|---|---|---|---|---|---|---|---|")
    for model, on, slots, threads, lv in rows:
        print("| %s | %s | %d x %d | %d | %s | %s s | %s s | %s | %d of %d |" % (
            model, on, slots, threads, lv["concurrency"], lv["calls_per_min"], lv["p50_s"], lv["p95_s"],
            lv["out_tokens_per_s"], lv["failed"], lv["calls"]))


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "run":
        run(sys.argv[2], sys.argv[3], [int(x) for x in (sys.argv[4] if len(sys.argv) > 4 else "1,2,4,8").split(",")])
    elif len(sys.argv) == 3 and sys.argv[1] == "table":
        table(sys.argv[2])
    else:
        sys.exit(__doc__)
