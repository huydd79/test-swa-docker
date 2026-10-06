#!/bin/bash
# 52-lab-stop.sh [prod|dev] - Stop the lab containers when not testing (default: both environments).
# Stops workloads first, then servers, then the token timer. Nothing is deleted (state/, images, tenant objects stay).
source "$(dirname "$0")/lib.sh"
for e in ${1:-$ENVS}; do
  env_load "$e"
  docker stop -t 10 "$WL" "$SERVER" >/dev/null 2>&1 || true
  systemctl stop "swa-lab-token@$ENV.timer" 2>/dev/null || true
  echo "$ENV: $WL $(docker inspect -f '{{.State.Status}}' "$WL" 2>/dev/null || echo missing), $SERVER $(docker inspect -f '{{.State.Status}}' "$SERVER" 2>/dev/null || echo missing), timer $(systemctl is-active "swa-lab-token@$ENV.timer" 2>/dev/null)"
done
echo "Stopped. Start again with ./51-lab-start.sh"
