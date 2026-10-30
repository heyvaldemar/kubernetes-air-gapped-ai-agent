#!/usr/bin/env bash
# aks.sh <login|images|sweep|delete|residue|leftovers|cost|spend|budget|guard>
# - the parts of the AKS run (ADR 23) that are not Terraform.
# .github/workflows/aks.yml and aks-sweep.yml call them, logged in with az as
# the run's identity; each reads the environment the workflow sets:
# AZURE_SUBSCRIPTION_ID, AZURE_STATE_ACCOUNT, CLUSTER (the run's cluster name,
# and its resource group's), REGISTRY (the registry's login server),
# REGISTRY_NAME and INSIDE (where images go in it).
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
#   spend      what Cost Management has counted for each run this month
#   budget     the subscription's budget is there, $10 a month at most, with
#              its alerts on
#   guard      before a run applies: the budget, and room under the $10 a
#              month the maintainer allowed the runs for one more
set -euo pipefail
# An az that fails inside $(...) must stop the script, not read as "nothing
# there".
shopt -s inherit_errexit
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_CONTAINER=airgap-runs
# The maintainer's limits (2026-10-29 and 2026-10-30): the subscription's
# budget, and what the runs may cost in a month; one run at list prices.
BUDGET=flagship-monthly
CAP=10
ONE_RUN=1.75
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

# month_costs: this month's cost of every run, as JSON {run: {meter: cost}},
# from Cost Management, by the runs' resource groups. On no answer it
# prints why and fails; it asks again while Cost Management says 429.
month_costs() {
  local body out attempt
  body='{"type":"ActualCost","timeframe":"MonthToDate","dataset":{"granularity":"None","aggregation":{"cost":{"name":"Cost","function":"Sum"}},"grouping":[{"type":"Dimension","name":"ResourceGroupName"},{"type":"Dimension","name":"MeterCategory"}]}}'
  for attempt in 1 2 3 4; do
    if out="$(az rest --method post --body "$body" -o json --only-show-errors \
        --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/providers/Microsoft.CostManagement/query?api-version=2025-03-01" 2>&1)"; then
      python3 -c '
import json, re, sys
d = json.loads(sys.argv[1])["properties"]
cols = [c["name"] for c in d["columns"]]
runs = {}
for row in d["rows"]:
    r = dict(zip(cols, row))
    m = re.match(r"airgap-(\d+)(-nodes)?$", str(r.get("ResourceGroupName", "")), re.I)
    if m:
        runs.setdefault(m.group(1), {}).setdefault(r["MeterCategory"], 0.0)
        runs[m.group(1)][r["MeterCategory"]] += r["Cost"]
print(json.dumps(runs))
' "$out"
      return 0
    fi
    case "$out" in
      *"Too many requests"*|*"429"*) sleep $((attempt * 20)) ;;
      *) printf 'Cost Management answered: %s\n' "$(grep -o '"message":"[^"]*"' <<<"$out" | head -1)"; return 1 ;;
    esac
  done
  echo "Cost Management kept answering 429, too many requests"; return 1
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
    printf '\nCost Management, this month, by run:\n\n'
    "$0" spend
    ;;
  spend)
    # What Azure itself has counted for the runs this month, by run, from
    # their resource groups. Cost Management reports a day or so late, so
    # the run that asks is not in it yet; the ones before it are.
    : "${AZURE_SUBSCRIPTION_ID:?}"
    if ! out="$(month_costs)"; then printf '%s\n' "$out"; exit 0; fi
    python3 -c '
import json, sys
runs = json.loads(sys.argv[1])
if not runs:
    print("no run has a cost recorded yet")
    sys.exit(0)
print("| Run | What | Cost |\n|---|---|---|")
for run in sorted(runs):
    for what, cost in sorted(runs[run].items()):
        print("| %s | %s | $%.4f |" % (run, what, cost))
    print("| %s | **total** | **$%.2f** |" % (run, sum(runs[run].values())))
print("| **this month** | | **$%.2f** |" % sum(sum(r.values()) for r in runs.values()))
' "$out"
    ;;
  budget)
    # The subscription's budget, as the maintainer set it on 2026-10-29: $10
    # a month with its alerts on. Printed without its addresses, which a
    # public log has no need of; missing, larger or silent, it fails.
    : "${AZURE_SUBSCRIPTION_ID:?}"
    b="$(az rest --method get -o json --only-show-errors \
      --url "https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_ID/providers/Microsoft.Consumption/budgets/$BUDGET?api-version=2024-08-01")"
    python3 -c '
import json, sys
p = json.loads(sys.argv[1])["properties"]
on = [n for n in p.get("notifications", {}).values() if n.get("enabled")]
print("budget %s: $%s a %s, $%s spent so far, %d alerts on: %s" % (sys.argv[2], p["amount"], {"Monthly": "month", "Quarterly": "quarter", "Annually": "year"}.get(p["timeGrain"], p["timeGrain"]),
      (p.get("currentSpend") or {}).get("amount", 0), len(on),
      ", ".join(sorted("%s %s%%" % (n.get("thresholdType", "Actual").lower(), n["threshold"]) for n in on))))
if float(p["amount"]) > float(sys.argv[3]) or not on:
    sys.exit("the budget is not the $%s a month with alerts the maintainer approved" % sys.argv[3])
' "$b" "$BUDGET" "$CAP"
    ;;
  guard)
    # Before anything is billed: the budget is there, and this month's runs
    # have left room for one more under the $10 a month the maintainer
    # allowed for them (2026-10-30). A budget only alerts; this refuses.
    : "${AZURE_SUBSCRIPTION_ID:?}"
    "$0" budget
    if ! out="$(month_costs)"; then printf '%s; going on, with list prices as the only count\n' "$out"; exit 0; fi
    python3 -c '
import json, sys
spent = sum(sum(r.values()) for r in json.loads(sys.argv[1]).values())
cap, one = float(sys.argv[2]), float(sys.argv[3])
print("this month the runs have cost $%.2f in Cost Management; with one more, about $%.2f, of the $%.2f a month allowed" % (spent, spent + one, cap))
if spent + one > cap:
    sys.exit("one more run would pass the $%.2f a month the maintainer allowed: none until next month, unless he raises it" % cap)
' "$out" "$CAP" "$ONE_RUN"
    ;;
  *) echo "usage: aks.sh <login|images|sweep|delete|residue|leftovers|cost|spend|budget|guard>" >&2; exit 2 ;;
esac
