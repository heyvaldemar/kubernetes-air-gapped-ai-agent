#!/usr/bin/env python3
"""tests/static/params.py - the four numbers a longer or larger run may turn, against a kubectl that is a file.

No cluster, no network. A kubectl and a sleep made of a few lines stand first
in PATH: the kubectl writes down what it is asked and keeps what it is handed
on stdin, the sleep returns at once and counts. scripts/evals.sh and
scripts/serve.sh then run as they are, and each case reads what reached
kubectl. Run by static check "params".

ATTEMPTS and EVALS_DEADLINE_SECONDS (scripts/evals.sh, ADR 7), GPU_SLOTS and
MODELS_LOCK (scripts/serve.sh, scripts/gpu.sh, scripts/model.sh, ADR 19).
With nothing set every one of them is the value the runs have always used.

  A  evals.sh, nothing set: three attempts and an hour in the Job, the
     people's tokens for two hours
  B  ATTEMPTS=10 and EVALS_DEADLINE_SECONDS=7200: the Job says both, and the
     tokens last an hour longer than the Job may run, three hours
  C  a Job that never ends is asked after for its deadline and no longer:
     twenty seconds, four times
  D  ATTEMPTS or the deadline that is not a whole number above zero: refused
     before anything is handed to kubectl
  E  the verdict asks for the tasks times the same ATTEMPTS, not a number
     written anywhere else
  F  serve.sh with the GPU server's manifest, nothing set: eight slots of
     8192 tokens
  G  GPU_SLOTS=2: two slots, and the context follows
  H  GPU_SLOTS that is not a whole number above zero: refused, nothing
     handed to kubectl
  I  the CPU server keeps its one slot whatever GPU_SLOTS says
  J  MODELS_LOCK names another file: its line is served, by its digest;
     with nothing set, the repository's
  K  gpu.sh and model.sh open the same file, and gpu.sh measures with the
     slots the server was given
  L  a deadline above six hours is refused before kubectl hears of it: no
     number of the run mints the people's tokens for days; six hours is taken
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
results, failed = [], 0
# What a template still holds when something was not filled in.
PLACEHOLDER = re.compile(r"@[A-Z_]+@")

KUBECTL = """#!/bin/sh
printf '%s\\n' "$*" >>"$FAKE/calls.log"
case " $* " in
  *" apply "*) n="$(find "$FAKE" -name 'applied-*' | wc -l | tr -d ' ')"; cat >"$FAKE/applied-$n.yaml" ;;
  *" create configmap "*) echo "kind: ConfigMap" ;;
  *" create token "*) echo token ;;
  *" get svc "*) printf models ;;
  *" get job evals "*) [ -z "${FAKE_JOB_DONE:-}" ] || printf 1 ;;
esac
exit 0
"""
SLEEP = """#!/bin/sh
echo "$*" >>"$FAKE/sleeps.log"
"""


def check(ok, what):
    global failed
    results.append(("PASS  " if ok else "FAIL  ") + what)
    failed |= not ok


def case(letter, what, body):
    try:
        check(body(), "%-2s %s" % (letter, what))
    except Exception as e:  # a case that cannot be read is a case that failed
        check(False, "%-2s %s (%s: %s)" % (letter, what, type(e).__name__, e))


class Ran:
    def __init__(self, fake, code, said):
        self.code, self.said = code, said
        read = lambda name: open(os.path.join(fake, name), encoding="utf-8").read() if os.path.exists(os.path.join(fake, name)) else ""
        self.calls = read("calls.log").splitlines()
        self.sleeps = read("sleeps.log").splitlines()
        self.applied = [read(n) for n in sorted(os.listdir(fake)) if n.startswith("applied-")]

    def one(self, kind):
        found = [a for a in self.applied if re.search(r"^kind: %s$" % kind, a, re.M)]
        return found[0] if len(found) == 1 else ""


def run(tmp, script, **env):
    """One script, as it is, with the stand-ins first in PATH."""
    fake = tempfile.mkdtemp(prefix="fake-", dir=tmp)
    for name, text in (("kubectl", KUBECTL), ("sleep", SLEEP)):
        path = os.path.join(fake, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(path, 0o755)
    clean = {k: v for k, v in os.environ.items()
             if k not in ("ATTEMPTS", "EVALS_DEADLINE_SECONDS", "GPU_SLOTS", "MODELS_LOCK", "MODEL", "INSIDE",
                          "EVALS_RESULTS", "E2E_RESULTS", "SERVE_NAME", "SERVE_MANIFEST", "SERVE_REPLICAS")}
    clean.update(PATH=fake + os.pathsep + os.environ["PATH"], FAKE=fake, KUBECONFIG=os.devnull,
                 EVALS_OUT=os.path.join(fake, "out"), **env)
    p = subprocess.run(["bash", os.path.join(ROOT, "scripts", script)], env=clean, capture_output=True, text=True, timeout=300)
    return Ran(fake, p.returncode, p.stdout + p.stderr)


def evals(tmp, **env):
    return run(tmp, "evals.sh", MODEL="granite-4.0-1b", **env)


def token_durations(r):
    return sorted({c.rsplit("--duration ", 1)[1] for c in r.calls if " create token " in " %s " % c})


def job_says(r, attempts, deadline):
    job = r.one("Job")
    return ('- {name: ATTEMPTS, value: "%s"}\n' % attempts in job and "\n  activeDeadlineSeconds: %s\n" % deadline in job
            and not PLACEHOLDER.search(job))


def server_args(r):
    m = re.search(r'"-c", "([^"]*)", "-np", "([^"]*)"', r.one("Deployment"))
    return m.groups() if m else None


def main():
    gpu_manifest = os.path.join(ROOT, "manifests", "inference", "llama-gpu.yaml")
    read = lambda *p: open(os.path.join(ROOT, *p), encoding="utf-8").read()
    tmp = tempfile.mkdtemp(prefix="params-")
    try:
        a = evals(tmp, FAKE_JOB_DONE="1")
        case("A", "evals.sh with nothing set: three attempts and an hour in the Job, the people's tokens for two hours",
             lambda: job_says(a, 3, 3600) and token_durations(a) == ["7200s"] and not a.sleeps)
        b = evals(tmp, FAKE_JOB_DONE="1", ATTEMPTS="10", EVALS_DEADLINE_SECONDS="7200")
        case("B", "ATTEMPTS=10 and EVALS_DEADLINE_SECONDS=7200: the Job says both, and the tokens last an hour longer, three hours",
             lambda: job_says(b, 10, 7200) and token_durations(b) == ["10800s"])
        c = evals(tmp, EVALS_DEADLINE_SECONDS="20")
        case("C", "a Job that never ends is asked after for its deadline and no longer: twenty seconds, four times",
             lambda: c.sleeps == ["5"] * 4 and sum(" get job evals " in " %s " % x for x in c.calls) == 4)
        refused = [evals(tmp, FAKE_JOB_DONE="1", **bad) for bad in
                   ({"ATTEMPTS": "0"}, {"ATTEMPTS": "3x"}, {"ATTEMPTS": "03"}, {"EVALS_DEADLINE_SECONDS": "0"},
                    {"EVALS_DEADLINE_SECONDS": "1h"}, {"EVALS_DEADLINE_SECONDS": "-5"})]
        case("D", "ATTEMPTS or the deadline that is not a whole number above zero is refused before kubectl hears of it",
             lambda: all(r.code == 1 and not r.calls and "whole numbers above zero" in r.said for r in refused))
        sh = read("scripts", "evals.sh")
        case("E", "the verdict asks for the tasks times the same ATTEMPTS, not a number written anywhere else",
             lambda: sh.count('* int(os.environ["ATTEMPTS"])\n') == 1 and "export ATTEMPTS\n" in sh
             and not re.search(r"ATTEMPTS, value", sh))
        f = run(tmp, "serve.sh", SERVE_MANIFEST=gpu_manifest, SERVE_NAME="llama-gpu")
        case("F", "serve.sh with the GPU server's manifest and nothing set: eight slots of 8192 tokens",
             lambda: f.code == 0 and server_args(f) == ("65536", "8") and not PLACEHOLDER.search(f.one("Deployment")))
        g = run(tmp, "serve.sh", SERVE_MANIFEST=gpu_manifest, SERVE_NAME="llama-gpu", GPU_SLOTS="2")
        case("G", "GPU_SLOTS=2: two slots, and the context follows",
             lambda: g.code == 0 and server_args(g) == ("16384", "2"))
        bad_slots = [run(tmp, "serve.sh", SERVE_MANIFEST=gpu_manifest, GPU_SLOTS=v) for v in ("0", "two", "08", "-1")]
        case("H", "GPU_SLOTS that is not a whole number above zero is refused, and nothing is handed to kubectl",
             lambda: all(r.code == 1 and not r.applied and "whole number above zero" in r.said for r in bad_slots))
        i = run(tmp, "serve.sh", GPU_SLOTS="4")
        case("I", "the CPU server keeps its one slot whatever GPU_SLOTS says",
             lambda: i.code == 0 and server_args(i) == ("8192", "1"))
        lock = os.path.join(tmp, "other.lock")
        digest = "sha256:" + "ab" * 32
        with open(lock, "w", encoding="utf-8") as fh:
            fh.write("# another lock\nlarge https://example.invalid/large.gguf %s Apache-2.0 %s\n" % ("cd" * 32, digest))
        j = run(tmp, "serve.sh", MODELS_LOCK=lock, MODEL="large")
        own = read("models", "models.lock")
        first = next(l for l in own.splitlines() if l.strip() and not l.lstrip().startswith("#")).split()
        case("J", "MODELS_LOCK names another file: its line is served, by its digest; with nothing set, the repository's",
             lambda: "/models/large@%s\n" % digest in j.one("Deployment") and "--alias\", \"large\"" in j.one("Deployment")
             and "/models/%s@%s\n" % (first[0], first[-1]) in i.one("Deployment"))
        gpu, model, serve = read("scripts", "gpu.sh"), read("scripts", "model.sh"), read("scripts", "serve.sh")
        case("K", "gpu.sh and model.sh open the same file, and gpu.sh measures with the slots the server was given",
             lambda: all(t.count('MODELS_LOCK="${MODELS_LOCK:-$ROOT/models/models.lock}"\n') == 1
                         and t.count("models/models.lock\"") == 0 for t in (gpu, model, serve))
             and "export MODELS_LOCK GPU_SLOTS\n" in gpu and 'GPU_SLOTS="${GPU_SLOTS:-8}"\n' in gpu
             and gpu.count('"$GPU_SLOTS" 0 "GPU, $CARD"') == 2 and 'SLOTS="$GPU_SLOTS" THREADS=0' in gpu
             and not re.search(r'in_cluster llama-gpu\S* \S+ \S+ \d', gpu) and "SLOTS=8" not in gpu)
        over = evals(tmp, FAKE_JOB_DONE="1", EVALS_DEADLINE_SECONDS="21601")
        most = evals(tmp, FAKE_JOB_DONE="1", EVALS_DEADLINE_SECONDS="21600")
        case("L", "a deadline above six hours is refused before kubectl hears of it, and six hours is taken",
             lambda: over.code == 1 and not over.calls and "at most 21600" in over.said
             and job_says(most, 3, 21600) and token_durations(most) == ["25200s"])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("\n".join(results))
    print(f"{sum(r.startswith('PASS') for r in results)} of {len(results)} cases passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
