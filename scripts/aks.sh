#!/usr/bin/env bash
# aks.sh <login|images|sweep|delete|residue|leftovers|cost> - the parts of the
# AKS run (ADR 23) that are not Terraform. .github/workflows/aks.yml and
# aks-sweep.yml call them, logged in with az as the run's identity; each
# reads the environment the workflow sets: AZURE_SUBSCRIPTION_ID,
# AZURE_STATE_ACCOUNT, CLUSTER (the run's cluster name, and its resource
# group's), REGISTRY (the registry's login server), REGISTRY_NAME and INSIDE
# (where images go in it).
#
#   login      the registry's credential for this run, into the DOCKER_CONFIG
#              the bundle and the checks read, on oras's stdin; never printed
#   images     the boundary alone: copy busybox into this run's registry by
#              the digest airgap/images.txt pins, from the connected side,
#              before anything inside can ask for it
#   sweep      with the creation identity, before a run applies: delete every
#              earlier run's resource group. Runs on main never overlap
#              (concurrency aks-boundary), so any there is a finished run's
#   delete     the teardown: delete this run's resource group, which takes
#              everything the run made, and AKS's node group with the cluster
#   residue    after the delete, look for anything of this run's, and of any
#              earlier run's, still in the subscription: none is the only
#              passing answer. Then this run's state goes too
#   leftovers  the daily sweep, with the delete-only identity: delete what any
#              run left, once GitHub says that run has finished or its group
#              is older than three hours
#   cost       what the run cost, from its length and list prices, and what
#              Cost Management has measured for the runs before it
set -euo pipefail
# An az that fails inside $(...) must stop the script, not read as "nothing
# there".
shopt -s inherit_errexit
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_CONTAINER=airgap-runs
# The credential store bundle.sh and the checks read, as on kind.
export DOCKER_CONFIG="$ROOT/.cache/airgap/docker"
say() { printf '== %s\n' "$*"; }

# groups: every resource group a run makes, or AKS makes for one, as
# "<name> <created> <run-id tag>", one a line. A run names its group
# airgap-<run> and tags it with the run; AKS names the node's group
# airgap-<run>-nodes. The standing groups (airgap-state, airgap-identities)
# match neither.
groups() {
  az rest --method get \
    --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/resourcegroups?api-version=2021-04-01&\$expand=createdTime" \
    --query "value[?starts_with(name, 'airgap-')].[name, createdTime, tags.\"run-id\" || '-']" -o tsv \
    | { grep -E '^airgap-[0-9]+(-nodes)?[[:space:]]' || true; }
}

# owner <group>: the run a group belongs to, from airgap-<run> in its name
owner() { sed -nE 's/^airgap-([0-9]+)(-nodes)?$/\1/p' <<<"$1"; }

# tagged: anything outside those groups that carries a run's tag
tagged() {
  az resource list --tag run-id --query '[].[resourceGroup, type, name]' -o tsv
}

# drop <group>: delete it and wait; a group already gone is not an error
drop() {
  if az group exists -n "$1" -o tsv | grep -qx true; then
    az group delete -n "$1" --yes
    say "deleted $1"
  fi
}

case "${1:-}" in
  login)
    : "${REGISTRY:?}" "${REGISTRY_NAME:?}"
    mkdir -p "$DOCKER_CONFIG"
    # An ACR refresh token for the run's identity, on stdout and into oras;
    # az's errors and notes go to stderr, which carries no token. The user
    # name ACR asks for with one is this fixed GUID.
    token="$(az acr login --name "$REGISTRY_NAME" --expose-token --query accessToken -o tsv --only-show-errors)"
    [ -n "$token" ] || { echo "the registry gave no token" >&2; exit 1; }
    oras login --username 00000000-0000-0000-0000-000000000000 --password-stdin "$REGISTRY" <<<"$token" >/dev/null
    unset token
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
    : "${AZURE_SUBSCRIPTION_ID:?}" "${CLUSTER:?}"
    swept=0
    while read -r name _; do
      [ -n "$name" ] || continue
      case "$name" in "$CLUSTER" | "$CLUSTER-nodes") continue ;; esac
      say "$name: an earlier run's, left: deleting"
      drop "$name"; swept=$((swept + 1))
    done <<<"$(groups | sort -r)"
    say "deleted $swept group(s) earlier runs left"
    # A state whose run left no group behind records nothing that exists:
    # its teardown deleted the group and stopped before the state.
    if [ -n "${AZURE_STATE_ACCOUNT:-}" ]; then
      left="$(groups)"
      for run in $(az storage blob list --auth-mode login --account-name "$AZURE_STATE_ACCOUNT" -c "$STATE_CONTAINER" \
          --query '[].name' -o tsv | sed -n 's#^\([0-9]*\)/.*#\1#p' | sort -u); do
        [ "$run" = "${CLUSTER#airgap-}" ] && continue
        grep -qE "^airgap-$run(-nodes)?[[:space:]]" <<<"$left" && continue
        az storage blob delete-batch --auth-mode login --account-name "$AZURE_STATE_ACCOUNT" \
          --source "$STATE_CONTAINER" --pattern "$run/*" -o none
        say "run $run: no group left, so its state is deleted too"
      done
    fi
    ;;
  delete)
    : "${CLUSTER:?}"
    drop "$CLUSTER"
    # AKS deletes the node's group with the cluster; if it outlived it, so
    # much the worse for the residue check, which looks next.
    ;;
  residue)
    : "${AZURE_SUBSCRIPTION_ID:?}" "${CLUSTER:?}"
    run="${CLUSTER#airgap-}"
    mine="" elsewhere=""
    while read -r name _; do
      [ -n "$name" ] || continue
      if [ "$(owner "$name")" = "$run" ]; then mine="$mine group/$name"; else elsewhere="$elsewhere group/$name"; fi
    done <<<"$(groups)"
    while read -r rg type name; do
      [ -n "$name" ] || continue
      if [ "$(owner "$rg")" = "$run" ]; then mine="$mine $type/$name"; else elsewhere="$elsewhere $type/$name(in $rg)"; fi
    done <<<"$(tagged)"
    # The runs never overlap (concurrency aks-boundary), so at this point
    # nothing but this run's should have existed, and none of it should now.
    if [ -z "$mine" ] && [ -z "$elsewhere" ]; then
      say "nothing left of $CLUSTER, and nothing of any earlier run"
      if [ -n "${AZURE_STATE_ACCOUNT:-}" ]; then
        az storage blob delete-batch --auth-mode login --account-name "$AZURE_STATE_ACCOUNT" \
          --source "$STATE_CONTAINER" --pattern "$run/*" -o none
        say "its state, under $STATE_CONTAINER/$run/, deleted with it"
      fi
      exit 0
    fi
    [ -z "$mine" ] || echo "left behind by $CLUSTER:$mine" >&2
    [ -z "$elsewhere" ] || echo "left behind by earlier runs:$elsewhere" >&2
    exit 1
    ;;
  leftovers)
    : "${AZURE_SUBSCRIPTION_ID:?}" "${GITHUB_REPOSITORY:?}"
    now=$(date +%s)
    inventory="$(groups)"
    [ -n "$inventory" ] || { say "nothing of any run in the subscription"; exit 0; }
    # finished <run>: GitHub says the run is over, or its oldest group is
    # older than any run can be
    finished() {
      local status age_h=0 h
      status="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$1" --jq .status 2>/dev/null || echo unknown)"
      while read -r name created _; do
        [ "$(owner "$name")" = "$1" ] || continue
        h=$(( (now - $(date -d "$created" +%s)) / 3600 )); [ "$h" -gt "$age_h" ] && age_h=$h
      done <<<"$inventory"
      say "run $1: $status on GitHub, $age_h h old"
      [ "$status" = completed ] || [ "$age_h" -ge 3 ]
    }
    swept=0 kept=0
    for run in $(while read -r name _; do owner "$name"; done <<<"$inventory" | sort -u); do
      if ! finished "$run"; then
        say "run $run: leaving it to its own teardown"; kept=$((kept + 1)); continue
      fi
      # The run's group first: deleting it deletes the cluster, and AKS the
      # node's group with it. Then the node's group, if it outlived that.
      drop "airgap-$run"
      drop "airgap-$run-nodes"
      swept=$((swept + 1))
    done
    say "deleted what $swept run(s) left; $kept still running"
    # Then the inventory again, held to the same rule: what is left of a
    # finished run is what the sweep failed to delete.
    inventory="$(groups)" left=""
    for run in $(while read -r name _; do owner "$name"; done <<<"$inventory" | sort -u); do
      finished "$run" >/dev/null || continue
      while read -r name _; do
        [ "$(owner "$name")" = "$run" ] && left="$left $name"
      done <<<"$inventory"
    done
    if [ -n "$left" ]; then echo "still there after the sweep:$left" >&2; exit 1; fi
    ;;
  cost)
    # List prices, eastus, per hour, read from the Azure Retail Prices API on
    # 2026-10-29. AKS's Free tier control plane has a meter of its own since
    # 2026-10-01 (FreeTierInfrastructureCost). A Premium registry is priced
    # per day, and counted here as one whole day, however short the run;
    # Cost Management, below, says whether Azure counts it so. The private
    # zone and the resolver policy's three domains are priced per month,
    # counted by the hour. DNS queries and the bytes through the private
    # endpoint round to nothing for one run.
    : "${STARTED:?}"
    python3 - "$STARTED" "$(date +%s)" "${NODE_SIZE:-Standard_D2as_v7}" <<'PY'
import sys
hours = (int(sys.argv[2]) - int(sys.argv[1])) / 3600
node = sys.argv[3]
per_node = {"Standard_D2as_v7": 0.0908, "Standard_D4as_v7": 0.182}
rows = [("AKS Free tier control plane", 0.05, hours),
        ("one %s node" % node, per_node[node], hours),
        ("its 64 GB Premium SSD (P6) OS disk", 9.86 / 730, hours),
        ("the registry's private endpoint", 0.01, hours),
        ("the private zone privatelink.azurecr.io", 0.50 / 730, hours),
        ("the resolver policy's three domains", 3 * 0.50 / 730, hours)]
print("| What | Per hour | This run |\n|---|---|---|")
for what, rate, h in rows:
    print("| %s | $%.4f | $%.2f |" % (what, rate, rate * h))
print("| a Premium registry, priced per day | $1.6666 a day | $1.67 |")
total = sum(r * h for _, r, h in rows) + 1.6666
print("| **Total, %.2f h** | | **about $%.2f** |" % (hours, total))
PY
    # What Azure itself has counted, by run, from Cost Management. It reports
    # a day or so late, so this run is not in it yet; the ones before it are.
    printf '\nCost Management, this month, by run:\n\n'
    body='{"type":"ActualCost","timeframe":"MonthToDate","dataset":{"granularity":"None","aggregation":{"cost":{"name":"Cost","function":"Sum"}},"grouping":[{"type":"Dimension","name":"ResourceGroupName"},{"type":"Dimension","name":"MeterCategory"}]}}'
    for attempt in 1 2 3 4; do
      if out="$(az rest --method post --body "$body" -o json \
          --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/providers/Microsoft.CostManagement/query?api-version=2025-03-01" 2>&1)"; then
        python3 -c '
import json, re, sys
d = json.loads(sys.argv[1])["properties"]
cols = [c["name"] for c in d["columns"]]
runs = {}
for row in d["rows"]:
    r = dict(zip(cols, row))
    m = re.match(r"airgap-(\d+)(-nodes)?$", str(r.get("ResourceGroupName", "")), re.I)
    if not m:
        continue
    runs.setdefault(m.group(1), {}).setdefault(r["MeterCategory"], 0.0)
    runs[m.group(1)][r["MeterCategory"]] += r["Cost"]
if not runs:
    print("no run has a cost recorded yet")
print("| Run | What | Cost |\n|---|---|---|") if runs else None
for run in sorted(runs):
    for what, cost in sorted(runs[run].items()):
        print("| %s | %s | $%.4f |" % (run, what, cost))
    print("| %s | **total** | **$%.2f** |" % (run, sum(runs[run].values())))
' "$out"
        exit 0
      fi
      case "$out" in
        *"Too many requests"*|*"429"*) sleep $((attempt * 20)) ;;
        *) printf 'Cost Management answered: %s\n' "$(grep -o '"message":"[^"]*"' <<<"$out" | head -1)"; exit 0 ;;
      esac
    done
    echo "Cost Management kept answering 429, too many requests"
    ;;
  *) echo "usage: aks.sh <login|images|sweep|delete|residue|leftovers|cost>" >&2; exit 2 ;;
esac
