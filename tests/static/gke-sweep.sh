#!/usr/bin/env bash
# tests/static/gke-sweep.sh - scripts/gke.sh's sweep (the run's own pre-clean)
# and leftovers (the daily sweep), against a Google Cloud and a Terraform
# that are files in a temporary directory: no project, no credential, no
# cost. Run by static check "gke".
#
# Each case builds a project (what is in it, by name and age), a state
# bucket (each run's state, how many resources it holds, how old it is) and
# GitHub's word on each run, runs one subcommand, and reads what it did:
# its exit status, the calls it made, what is left in the project and in
# the bucket.
#
#   A  a state whose resources are all gone (the daily sweep deleted them)
#      is removed, without a destroy that can only fail: the first
#      scheduled run, 41038578800, died destroying against one
#   B  a state whose resources are there is destroyed, then removed
#   C  when Terraform cannot destroy (its repository already gone), what is
#      left is deleted by name, and the state removed
#   D  a state younger than three hours belongs to a run still going: kept
#   E  what neither the destroy nor the deletes take away fails the run
#   F  an empty state older than three hours is removed
#   G  leftovers deletes what a finished run left, and touches no state
#   H  leftovers leaves a run still going alone
#   I  leftovers fails when something of a finished run is still there
#   J  volumes sweep deletes a disk Vault's claim left (ADR 24), unused and
#      older than three hours, and keeps one in use and one younger
#   K  volumes 0 fails while a disk made for Vault's claim is there, and
#      volumes 1 passes with it
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
results=(); failed=0
pass() { results+=("PASS  $1"); }
fail() { results+=("FAIL  $1"); failed=1; }

mkdir -p "$T/bin"
cat >"$T/bin/gcloud" <<'PY'
#!/usr/bin/env python3
# A Google Cloud made of files under $FAKE_GCP: inventory (kind name
# created), bucket/ (the state bucket), refuse (kind name it will not
# delete). Every call is appended to calls. A call this does not know is an
# error, so the test fails if gke.sh asks for something new.
import os, re, shutil, sys
W = os.environ["FAKE_GCP"]
args = sys.argv[1:]
open(os.path.join(W, "calls"), "a").write("gcloud " + " ".join(args) + "\n")
takes_value = {"--project", "--location", "--zone", "--region", "--type", "--response-policy"}
words, opts, i = [], {}, 0
while i < len(args):
    a = args[i]
    if a in takes_value:
        opts[a] = args[i + 1]; i += 2; continue
    if a.startswith("--"):
        k, _, v = a.partition("="); opts[k] = v
    else:
        words.append(a)
    i += 1
inv_path = os.path.join(W, "inventory")
rows = [l.split() for l in open(inv_path).read().splitlines() if l.strip()]
refuse = open(os.path.join(W, "refuse")).read().split("\n")
def path(url):
    return os.path.join(W, "bucket", url.split("/", 3)[3] if url.count("/") >= 3 else "")
def drop(kind, name):
    if "%s %s" % (kind, name) in refuse:
        sys.exit("fake gcloud: refused to delete %s %s" % (kind, name))
    left = [r for r in rows if not (r[0] == kind and r[1] == name)]
    if len(left) == len(rows):
        sys.exit("fake gcloud: no %s %s" % (kind, name))
    open(inv_path, "w").write("".join(" ".join(r) + "\n" for r in left))
lists = {
    ("container", "clusters", "list"): "cluster",
    ("artifacts", "repositories", "list"): "repository",
    ("compute", "networks", "list"): "network",
    ("compute", "networks", "subnets", "list"): "subnet",
    ("compute", "routes", "list"): "route",
    ("compute", "firewall-rules", "list"): "firewall",
    ("compute", "instances", "list"): "instance",
    ("compute", "instance-groups", "managed", "list"): "instance-group",
    ("compute", "instance-templates", "list"): "instance-template",
    ("compute", "disks", "list"): "disk",
    ("compute", "forwarding-rules", "list"): "forwarding-rule",
    ("dns", "managed-zones", "list"): "zone",
    ("dns", "response-policies", "list"): "response-policy",
}
deletes = {
    ("container", "clusters", "delete"): "cluster",
    ("artifacts", "repositories", "delete"): "repository",
    ("dns", "response-policies", "delete"): "response-policy",
    ("dns", "managed-zones", "delete"): "zone",
    ("compute", "firewall-rules", "delete"): "firewall",
    ("compute", "routes", "delete"): "route",
    ("compute", "networks", "subnets", "delete"): "subnet",
    ("compute", "networks", "delete"): "network",
    ("compute", "disks", "delete"): "disk",
}
# The disks made for claims (ADR 24): pvc-disks holds them as gcloud's JSON
# would, name, zone, users, creation time and the provisioner's description.
pvc_path = os.path.join(W, "pvc-disks")
pvc = __import__("json").load(open(pvc_path)) if os.path.exists(pvc_path) else []
if tuple(words[:3]) == ("compute", "disks", "list") and "created-for" in opts.get("--filter", ""):
    print(__import__("json").dumps(pvc)); sys.exit(0)
if tuple(words[:3]) == ("compute", "disks", "delete") and words[3].startswith("pvc-"):
    left = [d for d in pvc if d["name"] != words[3]]
    if len(left) == len(pvc) or "disk %s" % words[3] in refuse:
        sys.exit("fake gcloud: cannot delete disk %s" % words[3])
    open(pvc_path, "w").write(__import__("json").dumps(left)); sys.exit(0)
for n in (4, 3):
    key = tuple(words[:n])
    if key in lists:
        kind, run = lists[key], re.search(r"airgap-(\d+)", opts.get("--filter", ""))
        # The fields --format asks for: a name, a time, or a disk's zone.
        fields = re.findall(r"[\w.()]+", opts.get("--format", "value(name)")[len("value("):-1])
        for r in rows:
            if r[0] == kind and (not run or "airgap-%s" % run.group(1) in r[1]):
                print("\t".join(r[2] if "ime" in f else "us-central1-a" if f.startswith("zone") else r[1] for f in fields))
        sys.exit(0)
    if key in deletes:
        drop(deletes[key], words[n]); sys.exit(0)
w = tuple(words)
if w[:3] in {("container", "clusters", "describe"), ("dns", "response-policies", "describe")}:
    kind = "cluster" if w[0] == "container" else "response-policy"
    sys.exit(0 if any(r[0] == kind and r[1] == w[3] for r in rows) else 1)
if w[:4] == ("dns", "response-policies", "rules", "list") or w[:3] == ("dns", "record-sets", "list"):
    sys.exit(0)
if w[:4] == ("dns", "response-policies", "rules", "delete") or w[:3] in {("dns", "response-policies", "update"), ("dns", "record-sets", "delete")}:
    sys.exit(0)
if w[:2] == ("storage", "ls"):
    d = path(w[2])
    if not os.path.isdir(d):
        sys.exit(1)
    for e in sorted(os.listdir(d)):
        print("%s%s/" % (w[2], e))
    sys.exit(0)
if w[:3] == ("storage", "objects", "describe"):
    f = path(w[3])
    if not os.path.exists(f):
        sys.exit(1)
    print(open(os.path.join(os.path.dirname(f), ".updated")).read().strip()); sys.exit(0)
if w[:2] == ("storage", "cat"):
    sys.stdout.write(open(path(w[2])).read()); sys.exit(0)
if w[:2] == ("storage", "cp"):
    shutil.copy(path(w[2]), w[3]); sys.exit(0)
if w[:2] == ("storage", "rm") and "--recursive" in opts:
    shutil.rmtree(path(w[2])); sys.exit(0)
sys.exit("fake gcloud: unhandled: " + " ".join(args))
PY
cat >"$T/bin/terraform" <<'SH'
#!/usr/bin/env bash
# A Terraform whose destroy takes away every part of the run its backend
# names, unless $FAKE_GCP/destroy-fails says it cannot read the state.
echo "terraform $*" >>"$FAKE_GCP/calls"
case " $* " in
  *" init "*) sed -nE 's/.*prefix=airgap-runs\/([0-9]+).*/\1/p' <<<"$*" >"$FAKE_GCP/tf-run"; exit 0 ;;
  *" destroy "*)
    if [ -e "$FAKE_GCP/destroy-fails" ]; then
      echo 'Error: Error when reading or editing Resource "artifactregistry repository" with IAM' >&2; exit 1
    fi
    run="$(cat "$FAKE_GCP/tf-run")"
    grep -vE " (gke-)?airgap-$run([^0-9]| |$)" "$FAKE_GCP/inventory" >"$FAKE_GCP/inventory.new" || true
    mv "$FAKE_GCP/inventory.new" "$FAKE_GCP/inventory"; exit 0 ;;
esac
echo "fake terraform: unhandled: $*" >&2; exit 2
SH
cat >"$T/bin/gh" <<'SH'
#!/usr/bin/env bash
# GitHub's word on a run: gh api repos/<r>/actions/runs/<run> --jq .status
run="$(sed -nE 's#.*/actions/runs/([0-9]+).*#\1#p' <<<"$*")"
cat "$FAKE_GCP/gh/$run" 2>/dev/null || exit 1
SH
chmod +x "$T/bin/gcloud" "$T/bin/terraform" "$T/bin/gh"
export PATH="$T/bin:$PATH" GKE_STATE_BUCKET=state GKE_PROJECT=validation GKE_REGION=us-central1 \
  GKE_ZONE=us-central1-a RUN_ID=900 GITHUB_REPOSITORY=heyvaldemar/kubernetes-air-gapped-ai-agent

ago() { python3 -c 'import datetime, sys; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=float(sys.argv[1]))).isoformat())' "$1"; }
world() {
  W="$T/$1"; mkdir -p "$W/bucket/airgap-runs" "$W/gh"; : >"$W/inventory"; : >"$W/calls"; : >"$W/refuse"
  export FAKE_GCP="$W"
}
# state <run> <resources> <hours ago>: the run's state and variables
state() {
  local d="$W/bucket/airgap-runs/$1"; mkdir -p "$d"
  python3 -c 'import json, sys; print(json.dumps({"resources": [{"mode": "managed", "instances": [{}]} for _ in range(int(sys.argv[1]))]}))' "$2" >"$d/default.tfstate"
  echo '{}' >"$d/run.tfvars.json"; ago "$3" >"$d/.updated"
}
# made <run> <hours ago>: everything a run makes, in the project
made() {
  local c="airgap-$1" t; t="$(ago "$2")"
  for part in "cluster $c" "repository $c" "network $c" "subnet $c" "route $c-google-apis" "route $c-google-images" \
              "firewall $c-deny-egress" "firewall $c-egress-inside" "firewall gke-$c-0a1b2c3d-all" \
              "zone $c-googleapis" "zone $c-gcr" "zone $c-pkg"; do
    echo "$part $t" >>"$W/inventory"
  done
  echo "response-policy $c -" >>"$W/inventory"
}
run_gke() { "$BASH" "$ROOT/scripts/gke.sh" "$1" >"$W/out" 2>&1; echo $? >"$W/rc"; }
rc() { cat "$W/rc"; }
has_state() { [ -d "$W/bucket/airgap-runs/$1" ]; }
owned() { grep -cE " (gke-)?airgap-$1([^0-9]| |$)" "$W/inventory" || true; }
said() { grep -qF "$1" "$W/out"; }
called() { grep -qF "$1" "$W/calls"; }
why() { tr '\n' ' ' <"$W/out" | cut -c1-300; }

world A; state 40571490437 34 62; touch "$W/destroy-fails"; run_gke sweep
if [ "$(rc)" = 0 ] && ! has_state 40571490437 && ! called "terraform" && said "none of them in the project"; then
  pass "A: a state whose resources are gone is removed, with no destroy (run 41038578800's case)"
else fail "A: a state whose resources are gone was not simply removed (rc $(rc)): $(why)"; fi

world B; state 222 34 5; made 222 5; run_gke sweep
if [ "$(rc)" = 0 ] && called "terraform -chdir" && [ "$(owned 222)" = 0 ] && ! has_state 222; then
  pass "B: a state whose resources are there is destroyed, then removed"
else fail "B: a state whose resources are there was not destroyed and removed (rc $(rc), $(owned 222) parts left): $(why)"; fi

world C; state 333 34 30; made 333 30; grep -v '^repository ' "$W/inventory" >"$W/i" && mv "$W/i" "$W/inventory"
touch "$W/destroy-fails"; run_gke sweep
if [ "$(rc)" = 0 ] && said "deleting what is left by name" && [ "$(owned 333)" = 0 ] && ! has_state 333; then
  pass "C: when Terraform cannot destroy, what is left is deleted by name and the state removed"
else fail "C: a destroy that failed was not finished by name (rc $(rc), $(owned 333) parts left): $(why)"; fi

world D; state 444 34 1; made 444 1; run_gke sweep
if [ "$(rc)" = 0 ] && has_state 444 && [ "$(owned 444)" -gt 0 ] && ! called "terraform"; then
  pass "D: a state younger than three hours, a run still going, is left alone"
else fail "D: a run still going was touched (rc $(rc)): $(why)"; fi

world E; state 555 34 30; made 555 30; touch "$W/destroy-fails"; echo "network airgap-555" >"$W/refuse"; run_gke sweep
if [ "$(rc)" != 0 ] && said "still in the project" && has_state 555; then
  pass "E: what neither the destroy nor the deletes take away fails the run, and the state stays"
else fail "E: a run with something still in the project passed (rc $(rc)): $(why)"; fi

world F; state 666 0 10; run_gke sweep
if [ "$(rc)" = 0 ] && ! has_state 666 && ! called "terraform"; then
  pass "F: an empty state older than three hours is removed"
else fail "F: an empty old state was not removed (rc $(rc)): $(why)"; fi

world G; state 777 34 0; made 777 0; echo completed >"$W/gh/777"; run_gke leftovers
if [ "$(rc)" = 0 ] && [ "$(owned 777)" = 0 ] && has_state 777; then
  pass "G: leftovers deletes what a finished run left, and touches no state"
else fail "G: leftovers did not delete a finished run's parts, or touched its state (rc $(rc), $(owned 777) left): $(why)"; fi

world H; made 888 0; echo in_progress >"$W/gh/888"; run_gke leftovers
if [ "$(rc)" = 0 ] && [ "$(owned 888)" -gt 0 ] && said "leaving it to its own teardown"; then
  pass "H: leftovers leaves a run still going alone"
else fail "H: leftovers touched a run still going (rc $(rc)): $(why)"; fi

world I; made 999 0; echo completed >"$W/gh/999"; echo "network airgap-999" >"$W/refuse"; run_gke leftovers
if [ "$(rc)" != 0 ] && said "still there after the sweep"; then
  pass "I: leftovers fails when something of a finished run is still there"
else fail "I: leftovers passed with a finished run's network still there (rc $(rc)): $(why)"; fi

# pvc_disk <name> <hours ago> <used|unused> [namespace]: a disk made for a
# claim, as gcloud lists it
pvc_disk() {
  python3 - "$W/pvc-disks" "$1" "$(ago "$2")" "$3" "${4:-vault}" <<'PY'
import json, os, sys
path, name, created, use, ns = sys.argv[1:]
disks = json.load(open(path)) if os.path.exists(path) else []
desc = json.dumps({"kubernetes.io/created-for/pv/name": name, "kubernetes.io/created-for/pvc/name": "data-vault-0",
                   "kubernetes.io/created-for/pvc/namespace": ns, "storage.gke.io/created-by": "pd.csi.storage.gke.io"})
disks.append({"name": name, "zone": "us-central1-a", "sizeGb": "1", "type": "pd-balanced", "creationTimestamp": created,
              "description": desc, **({"users": ["projects/p/zones/z/instances/gke-airgap-1-node"]} if use == "used" else {})})
json.dump(disks, open(path, "w"))
PY
}
disks_left() { python3 -c 'import json, sys; print(" ".join(sorted(d["name"] for d in json.load(open(sys.argv[1])))))' "$W/pvc-disks"; }

world J; pvc_disk pvc-old 30 unused; pvc_disk pvc-used 30 used; pvc_disk pvc-young 1 unused; pvc_disk pvc-other 30 unused records
"$BASH" "$ROOT/scripts/gke.sh" volumes sweep >"$W/out" 2>&1; echo $? >"$W/rc"
if [ "$(rc)" = 0 ] && [ "$(disks_left)" = "pvc-other pvc-used pvc-young" ] && said "deleted 1 disk(s)"; then
  pass "J: volumes sweep deletes the unused disk Vault's claim left three hours ago, and keeps the one in use, the young one and another namespace's"
else fail "J: volumes sweep kept or took the wrong disks (rc $(rc), left: $(disks_left)): $(why)"; fi

world K; pvc_disk pvc-vault 0 used
"$BASH" "$ROOT/scripts/gke.sh" volumes 0 >"$W/out" 2>&1; echo $? >"$W/rc"; zero="$(rc)"
"$BASH" "$ROOT/scripts/gke.sh" volumes 1 >"$W/out" 2>&1; echo $? >"$W/rc"
if [ "$zero" != 0 ] && [ "$(rc)" = 0 ] && said "pvc-vault"; then
  pass "K: volumes 0 fails while Vault's disk is there, and volumes 1 passes and lists it"
else fail "K: volumes counted Vault's disk wrong (0: rc $zero, 1: rc $(rc)): $(why)"; fi

printf '%s\n' "${results[@]}"
exit "$failed"
