#!/bin/bash
# 53-lab-status.sh [prod|dev] - Show lab state: k3s container/node, per environment the swa-server deployment,
# workload container, agent socket and whether the workload can get a JWT-SVID (via swa-go-test; no secret is read).
source "$(dirname "$0")/lib.sh"
echo "k3s      $K3S_NAME: $(cstate "$K3S_NAME")   node: $(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2, $5}' || true)"
for e in ${1:-$ENVS}; do
  env_load "$e"
  echo "===== $ENV ($TD)"
  r=$(kubectl -n "$NS" get deploy swa-server -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || true)
  case "$r" in "") r="not installed";; /*) r="0$r";; esac
  echo "server   $SERVER: ns $NS deploy swa-server ${r} ready   api :$API_PORT -> nodePort $NODE_PORT"
  echo "workload $WL: $(cstate "$WL")"
  if [ "$(cstate "$WL")" = running ]; then
    out=$(docker exec --user "$SA_USER" "$WL" "$WL_CLIENT" -sm "$SWA_API_BASE/api" -authn "$AUTHN" nonexistent/var 2>&1 || true)
    sub=$(grep -o 'sub: [^ ]*' <<<"$out" || true); tok=$(grep -o 'Access token: OK' <<<"$out" || true)
    echo "check    JWT-SVID: ${sub:-FAILED $(grep -o 'desc = .*' <<<"$out" | tail -c 100 || true)}   ${tok:-}"
  fi
done
