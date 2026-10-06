#!/bin/bash
# 51-lab-start.sh [prod|dev] - Start the lab containers for testing (default: both environments).
# Order: fresh server JWT -> swa-server-<env> (wait readyz) -> wl-<env> (wait agent socket) -> token timer.
# Tenant objects are untouched; containers must already exist (created by 20-server-run.sh / 31-workload-run.sh).
source "$(dirname "$0")/lib.sh"
for e in ${1:-$ENVS}; do
  env_load "$e"
  docker container inspect "$SERVER" >/dev/null 2>&1 || die "$SERVER does not exist -> ./20-server-run.sh $ENV"
  docker container inspect "$WL" >/dev/null 2>&1     || die "$WL does not exist -> ./31-workload-run.sh $ENV"
  ./mint-token.sh "$ENV" >/dev/null          # the old JWT may have expired while the lab was stopped
  docker start "$SERVER" >/dev/null
  for i in $(seq 1 30); do curl -sf -m 3 "http://127.0.0.1:$WEB_PORT/readyz" >/dev/null && break; sleep 2; done
  echo "$SERVER: readyz $(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://127.0.0.1:$WEB_PORT/readyz")"
  docker start "$WL" >/dev/null
  for i in $(seq 1 30); do docker exec "$WL" test -S /run/swa-agent/api.sock 2>/dev/null && break; sleep 2; done
  echo "$WL: $(docker exec "$WL" test -S /run/swa-agent/api.sock && echo 'agent socket up' || echo 'agent socket NOT up')"
  systemctl start "swa-lab-token@$ENV.timer" 2>/dev/null || true
done
echo "Started. Check: ./53-lab-status.sh   Test: ./55-full-test.sh"
