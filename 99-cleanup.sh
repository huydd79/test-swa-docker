#!/bin/bash
# 99-cleanup.sh [local|tenant|all] - Remove the prod/dev lab. Default: all. Only touches the objects this lab created.
source "$(dirname "$0")/lib.sh"
MODE=${1:-all}
if [[ $MODE == local || $MODE == all ]]; then
  for e in $ENVS; do env_load $e; docker rm -f "$WL" "$SERVER" >/dev/null 2>&1 || true
    systemctl disable --now "swa-lab-token@$e.timer" 2>/dev/null || true; done
  rm -f /etc/systemd/system/swa-lab-token@.{service,timer}; systemctl daemon-reload
  docker rmi -f "$WL_IMAGE" >/dev/null 2>&1 || true
  echo "local: containers, timers and image removed"
fi
if [[ $MODE == tenant || $MODE == all ]]; then
  need_conjur
  for e in $ENVS; do env_load $e; echo "== tenant $e"
    # permissions + authenticator (Secrets Manager)
    P=""; for v in $SECRETS; do P+="- !deny
  role: !host /$HOST
  privileges: [ read, execute ]
  resource: !variable ${v#$SAFE_POLICY/}
"; done
    conjur role exists "conjur:host:$HOST" 2>/dev/null | grep -q true && policy "$SAFE_POLICY" "$P" || true
    policy conjur/authn-jwt "- !delete
  record: !policy $AUTHN" || true
    # SWA: node group -> component -> server group -> trust domain
    api DELETE "/trust-domains/$TD/server-groups/$SG/node-groups/$NG"; echo "  node group $NG: $CODE"
    api DELETE "/trust-domains/$TD/server-groups/$SG/components/$SERVER"; echo "  component $SERVER: $CODE"
    api DELETE "/trust-domains/$TD/server-groups/$SG"; echo "  server group $SG: $CODE"
    api DELETE "/trust-domains/$TD"; echo "  trust domain $TD: $CODE"
    rm -f "$ST/authn_id"
  done
  left=$(conjur list 2>/dev/null | grep -cE "prod\\.swa\\.$BASE_DOMAIN|dev\\.swa\\.$BASE_DOMAIN|authn-jwt/swa-(prod|dev)" || true); echo "Leftover Secrets Manager objects: $left"
fi
[[ $MODE == all ]] && { find state -name '*.key' -exec shred -u {} \; 2>/dev/null; rm -rf state; echo "state/ removed (keys shredded)"; }
