#!/bin/bash
# 53-lab-status.sh [prod|dev] - Show lab state per environment: containers, server readiness, server JWT expiry,
# agent socket and whether the workload can get a JWT-SVID (via swa-go-test; no secret is read).
source "$(dirname "$0")/lib.sh"
st(){ docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || echo missing; }
for e in ${1:-$ENVS}; do
  env_load "$e"
  echo "===== $ENV ($TD)"
  echo "server   $SERVER: $(st "$SERVER")   readyz: $(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://127.0.0.1:$WEB_PORT/readyz" 2>/dev/null | sed 's/^000$/down/' || true)   api :$API_PORT"
  if [ -s "$ST/tokens/swa-token" ]; then
    exp=$(cut -d. -f2 "$ST/tokens/swa-token" | tr '_-' '/+' | { s=$(cat); while (( ${#s} % 4 )); do s+='='; done; base64 -d <<<"$s" 2>/dev/null; } | jq -r .exp)
    left=$(( exp - $(date +%s) )); echo "jwt      server JWT expires $(date -d @"$exp" '+%F %T') ($([ $left -gt 0 ] && echo "${left}s left" || echo EXPIRED))"
  fi
  echo "timer    swa-lab-token@$ENV: $(systemctl is-active "swa-lab-token@$ENV.timer" 2>/dev/null)"
  echo "workload $WL: $(st "$WL")"
  if [ "$(st "$WL")" = running ]; then
    out=$(docker exec --user "$SA_USER" "$WL" "$WL_CLIENT" -sm "$SWA_API_BASE/api" -authn "$AUTHN" nonexistent/var 2>&1 || true)
    sub=$(grep -o 'sub: [^ ]*' <<<"$out"); tok=$(grep -o 'Access token: OK' <<<"$out")
    echo "check    JWT-SVID: ${sub:-FAILED $(grep -o 'desc = .*' <<<"$out" | tail -c 100)}   ${tok:-}"
  fi
done
