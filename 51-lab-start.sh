#!/bin/bash
# 51-lab-start.sh [prod|dev] - Start the lab for testing (default: both environments).
# Order: k3s container (wait node Ready) -> swa-server in swa-<env> (scale 1, wait Ready) -> wl-<env> (wait agent socket).
# Tenant objects are untouched; everything must already exist (05 / 20 / 31).
source "$(dirname "$0")/lib.sh"
docker container inspect "$K3S_NAME" >/dev/null 2>&1 || die "$K3S_NAME does not exist -> ./05-k3s-up.sh"
docker start "$K3S_NAME" >/dev/null
for i in $(seq 1 60); do kubectl get nodes 2>/dev/null | grep -q ' Ready' && break; sleep 3; done
for e in ${1:-$ENVS}; do
  env_load "$e"
  kubectl -n "$NS" get deploy swa-server >/dev/null 2>&1 || die "swa-server not installed in $NS -> ./20-server-install.sh $ENV"
  docker container inspect "$WL" >/dev/null 2>&1 || die "$WL does not exist -> ./31-workload-run.sh $ENV"
  kubectl -n "$NS" scale deploy/swa-server --replicas=1 >/dev/null
  kubectl -n "$NS" rollout status deploy/swa-server --timeout=180s >/dev/null && echo "$SERVER ($NS): ready" || echo "$SERVER ($NS): NOT ready"
  docker start "$WL" >/dev/null
  for i in $(seq 1 30); do docker exec "$WL" test -S /run/swa-agent/api.sock 2>/dev/null && break; sleep 2; done
  # after a k3s/server restart the agent must re-establish trust (its restart loop takes ~30-60s); the deployment status
  # may still be the pre-restart one, so wait until the agent reaches the server again. Probe as root: "no matching
  # registration policy" still proves the agent<->server connection works.
  probe(){ local o; o=$(docker exec "$WL" /opt/swa/bin/swa-agent api fetch jwt -a conjur -s /run/swa-agent/api.sock 2>&1 || true)
    ! grep -qE 'no connection available|connection refused|no such file|Unavailable' <<<"$o"; }
  for i in $(seq 1 36); do probe && break; sleep 5; done
  echo "$WL: $(probe && echo 'agent connected to server' || echo 'agent NOT connected to server (see /var/log/swa-agent.log)')"
done
echo "Started. Check: ./53-lab-status.sh   Test: ./55-full-test.sh"
