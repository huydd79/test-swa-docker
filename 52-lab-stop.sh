#!/bin/bash
# 52-lab-stop.sh [prod|dev] - Stop the lab when not testing. Nothing is deleted (state/, images, k3s volume, tenant objects stay).
#   With an env: stop wl-<env> and scale its swa-server to 0. Without: stop both workloads, then the whole k3s container.
source "$(dirname "$0")/lib.sh"
for e in ${1:-$ENVS}; do
  env_load "$e"
  docker stop -t 10 "$WL" >/dev/null 2>&1 || true
  [ -n "${1:-}" ] && kubectl -n "$NS" scale deploy/swa-server --replicas=0 >/dev/null 2>&1 || true
  echo "$ENV: $WL $(cstate "$WL")"
done
[ -z "${1:-}" ] && { docker stop -t 20 "$K3S_NAME" >/dev/null 2>&1 || true; echo "k3s: $K3S_NAME $(cstate "$K3S_NAME")"; }
echo "Stopped. Start again with ./51-lab-start.sh"
