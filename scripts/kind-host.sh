#!/usr/bin/env bash
# kind-host.sh - the host's inotify limits a kind cluster needs, raised
# before the cluster is made and read back (ADR 20). kind's known issue
# "Pod errors due to too many open files" is this: every process of every
# kind node is root on the host, so the kubelets, containerd and systemd of
# each node, kube-proxy, kindnet and every controller that watches its files
# draw on one user's inotify instances. GitHub's Ubuntu image writes the
# values below to /etc/sysctl.conf; on ubuntu-26.04 the host had the
# kernel's own, 128 instances and 129232 watches (run 42502092301), and
# kube-proxy on a kind node started again failed to start, again and again.
# Nothing on 26.04 reads /etc/sysctl.conf at boot any more: Ubuntu dropped
# the /etc/sysctl.d/99-sysctl.conf link (actions/runner-images#15108).
#
# Raises only: a host that already allows more keeps what it allows. Linux
# only; elsewhere Docker's own VM sets them, and this says so.
set -euo pipefail
[ "$(uname -s)" = Linux ] || { echo "== kind-host: not Linux, the inotify limits are Docker's VM's"; exit 0; }
for kv in fs.inotify.max_user_watches=655360 fs.inotify.max_user_instances=1280; do
  key="${kv%=*}" need="${kv#*=}"
  had="$(sysctl -n "$key")"
  [ "$had" -ge "$need" ] || sudo sysctl -qw "$key=$need"
  now="$(sysctl -n "$key")"
  if [ "$now" -lt "$need" ]; then
    echo "kind-host: $key is $now after setting it, and a kind cluster needs $need" >&2
    exit 1
  fi
  echo "== $key: $now (the host had $had)"
done
