#!/usr/bin/env bash
# aks/bootstrap.sh - the standing parts of the AKS run (ADR 23) that a run
# cannot make for itself, run once by the maintainer from his own login
# (`az login`), and again to check them. Idempotent: what exists is left as
# it is and printed.
#
# A cluster in a network of its own needs two managed identities with roles:
# its control plane's, which may change the network AKS runs in, and its
# kubelet's, which may pull from the registry inside. Giving them roles needs
# Microsoft.Authorization/roleAssignments/write, which the run's creation
# identity does not hold (Contributor), and should not: an identity that can
# assign roles can widen its own. So the two identities stand here, in a
# resource group no run makes or deletes, with their roles given once:
#
#   airgap-cluster  Network Contributor on the subscription, which holds
#                   nothing but these runs and their state; Managed Identity
#                   Operator on airgap-kubelet, so AKS can hand the kubelet
#                   its identity
#   airgap-kubelet  AcrPull on the subscription: each run's registry, and
#                   there is no other
#
# Set up before this, on 2026-10-29, also from the maintainer's login and
# not repeated here: the two Entra applications GitHub federates to
# (airgap-validation-create, Contributor; airgap-validation-sweep, the custom
# role airgap-sweeper), the state account, and the budget. `check` lists all
# of it, read-only.
set -euo pipefail
LOCATION="${AZURE_REGION:-eastus}"
RG=airgap-identities
say() { printf '== %s\n' "$*"; }
sub="$(az account show --query id -o tsv)"

case "${1:-check}" in
  apply)
    az group create -n "$RG" -l "$LOCATION" \
      --tags airgap-project=kubernetes-air-gapped-ai-agent purpose=standing-identities -o none
    for id in airgap-cluster airgap-kubelet; do
      az identity show -g "$RG" -n "$id" -o none 2>/dev/null \
        || az identity create -g "$RG" -n "$id" -l "$LOCATION" --tags airgap-project=kubernetes-air-gapped-ai-agent -o none
    done
    cluster="$(az identity show -g "$RG" -n airgap-cluster --query principalId -o tsv)"
    kubelet="$(az identity show -g "$RG" -n airgap-kubelet --query principalId -o tsv)"
    kubelet_id="$(az identity show -g "$RG" -n airgap-kubelet --query id -o tsv)"
    grant() { # <principal> <role> <scope>
      # A new identity can take a minute to reach the directory the lookup reads.
      if [ -z "$(az role assignment list --assignee "$1" --role "$2" --scope "$3" --query '[].id' -o tsv 2>/dev/null)" ]; then
        az role assignment create --assignee-object-id "$1" --assignee-principal-type ServicePrincipal \
          --role "$2" --scope "$3" -o none
      fi
    }
    grant "$cluster" "Network Contributor" "/subscriptions/$sub"
    grant "$cluster" "Managed Identity Operator" "$kubelet_id"
    grant "$kubelet" "AcrPull" "/subscriptions/$sub"
    "$0" check
    ;;
  check)
    say "standing identities in $RG"
    az identity list -g "$RG" --query '[].{name:name, principal:principalId}' -o table 2>/dev/null || echo "  none: run aks/bootstrap.sh apply"
    say "role assignments in the subscription"
    az role assignment list --all --query '[].{who:principalName, role:roleDefinitionName, scope:scope}' -o tsv \
      | sed -E "s#/subscriptions/$sub#/subscription#" | sort
    say "resource groups"
    az group list --query '[].name' -o tsv | sort
    ;;
  *) echo "usage: aks/bootstrap.sh <apply|check>" >&2; exit 2 ;;
esac
