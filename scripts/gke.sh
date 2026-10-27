#!/usr/bin/env bash
# gke.sh <login|images|sweep|residue|leftovers|cost> - the parts of the GKE
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
#   sweep      destroy this workflow's own runs that an earlier run left: any
#              state under airgap-runs/ older than three hours that still
#              holds resources, with the creation account
#   residue    after the destroy, look for anything of this run's, and of any
#              earlier run's, still in the project: none is the only passing
#              answer
#   leftovers  the daily sweep, with the delete-only account: delete what any
#              run left, once GitHub says that run has finished or it is
#              older than three hours
#   cost       what the run cost, from its length and list prices
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
    : "${GKE_STATE_BUCKET:?}"
    now=$(date +%s); swept=0
    for run in $(gcloud storage ls "gs://$GKE_STATE_BUCKET/$PREFIX/" 2>/dev/null | sed -n "s#^gs://$GKE_STATE_BUCKET/$PREFIX/\([0-9]*\)/\$#\1#p"); do
      [ "$run" = "${RUN_ID:-}" ] && continue
      state="gs://$GKE_STATE_BUCKET/$PREFIX/$run/default.tfstate"
      updated="$(gcloud storage objects describe "$state" --format='value(update_time)' 2>/dev/null)" || continue
      age_h=$(( (now - $(date -d "$updated" +%s)) / 3600 ))
      left="$(gcloud storage cat "$state" | python3 -c 'import json,sys; print(sum(len(r.get("instances", [])) for r in json.load(sys.stdin).get("resources", []) if r.get("mode") == "managed"))')"
      [ "$left" = 0 ] && continue
      if [ "$age_h" -lt 3 ]; then say "run $run: $left resources, $age_h h old: still inside its run"; continue; fi
      say "run $run: $left resources left for $age_h h: destroying"
      work="$(mktemp -d)"
      gcloud storage cp --no-user-output-enabled "gs://$GKE_STATE_BUCKET/$PREFIX/$run/run.tfvars.json" "$work/run.tfvars.json"
      mkdir -p "$work/tf" && cp -r "$ROOT/gke/." "$work/tf/"
      rm -rf "$work/tf/.terraform" "$work/tf/bootstrap"
      printf 'terraform {\n  backend "gcs" {}\n}\n' >"$work/tf/ci_backend.tf"
      terraform -chdir="$work/tf" init -input=false -lockfile=readonly -backend-config="bucket=$GKE_STATE_BUCKET" \
        -backend-config="prefix=$PREFIX/$run" >/dev/null
      terraform -chdir="$work/tf" destroy -input=false -auto-approve -var-file="$work/run.tfvars.json" \
        -var 'operator_cidrs=["198.51.100.1/32"]' >/dev/null
      say "run $run: destroyed"; swept=$((swept + 1))
    done
    say "swept $swept earlier run(s)"
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
    p="$GKE_PROJECT"; now=$(date +%s)
    inventory="$(what "$p" "$GKE_REGION")"
    runs="$(while read -r _ name _; do owner "$name"; done <<<"$inventory" | grep -v '^$' | sort -u || true)"
    [ -n "$runs" ] || { say "nothing of any run in $p"; exit 0; }
    swept=0 kept=0
    for run in $runs; do
      c="airgap-$run"
      # A run that GitHub says has finished owns nothing any more; one still
      # going keeps what it has, unless it is older than any run can be.
      status="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run" --jq .status 2>/dev/null || echo unknown)"
      age_h=0
      while read -r _ name created; do
        [ "$(owner "$name")" = "$run" ] && [ "$created" != - ] || continue
        h=$(( (now - $(date -d "$created" +%s)) / 3600 )); [ "$h" -gt "$age_h" ] && age_h=$h
      done <<<"$inventory"
      if [ "$status" != completed ] && [ "$age_h" -lt 3 ]; then
        say "run $run: $status on GitHub, $age_h h old: leaving it to its own teardown"; kept=$((kept + 1)); continue
      fi
      say "run $run: $status on GitHub, $age_h h old: deleting what it left"
      # The cluster first: GKE deletes its node VMs, groups and firewall rules
      # with it. Then the registry, the DNS, and the network last.
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
      swept=$((swept + 1))
    done
    say "deleted what $swept run(s) left; $kept still running"
    # Then the same inventory again: what is left now belongs to a run still
    # going, or the sweep failed to delete it.
    after="$(what "$p" "$GKE_REGION")" left=""
    while read -r kind name _; do
      [ -n "$name" ] || continue
      st="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$(owner "$name")" --jq .status 2>/dev/null || echo unknown)"
      [ "$st" = completed ] && left="$left $kind/$name"
    done <<<"$after"
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
  *) echo "usage: gke.sh <login|images|sweep|residue|leftovers|cost>" >&2; exit 2 ;;
esac
