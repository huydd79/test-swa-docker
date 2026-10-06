#!/bin/bash
# 56-script-test.sh [prod|dev] - Run the swa-test.sh demo script inside the workload container(s) as the service account,
# showing each step: caller identity, JWT-SVID (header/payload), JWKS kid, authn-jwt exchange, secret reads.
# Pass-through options:  SHOW=1 (print secrets in full)  SHOW_JWT=1 (print the raw JWT-SVID in full)
source "$(dirname "$0")/lib.sh"
TTY=""; [ -t 1 ] && TTY="-t"
for e in ${1:-$ENVS}; do
  env_load "$e"
  [ "$(docker inspect -f '{{.State.Status}}' "$WL" 2>/dev/null)" = running ] || die "$WL is not running -> ./51-lab-start.sh $ENV"
  echo; echo "################ $ENV : $WL as $SA_USER ################"
  docker exec $TTY --user "$SA_USER" -e SM_URL="$SWA_API_BASE/api" -e AUTHN="$AUTHN" -e SHOW="${SHOW:-0}" -e SHOW_JWT="${SHOW_JWT:-0}" "$WL" swa-test.sh $SECRETS || true
done
