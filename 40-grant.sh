#!/bin/bash
# 40-grant.sh <prod|dev> - After the workload fetches its first JWT (tenant creates the host): annotation + apps group + permissions on the environment variables only
source "$(dirname "$0")/lib.sh"
env_load "${1:?prod|dev}"; need_conjur
echo "Triggering the workload once (creates the host on the tenant)..."
docker exec --user "$SA_USER" "$WL" "$WL_CLIENT" -sm "$SWA_API_BASE/api" -authn "$AUTHN" >/dev/null 2>&1 || true
for i in $(seq 1 18); do conjur role exists "conjur:host:$HOST" 2>/dev/null | grep -q true && break; sleep 5; done
conjur role exists "conjur:host:$HOST" | grep -q true || die "host not found: $HOST"
policy "data/swa/trust-domains/$TD/workloads" "- !host
  id: $SID
  annotations:
    authn-jwt/$AUTHN/sub: $SID"
policy "conjur/authn-jwt/$AUTHN" "- !grant
  role: !group apps
  member: !host /$HOST"
P=""; for v in $SECRETS; do P+="- !permit
  role: !host /$HOST
  privileges: [ read, execute ]
  resource: !variable ${v#$SAFE_POLICY/}
"; done
policy "$SAFE_POLICY" "$P"
conjur role memberships "conjur:host:$HOST"
