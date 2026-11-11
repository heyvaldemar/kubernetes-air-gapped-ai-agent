#!/usr/bin/env python3
"""cloud-results.py - one finished cloud run's own results, kept where they do not expire (ADR 25).

  cloud-results.py record RUN_ID OUT_DIR   read the run from GitHub, and write
                                           OUT_DIR/<cloud>/<run id>-<attempt>/record.json
                                           and, beside it, the run's results
                                           artifact as the API gave it
  cloud-results.py add OUT_DIR BRANCH_DIR  copy into a checkout of the branch
                                           `cloud-results` every record it does
                                           not hold yet, and write its index

`record` keeps a run only when all of these hold, and exits 1 with the reason
when one does not, having written nothing:

  - it is this repository's run, from this repository's own code, not a fork's;
  - of aws.yml, gke.yml or aks.yml, and of no other workflow;
  - on main;
  - started by the schedule or by hand, never by a push or a pull request;
  - finished.

A run that failed is kept too, with whatever it uploaded: a week that went
wrong has to be on the record, or a reader cannot tell it from a week that
never ran. A run that uploaded nothing leaves a record that says so.

The artifact is data. Nothing in it is run and it is never unpacked to disk:
it is hashed, and kept only when its sha256 is the digest GitHub reports for
it and it is no larger than 5 MB (the largest so far is 17,517 bytes, run
42656218231). The record names the file's sha256, and the workflow signs the
record, so one signature covers the run's facts and its file together.

What is kept is kept for good, so the file is also read, in memory, for
anything shaped like a credential: a token, a private key, a signed address.
An artifact that holds one is not kept, and the message names the kind and
the file inside, never the value. The 30 artifacts GitHub held on 2026-11-11
held none.

`add` never replaces a record the branch already holds.

GITHUB_REPOSITORY names the repository and GITHUB_TOKEN reads it; the token
goes to api.github.com alone, and the artifact's signed download address is
followed without it and never printed. CLOUD_RESULTS_FAKE points at a GitHub
made of files instead, for tests/static/cloud-results.py. Standard library
only.
"""
import hashlib
import io
import json
import os
import re
import shutil
import sys
import urllib.error
import urllib.request
import zipfile

API = "https://api.github.com"
BRANCH = "main"
EVENTS = ("schedule", "workflow_dispatch")
CLOUDS = {".github/workflows/aws.yml": "aws", ".github/workflows/gke.yml": "gke", ".github/workflows/aks.yml": "aks"}
MAX_ARTIFACT = 5 * 1024 * 1024
MAX_UNPACKED = 50 * 1024 * 1024
# What a credential looks like, by kind. A run's results have never held one;
# a failed step's output could.
CREDENTIALS = {
    "a JSON Web Token": rb"eyJ[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{8,}",
    "a GitHub token": rb"gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}",
    "an AWS access key id": rb"\b(AKIA|ASIA)[0-9A-Z]{16}\b",
    "a private key": rb"-----BEGIN [A-Z ]*PRIVATE KEY",
    "a Google access token": rb"ya29\.[A-Za-z0-9_-]{20,}",
    "a signed address": rb"[?&](sig|X-Amz-Signature|X-Goog-Signature)=[A-Za-z0-9%/+]{16,}",
    "a bearer token": rb"[Bb]earer\s+[A-Za-z0-9._~+/-]{20,}",
}
RUN_FIELDS = ("id", "name", "path", "event", "status", "conclusion", "head_branch", "head_sha", "run_attempt",
              "run_number", "created_at", "run_started_at", "updated_at", "html_url")


class Refused(Exception):
    """The run is not one whose results are kept, or its file is not the run's."""


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def get(path, binary=False):
    """One answer of GitHub's API: JSON, or with binary an artifact's bytes."""
    fake = os.environ.get("CLOUD_RESULTS_FAKE")
    if fake:
        try:
            with open(os.path.join(fake, path.strip("/").replace("/", "_")), "rb") as f:
                body = f.read()
        except OSError:
            raise Refused(f"GitHub has no {path}")
        return body if binary else json.loads(body)
    req = urllib.request.Request(API + path, headers={"Accept": "application/vnd.github+json",
                                                      "Authorization": "Bearer " + os.environ["GITHUB_TOKEN"],
                                                      "X-GitHub-Api-Version": "2022-11-28"})
    try:
        if not binary:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)
        try:
            with urllib.request.build_opener(_NoRedirect).open(req, timeout=60) as r:
                return r.read(MAX_ARTIFACT + 1)
        except urllib.error.HTTPError as e:
            # The download is a redirect to storage that rejects the API's
            # Authorization header: follow it without, and never print it.
            if e.code not in (301, 302, 303, 307, 308) or not e.headers.get("Location"):
                raise
            with urllib.request.urlopen(e.headers["Location"], timeout=120) as r:
                return r.read(MAX_ARTIFACT + 1)
    except urllib.error.HTTPError as e:
        # The status and the path, never the body: an auth error can echo a token.
        raise Refused(f"GitHub answered {e.code} for {path}")
    except urllib.error.URLError as e:
        raise Refused(f"{path}: {e.reason}")


def why_not(repo, run):
    """Why this run's results are not kept; nothing when they are."""
    reasons = []
    if (run.get("repository") or {}).get("full_name") != repo:
        reasons.append(f"a run of {(run.get('repository') or {}).get('full_name')}, not of {repo}")
    if (run.get("head_repository") or {}).get("full_name") != repo:
        reasons.append(f"its code came from {(run.get('head_repository') or {}).get('full_name')}, not from {repo}")
    if run.get("path") not in CLOUDS:
        reasons.append(f"a run of {run.get('path')}, which is no cloud's workflow")
    if run.get("head_branch") != BRANCH:
        reasons.append(f"a run on {run.get('head_branch')}, not on {BRANCH}")
    if run.get("event") not in EVENTS:
        reasons.append(f"started by {run.get('event')}, not by the schedule or by hand")
    if run.get("status") != "completed":
        reasons.append(f"the run is {run.get('status')}, not finished")
    return reasons


def credential_in(body):
    """(kind, file inside) of the first thing in the artifact shaped like a credential, or None. Read in memory."""
    try:
        archive = zipfile.ZipFile(io.BytesIO(body))
    except zipfile.BadZipFile:
        raise Refused("the artifact is not a zip archive")
    if sum(i.file_size for i in archive.infolist()) > MAX_UNPACKED:
        raise Refused(f"the artifact unpacks to more than the {MAX_UNPACKED} bytes this reads")
    for member in archive.namelist():
        data = archive.read(member)
        for kind, pattern in CREDENTIALS.items():
            if re.search(pattern, data):
                return kind, member
    return None


def record(run_id, out):
    repo = os.environ["GITHUB_REPOSITORY"]
    if not run_id.isdigit():
        raise Refused(f"{run_id!r} is not a run's id")
    run = get(f"/repos/{repo}/actions/runs/{run_id}")
    reasons = why_not(repo, run)
    if reasons:
        raise Refused("; ".join(reasons))
    cloud = CLOUDS[run["path"]]
    name = f"e2e-results-{cloud}"
    kept = {k: run.get(k) for k in RUN_FIELDS}
    kept["repository"], kept["head_repository"] = run["repository"]["full_name"], run["head_repository"]["full_name"]
    jobs = get(f"/repos/{repo}/actions/runs/{run_id}/jobs?per_page=100").get("jobs", [])
    doc = {"schema": 1, "kept_by": ".github/workflows/cloud-results.yml", "repository": repo, "cloud": cloud,
           "run": kept, "artifact": None,
           "jobs": [{k: j.get(k) for k in ("name", "conclusion", "started_at", "completed_at")} for j in jobs]}
    found = [a for a in get(f"/repos/{repo}/actions/runs/{run_id}/artifacts?per_page=100").get("artifacts", [])
             if a.get("name") == name]
    held = [a for a in found if not a.get("expired")]
    body = None
    if len(held) > 1:
        raise Refused(f"the run holds {len(held)} artifacts named {name}; there must be one at most")
    if held:
        a = held[0]
        if a["size_in_bytes"] > MAX_ARTIFACT:
            raise Refused(f"{name} is {a['size_in_bytes']} bytes, more than the {MAX_ARTIFACT} this keeps")
        body = get(f"/repos/{repo}/actions/artifacts/{a['id']}/zip", binary=True)
        digest = "sha256:" + hashlib.sha256(body).hexdigest()
        if len(body) > MAX_ARTIFACT:
            raise Refused(f"{name} is larger than GitHub said, and more than the {MAX_ARTIFACT} bytes this keeps")
        if digest != a.get("digest"):
            raise Refused(f"the file's digest is {digest} and GitHub reports {a.get('digest')} for artifact "
                          f"{a['id']}: it is not the run's file")
        found_in = credential_in(body)
        if found_in:
            raise Refused(f"{name} holds what looks like {found_in[0]}, in {found_in[1]}: what is kept is kept "
                          "for good, so this is not")
        doc["artifact"] = {"id": a["id"], "name": name, "file": name + ".zip", "size_in_bytes": len(body),
                           "sha256": digest.split(":")[1], "created_at": a.get("created_at"),
                           "expires_at": a.get("expires_at")}
    else:
        doc["no_artifact"] = ("the run's artifact had expired when this was written" if found
                              else f"the run uploaded no {name}")
    where = os.path.join(out, cloud, f"{run['id']}-{run.get('run_attempt') or 1}")
    os.makedirs(where)
    with open(os.path.join(where, "record.json"), "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1, sort_keys=True)
        f.write("\n")
    if body is not None:
        with open(os.path.join(where, name + ".zip"), "wb") as f:
            f.write(body)
    print(f"{cloud} run {run['id']}, attempt {run.get('run_attempt') or 1}: {run['event']}, {run.get('conclusion')}, "
          + (f"{name} of {len(body)} bytes, sha256 {doc['artifact']['sha256']}" if body is not None
             else doc["no_artifact"]))
    return where


def records(branch):
    """Every record a checkout of the branch holds, oldest first."""
    out = []
    for cloud in sorted(CLOUDS.values()):
        for name in sorted(os.listdir(os.path.join(branch, cloud))) if os.path.isdir(os.path.join(branch, cloud)) else []:
            path = os.path.join(branch, cloud, name, "record.json")
            if os.path.exists(path):
                with open(path, encoding="utf-8") as f:
                    out.append((f"{cloud}/{name}", json.load(f)))
    return sorted(out, key=lambda r: (r[1]["run"]["created_at"], r[0]))


def add(out, branch):
    added = []
    for cloud in sorted(CLOUDS.values()):
        for name in sorted(os.listdir(os.path.join(out, cloud))) if os.path.isdir(os.path.join(out, cloud)) else []:
            src, dst = os.path.join(out, cloud, name), os.path.join(branch, cloud, name)
            if not os.path.exists(os.path.join(src, "record.json")):
                continue
            if os.path.exists(dst):
                print(f"{cloud}/{name} is already kept: left as it is")
                continue
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copytree(src, dst)
            added.append(f"{cloud}/{name}")
    held = records(branch)
    index = [{"path": path, "cloud": r["cloud"], "run": r["run"]["id"], "attempt": r["run"].get("run_attempt") or 1,
              "event": r["run"]["event"], "conclusion": r["run"].get("conclusion"),
              "created_at": r["run"]["created_at"], "commit": r["run"]["head_sha"],
              "artifact_sha256": (r.get("artifact") or {}).get("sha256")} for path, r in held]
    with open(os.path.join(branch, "index.json"), "w", encoding="utf-8") as f:
        json.dump(index, f, indent=1, sort_keys=True)
        f.write("\n")
    repo = os.environ.get("GITHUB_REPOSITORY", "this repository")
    lines = ["# cloud-results", "",
             "Written by `.github/workflows/cloud-results.yml` on main, and by nothing else: after each run of "
             "aws.yml, gke.yml and aks.yml on main, the run's own record and the results it uploaded, checked "
             "against the digest GitHub reported and signed by that workflow (ADR 25). Nothing here is edited by "
             "hand, and a record is never replaced.", "",
             "Each directory holds `record.json`, its signature `record.json.sigstore.json`, and the run's "
             "artifact when it uploaded one. The record names the artifact's sha256, so the one signature covers "
             "both:", "", "```sh",
             "cosign verify-blob record.json --bundle record.json.sigstore.json \\",
             f"  --certificate-identity https://github.com/{repo}/.github/workflows/cloud-results.yml@refs/heads/main \\",
             "  --certificate-oidc-issuer https://token.actions.githubusercontent.com",
             "sha256sum e2e-results-*.zip   # the value record.json gives as artifact.sha256",
             "```", "", "| Cloud | Run | Started by | Ended | Date | Results kept |", "|---|---|---|---|---|---|"]
    for path, r in reversed(held):
        run = r["run"]
        lines.append(f"| {r['cloud']} | [{run['id']}]({run['html_url']}) | {run['event']} | {run.get('conclusion')} | "
                     f"{run['created_at'][:10]} | "
                     + (f"[{path}]({path}), {r['artifact']['size_in_bytes']} bytes" if r.get("artifact")
                        else r.get("no_artifact", "none")) + " |")
    with open(os.path.join(branch, "README.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{len(added)} record(s) added ({', '.join(added) or 'none'}); the branch holds {len(held)}")
    return added


def main(argv):
    try:
        if len(argv) == 3 and argv[0] == "record":
            record(argv[1], argv[2])
        elif len(argv) == 3 and argv[0] == "add":
            add(argv[1], argv[2])
        else:
            sys.stderr.write(__doc__)
            return 2
    except Refused as e:
        print(f"cloud-results: not kept: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
