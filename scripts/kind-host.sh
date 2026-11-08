#!/usr/bin/env bash
# kind-host.sh - the host's inotify limits a kind cluster needs, raised
# before the cluster is made and read back (ADR 20). kind's known issue
# "Pod errors due to too many open files" is this: every process of every
# kind node is root on the host, so the kubelets, containerd and systemd of
# each node, kube-proxy, kindnet and every controller that watches its files
# draw on one user's inotify instances. GitHub's Ubuntu image writes the
# values below to /etc/sysctl.conf; the run on ubuntu-26.04 prints what the
# host had before this raised it.
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
