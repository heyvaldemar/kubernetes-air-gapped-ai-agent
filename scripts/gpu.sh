#!/usr/bin/env bash
# gpu.sh <install|serve|check|measure> - a GPU beside the CPU (ADR 19), on the
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
#            model digest as the CPU server; every layer is on the GPU; and a
#            pod that asks for the GPU with weights nobody signed is refused
#            like any other
#   measure  scripts/capacity.py against the CPU server and the GPU server,
#            each through a port-forward from the runner, at concurrency 1,
#            2, 4 and 8: calls a minute, p50 and p95, output tokens a second,
#            and what a thousand calls cost at the node's list price. The
#            table to $GITHUB_STEP_SUMMARY, the files to $CAPACITY_DIR
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$ROOT/.cache/airgap"
# shellcheck source=scripts/inside.sh
. "$ROOT/scripts/inside.sh"
read -r MODEL _rest < <(grep -vE '^\s*(#|$)' "$ROOT/models/models.lock" | awk -v m="${MODEL:-}" 'm == "" || $1 == m' | head -n 1)
GPU_NODE_LABEL=boundary.heyvaldemar.com/accelerator=nvidia
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
    off="$(kubectl -n inference logs deploy/llama-gpu 2>/dev/null | grep -oE 'offloaded [0-9]+/[0-9]+ layers to GPU' | tail -1)"
    if [ -n "$off" ] && [ "$(sed -E 's/offloaded ([0-9]+)\/([0-9]+).*/\1/' <<<"$off")" = "$(sed -E 's/offloaded ([0-9]+)\/([0-9]+).*/\2/' <<<"$off")" ]; then
      pass "every layer of the model is on the GPU (llama-server: $off)"
    else
      fail "not every layer is on the GPU: '${off:-no offload line in the server log}'"
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
    mkdir -p "$dir"
    kubectl -n inference port-forward svc/llama 18080:8080 >/dev/null 2>&1 & pf_cpu=$!
    kubectl -n inference port-forward svc/llama-gpu 18081:8080 >/dev/null 2>&1 & pf_gpu=$!
    trap 'kill "$pf_cpu" "$pf_gpu" 2>/dev/null' EXIT
    for port in 18080 18081; do
      for _ in $(seq 1 30); do curl -fs -o /dev/null "http://127.0.0.1:$port/health" && break; sleep 1; done
    done
    MODEL="$MODEL" SLOTS=1 THREADS=2 ACCELERATOR="CPU, $CPU_NODE" \
      python3 "$ROOT/scripts/capacity.py" run http://127.0.0.1:18080 "$dir/cpu.json" 1,2,4,8
    MODEL="$MODEL" SLOTS=8 THREADS=0 ACCELERATOR="GPU, $GPU_NODE (L4)" \
      python3 "$ROOT/scripts/capacity.py" run http://127.0.0.1:18081 "$dir/gpu.json" 1,2,4,8
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      { echo "### One model server, on CPU and on GPU"; echo; python3 "$ROOT/scripts/capacity.py" table "$dir"; echo; } >>"$GITHUB_STEP_SUMMARY"
    fi
    python3 "$ROOT/scripts/capacity.py" table "$dir"
    # The checks and the numbers: every call answered on both, and per level
    # what a thousand calls cost at each node's list price.
    while IFS= read -r line; do
      case "$line" in PASS*) pass "${line#PASS  }" ;; FAIL*) fail "${line#FAIL  }" ;; M*) measure_line "${line#M  }" ;; esac
    done < <(python3 - "$dir/cpu.json" "$dir/gpu.json" "$(price "$CPU_NODE")" "$(price "$GPU_NODE")" "$CPU_NODE" "$GPU_NODE" <<'PY'
import json, sys
cpu, gpu = (json.load(open(f)) for f in sys.argv[1:3])
cpu_price, gpu_price = float(sys.argv[3]), float(sys.argv[4])
cpu_node, gpu_node = sys.argv[5], sys.argv[6]
for name, r in (("CPU", cpu), ("GPU", gpu)):
    calls = sum(lv["calls"] for lv in r["levels"])
    bad = sum(lv["failed"] for lv in r["levels"])
    print(("PASS  " if bad == 0 else "FAIL  ") + "the %s server answered %d of %d calls at concurrency 1, 2, 4 and 8" % (name, calls - bad, calls))
by = lambda r: {lv["concurrency"]: lv for lv in r["levels"]}
c, g = by(cpu), by(gpu)
for k in sorted(set(c) & set(g)):
    cc, gg = c[k], g[k]
    per_k = lambda lv, p: p / (lv["calls_per_min"] * 60) * 1000 if lv["calls_per_min"] else float("nan")
    print("M  at concurrency %d: CPU (%s) %s calls a minute, p50 %s s, $%.3f a thousand calls; GPU (%s) %s calls a minute, p50 %s s, $%.3f a thousand calls"
          % (k, cpu_node, cc["calls_per_min"], cc["p50_s"], per_k(cc, cpu_price), gpu_node, gg["calls_per_min"], gg["p50_s"], per_k(gg, gpu_price)))
PY
)
    record
    exit "$failed"
    ;;
  *) echo "usage: gpu.sh <install|serve|check|measure>" >&2; exit 2 ;;
esac
