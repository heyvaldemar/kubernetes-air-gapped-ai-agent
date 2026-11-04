#!/usr/bin/env bash
# gke.sh <login|images|sweep|drop|residue|leftovers|volumes|cost> - the parts of the GKE
# run (ADR 22) that are not Terraform. .github/workflows/gke.yml and
# gke-sweep.yml call them; each reads the environment the workflow sets:
# GKE_PROJECT, GKE_REGION, GKE_STATE_BUCKET, CLUSTER (the run's cluster
# name), REGISTRY (Artifact Registry's host in the region) and INSIDE (the
# run's repository).
#
#   login      Artifact Registry's credential for this run, into the
#              DOCKER_CONFIG the bundle and the checks read, on oras's stdin;
#              never printed
#   images     the boundary alone: copy busybox into this run's repository by
#              the digest airgap/images.txt pins, the connected side, before
#              anything inside can ask for it. With the agent, the bundle
#              carries everything instead (bundle.sh load)
#   sweep      clear this workflow's own runs that an earlier run left, with
#              the creation account: any state under airgap-runs/ older than
#              three hours. A state whose resources are no longer in the
#              project (the daily sweep deleted them) is removed; one whose
#              resources are is destroyed, or, when Terraform cannot, cleared
#              by name as the daily sweep clears; whatever is still there
#              after that fails the run. Run 41038578800 died destroying
#              against a state whose repository the daily sweep had deleted
#   drop       remove this run's own state, once its destroy left nothing
#   residue    after the destroy, look for anything of this run's, and of any
#              earlier run's, still in the project: none is the only passing
#              answer
#   leftovers  the daily sweep, with the delete-only account: delete what any
#              run left, once GitHub says that run has finished or it is
#              older than three hours. It reads no state and touches none:
#              the next run's sweep removes the state of what it deleted
#   cost       what the run cost, from its length and list prices
#   volumes N  the disks made for Vault's claim (ADR 24), found by the
#              claim the provisioner writes in a disk's description, which
#              names no run: name, zone, size, type, whether a VM uses it,
#              its labels. There must be exactly N: 1 once Vault is up, 0
#              after the destroy, since GKE keeps such a disk when the
#              cluster goes
#   volumes sweep  delete such a disk that no VM uses and that is more than
#              three hours old, which only a run that never released it
#              can have left; fail if one is still there after
set -euo pipefail
# A gcloud that fails inside $(what ...) must stop the script, not read as
# "nothing there".
shopt -s inherit_errexit
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX=airgap-runs
# The credential store bundle.sh and the checks read, as on kind.
export DOCKER_CONFIG="$ROOT/.cache/airgap/docker"
say() { printf '== %s\n' "$*"; }

# what <project> <region>: every resource an airgap run makes, or GKE makes
# for one, as "<kind> <name> <created>", one a line. A run names what it
# makes airgap-<run>; GKE names its node VMs, instance groups and firewall
# rules gke-airgap-<run>-..., and labels its disks with the cluster.
what() {
  local p="$1" r="$2"
  gcloud container clusters list --project "$p" --filter='name ~ ^airgap-' --format='value(name,createTime)' | sed 's/^/cluster /'
  gcloud artifacts repositories list --project "$p" --location "$r" --format='value(name.basename(),createTime)' | { grep '^airgap-' || true; } | sed 's/^/repository /'
  gcloud compute networks list --project "$p" --filter='name ~ ^airgap-' --format='value(name,creationTimestamp)' | sed 's/^/network /'
  gcloud compute networks subnets list --project "$p" --filter='name ~ ^airgap-' --format='value(name,creationTimestamp)' | sed 's/^/subnet /'
  # Not the subnet's own route, which goes with the subnet.
  gcloud compute routes list --project "$p" --filter='network ~ /airgap- AND NOT name ~ ^default-route-' --format='value(name,creationTimestamp)' | sed 's/^/route /'
  gcloud compute firewall-rules list --project "$p" --filter='network ~ /airgap-' --format='value(name,creationTimestamp)' | sed 's/^/firewall /'
  gcloud compute instances list --project "$p" --filter='name ~ ^gke-airgap-' --format='value(name,creationTimestamp)' | sed 's/^/instance /'
  gcloud compute instance-groups managed list --project "$p" --filter='name ~ ^gke-airgap-' --format='value(name,creationTimestamp)' | sed 's/^/instance-group /'
  gcloud compute instance-templates list --project "$p" --filter='name ~ ^gke-airgap-' --format='value(name,creationTimestamp)' | sed 's/^/instance-template /'
  gcloud compute disks list --project "$p" --filter='labels.goog-k8s-cluster-name ~ ^airgap- OR name ~ ^gke-airgap-' --format='value(name,creationTimestamp)' | sed 's/^/disk /'
  gcloud compute forwarding-rules list --project "$p" --filter='network ~ /airgap-' --format='value(name,creationTimestamp)' | sed 's/^/forwarding-rule /'
  gcloud dns managed-zones list --project "$p" --filter='name ~ ^airgap-' --format='value(name,creationTime)' | sed 's/^/zone /'
  # A response policy carries no time of its own: its run's network does.
  gcloud dns response-policies list --project "$p" --format='value(responsePolicyName)' | { grep '^airgap-' || true; } | sed 's/^/response-policy /;s/$/ -/'
}

# owner <name>: the run a resource belongs to, from airgap-<run> in its name
owner() { sed -nE 's/^(gke-)?airgap-([0-9]+)([^0-9].*)?$/\2/p' <<<"$1"; }

# parts <run> <inventory>: the lines of an inventory from what() that are
# that run's
parts() {
  local kind name created
  while read -r kind name created; do
    [ -n "$name" ] && [ "$(owner "$name")" = "$1" ] && printf '%s %s %s\n' "$kind" "$name" "$created"
  done <<<"$2"
  return 0
}

# epoch <time>: seconds since 1970 for any of the times Google Cloud prints.
# GNU date reads them all; python3 where there is none (a Mac).
epoch() {
  date -d "$1" +%s 2>/dev/null \
    || python3 -c 'import datetime, sys; print(int(datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00")).timestamp()))' "$1"
}

# age_h <run> <inventory>: how many hours ago the oldest of its parts was
# made, 0 when none says
age_h() {
  local kind name created h oldest=0 now
  now=$(date +%s)
  while read -r kind name created; do
    [ -n "$created" ] && [ "$created" != - ] || continue
    h=$(( (now - $(epoch "$created")) / 3600 )); [ "$h" -gt "$oldest" ] && oldest=$h
  done < <(parts "$1" "$2")
  echo "$oldest"
}

# delete_run <run>: delete, by name and in the order their dependencies
# need, everything of that run in the project. The cluster first: GKE
# deletes its node VMs, groups and firewall rules with it. Then the
# registry, the DNS, and the network last. What this misses, the inventory
# after it shows; the callers fail on it.
delete_run() {
  local c="airgap-$1" p="$GKE_PROJECT" rule zone rname rtype fw route disk
  if gcloud container clusters describe "$c" --project "$p" --zone "$GKE_ZONE" >/dev/null 2>&1; then
    gcloud container clusters delete "$c" --project "$p" --zone "$GKE_ZONE" --quiet
  fi
  gcloud artifacts repositories delete "$c" --project "$p" --location "$GKE_REGION" --quiet 2>/dev/null || true
  if gcloud dns response-policies describe "$c" --project "$p" >/dev/null 2>&1; then
    for rule in $(gcloud dns response-policies rules list "$c" --project "$p" --format='value(ruleName)'); do
      gcloud dns response-policies rules delete "$rule" --response-policy "$c" --project "$p" --quiet
    done
    gcloud dns response-policies update "$c" --project "$p" --networks="" --quiet
    gcloud dns response-policies delete "$c" --project "$p" --quiet
  fi
  for zone in $(gcloud dns managed-zones list --project "$p" --filter="name ~ ^$c-" --format='value(name)'); do
    gcloud dns record-sets list --zone "$zone" --project "$p" --format='value(name,type)' | while read -r rname rtype; do
      case "$rtype" in SOA|NS) continue ;; esac
      gcloud dns record-sets delete "$rname" --type "$rtype" --zone "$zone" --project "$p" --quiet
    done
    gcloud dns managed-zones delete "$zone" --project "$p" --quiet
  done
  for fw in $(gcloud compute firewall-rules list --project "$p" --filter="network ~ /$c\$" --format='value(name)'); do
    gcloud compute firewall-rules delete "$fw" --project "$p" --quiet
  done
  for route in $(gcloud compute routes list --project "$p" --filter="network ~ /$c\$ AND NOT name ~ ^default-route-" --format='value(name)'); do
    gcloud compute routes delete "$route" --project "$p" --quiet
  done
  gcloud compute networks subnets delete "$c" --project "$p" --region "$GKE_REGION" --quiet 2>/dev/null || true
  gcloud compute networks delete "$c" --project "$p" --quiet 2>/dev/null || true
  for disk in $(gcloud compute disks list --project "$p" --filter="labels.goog-k8s-cluster-name=$c" --format='value(name,zone.basename())' | tr '\t' ':'); do
    gcloud compute disks delete "${disk%%:*}" --zone "${disk#*:}" --project "$p" --quiet
  done
}

# destroy_state <run>: terraform destroy against that run's own state and
# variables, from a copy of gke/
destroy_state() {
  local work
  work="$(mktemp -d)"
  gcloud storage cp --no-user-output-enabled "gs://$GKE_STATE_BUCKET/$PREFIX/$1/run.tfvars.json" "$work/run.tfvars.json" \
    && mkdir -p "$work/tf" && cp -r "$ROOT/gke/." "$work/tf/" \
    && rm -rf "$work/tf/.terraform" "$work/tf/bootstrap" \
    && printf 'terraform {\n  backend "gcs" {}\n}\n' >"$work/tf/ci_backend.tf" \
    && terraform -chdir="$work/tf" init -input=false -lockfile=readonly -backend-config="bucket=$GKE_STATE_BUCKET" \
         -backend-config="prefix=$PREFIX/$1" >/dev/null \
    && terraform -chdir="$work/tf" destroy -input=false -auto-approve -var-file="$work/run.tfvars.json" \
         -var 'operator_cidrs=["198.51.100.1/32"]' >/dev/null
}

# drop_state <run>: the run's state and variables, gone from the bucket
drop_state() { gcloud storage rm --recursive --no-user-output-enabled "gs://$GKE_STATE_BUCKET/$PREFIX/$1/"; }

case "${1:-}" in
  login)
    : "${REGISTRY:?}"
    mkdir -p "$DOCKER_CONFIG"
    gcloud auth print-access-token | oras login --username oauth2accesstoken --password-stdin "$REGISTRY" >/dev/null
    say "logged in to $REGISTRY for this run"
    ;;
  images)
    : "${REGISTRY:?}" "${INSIDE:?}"
    "$0" login
    src="$(grep -E '^docker.io/library/busybox:' "$ROOT/airgap/images.txt")"
    repo="${src%%:*}"; tag="${src#*:}"; tag="${tag%@*}"
    oras cp "$src" "$INSIDE/$repo:$tag" >/dev/null
    got="$(oras manifest fetch --descriptor "$INSIDE/$repo:$tag" | python3 -c 'import json,sys; print(json.load(sys.stdin)["digest"])')"
    [ "$got" = "${src#*@}" ] || { echo "$repo: the registry inside holds $got, the pin is ${src#*@}" >&2; exit 1; }
    say "$repo copied into $INSIDE/$repo, by digest $got"
    ;;
  sweep)
    : "${GKE_STATE_BUCKET:?}" "${GKE_PROJECT:?}" "${GKE_REGION:?}" "${GKE_ZONE:?}"
    now=$(date +%s); destroyed=0 removed=0 inventory=""
    for run in $(gcloud storage ls "gs://$GKE_STATE_BUCKET/$PREFIX/" 2>/dev/null | sed -n "s#^gs://$GKE_STATE_BUCKET/$PREFIX/\([0-9]*\)/\$#\1#p"); do
      [ "$run" = "${RUN_ID:-}" ] && continue
      state="gs://$GKE_STATE_BUCKET/$PREFIX/$run/default.tfstate"
      if ! updated="$(gcloud storage objects describe "$state" --format='value(update_time)' 2>/dev/null)"; then
        # Variables and no state: the run stopped before Terraform wrote one.
        updated="$(gcloud storage objects describe "gs://$GKE_STATE_BUCKET/$PREFIX/$run/run.tfvars.json" --format='value(update_time)')"
        left=0
      else
        left="$(gcloud storage cat "$state" | python3 -c 'import json,sys; print(sum(len(r.get("instances", [])) for r in json.load(sys.stdin).get("resources", []) if r.get("mode") == "managed"))')"
      fi
      age=$(( (now - $(epoch "$updated")) / 3600 ))
      if [ "$age" -lt 3 ]; then say "run $run: $left resources in its state, $age h old: still inside its run"; continue; fi
      [ -n "$inventory" ] || inventory="$(what "$GKE_PROJECT" "$GKE_REGION")"
      mine="$(parts "$run" "$inventory")"
      if [ -z "$mine" ]; then
        say "run $run: $left resources in its state, none of them in the project, $age h old: its state removed"
        drop_state "$run"; removed=$((removed + 1)); continue
      fi
      say "run $run: $left resources in its state, $(grep -c . <<<"$mine") of its parts in the project, $age h old: destroying"
      if ! destroy_state "$run"; then
        say "run $run: Terraform could not destroy against its state: deleting what is left by name"
        delete_run "$run"
      fi
      inventory="$(what "$GKE_PROJECT" "$GKE_REGION")"
      still="$(parts "$run" "$inventory" | awk '{print $1 "/" $2}' | tr '\n' ' ')"
      if [ -n "$still" ]; then echo "run $run: still in the project after its destroy: $still" >&2; exit 1; fi
      drop_state "$run"; say "run $run: destroyed, its state removed"; destroyed=$((destroyed + 1))
    done
    say "destroyed $destroyed earlier run(s), removed $removed state(s) whose resources were gone"
    ;;
  drop)
    : "${GKE_STATE_BUCKET:?}" "${RUN_ID:?}"
    drop_state "$RUN_ID"
    say "run $RUN_ID: its state removed"
    ;;
  residue)
    : "${GKE_PROJECT:?}" "${GKE_REGION:?}" "${CLUSTER:?}"
    run="${CLUSTER#airgap-}"
    inventory="$(what "$GKE_PROJECT" "$GKE_REGION")"
    mine="" elsewhere=""
    while read -r kind name _; do
      [ -n "$name" ] || continue
      if [ "$(owner "$name")" = "$run" ]; then mine="$mine $kind/$name"; else elsewhere="$elsewhere $kind/$name"; fi
    done <<<"$inventory"
    # The runs never overlap (concurrency gke-boundary), so at this point
    # nothing but this run's should have existed, and none of it should now.
    if [ -z "$mine" ] && [ -z "$elsewhere" ]; then
      say "nothing left of $CLUSTER, and nothing of any earlier run"; exit 0
    fi
    [ -z "$mine" ] || echo "left behind by $CLUSTER:$mine" >&2
    [ -z "$elsewhere" ] || echo "left behind by earlier runs:$elsewhere" >&2
    exit 1
    ;;
  leftovers)
    : "${GKE_PROJECT:?}" "${GKE_REGION:?}" "${GKE_ZONE:?}" "${GITHUB_REPOSITORY:?}"
    p="$GKE_PROJECT"
    inventory="$(what "$p" "$GKE_REGION")"
    runs="$(while read -r _ name _; do owner "$name"; done <<<"$inventory" | grep -v '^$' | sort -u || true)"
    [ -n "$runs" ] || { say "nothing of any run in $p"; exit 0; }
    swept=0 kept=0
    for run in $runs; do
      # A run that GitHub says has finished owns nothing any more; one still
      # going keeps what it has, unless it is older than any run can be.
      status="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run" --jq .status 2>/dev/null || echo unknown)"
      age="$(age_h "$run" "$inventory")"
      if [ "$status" != completed ] && [ "$age" -lt 3 ]; then
        say "run $run: $status on GitHub, $age h old: leaving it to its own teardown"; kept=$((kept + 1)); continue
      fi
      say "run $run: $status on GitHub, $age h old: deleting what it left"
      delete_run "$run"
      swept=$((swept + 1))
    done
    say "deleted what $swept run(s) left; $kept still running"
    # Then the same inventory again, held to the same rule: what is left of a
    # finished run, or of one older than any run can be, is what the sweep
    # failed to delete.
    after="$(what "$p" "$GKE_REGION")" left=""
    for run in $(while read -r _ name _; do owner "$name"; done <<<"$after" | grep -v '^$' | sort -u || true); do
      status="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run" --jq .status 2>/dev/null || echo unknown)"
      age="$(age_h "$run" "$after")"
      [ "$status" != completed ] && [ "$age" -lt 3 ] && continue
      left="$left $(parts "$run" "$after" | awk '{print $1 "/" $2}' | tr '\n' ' ')"
    done
    left="${left%% }"; [ -n "${left// /}" ] || left=""
    if [ -n "$left" ]; then echo "still there after the sweep:$left" >&2; exit 1; fi
    ;;
  cost)
    # List prices, us-central1, per hour, read from the Cloud Billing Catalog
    # API on 2026-10-27: the zonal cluster's management fee (GKE's free tier
    # credits one zonal cluster's per billing account; it is counted here as
    # if it did not), the node on demand from its vCPU and memory SKUs, its
    # 50 GB balanced disk, and the three private zones. Cloud DNS's queries,
    # Artifact Registry's storage for an hour and the bytes into Google
    # Cloud, which are free, round to nothing for one run.
    : "${STARTED:?}"
    python3 - "$STARTED" "$(date +%s)" "${NODE_TYPE:-e2-standard-2}" <<'PY'
import sys
hours = (int(sys.argv[2]) - int(sys.argv[1])) / 3600
node = sys.argv[3]
# vCPU-hour x vCPUs + GiB-hour x GiB, from the E2 and C3D SKUs.
per_node = {"e2-standard-2": 2 * 0.02181159 + 8 * 0.00292353,
            "c3d-standard-4": 4 * 0.029563 + 16 * 0.003959}
rows = [("GKE zonal cluster management", 0.10, hours),
        ("one %s node" % node, per_node[node], hours),
        ("its 50 GB balanced persistent disk", 50 * 0.10 / 730, hours),
        ("three private DNS zones", 3 * 0.20 / 730, hours)]
print("| What | Per hour | This run |\n|---|---|---|")
for what, rate, h in rows:
    print("| %s | $%.4f | $%.2f |" % (what, rate, rate * h))
print("| **Total, %.2f h** | | **about $%.2f** |" % (hours, sum(r * h for _, r, h in rows)))
PY
    ;;
  volumes)
    : "${GKE_PROJECT:?}"
    want="${2:?volumes needs a count or sweep}" list="$(mktemp)"
    gcloud compute disks list --project "$GKE_PROJECT" --filter='description ~ created-for/pvc/namespace' \
      --format='json(name,zone.basename(),users,labels,sizeGb,type.basename(),creationTimestamp,description)' >"$list"
    # The disks Vault's claim left: their description is the provisioner's
    # JSON, naming the claim's namespace.
    vault="$(python3 - "$list" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1])):
    try:
        ns = json.loads(d.get("description") or "{}").get("kubernetes.io/created-for/pvc/namespace")
    except ValueError:
        continue
    if ns == "vault":
        print(" ".join([d["name"], d.get("zone", "-"), str(d.get("sizeGb", "-")), d.get("type", "-"), d.get("creationTimestamp", "-"),
                        "used" if d.get("users") else "unused",
                        ",".join("%s=%s" % kv for kv in sorted((d.get("labels") or {}).items())) or "no-labels"]))
PY
)"
    if [ "$want" = sweep ]; then
      now=$(date +%s) deleted=0 left=""
      while read -r name zone _ _ created use _; do
        [ -n "$name" ] && [ "$use" = unused ] || continue
        [ $(( (now - $(epoch "$created")) / 3600 )) -ge 3 ] || continue
        if gcloud compute disks delete "$name" --zone "$zone" --project "$GKE_PROJECT" --quiet; then
          say "disk $name, left by Vault's claim since $created: deleted"; deleted=$((deleted + 1))
        else left="$left $name"; fi
      done <<<"$vault"
      say "deleted $deleted disk(s) Vault's claims left"
      if [ -n "$left" ]; then echo "still there after the sweep:$left" >&2; exit 1; fi
      exit 0
    fi
    [ -z "$vault" ] || while read -r line; do printf '  %s\n' "$line"; done <<<"$vault"
    n=$(grep -c . <<<"$vault" || true)
    say "$n disk(s) made for Vault's claim in $GKE_PROJECT"
    [ "$n" = "$want" ] || { echo "expected $want" >&2; exit 1; }
    ;;
  *) echo "usage: gke.sh <login|images|sweep|drop|residue|leftovers|volumes|cost>" >&2; exit 2 ;;
esac
