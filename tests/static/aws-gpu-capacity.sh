#!/usr/bin/env bash
# tests/static/aws-gpu-capacity.sh - what the AWS run does when EC2 gives
# its GPU node group no GPU (ADR 19, 2026-11-11): scripts/aws.sh refused,
# launches, capacity and missed, against an AWS and a GitHub that are files
# in a temporary directory: no account, no credential, no cost. Run by
# static check "aws".
#
# Each case builds what EKS says of the node group, what its Auto Scaling
# group tried, and what GitHub says of the scheduled runs before, runs one
# subcommand, and reads its exit status and what it said.
#
#   A  every launch refused for capacity, in three zones, and EKS gave the
#      node group up for that: capacity passes and records zone, type and
#      count (the message is run 42005832115's)
#   B  one launch among them refused for the account's vCPU limit: the
#      failure is the run's
#   C  one launch refused for capacity, then an instance that launched and
#      never joined (NodeCreationFailure): the run's
#   D  the node group is active and the apply failed elsewhere: the run's
#   E  EKS blames capacity and the Auto Scaling group has no refused launch
#      on record: the run's
#   F  no such node group: the run's
#   G  missed, by hand: said in the summary, as a warning and in the
#      results; GitHub is not asked, and the run goes on
#   H  missed on the schedule, and the scheduled run before measured a GPU:
#      the first in a row, the run goes on
#   I  missed on the schedule, and the scheduled run before was given none
#      either: the second in a row fails
#   J  the scheduled run before asked for no GPU, and the one before that
#      was given none: still the second in a row, it fails
#   K  GitHub does not answer: the rule cannot be held, the run fails
#   L  missed with no record of a miss: fails
#   M  launches, for a node EC2 gave after two refusals: zone, type and the
#      refusals in the results
#   N  refused: CloudTrail's refusals by day, zone and type; and a
#      CloudTrail that cannot be read is said, never a failure
#   O  what launches keeps is not among the measurements: scripts/
#      capacity.py reads every JSON file under $CAPACITY_DIR as one, and
#      its table still prints after launches has run
#   T  everything kept for the run's artifact is .json, after a miss on
#      the schedule too: the cloud-results archive (ADR 25) refuses an
#      artifact with any other file in it, as it did run 43101489006's
#   P  the scheduled run before failed as the second in a row: this one
#      is the third, and fails
#   Q  GitHub lists a scheduled run before and does not say what it did:
#      the rule cannot be held, the run fails
#   R  the scheduled run before failed its GPU apply for another reason,
#      and the one before that was given none: it neither counts nor
#      clears, this is the second in a row, and fails
#   S  one launch refused for capacity and one that was not refused, still
#      starting when EKS gave the node group up: an instance may exist, so
#      it is not a miss
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT
results=(); failed=0
pass() { results+=("PASS  $1"); }
fail() { results+=("FAIL  $1"); failed=1; }

mkdir -p "$T/bin"
cat >"$T/bin/aws" <<'PY'
#!/usr/bin/env python3
# An AWS made of files under $FAKE_AWS: nodegroup.json, subnets.json,
# activities.json, RunInstances.json, CreateFleet.json. A file that is not
# there is a call AWS refuses. A call this does not know is an error, so
# the test fails if aws.sh asks for something new.
import os, shutil, sys
W = os.environ["FAKE_AWS"]
args = sys.argv[1:]
open(os.path.join(W, "calls"), "a").write("aws " + " ".join(args) + "\n")
def give(name):
    path = os.path.join(W, name)
    if not os.path.exists(path):
        sys.exit("fake aws: %s refused" % " ".join(args[:2]))
    shutil.copyfileobj(open(path), sys.stdout)
    sys.exit(0)
two = tuple(args[:2])
if two == ("eks", "describe-nodegroup"):
    give("nodegroup.json")
if two == ("ec2", "describe-subnets"):
    give("subnets.json")
if two == ("autoscaling", "describe-scaling-activities"):
    give("activities.json")
if two == ("cloudtrail", "lookup-events"):
    give("%s.json" % next(a.split("AttributeValue=")[1] for a in args if "AttributeValue=" in a))
sys.exit("fake aws: unknown call: " + " ".join(args))
PY
cat >"$T/bin/gh" <<'PY'
#!/usr/bin/env python3
# A GitHub made of files under $FAKE_AWS/gh: runs.json for the workflow's
# scheduled runs, jobs-<id>.json for a run's jobs.
import os, re, shutil, sys
W = os.path.join(os.environ["FAKE_AWS"], "gh")
args = sys.argv[1:]
open(os.path.join(os.environ["FAKE_AWS"], "calls"), "a").write("gh " + " ".join(args) + "\n")
if args[:1] != ["api"]:
    sys.exit("fake gh: unknown call: " + " ".join(args))
jobs = re.search(r"/actions/runs/(\d+)/jobs", args[1])
name = "jobs-%s.json" % jobs.group(1) if jobs else "runs.json" if "/workflows/aws.yml/runs?event=schedule&branch=main&status=completed" in args[1] else None
if not name or not os.path.exists(os.path.join(W, name)):
    sys.exit("fake gh: HTTP 502 for " + args[1])
shutil.copyfileobj(open(os.path.join(W, name)), sys.stdout)
PY
chmod +x "$T/bin/aws" "$T/bin/gh"

# refusal <type> <zone>: the Auto Scaling group's words for a launch EC2
# refused for capacity, as run 42005832115's error carried them
refusal() {
  echo "Could not launch On-Demand Instances. InsufficientInstanceCapacity - We currently do not have sufficient $1 capacity in the Availability Zone you requested ($2). Our system will be working on provisioning additional capacity. You can currently get $1 capacity by not specifying an Availability Zone in your request or choosing us-east-1b, us-east-1c, us-east-1d, us-east-1f. Launching EC2 instance failed."
}

# world <case>: a fresh AWS and GitHub, and the run's own files
world() {
  W="$T/$1"; mkdir -p "$W/gh" "$W/capacity"
  : >"$W/calls"; : >"$W/summary"
  echo '{"checks": [{"name": "the boundary held", "passed": true}], "measured": []}' >"$W/results.json"
}
# nodegroup <status> [<issue code> <issue message>]
nodegroup() {
  python3 - "$W/nodegroup.json" "$W/subnets.json" "$@" <<'PY'
import json, sys
out, subnets, status = sys.argv[1:4]
issue = sys.argv[4:6]
zones = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d", "us-east-1f"]
json.dump({"nodegroup": {
    "nodegroupName": "reference-platform-airgap-1-gpu", "status": status, "instanceTypes": ["g6.xlarge", "g5.xlarge"],
    "subnets": ["subnet-%d" % i for i in range(len(zones))],
    "resources": {"autoScalingGroups": [{"name": "eks-reference-platform-airgap-1-gpu-3ad0d5ab"}]},
    "health": {"issues": [{"code": issue[0], "message": issue[1], "resourceIds": ["eks-reference-platform-airgap-1-gpu-3ad0d5ab"]}] if issue else []},
}}, open(out, "w"))
json.dump([{"SubnetId": "subnet-%d" % i, "AvailabilityZone": z} for i, z in enumerate(zones)], open(subnets, "w"))
PY
}
# activity <minute> <zone> <Failed|Successful> [<message>]: one launch the
# Auto Scaling group tried, as describe-scaling-activities lists it
activity() {
  python3 - "$W/activities.json" "$@" <<'PY'
import json, os, sys
path, minute, zone, status = sys.argv[1:5]
message = sys.argv[5] if len(sys.argv) > 5 else ""
acts = json.load(open(path)) if os.path.exists(path) else []
acts.append({"ActivityId": "a-%d" % len(acts), "AutoScalingGroupName": "eks-reference-platform-airgap-1-gpu-3ad0d5ab",
             "Description": "Launching a new EC2 instance" + (": i-0123456789abcdef0" if status == "Successful" else ".  Status Reason: " + message),
             "Cause": "At 2026-11-05T10:%sZ an instance was started in response to a difference between desired and actual capacity, increasing the capacity from 0 to 1." % minute,
             "StartTime": "2026-11-05T10:%s:07.123000+00:00" % minute, "StatusCode": status, "StatusMessage": message, "Progress": 100,
             "Details": json.dumps({"Subnet ID": "subnet-0", "Availability Zone": zone})})
json.dump(acts, open(path, "w"))
PY
}
refused_in() { activity "$1" "$2" Failed "$(refusal "$3" "$2")"; }
# scheduled <id> <run number> <asked step> <missed step>: a scheduled run
# before this one, by the conclusions GitHub gives its two steps
scheduled() {
  python3 - "$W/gh" "$@" <<'PY'
import json, os, sys
d, rid, number, asked, missed = sys.argv[1:6]
path = os.path.join(d, "runs.json")
runs = json.load(open(path)) if os.path.exists(path) else {"workflow_runs": []}
runs["workflow_runs"].insert(0, {"id": int(rid), "run_number": int(number), "event": "schedule", "status": "completed"})
json.dump(runs, open(path, "w"))
json.dump({"jobs": [{"name": "Apply, load, check", "steps": [
    {"name": "Run the agent through the evals", "conclusion": "success"},
    {"name": "The GPU node, for the minutes it is measured", "conclusion": asked},
    {"name": "No GPU, EC2 had none to give", "conclusion": missed},
]}, {"name": "Destroy, look for residue, report the cost", "steps": []}]}, open(os.path.join(d, "jobs-%s.json" % rid), "w"))
PY
}
# aws_sh <event> <subcommand...>: scripts/aws.sh in the case's world
aws_sh() {
  local event="$1"; shift
  PATH="$T/bin:$PATH" FAKE_AWS="$W" CLUSTER=reference-platform-airgap-1 CAPACITY_DIR="$W/capacity" EC2_DIR="$W/ec2" \
    E2E_RESULTS="$W/results.json" GITHUB_STEP_SUMMARY="$W/summary" GITHUB_EVENT_NAME="$event" \
    GITHUB_REPOSITORY=heyvaldemar/kubernetes-air-gapped-ai-agent GITHUB_RUN_NUMBER=40 GH_RETRY_SECONDS=0 \
    "$BASH" "$ROOT/scripts/aws.sh" "$@" >"$W/out" 2>&1
  echo $? >"$W/rc"
}
rc() { cat "$W/rc"; }
said() { grep -qF -- "$1" "$W/out"; }
why() { tail -n 3 "$W/out" | tr '\n' ' ' | cut -c1-400; }
record() { python3 -c 'import json, sys; r = json.load(open(sys.argv[1])); print(" ".join("%(zone)s/%(type)s/%(times)d" % x for x in r["refused"]))' "$W/ec2/no-capacity.json" 2>/dev/null; }
measured() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(len(d["checks"]), "|".join(d["measured"]))' "$W/results.json"; }
# a capacity miss on record, as cases G to K start from
missed_world() {
  world "$1"; nodegroup CREATE_FAILED AsgInstanceLaunchFailures "$(refusal g6.xlarge us-east-1a)"
  refused_in 53 us-east-1a g6.xlarge; refused_in 54 us-east-1b g6.xlarge; refused_in 55 us-east-1c g5.xlarge
  aws_sh workflow_dispatch capacity
}

world A; nodegroup CREATE_FAILED AsgInstanceLaunchFailures "$(refusal g6.xlarge us-east-1a)"
refused_in 53 us-east-1a g6.xlarge; refused_in 54 us-east-1b g6.xlarge; refused_in 55 us-east-1a g6.xlarge; refused_in 56 us-east-1f g5.xlarge
aws_sh workflow_dispatch capacity
if [ "$(rc)" = 0 ] && [ "$(record)" = "us-east-1a/g6.xlarge/2 us-east-1b/g6.xlarge/1 us-east-1f/g5.xlarge/1" ] && said "refused all 4 launch(es)"; then
  pass "A: a node group EKS gave up for capacity alone, every launch refused for it, is a capacity miss, recorded by zone and type"
else fail "A: capacity did not pass on a plain capacity miss (rc $(rc), record '$(record)'): $(why)"; fi

world B; nodegroup CREATE_FAILED AsgInstanceLaunchFailures "$(refusal g6.xlarge us-east-1a)"
refused_in 53 us-east-1a g6.xlarge
activity 54 us-east-1b Failed "Could not launch On-Demand Instances. VcpuLimitExceeded - You have requested more vCPU capacity than your current vCPU limit of 8 allows for the instance bucket that the specified instance type belongs to. Launching EC2 instance failed."
aws_sh workflow_dispatch capacity
if [ "$(rc)" != 0 ] && said "VcpuLimitExceeded" && [ ! -s "$W/ec2/no-capacity.json" ]; then
  pass "B: a launch refused for the account's vCPU limit, among capacity refusals, stays the run's failure"
else fail "B: capacity passed with a launch refused for the vCPU limit (rc $(rc)): $(why)"; fi

world C; nodegroup CREATE_FAILED NodeCreationFailure "Instances failed to join the kubernetes cluster"
refused_in 52 us-east-1a g6.xlarge; activity 53 us-east-1b Successful
aws_sh workflow_dispatch capacity
if [ "$(rc)" != 0 ] && said "did not fail for want of capacity alone: EKS's health issue is NodeCreationFailure" && [ ! -s "$W/ec2/no-capacity.json" ]; then
  pass "C: a GPU node that launched after a refusal and never joined stays the run's failure"
else fail "C: capacity passed on a node that never joined (rc $(rc)): $(why)"; fi

world D; nodegroup ACTIVE
activity 53 us-east-1a Successful
aws_sh workflow_dispatch capacity
if [ "$(rc)" != 0 ] && said "not CREATE_FAILED"; then
  pass "D: an apply that failed with the node group active stays the run's failure"
else fail "D: capacity passed with the node group active (rc $(rc)): $(why)"; fi

world E; nodegroup CREATE_FAILED AsgInstanceLaunchFailures "$(refusal g6.xlarge us-east-1a)"
echo '[]' >"$W/activities.json"
aws_sh workflow_dispatch capacity
if [ "$(rc)" != 0 ] && said "no refused launch on record"; then
  pass "E: EKS's word alone, with no refused launch on the Auto Scaling group's record, is not a capacity miss"
else fail "E: capacity passed with no refused launch on record (rc $(rc)): $(why)"; fi

world F
aws_sh workflow_dispatch capacity
if [ "$(rc)" != 0 ] && said "could not be read from AWS"; then
  pass "F: an apply that failed with no GPU node group to read stays the run's failure"
else fail "F: capacity passed with no node group (rc $(rc)): $(why)"; fi

missed_world G; aws_sh workflow_dispatch missed
if [ "$(rc)" = 0 ] && said "::warning title=GPU: no capacity::" && grep -qF '### GPU: no capacity' "$W/summary" \
  && grep -qF '| us-east-1b | g6.xlarge | 1 |' "$W/summary" \
  && [[ "$(measured)" == "1 GPU node: none, EC2 had no capacity (3 launches of g6.xlarge then g5.xlarge refused in us-east-1a, us-east-1b, us-east-1c, us-east-1d, us-east-1f, 10:53 to 10:55 UTC;"* ]] \
  && ! grep -q '^gh ' "$W/calls"; then
  pass "G: a miss by hand is said in the summary, as a warning and in the results beside the checks, and the run goes on"
else fail "G: the miss was not said, or a run by hand failed for it (rc $(rc), results '$(measured)'): $(why)"; fi

missed_world H; scheduled 100 38 success skipped; aws_sh schedule missed
if [ "$(rc)" = 0 ] && said "the first scheduled run in a row to be given no GPU: the one before that asked for one, 100, was given one"; then
  pass "H: the first scheduled run in a row to be given no GPU says so and goes on"
else fail "H: a first scheduled miss failed the run (rc $(rc)): $(why)"; fi

missed_world I; scheduled 100 38 success skipped; scheduled 101 39 success success; aws_sh schedule missed
if [ "$(rc)" != 0 ] && said "second scheduled run in a row" && said "101" && ! said "the first scheduled run in a row" \
  && grep -qF '### GPU: no capacity' "$W/summary"; then
  pass "I: the second scheduled run in a row to be given no GPU fails, and still says what it found"
else fail "I: a second scheduled miss in a row passed (rc $(rc)): $(why)"; fi

missed_world J; scheduled 101 37 success success; scheduled 102 39 skipped skipped; aws_sh schedule missed
if [ "$(rc)" != 0 ] && said "second scheduled run in a row" && said "101"; then
  pass "J: a scheduled run between that asked for no GPU neither counts nor clears the count"
else fail "J: a run that asked for no GPU cleared the count (rc $(rc)): $(why)"; fi

missed_world K; aws_sh schedule missed
if [ "$(rc)" != 0 ] && said "GitHub did not answer"; then
  pass "K: when GitHub does not list the runs before, the rule cannot be held and the run fails"
else fail "K: the rule passed unread (rc $(rc)): $(why)"; fi

missed_world P; scheduled 100 37 success success; scheduled 101 39 success failure; aws_sh schedule missed
if [ "$(rc)" != 0 ] && said "third scheduled run in a row" && said "101, 100"; then
  pass "P: the week after a run this rule failed is the third in a row, and fails"
else fail "P: the run after a failed second miss passed (rc $(rc)): $(why)"; fi

missed_world Q
echo '{"workflow_runs": [{"id": 101, "run_number": 39, "event": "schedule", "status": "completed"}]}' >"$W/gh/runs.json"
aws_sh schedule missed
if [ "$(rc)" != 0 ] && said "GitHub did not answer for repos/heyvaldemar/kubernetes-air-gapped-ai-agent/actions/runs/101/jobs"; then
  pass "Q: a scheduled run before that GitHub lists and does not answer for fails the run, unread"
else fail "Q: the rule passed with a run before it unread (rc $(rc)): $(why)"; fi

missed_world R; scheduled 100 37 success success; scheduled 101 39 failure skipped; aws_sh schedule missed
if [ "$(rc)" != 0 ] && said "second scheduled run in a row" && said "after 100"; then
  pass "R: a scheduled run whose GPU apply failed for another reason neither counts nor clears the count"
else fail "R: a run that failed its GPU apply cleared the count (rc $(rc)): $(why)"; fi

world S; nodegroup CREATE_FAILED AsgInstanceLaunchFailures "$(refusal g6.xlarge us-east-1a)"
refused_in 53 us-east-1a g6.xlarge; activity 54 us-east-1b PreInService
aws_sh workflow_dispatch capacity
if [ "$(rc)" != 0 ] && said "is PreInService, not refused: an instance may exist" && [ ! -s "$W/ec2/no-capacity.json" ]; then
  pass "S: a launch that was not refused, among capacity refusals, is an instance that may exist: not a miss"
else fail "S: capacity passed with a launch that was not refused (rc $(rc)): $(why)"; fi

missed_world T; scheduled 100 38 success skipped; aws_sh schedule missed
other="$(find "$W/ec2" -type f ! -name '*.json' | sed "s#^$W/##" | tr '\n' ' ')"
if [ "$(rc)" = 0 ] && [ -z "$other" ] && [ -s "$W/ec2/runs/runs.json" ] && [ -s "$W/ec2/runs/jobs-100.json" ] && [ -s "$W/ec2/activities.json" ]; then
  pass "T: everything kept for the run's artifact is .json, GitHub's answers among it"
else fail "T: a file that is not .json is kept for the artifact, or an answer is missing (rc $(rc)): ${other:-none}"; fi

world L; aws_sh schedule missed
if [ "$(rc)" != 0 ] && said "no record of a capacity miss"; then
  pass "L: missed with no record of a miss fails"
else fail "L: missed passed with nothing to say (rc $(rc)): $(why)"; fi

world M; nodegroup ACTIVE
refused_in 53 us-east-1a g6.xlarge; refused_in 54 us-east-1b g6.xlarge; activity 55 us-east-1c Successful
aws_sh workflow_dispatch launches g6.xlarge us-east-1c
if [ "$(rc)" = 0 ] && said "us-east-1a   g6.xlarge   refused, InsufficientInstanceCapacity x1" && said "us-east-1c   g6.xlarge   launched x1" \
  && [ "$(measured)" = "1 GPU node: g6.xlarge in us-east-1c (after 2 launch(es) EC2 refused: us-east-1a g6.xlarge x1, us-east-1b g6.xlarge x1)" ]; then
  pass "M: the node EC2 gave is named by type and zone in the results, with the launches refused before it"
else fail "M: launches did not name the node and what was refused before it (rc $(rc), results '$(measured)'): $(why)"; fi

world N
python3 - "$W" "$(refusal g6.xlarge us-east-1a | sed 's/^Could not launch On-Demand Instances. InsufficientInstanceCapacity - //; s/ Launching EC2 instance failed.$//')" <<'PY'
import json, os, sys
W, message = sys.argv[1:3]
event = lambda minute, **more: json.dumps(dict({"eventTime": "2026-11-05T10:%s:00Z" % minute, "eventName": "RunInstances",
                                                "userIdentity": {"invokedBy": "autoscaling.amazonaws.com"}}, **more))
json.dump([event("53", errorCode="Server.InsufficientInstanceCapacity", errorMessage=message),
           event("58", errorCode="Server.InsufficientInstanceCapacity", errorMessage=message),
           event("52", errorCode="Client.DryRunOperation", errorMessage="Request would have succeeded, but DryRun flag is set."),
           event("59", responseElements={"instancesSet": {"items": [{"instanceId": "i-0123456789abcdef0"}]}})],
          open(os.path.join(W, "RunInstances.json"), "w"))
json.dump([json.dumps({"eventTime": "2026-11-09T17:20:00Z", "eventName": "CreateFleet", "responseElements": {"CreateFleetResponse": {"errorSet": {"item": [
    {"errorCode": "InsufficientInstanceCapacity", "errorMessage": message.replace("us-east-1a", "us-east-1d").replace("g6.xlarge", "g5.xlarge"),
     "launchTemplateAndOverrides": {"overrides": {"instanceType": "g5.xlarge"}}}]}}}})], open(os.path.join(W, "CreateFleet.json"), "w"))
PY
aws_sh workflow_dispatch refused 192; listed="$(rc)"
if [ "$listed" = 0 ] && said "2026-11-05  us-east-1a   g6.xlarge   InsufficientInstanceCapacity" && said "x2   10:53 to 10:58 UTC" \
  && said "2026-11-09  us-east-1d   g5.xlarge   InsufficientInstanceCapacity" && said "of 5 launch call(s)" \
  && said "none of them a refusal for capacity: DryRunOperation x1" && ! said "2026-11-05  ?"; then
  world N-unread; aws_sh workflow_dispatch refused 192
  if [ "$(rc)" = 0 ] && said "CloudTrail could not be read"; then
    pass "N: what EC2 refused for capacity is listed by day, zone and type, from RunInstances and CreateFleet, a dry run apart from it; a CloudTrail that cannot be read is said, never a failure"
  else fail "N: an unreadable CloudTrail was not said, or failed the step (rc $(rc)): $(why)"; fi
else fail "N: refused did not list CloudTrail's refusals (rc $listed): $(why)"; fi

world O; nodegroup ACTIVE; activity 55 us-east-1c Successful
echo '{"server": {"MODEL": "granite-4.0-1b", "ACCELERATOR": "NVIDIA L4 (g6.xlarge)", "SLOTS": "8", "THREADS": "0"}, "levels": [{"concurrency": 1, "calls_per_min": 402.1, "p50_s": 0.16, "p95_s": 0.16, "out_tokens_per_s": 140.0, "failed": 0, "calls": 201}]}' >"$W/capacity/gpu.json"
aws_sh workflow_dispatch launches g6.xlarge us-east-1c
if [ "$(rc)" = 0 ] && table="$(python3 "$ROOT/scripts/capacity.py" table "$W/capacity" 2>&1)" && grep -qF '| granite-4.0-1b | NVIDIA L4 (g6.xlarge) | 8 x 0 | 1 | 402.1 |' <<<"$table" \
  && [ -s "$W/ec2/nodegroup.json" ] && [ -z "$(find "$W/capacity" -name nodegroup.json)" ]; then
  pass "O: what launches keeps is outside the measurements, and capacity.py's table still prints after it"
else fail "O: launches left a file among the measurements, or the table no longer prints (rc $(rc)): $(tail -n 2 <<<"${table:-}" | tr '\n' ' ' | cut -c1-300)"; fi

printf '%s\n' "${results[@]}"
exit "$failed"
