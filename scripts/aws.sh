#!/usr/bin/env bash
# aws.sh <repositories|login|images|sweep|residue|cost> - the parts of the AWS
# run (ADR 18) that are not Terraform. .github/workflows/aws.yml calls them;
# each reads the environment the workflow sets: AWS_REGION, TF_STATE_BUCKET,
# CLUSTER (the run's cluster name), and REGISTRY, the account's ECR.
#
#   repositories  the ECR repositories the run makes, as JSON: every one the
#            bundle carries (scripts/bundle.sh create), under its original
#            path, or only busybox's for a run of the boundary alone
#   login    ECR's credential for this run, into the DOCKER_CONFIG the bundle
#            and the checks read, on oras's stdin; never printed
#   images   the boundary alone: copy busybox into this run's ECR by the
#            digest airgap/images.txt pins, the connected side, before
#            anything inside can ask for it. With the agent, the bundle
#            carries everything instead (bundle.sh load)
#   sweep    destroy this workflow's own runs that an earlier run left: any
#            state under airgap-runs/ older than three hours that still holds
#            resources. The other repository's sweeper reads runs/ only
#   residue  after the destroy, look for anything still tagged with the run's
#            cluster, or named after it: none is the only passing answer
#   cost     what the run cost, from its length and list prices
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX=airgap-runs
# The credential store bundle.sh and the checks read, as on kind.
export DOCKER_CONFIG="$ROOT/.cache/airgap/docker"
say() { printf '== %s\n' "$*"; }

case "${1:-}" in
  repositories)
    bundle="$ROOT/.cache/airgap/bundle.tar"
    if [ -s "$bundle" ]; then
      tar -tf "$bundle" | grep -v '/blobs/' | sed -n 's#^\./oci/\(.*\)/index\.json$#\1#p'
    else
      echo docker.io/library/busybox
    fi | sort -u | python3 -c 'import json, sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))'
    ;;
  login)
    : "${REGISTRY:?}" "${AWS_REGION:?}"
    mkdir -p "$DOCKER_CONFIG"
    aws ecr get-login-password --region "$AWS_REGION" | oras login --username AWS --password-stdin "$REGISTRY" >/dev/null
    say "logged in to $REGISTRY for this run"
    ;;
  images)
    : "${REGISTRY:?}" "${CLUSTER:?}" "${AWS_REGION:?}"
    "$0" login
    src="$(grep -E '^docker.io/library/busybox:' "$ROOT/airgap/images.txt")"
    repo="${src%%:*}"; tag="${src#*:}"; tag="${tag%@*}"
    oras cp "$src" "$REGISTRY/$CLUSTER/$repo:$tag" >/dev/null
    got="$(oras manifest fetch --descriptor "$REGISTRY/$CLUSTER/$repo:$tag" | python3 -c 'import json,sys; print(json.load(sys.stdin)["digest"])')"
    [ "$got" = "${src#*@}" ] || { echo "$repo: ECR holds $got, the pin is ${src#*@}" >&2; exit 1; }
    say "$repo copied into $REGISTRY/$CLUSTER/$repo, by digest $got"
    ;;
  sweep)
    : "${TF_STATE_BUCKET:?}" "${AWS_REGION:?}"
    now=$(date +%s); swept=0
    # shellcheck disable=SC2016  # the backticks are JMESPath's, not the shell's
    for key in $(aws s3api list-objects-v2 --bucket "$TF_STATE_BUCKET" --prefix "$PREFIX/" \
                   --query 'Contents[?ends_with(Key, `.tfstate`)].Key' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^None$' || true); do
      run="$(basename "$key" .tfstate)"
      [ "$run" = "${RUN_ID:-}" ] && continue
      modified="$(aws s3api head-object --bucket "$TF_STATE_BUCKET" --key "$key" --query LastModified --output text)"
      age_h=$(( (now - $(date -d "$modified" +%s)) / 3600 ))
      left="$(aws s3 cp "s3://$TF_STATE_BUCKET/$key" - | python3 -c 'import json,sys; print(sum(len(r.get("instances", [])) for r in json.load(sys.stdin).get("resources", []) if r.get("mode") == "managed"))')"
      [ "$left" = 0 ] && continue
      if [ "$age_h" -lt 3 ]; then say "run $run: $left resources, $age_h h old: still inside its run"; continue; fi
      say "run $run: $left resources left for $age_h h: destroying"
      work="$(mktemp -d)"
      aws s3 cp --quiet "s3://$TF_STATE_BUCKET/$PREFIX/$run.tfvars.json" "$work/run.tfvars.json"
      mkdir -p "$work/tf" && cp -r "$ROOT/aws/." "$work/tf/"
      rm -rf "$work/tf/.terraform"
      printf 'terraform {\n  backend "s3" {}\n}\n' >"$work/tf/ci_backend.tf"
      terraform -chdir="$work/tf" init -input=false -lockfile=readonly -backend-config="bucket=$TF_STATE_BUCKET" \
        -backend-config="key=$key" -backend-config="region=$AWS_REGION" -backend-config="use_lockfile=true" >/dev/null
      terraform -chdir="$work/tf" destroy -input=false -auto-approve -var-file="$work/run.tfvars.json" \
        -var 'operator_cidrs=["198.51.100.1/32"]' >/dev/null
      say "run $run: destroyed"; swept=$((swept + 1))
    done
    say "swept $swept earlier run(s)"
    ;;
  residue)
    : "${CLUSTER:?}" "${AWS_REGION:?}"
    # exists <arn> <cluster>: the tagging API keeps a deleted resource's tags
    # for a while; a resource it lists is asked about directly before it
    # counts.
    exists() {
      case "$1" in
        *:vpc/*) aws ec2 describe-vpcs --vpc-ids "${1##*/}" >/dev/null 2>&1 ;;
        *:vpc-endpoint/*) [ "$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "${1##*/}" --query 'VpcEndpoints[0].State' --output text 2>/dev/null)" = available ] ;;
        # Run 39624648738 listed a security group and its rule that no longer
        # existed: the tagging API had not caught up with the delete.
        *:security-group/*) aws ec2 describe-security-groups --group-ids "${1##*/}" >/dev/null 2>&1 ;;
        *:security-group-rule/*) aws ec2 describe-security-group-rules --security-group-rule-ids "${1##*/}" >/dev/null 2>&1 ;;
        # Run 39898005905 listed a subnet EC2 never had: CloudTrail names no
        # event for it, and the run's one throttled CreateSubnet carried the
        # tag. EC2 answers for it now.
        *:subnet/*) aws ec2 describe-subnets --subnet-ids "${1##*/}" >/dev/null 2>&1 ;;
        *:route-table/*) aws ec2 describe-route-tables --route-table-ids "${1##*/}" >/dev/null 2>&1 ;;
        *:launch-template/*) aws ec2 describe-launch-templates --launch-template-ids "${1##*/}" >/dev/null 2>&1 ;;
        # The registry inside, and Kyverno's Pod Identity association, which
        # goes with its cluster.
        *:repository/*) aws ecr describe-repositories --repository-names "${1#*:repository/}" >/dev/null 2>&1 ;;
        *:podidentityassociation/*) aws eks describe-cluster --name "$2" >/dev/null 2>&1 ;;
        *) true ;;
      esac
    }
    left="$(aws resourcegroupstaggingapi get-resources --tag-filters "Key=airgap.heyvaldemar.com/cluster,Values=$CLUSTER" \
              --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n' | grep -v '^$' || true)"
    roles="$(aws iam list-roles --query "Roles[?starts_with(RoleName, '$CLUSTER')].RoleName" --output text | tr '\t' '\n' | grep -v '^$' || true)"
    cluster="$(aws eks describe-cluster --name "$CLUSTER" --query cluster.status --output text 2>/dev/null || true)"
    really=""
    while read -r arn; do
      [ -n "$arn" ] || continue
      exists "$arn" "$CLUSTER" && really="$really $arn"
    done <<<"$left"
    # And what any earlier run of this project left that its own run never
    # saw: a run destroys what its state holds and looks for its own tag,
    # and the sweep destroys an earlier run's state. A resource no state
    # holds is found here, by the project's tag, whichever run made it. The
    # runs never overlap (concurrency aws-boundary), so at this point none
    # but this one has a cluster.
    elsewhere="" gone=0
    # shellcheck disable=SC2016 # the backticks are JMESPath's, not the shell's
    while read -r arn owner; do
      [ -n "$arn" ] || continue
      [ "$owner" = "$CLUSTER" ] && continue
      if exists "$arn" "$owner"; then elsewhere="$elsewhere $arn ($owner)"; else gone=$((gone + 1)); fi
    done < <(aws resourcegroupstaggingapi get-resources \
               --tag-filters "Key=airgap.heyvaldemar.com/project,Values=kubernetes-air-gapped-ai-agent" "Key=airgap.heyvaldemar.com/cluster" \
               --query 'ResourceTagMappingList[].[ResourceARN, Tags[?Key==`airgap.heyvaldemar.com/cluster`] | [0].Value]' --output text || true)
    [ "$gone" -gt 0 ] && say "the tagging API still lists $gone resource(s) of earlier runs that no longer exist"
    if [ -z "${really// /}" ] && [ -z "$roles" ] && [ -z "$cluster" ] && [ -z "$elsewhere" ]; then
      say "nothing left of $CLUSTER, and nothing of any earlier run"; exit 0
    fi
    [ -z "${really// /}" ] && [ -z "$roles" ] && [ -z "$cluster" ] || echo "left behind by $CLUSTER: cluster '${cluster:-none}'; roles: ${roles:-none}; tagged:${really:- none}" >&2
    [ -z "$elsewhere" ] || echo "left behind by earlier runs:$elsewhere" >&2
    exit 1
    ;;
  cost)
    # List prices, us-east-1, per hour, read from the AWS price list on
    # 2026-10-21, the g6 nodes on 2026-10-22 from instances.vantage.sh, which
    # republishes it: the EKS control plane, the nodes on demand, and an
    # interface endpoint per zone (six endpoints, two zones). The DNS
    # Firewall's $0.60 a million queries, ECR's storage for an hour and the
    # bytes into AWS, which are free, round to nothing for one run.
    : "${STARTED:?}"
    python3 - "$STARTED" "$(date +%s)" "${NODE_TYPE:-m7i.large}" "${GPU_TYPE:-}" "${GPU_STARTED:-}" "${GPU_STOPPED:-}" "${NODES:-1}" <<'PY'
import sys
now = int(sys.argv[2])
hours = (now - int(sys.argv[1])) / 3600
node, gpu, gpu_started, gpu_stopped, nodes = sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], int(sys.argv[7] or 1)
per_node = {"m7i.large": 0.1008, "m7i.xlarge": 0.2016, "g6.xlarge": 0.8048, "g6.2xlarge": 0.9776}
# (what, per hour, hours). Two nodes (ADR 20) are priced as two for the
# whole run; the one the drill loses is replaced within minutes, and both
# bill meanwhile.
rows = [("EKS control plane", 0.10, hours),
        ("one %s node" % node if nodes == 1 else "two %s nodes" % node, per_node[node] * nodes, hours),
        ("six interface endpoints in two zones", 6 * 2 * 0.01, hours)]
if gpu and gpu_started:
    # The GPU node (ADR 19) from the apply that made it to the apply that
    # took it away, or to the end of the destroy when that one never ran.
    gpu_h = ((int(gpu_stopped) if gpu_stopped else now) - int(gpu_started)) / 3600
    rows.append(("one %s GPU node, %.2f h of the run" % (gpu, gpu_h), per_node[gpu], gpu_h))
print("| What | Per hour | This run |\n|---|---|---|")
for what, rate, h in rows:
    print("| %s | $%.4f | $%.2f |" % (what, rate, rate * h))
print("| **Total, %.2f h** | | **about $%.2f** |" % (hours, sum(r * h for _, r, h in rows)))
PY
    ;;
  *) echo "usage: aws.sh <repositories|login|images|sweep|residue|cost>" >&2; exit 2 ;;
esac
