#!/usr/bin/env bash
# gpu.sh <install|serve|check|measure|larger|reset> - a GPU beside the CPU (ADR 19), on the
# AWS run's cluster once the CPU side is up: the same signed model, by the
# same digest, served by the CUDA build of the same llama.cpp release.
#
#   install  NVIDIA's device plugin from the registry inside, on the GPU node
#            (manifests/gpu/device-plugin.yaml); waits until the node offers
#            its GPU to the scheduler
#   serve    the GPU server (manifests/inference/llama-gpu.yaml) through
#            scripts/serve.sh, so the model is named exactly as the CPU
#            server names it and admission reads the same signature
#   check    what the run claims about the GPU side, appended to $E2E_RESULTS:
#            the node offers one GPU; the GPU server runs on it with the same
#            model digest as the CPU server; the model is in the GPU's memory
#            (nvidia-smi, in the server's container); and a
#            pod that asks for the GPU with weights nobody signed is refused
#            like any other
#   measure <cpu|gpu>  scripts/capacity.py against one server, from a Job
#            beside it (manifests/gpu/measure.yaml and capacity.yaml), at
#            concurrency 1, 2, 4 and 8, each level at least $MIN_SECONDS
#            (30): calls a minute, p50 and p95, output tokens a second. The
#            CPU server first, before the GPU node exists; then the GPU's,
#            measured again through a port-forward from the runner, as runs
#            before measured it, beside the runner's time to the EKS API; and
#            the comparison: what a thousand calls cost at each node's list
#            price, the table to $GITHUB_STEP_SUMMARY, the files to
#            $CAPACITY_DIR. The door the Job needs into inference is closed
#            after, whatever happened, and checked closed
#   larger   the GPU server goes, and granite-4.1-8b takes the GPU: served,
#            checked like the first, and measured the same way
#   reset    the records service, the MCP server and the gateway's proxy
#            restarted, so a second model's evals start where a fresh
#            cluster's do: the records the service ships with, an empty
#            outbox, an empty audit log, the gateway's counters at zero
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$ROOT/.cache/airgap"
# shellcheck source=scripts/inside.sh
. "$ROOT/scripts/inside.sh"
read -r MODEL _rest < <(grep -vE '^\s*(#|$)' "$ROOT/models/models.lock" | awk -v m="${MODEL:-}" 'm == "" || $1 == m' | head -n 1)
GPU_NODE_LABEL=boundary.heyvaldemar.com/accelerator=nvidia
# The larger model the GPU serves once the first is measured (models.lock).
LARGER=granite-4.1-8b
# On-demand list prices, us-east-1, per hour, as scripts/aws.sh cost reads them.
CPU_NODE="${NODE_TYPE:-m7i.xlarge}" GPU_NODE="${GPU_TYPE:-g6.xlarge}"
price() { case "$1" in m7i.large) echo 0.1008 ;; m7i.xlarge) echo 0.2016 ;; g6.xlarge) echo 0.8048 ;; g6.2xlarge) echo 0.9776 ;; esac; }
say() { printf '== %s\n' "$*"; }
results=(); measured=(); failed=0
pass() { results+=("PASS  $1"); printf '  PASS  %s\n' "$1"; }
fail() { results+=("FAIL  $1"); printf '  FAIL  %s\n' "$1"; failed=1; }
measure_line() { measured+=("$1"); printf '  MEASURED  %s\n' "$1"; }
record() {
  [ -n "${E2E_RESULTS:-}" ] || return 0
  { printf '%s\n' "${results[@]}"; printf '\n--measured--\n'; printf '%s\n' "${measured[@]}"; } | python3 -c '
import json, os, sys
out = sys.argv[1]
lines = sys.stdin.read().split("\n--measured--\n")
d = json.load(open(out)) if os.path.exists(out) else {"checks": [], "measured": []}
d["checks"] += [{"name": l[6:].strip(), "passed": l.startswith("PASS")} for l in lines[0].splitlines() if l.strip()]
d["measured"] += [l for l in (lines[1] if len(lines) > 1 else "").splitlines() if l.strip()]
json.dump(d, open(out, "w"), indent=1)' "$E2E_RESULTS"
}

# close_door: the measurement's namespace and its door into inference gone.
close_door() {
  kubectl delete namespace measure --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1
  kubectl -n inference delete networkpolicy from-the-measurement --ignore-not-found >/dev/null 2>&1
}
door_closed() {
  if ! kubectl get namespace measure >/dev/null 2>&1 \
     && ! kubectl -n inference get networkpolicy from-the-measurement >/dev/null 2>&1; then
    pass "the door the measurement opened into inference is closed again: its namespace and its network policy are gone"
  else
    fail "the measurement's namespace or its network policy into inference is still there"
  fi
}

# in_cluster <service> <out.json> <model> <slots> <threads> <on>: scripts/
# capacity.py in a Job beside the model servers; its levels as they come,
# and the result to out.json.
in_cluster() {
  local svc="$1" out="$2" state=""
  close_door
  relocate <"$ROOT/manifests/gpu/measure.yaml" | kubectl apply -f - >/dev/null || return 1
  kubectl -n measure create configmap capacity --from-file="$ROOT/scripts/capacity.py" \
    --from-file="$ROOT/evals/harness.py" --from-file="$ROOT/evals/tasks.json" \
    --from-file="$ROOT/manifests/mcp/server.py" --from-file="$ROOT/manifests/mcp/policy.json" >/dev/null || return 1
  sed -e "s#@SERVER@#http://$svc.inference.svc.cluster.local:8080#" -e "s#@MODEL@#$3#" -e "s#@SLOTS@#$4#" \
    -e "s#@THREADS@#$5#" -e "s#@ACCELERATOR@#$6#" -e "s#@MIN_SECONDS@#${MIN_SECONDS:-30}#" \
    "$ROOT/manifests/gpu/capacity.yaml" | relocate | kubectl apply -f - >/dev/null || return 1
  for _ in $(seq 1 180); do
    state="$(kubectl -n measure get job capacity -o jsonpath='{.status.succeeded}{.status.failed}' 2>/dev/null)"
    [ -n "$state" ] && break
    sleep 5
  done
  kubectl -n measure logs job/capacity >"$out.log" 2>&1
  sed '/^--capacity--$/,$d' "$out.log"
  sed '1,/^--capacity--$/d' "$out.log" >"$out"
  rm -f "$out.log"
  python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$out" 2>/dev/null \
    || { echo "the measurement of $svc from inside the cluster wrote no result" >&2; rm -f "$out"; return 1; }
}

# The runner's time to the EKS API: TCP connects to its endpoint, the
# median of ten. Every call through a port-forward crosses that path.
api_rtt() {
  local server ca
  server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  ca="$(mktemp)"
  kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d >"$ca"
  for _ in $(seq 1 10); do curl -s -o /dev/null --cacert "$ca" -w '%{time_connect}\n' "$server/readyz"; done \
    | sort -n | awk '{a[NR] = $1} END {printf "%.0f", (a[5] + a[6]) / 2 * 1000}'
  rm -f "$ca"
}

case "${1:-}" in
  install)
    set -e
    relocate <"$ROOT/manifests/gpu/device-plugin.yaml" | kubectl apply -f - >/dev/null
    kubectl -n gpu-system rollout status daemonset/nvidia-device-plugin --timeout=600s >/dev/null
    for _ in $(seq 1 60); do
      n="$(kubectl get nodes -l "$GPU_NODE_LABEL" -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null)"
      [ "${n:-0}" -ge 1 ] 2>/dev/null && { say "the GPU node offers $n GPU to the scheduler"; exit 0; }
      sleep 5
    done
    echo "the GPU node never offered a GPU: $(kubectl -n gpu-system logs ds/nvidia-device-plugin --tail=20 2>&1 | tr '\n' ' ' | cut -c1-400)" >&2
    exit 1
    ;;
  serve)
    SERVE_NAME=llama-gpu SERVE_MANIFEST="$ROOT/manifests/inference/llama-gpu.yaml" MODEL="$MODEL" "$ROOT/scripts/serve.sh"
    ;;
  check)
    n="$(kubectl get nodes -l "$GPU_NODE_LABEL" -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null)"
    gpu_node="$(kubectl get nodes -l "$GPU_NODE_LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    if [ "$n" = 1 ]; then pass "the GPU node offers one GPU to the scheduler (NVIDIA's device plugin, from the bundle)"
    else fail "the GPU node offers '${n:-nothing}' GPUs"; fi
    cpu_ref="$(kubectl -n inference get deployment llama -o jsonpath='{.spec.template.spec.volumes[0].image.reference}')"
    gpu_ref="$(kubectl -n inference get deployment llama-gpu -o jsonpath='{.spec.template.spec.volumes[0].image.reference}')"
    on="$(kubectl -n inference get pod -l server=llama-gpu -o jsonpath='{.items[0].spec.nodeName}')"
    if [ -n "$gpu_ref" ] && [ "$gpu_ref" = "$cpu_ref" ] && [ -n "$on" ] && [ "$on" = "$gpu_node" ]; then
      pass "the GPU server runs on the GPU node with the CPU server's signed model, by the same digest (${gpu_ref##*@})"
    else
      fail "the GPU server's model or node is not the expected one: model '${gpu_ref:-none}' against '${cpu_ref:-none}', on '${on:-nowhere}'"
    fi
    # Asked of the GPU itself, not of a log line: llama-server b11429 no
    # longer logs its offload at the default verbosity (run 39893082349).
    # With every layer on the L4 the model and its cache take gigabytes of
    # its memory; a server that fell back to the CPU leaves it near empty.
    mem="$(kubectl -n inference exec deploy/llama-gpu -- nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)"
    used="$(cut -d, -f2 <<<"$mem" | tr -d ' ')"
    if [ -n "$used" ] && [ "$used" -ge 1024 ] 2>/dev/null; then
      pass "the model is on the GPU: the $(cut -d, -f1 <<<"$mem" | sed 's/^ *//') holds ${used} MiB of its$(cut -d, -f3 <<<"$mem") MiB (nvidia-smi, in the server's container)"
    else
      fail "the model is not on the GPU: nvidia-smi in the server's container answered '${mem:-nothing}'"
    fi
    unsigned="$MODELS/plant-unsigned@$(cat "$STATE/plant-unsigned.digest")"
    out="$(kubectl apply --dry-run=server -f - 2>&1 <<EOF
{"apiVersion":"v1","kind":"Pod","metadata":{"name":"gpu-probe","namespace":"inference"},"spec":{
 "automountServiceAccountToken":false,
 "nodeSelector":{"boundary.heyvaldemar.com/accelerator":"nvidia"},
 "tolerations":[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}],
 "securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}},
 "containers":[{"name":"c","image":"$(relocated "$(grep -E '^ghcr.io/ggml-org/llama.cpp:server-cuda' "$ROOT/airgap/images-gpu.txt")")",
  "resources":{"limits":{"nvidia.com/gpu":1}},
  "securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}},
  "volumeMounts":[{"name":"model","mountPath":"/models","readOnly":true}]}],
 "volumes":[{"name":"model","image":{"reference":"$unsigned","pullPolicy":"IfNotPresent"}}]}}
EOF
)"
    if grep -q "signed with the operator's key" <<<"$out"; then
      pass "a pod that asks for the GPU with weights nobody signed is refused (model weights are signed with the operator's key)"
    else
      fail "a pod that asks for the GPU with weights nobody signed was not refused for its signature: $(head -c 300 <<<"$out")"
    fi
    record
    exit "$failed"
    ;;
  measure)
    dir="${CAPACITY_DIR:-$STATE/capacity}"
    mkdir -p "$dir/port-forward"
    trap close_door EXIT
    case "${2:-}" in
      cpu)
        if in_cluster llama "$dir/cpu.json" "$MODEL" 1 2 "CPU, $CPU_NODE"; then
          pass "the CPU server measured from inside the cluster, each level at least ${MIN_SECONDS:-30} s"
        else
          fail "the CPU server could not be measured from inside the cluster"
        fi
        close_door; door_closed; record; exit "$failed"
        ;;
      gpu) ;;
      *) echo "usage: gpu.sh measure <cpu|gpu>" >&2; exit 2 ;;
    esac
    in_cluster llama-gpu "$dir/gpu.json" "$MODEL" 8 0 "GPU, $GPU_NODE (L4)" \
      || { fail "the GPU server could not be measured from inside the cluster"; close_door; record; exit 1; }
    close_door; door_closed
    # The same server through a port-forward from the runner, as runs
    # 39898005905 and 39914708816 measured it, beside the runner's time to
    # the EKS API: what that path adds to each call.
    kubectl -n inference port-forward svc/llama-gpu 18081:8080 >/dev/null 2>&1 & pf=$!
    trap 'kill "$pf" 2>/dev/null; close_door' EXIT
    for _ in $(seq 1 30); do curl -fs -o /dev/null "http://127.0.0.1:18081/health" && break; sleep 1; done
    MODEL="$MODEL" SLOTS=8 THREADS=0 ACCELERATOR="GPU, $GPU_NODE (L4), through a port-forward" MIN_SECONDS="${MIN_SECONDS:-30}" \
      python3 "$ROOT/scripts/capacity.py" run "http://127.0.0.1:18081" "$dir/port-forward/gpu.json" 1,2,4,8
    kill "$pf" 2>/dev/null
    rtt="$(api_rtt)"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      { echo "### One model server, on CPU and on GPU"; echo; python3 "$ROOT/scripts/capacity.py" table "$dir"; echo; } >>"$GITHUB_STEP_SUMMARY"
    fi
    python3 "$ROOT/scripts/capacity.py" table "$dir"
    # The checks and the numbers: every call answered on both, per level
    # what a thousand calls cost at each node's list price, and what the
    # port-forward added.
    while IFS= read -r line; do
      case "$line" in PASS*) pass "${line#PASS  }" ;; FAIL*) fail "${line#FAIL  }" ;; M*) measure_line "${line#M  }" ;; esac
    done < <(python3 - "$dir/cpu.json" "$dir/gpu.json" "$dir/port-forward/gpu.json" "$(price "$CPU_NODE")" "$(price "$GPU_NODE")" "$CPU_NODE" "$GPU_NODE" "$rtt" <<'PY'
import json, sys
cpu, gpu, fwd = (json.load(open(f)) for f in sys.argv[1:4])
cpu_price, gpu_price = float(sys.argv[4]), float(sys.argv[5])
cpu_node, gpu_node, rtt = sys.argv[6], sys.argv[7], sys.argv[8]
for name, r in (("CPU server", cpu), ("GPU server", gpu), ("GPU server, through the port-forward,", fwd)):
    calls = sum(lv["calls"] for lv in r["levels"])
    bad = sum(lv["failed"] for lv in r["levels"])
    print(("PASS  " if bad == 0 else "FAIL  ") + "the %s answered %d of %d calls at concurrency 1, 2, 4 and 8" % (name, calls - bad, calls))
by = lambda r: {lv["concurrency"]: lv for lv in r["levels"]}
c, g, f = by(cpu), by(gpu), by(fwd)
per_k = lambda lv, p: p / (lv["calls_per_min"] * 60) * 1000 if lv["calls_per_min"] else float("nan")
for k in sorted(set(c) & set(g)):
    cc, gg = c[k], g[k]
    print("M  at concurrency %d: CPU (%s) %s calls a minute, p50 %s s, $%.3f a thousand calls; GPU (%s) %s calls a minute, p50 %s s, $%.3f a thousand calls"
          % (k, cpu_node, cc["calls_per_min"], cc["p50_s"], per_k(cc, cpu_price), gpu_node, gg["calls_per_min"], gg["p50_s"], per_k(gg, gpu_price)))
for k in sorted(set(g) & set(f)):
    print("M  the port-forward at concurrency %d: %s calls a minute, p50 %s s, against %s and %s s from inside the cluster"
          % (k, f[k]["calls_per_min"], f[k]["p50_s"], g[k]["calls_per_min"], g[k]["p50_s"]))
print("M  from the runner to the EKS API: a TCP connect took %s ms (median of ten)" % (rtt or "?"))
PY
)
    record
    exit "$failed"
    ;;
  larger)
    dir="${CAPACITY_DIR:-$STATE/capacity}"
    mkdir -p "$dir"
    trap close_door EXIT
    # A pod holds a GPU whole: the first server goes before the next starts.
    kubectl -n inference delete deployment/llama-gpu service/llama-gpu --grace-period=5 --ignore-not-found --wait=true >/dev/null
    kubectl -n inference wait --for=delete pod -l server=llama-gpu --timeout=300s >/dev/null 2>&1
    SERVE_NAME=llama-gpu-8b SERVE_MANIFEST="$ROOT/manifests/inference/llama-gpu.yaml" MODEL="$LARGER" "$ROOT/scripts/serve.sh" \
      || { fail "$LARGER did not come up on the GPU"; record; exit 1; }
    read -r _ _ _ _rest < <(grep -vE '^\s*(#|$)' "$ROOT/models/models.lock" | awk -v m="$LARGER" '$1 == m')
    want="${_rest##* }"; [ "$want" = unpinned ] && want="$(cat "$STATE/$LARGER.digest")"
    ref="$(kubectl -n inference get deployment llama-gpu-8b -o jsonpath='{.spec.template.spec.volumes[0].image.reference}')"
    on="$(kubectl -n inference get pod -l server=llama-gpu-8b -o jsonpath='{.items[0].spec.nodeName}')"
    gpu_node="$(kubectl get nodes -l "$GPU_NODE_LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    if [ "${ref##*@}" = "$want" ] && [ -n "$on" ] && [ "$on" = "$gpu_node" ]; then
      pass "$LARGER runs on the GPU node with the image this run built and signed, by its digest (${want:0:19}), admitted on its signature and AI-BOM"
    else
      fail "$LARGER's model or node is not the expected one: '${ref:-none}' against '$want', on '${on:-nowhere}'"
    fi
    mem="$(kubectl -n inference exec deploy/llama-gpu-8b -- nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)"
    used="$(cut -d, -f2 <<<"$mem" | tr -d ' ')"
    # Its weights alone are 5.0 GiB (models.lock).
    if [ -n "$used" ] && [ "$used" -ge 5120 ] 2>/dev/null; then
      pass "$LARGER is on the GPU: the $(cut -d, -f1 <<<"$mem" | sed 's/^ *//') holds ${used} MiB of its$(cut -d, -f3 <<<"$mem") MiB (nvidia-smi, in the server's container)"
    else
      fail "$LARGER is not on the GPU: nvidia-smi in the server's container answered '${mem:-nothing}'"
    fi
    if in_cluster llama-gpu-8b "$dir/gpu-8b.json" "$LARGER" 8 0 "GPU, $GPU_NODE (L4)"; then
      while IFS= read -r line; do
        case "$line" in PASS*) pass "${line#PASS  }" ;; FAIL*) fail "${line#FAIL  }" ;; M*) measure_line "${line#M  }" ;; esac
      done < <(python3 - "$dir/gpu-8b.json" "$(price "$GPU_NODE")" "$LARGER" <<'PY'
import json, sys
r, price, model = json.load(open(sys.argv[1])), float(sys.argv[2]), sys.argv[3]
calls = sum(lv["calls"] for lv in r["levels"])
bad = sum(lv["failed"] for lv in r["levels"])
print(("PASS  " if bad == 0 else "FAIL  ") + "%s on the GPU answered %d of %d calls at concurrency 1, 2, 4 and 8" % (model, calls - bad, calls))
for lv in r["levels"]:
    k = price / (lv["calls_per_min"] * 60) * 1000 if lv["calls_per_min"] else float("nan")
    print("M  %s at concurrency %d: %s calls a minute, p50 %s s, p95 %s s, $%.3f a thousand calls"
          % (model, lv["concurrency"], lv["calls_per_min"], lv["p50_s"], lv["p95_s"], k))
PY
)
    else
      fail "$LARGER could not be measured from inside the cluster"
    fi
    close_door; door_closed
    python3 "$ROOT/scripts/capacity.py" table "$dir"
    record
    exit "$failed"
    ;;
  reset)
    set -e
    kubectl -n corp rollout restart deployment/records-api >/dev/null
    kubectl -n mcp rollout restart deployment/mcp-server >/dev/null
    # The proxy's Deployment is its controller's; its pod is replaced instead.
    kubectl -n gateway delete pod --all --wait=true >/dev/null
    kubectl -n corp rollout status deployment/records-api --timeout=180s >/dev/null
    kubectl -n mcp rollout status deployment/mcp-server --timeout=180s >/dev/null
    kubectl -n gateway rollout status deploy --timeout=180s >/dev/null
    say "the records service, the MCP server and the gateway's proxy restarted"
    ;;
  *) echo "usage: gpu.sh <install|serve|check|measure|larger|reset>" >&2; exit 2 ;;
esac
