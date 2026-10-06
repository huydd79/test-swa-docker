#!/bin/bash
# 55-full-test.sh - prod/dev test matrix. Expected result is shown in the "expect" column.
source "$(dirname "$0")/lib.sh"
set +e
row(){ # row <description> <expect OK|DENY> <command...>
  local desc=$1 exp=$2; shift 2; local out; out=$("$@" 2>&1)
  local got=DENY; grep -q '= .*\*\*\*\*\*' <<<"$out" && ! grep -q 'HTTP' <<<"$out" && got=OK
  local why; why=$(grep -oE 'no matching registration policy|authenticate HTTP [0-9]+|-> HTTP [0-9]+|no connection available|executable file .* not found' <<<"$out" | sort -u | tr '\n' ' ')
  printf '%-4s %-62s expect %-4s -> %-4s %s\n' "$([ $got = $exp ] && echo PASS || echo FAIL)" "$desc" "$exp" "$got" "$why"
}
env_load prod; P_SEC=$SECRETS; A_P=$AUTHN; env_load dev; D_SEC=$SECRETS; A_D=$AUTHN
SM="-sm $SWA_API_BASE/api"; C="$WL_CLIENT $SM"
row "wl-prod / swa-demo-sa / client / secret prod"        OK   docker exec --user swa-demo-sa wl-prod $C -authn $A_P $P_SEC
row "wl-prod / swa-demo-sa / client / secret dev"         DENY docker exec --user swa-demo-sa wl-prod $C -authn $A_P $D_SEC
row "wl-dev  / swa-demo-sa / client / secret dev"         OK   docker exec --user swa-demo-sa wl-dev  $C -authn $A_D  $D_SEC
row "wl-dev  / swa-demo-sa / client / secret prod"        DENY docker exec --user swa-demo-sa wl-dev  $C -authn $A_D  $P_SEC
row "wl-prod / prod JWT sent to authn-jwt/swa-dev"        DENY docker exec --user swa-demo-sa wl-prod $C -authn $A_D  $D_SEC
row "wl-prod / root / client"                             DENY docker exec --user root wl-prod $C -authn $A_P $P_SEC
row "wl-prod / swa-demo-sa / swa-agent CLI fetch jwt"     DENY docker exec --user swa-demo-sa wl-prod /opt/swa/bin/swa-agent api fetch jwt -a conjur -s /run/swa-agent/api.sock
row "wl-prod / swa-demo-sa / client copy, 1 byte changed" DENY docker exec --user root wl-prod sh -c "cp $WL_CLIENT /tmp/c && printf '\0' >> /tmp/c && chmod 755 /tmp/c && su -s /bin/sh swa-demo-sa -c '/tmp/c $SM -authn $A_P $P_SEC'; rm -f /tmp/c"
echo
echo "SPIFFE ID:"
for e in prod dev; do printf '  wl-%-4s ' $e; docker exec --user swa-demo-sa wl-$e $C -authn swa-$e 2>&1 | grep -o 'sub: [^ ]*'; done
