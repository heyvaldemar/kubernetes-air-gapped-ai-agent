#!/usr/bin/env python3
"""tests/static/cloud-results.py - scripts/cloud-results.py against a GitHub made of files.

No token, no network, no cloud. Each case builds what GitHub would answer
for one run (its record, its jobs, its artifacts and the artifact's bytes),
runs one subcommand, and reads what it did: its exit status, what it said,
and what it wrote. Run by static check "results".

  A  a scheduled run on main that passed: its record and its results kept,
     the record naming the file's sha256
  B  a scheduled run that failed after it uploaded: kept, as a failure
  C  a run that failed before it uploaded anything: a record that says so
  D  a run started by hand on main: kept, and the record says by hand
  E  a run on a branch: not kept, nothing written
  F  a run whose code came from a fork: not kept
  G  a run of another repository: not kept
  H  a run of the e2e workflow: not kept
  I  a run a pull request started: not kept
  J  a run still going: not kept
  K  results that are not the file GitHub reports: not kept, nothing written
  L  results GitHub says are larger than 5 MB: not kept, and not downloaded
  L2 results larger than GitHub said, and than 5 MB: not kept
  M  results that have expired: a record that says so, and no file
  N  two artifacts of the name: not kept
  O  an id that is not a number: not kept, and GitHub is not asked
  O2 an id in the digits of another script: not kept, and GitHub is not asked
  Q  results that hold something shaped like a credential: not kept, and
     the value is not printed
  Q2 the same for each other shape: an Anthropic API key, an AWS session
     token, a Hugging Face token, a kubeconfig's key and its token, a login
     and password in an address
  T  an archive holding a file that is neither .json nor .jsonl: not kept
  U  an archive holding a .json that is not UTF-8 text: not kept
  R  an artifact that is not an archive: not kept
  S  an archive that unpacks to more than 50 MB: not kept
  P  add: a record the branch holds is never replaced, a new one is added,
     and the index lists both, oldest first
"""
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(ROOT, "scripts", "cloud-results.py")
REPO = "heyvaldemar/kubernetes-air-gapped-ai-agent"
results, failed = [], 0


def check(ok, what):
    global failed
    results.append(("PASS  " if ok else "FAIL  ") + what)
    failed |= not ok


def github(tmp, run_id, artifacts=None, zips=None, **changes):
    """What GitHub answers for one run, as files; returns the directory."""
    fake = os.path.join(tmp, f"github-{run_id}")
    os.makedirs(fake, exist_ok=True)
    run = {"id": run_id, "name": "The boundary on AKS", "path": ".github/workflows/aks.yml", "event": "schedule",
           "status": "completed", "conclusion": "success", "head_branch": "main", "head_sha": "a" * 40,
           "run_attempt": 1, "run_number": 8, "created_at": "2026-11-10T11:41:38Z",
           "run_started_at": "2026-11-10T11:41:38Z", "updated_at": "2026-11-10T12:01:44Z",
           "html_url": f"https://github.com/{REPO}/actions/runs/{run_id}",
           "repository": {"full_name": REPO}, "head_repository": {"full_name": REPO}}
    run.update(changes)

    def put(path, body):
        with open(os.path.join(fake, path.strip("/").replace("/", "_")), "wb") as f:
            f.write(body if isinstance(body, bytes) else json.dumps(body).encode())

    put(f"/repos/{REPO}/actions/runs/{run_id}", run)
    put(f"/repos/{REPO}/actions/runs/{run_id}/jobs?per_page=100",
        {"jobs": [{"name": "Apply, load, check", "conclusion": run["conclusion"], "started_at": "t", "completed_at": "t"}]})
    put(f"/repos/{REPO}/actions/runs/{run_id}/artifacts?per_page=100", {"artifacts": artifacts or []})
    for aid, body in (zips or {}).items():
        put(f"/repos/{REPO}/actions/artifacts/{aid}/zip", body)
    return fake


def artifact(aid, body, name="e2e-results-aks", **changes):
    a = {"id": aid, "name": name, "size_in_bytes": len(body), "expired": False,
         "digest": "sha256:" + hashlib.sha256(body).hexdigest(),
         "created_at": "2026-11-10T11:50:04Z", "expires_at": "2027-02-08T11:41:38Z"}
    a.update(changes)
    return a


def run(fake, *args):
    env = dict(os.environ, CLOUD_RESULTS_FAKE=fake, GITHUB_REPOSITORY=REPO)
    env.pop("GITHUB_TOKEN", None)
    p = subprocess.run([sys.executable, SCRIPT, *args], capture_output=True, text=True, env=env)
    return p.returncode, p.stdout + p.stderr


def record(tmp, name, **kw):
    """(exit status, what it said, the record or None, the files it wrote) for one run."""
    out = os.path.join(tmp, f"out-{name}")
    code, said = run(github(tmp, **kw), "record", str(kw["run_id"]), out)
    files = sorted(os.path.relpath(os.path.join(b, f), out) for b, _, fs in os.walk(out) for f in fs)
    doc = None
    for f in files:
        if f.endswith("record.json"):
            with open(os.path.join(out, f)) as h:
                doc = json.load(h)
    return code, said, doc, files


def refused(tmp, letter, what, words, **kw):
    code, said, doc, files = record(tmp, letter, **kw)
    check(code == 1 and words in said and not files,
          f"{letter}  {what}: not kept ({said.strip()[:110] if code == 1 else f'exit {code}, wrote {files}'})")


def archive(members):
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for name, text in members.items():
            z.writestr(name, text)
    return out.getvalue()


def main():
    tmp = tempfile.mkdtemp(prefix="cloud-results-")
    body = archive({"e2e-results.json": json.dumps({"checks": [{"name": "a pod opens no TCP to 1.1.1.1:443", "passed": True}]})})
    try:
        code, said, doc, files = record(tmp, "A", run_id=101, artifacts=[artifact(11, body)], zips={11: body})
        check(code == 0 and files == ["aks/101-1/e2e-results-aks.zip", "aks/101-1/record.json"]
              and doc["artifact"]["sha256"] == hashlib.sha256(body).hexdigest() and doc["cloud"] == "aks"
              and doc["run"]["event"] == "schedule" and doc["run"]["conclusion"] == "success"
              and doc["run"]["head_sha"] == "a" * 40 and doc["repository"] == REPO,
              "A  a scheduled run on main that passed is kept, and its record names the file's sha256")
        with open(os.path.join(tmp, "out-A", "aks", "101-1", "e2e-results-aks.zip"), "rb") as f:
            check(f.read() == body, "A  the file kept is the artifact, byte for byte")

        code, said, doc, files = record(tmp, "B", run_id=102, conclusion="failure",
                                        artifacts=[artifact(12, body)], zips={12: body})
        check(code == 0 and doc and doc["run"]["conclusion"] == "failure" and doc["artifact"] is not None,
              "B  a scheduled run that failed after it uploaded is kept, as a failure")

        code, said, doc, files = record(tmp, "C", run_id=103, conclusion="failure")
        check(code == 0 and files == ["aks/103-1/record.json"] and doc["artifact"] is None
              and "uploaded no e2e-results-aks" in doc.get("no_artifact", ""),
              "C  a run that failed before it uploaded anything leaves a record that says so")

        code, said, doc, files = record(tmp, "D", run_id=104, event="workflow_dispatch",
                                        path=".github/workflows/aws.yml", artifacts=[artifact(14, body, "e2e-results-aws")],
                                        zips={14: body})
        check(code == 0 and doc and doc["run"]["event"] == "workflow_dispatch" and doc["cloud"] == "aws"
              and files == ["aws/104-1/e2e-results-aws.zip", "aws/104-1/record.json"],
              "D  a run started by hand on main is kept, and the record says by hand")

        good = dict(artifacts=[artifact(15, body)], zips={15: body})
        refused(tmp, "E", "a run on a branch", "not on main", run_id=105, head_branch="gpu-capacity", **good)
        refused(tmp, "F", "a run whose code came from a fork", "its code came from someone/",
                run_id=106, head_repository={"full_name": "someone/kubernetes-air-gapped-ai-agent"}, **good)
        refused(tmp, "G", "a run of another repository", "a run of someone/else",
                run_id=107, repository={"full_name": "someone/else"}, **good)
        refused(tmp, "H", "a run of the e2e workflow", "no cloud's workflow", run_id=108,
                path=".github/workflows/e2e.yml", **good)
        refused(tmp, "I", "a run a pull request started", "started by pull_request", run_id=109,
                event="pull_request", **good)
        refused(tmp, "J", "a run still going", "not finished", run_id=110, status="in_progress", conclusion=None, **good)
        refused(tmp, "K", "results that are not the file GitHub reports", "it is not the run's file", run_id=111,
                artifacts=[artifact(16, body)], zips={16: body + b"x"})
        big = os.urandom(5 * 1024 * 1024 + 1)
        refused(tmp, "L", "results GitHub says are larger than 5 MB", "is 5242881 bytes, more than the", run_id=112,
                artifacts=[artifact(17, big)])
        refused(tmp, "L2", "results larger than GitHub said, and than 5 MB", "is larger than GitHub said", run_id=115,
                artifacts=[artifact(21, big, size_in_bytes=732)], zips={21: big})

        code, said, doc, files = record(tmp, "M", run_id=113, artifacts=[artifact(18, body, expired=True)], zips={18: body})
        check(code == 0 and files == ["aks/113-1/record.json"] and doc["artifact"] is None
              and "expired" in doc.get("no_artifact", ""),
              "M  results that have expired leave a record that says so, and no file")

        refused(tmp, "N", "two artifacts of the name", "there must be one at most", run_id=114,
                artifacts=[artifact(19, body), artifact(20, body)], zips={19: body, 20: body})

        code, said = run(os.path.join(tmp, "nothing-here"), "record", "101; echo", os.path.join(tmp, "out-O"))
        check(code == 1 and "is not a run's id" in said and not os.path.exists(os.path.join(tmp, "out-O")),
              "O  an id that is not a number is not kept, and GitHub is not asked")

        code, said = run(os.path.join(tmp, "nothing-here"), "record", "\uff11\uff12\uff13", os.path.join(tmp, "out-O2"))
        check(code == 1 and "is not a run's id" in said and not os.path.exists(os.path.join(tmp, "out-O2")),
              "O2 an id in the digits of another script is not kept, and GitHub is not asked")

        # Made here, piece by piece: none of these is a credential, and none sits whole in this file.
        shapes = {
            "an Anthropic API key": "sk-" + "ant-" + "api03-" + "x" * 40,
            "an AWS session token": "IQo" + "Jb3JpZ2luX2Vj" + "A" * 120,
            "a Hugging Face token": "hf" + "_" + "a" * 34,
            "a kubeconfig credential": "client-key" + "-data: " + "LS0tLS1CRUdJTg" + "A" * 40,
            "a kubeconfig credential ": "user:\n    tok" + "en: " + "k" * 48,
            "a login and password in an address": "https://loader" + ":" + "s3cr3t-w0rd" + "@registry.example/v2/",
        }
        for n, (kind, value) in enumerate(shapes.items()):
            held = archive({"e2e-results.json": "{}", "_temp/evals.jsonl": json.dumps({"out": "failed: " + value})})
            code, said, doc, files = record(tmp, f"Q2-{n}", run_id=120 + n, artifacts=[artifact(30 + n, held)],
                                            zips={30 + n: held})
            check(code == 1 and f"holds what looks like {kind.strip()}, in _temp/evals.jsonl" in said and not files
                  and value not in said and value[-20:] not in said,
                  f"Q2 results that hold {kind.strip()} are not kept, and the value is not printed"
                  + ("" if code == 1 else f" (exit {code})"))

        other = archive({"e2e-results.json": "{}", "node.log.gz": "not text"})
        refused(tmp, "T", "an archive holding a file that is neither .json nor .jsonl", "is neither .json nor .jsonl",
                run_id=130, artifacts=[artifact(40, other)], zips={40: other})
        binary = archive({"e2e-results.json": b"\xff\xfe\x00{}"})
        refused(tmp, "U", "an archive holding a .json that is not UTF-8 text", "is not UTF-8 text", run_id=131,
                artifacts=[artifact(41, binary)], zips={41: binary})

        token = "eyJhbGciOiJSUzI1NiIsImtpZCI6Ing.eyJpc3MiOiJodHRwczovL2t1YmVybmV0ZXMuZGVmYXVsdCJ9.c2lnbmF0dXJlLW9mLWEtdG9rZW4"
        leaked = archive({"e2e-results.json": "{}", "_temp/mcp-audit.jsonl": '{"error": "401 for Bearer %s"}' % token})
        code, said, doc, files = record(tmp, "Q", run_id=116, artifacts=[artifact(22, leaked)], zips={22: leaked})
        check(code == 1 and "holds what looks like a JSON Web Token, in _temp/mcp-audit.jsonl" in said and not files
              and token not in said and token[:24] not in said,
              "Q  results that hold something shaped like a credential are not kept, and the value is not printed")
        refused(tmp, "R", "an artifact that is not an archive", "is not a zip archive", run_id=117,
                artifacts=[artifact(23, b"not a zip")], zips={23: b"not a zip"})
        bomb = archive({"e2e-results.json": "0" * (50 * 1024 * 1024 + 1)})
        refused(tmp, "S", "an archive that unpacks to more than 50 MB", "unpacks to more than", run_id=118,
                artifacts=[artifact(24, bomb)], zips={24: bomb})

        branch = os.path.join(tmp, "branch")
        os.makedirs(branch)
        code1, _ = run(tmp, "add", os.path.join(tmp, "out-A"), branch)
        held = os.path.join(branch, "aks", "101-1", "record.json")
        with open(held) as f:
            first = f.read()
        changed = os.path.join(tmp, "out-A2")
        shutil.copytree(os.path.join(tmp, "out-A"), changed)
        with open(os.path.join(changed, "aks", "101-1", "record.json"), "w") as f:
            f.write(first.replace('"success"', '"failure"'))
        shutil.copytree(os.path.join(tmp, "out-B", "aks", "102-1"), os.path.join(changed, "aks", "102-1"))
        code2, said2 = run(tmp, "add", changed, branch)
        with open(held) as f:
            still = f.read() == first
        with open(os.path.join(branch, "index.json")) as f:
            index = json.load(f)
        check(code1 == 0 and code2 == 0 and still and "aks/101-1 is already kept" in said2
              and [i["path"] for i in index] == ["aks/101-1", "aks/102-1"]
              and [i["conclusion"] for i in index] == ["success", "failure"]
              and os.path.exists(os.path.join(branch, "README.md")),
              "P  add never replaces a record the branch holds, adds a new one, and the index lists both")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("\n".join(results))
    print(f"{sum(r.startswith('PASS') for r in results)} of {len(results)} cases passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
