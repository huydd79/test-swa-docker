#!/bin/bash
# swa-test.sh - Demo script: walk through how a workload gets a JWT-SVID from the SWA Server (via the local agent),
# exchanges it for a Secrets Manager access token, and reads secrets. Same flow as ../12-get-secret.sh, with explanations.
# Usage (as the workload user):  swa-test.sh [variable-id ...]
#   SHOW=1      print secret values in full (masked by default)
#   SHOW_JWT=1  print the raw JWT-SVID in full (shortened by default; it is a bearer token valid ~5 min)
#   AUTHN=...   authn-jwt service id (default: swa-<first label of the trust domain>, e.g. swa-prod)
set -uo pipefail
SM_URL=${SM_URL:?set SM_URL=https://<tenant>.secretsmgr.cyberark.cloud/api (56-script-test.sh passes it)}
SOCK=${SPIFFE_ENDPOINT_SOCKET:-/run/swa-agent/api.sock}; SOCK=${SOCK#unix://}
AGENT=/opt/swa/bin/swa-agent
B=$'\e[1m'; D=$'\e[2m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; N=$'\e[0m'
step(){ echo; echo "${B}== $*${N}"; }
note(){ echo "${D}   $*${N}"; }
b64d(){ local s; s=$(tr '_-' '/+'); while (( ${#s} % 4 )); do s+='='; done; base64 -d <<<"$s" 2>/dev/null; }
fail(){ echo "${R}   FAILED: $*${N}"; exit 1; }

step "0. Who is asking"
echo "   host         : $(hostname)"
echo "   user / uid   : $(id -un) / $(id -u)   group: $(id -gn) / $(id -g)"
echo "   caller binary: $AGENT"
echo "   sha256       : $(sha256sum $AGENT | cut -d' ' -f1)"
echo "   agent socket : $SOCK"
note "The workload presents no secret. The agent identifies the process connected to the socket (SO_PEERCRED -> PID),"
note "reads its user/uid/gid/path/sha256 from /proc and sends them to the SWA Server, which evaluates the node group policy."

step "1. Ask the local SWA Agent for a JWT-SVID (audience=conjur)"
echo "   \$ $AGENT api fetch jwt -a conjur -s $SOCK"
OUT=$($AGENT api fetch jwt -a conjur -s "$SOCK" --output json 2>&1)
JWT=$(jq -r '..|strings|select(startswith("eyJ"))' <<<"$OUT" 2>/dev/null | head -1)
[ -n "$JWT" ] || fail "$(grep -o 'desc = .*' <<<"$OUT" | tail -c 150)
   -> the agent/server refused: this user/binary does not match the node group registration policy."
IFS=. read -r JH JP JS <<<"$JWT"
if [ "${SHOW_JWT:-0}" = 1 ]; then echo "   JWT-SVID: $JWT"
else echo "   JWT-SVID: ${JWT:0:40}...${JWT: -20}  ${D}(${#JWT} bytes; SHOW_JWT=1 to print in full)${N}"; fi
echo "   ${B}Header${N} : $(b64d <<<"$JH" | jq -c .)"
echo "   ${B}Payload${N}:"; b64d <<<"$JP" | jq --argjson now "$(date +%s)" '. + {"_iat":(.iat|todate), "_exp":(.exp|todate), "_valid_for_s":(.exp-$now)}' | sed 's/^/     /'
echo "   ${B}Signature${N}: ${#JS} chars base64url"
SUB=$(b64d <<<"$JP" | jq -r .sub); ISS=$(b64d <<<"$JP" | jq -r .iss); KID=$(b64d <<<"$JH" | jq -r .kid)
TD=${SUB#spiffe://}; TD=${TD%%/*}
note "sub = SPIFFE ID built from the node group template: spiffe://<trust domain>/<node group>/workload/<unix user>"
note "iss = the trust domain on the tenant (not the server); signed by the SWA Server's trust-domain key (alg/kid above)."

step "2. Where the signature can be checked: the trust domain JWKS on the tenant (public)"
JWKS=$(curl -sS -m 15 "$ISS/.well-known/jwks")
echo "   GET $ISS/.well-known/jwks -> $(jq '.keys|length' <<<"$JWKS") keys"
if jq -e --arg k "$KID" '.keys[]|select(.kid==$k)' >/dev/null <<<"$JWKS"; then
  echo "   ${G}kid $KID found${N}: $(jq -c --arg k "$KID" '.keys[]|select(.kid==$k)|{kty,alg,use,n_bits_approx:((.n|length)*6)}' <<<"$JWKS")"
else echo "   ${Y}kid $KID not (yet) in JWKS${N}"; fi
note "Every SWA Server in the trust domain uploads its signing key here; Secrets Manager verifies the JWT with it."

step "3. Exchange the JWT-SVID for a Secrets Manager access token (authn-jwt, host-in-URL)"
AUTHN=${AUTHN:-swa-${TD%%.*}}
HOST="host/data/swa/trust-domains/$TD/workloads/$SUB"
echo "   authenticator: authn-jwt/$AUTHN"
echo "   host id      : $HOST"
echo "   \$ curl -X POST $SM_URL/authn-jwt/$AUTHN/conjur/<urlencoded host id>/authenticate --data-urlencode jwt=<JWT-SVID>"
HOST_ENC=$(jq -rn --arg s "$HOST" '$s|@uri')
RESP=$(curl -sS -m 30 -w '\n%{http_code}' -X POST "$SM_URL/authn-jwt/$AUTHN/conjur/$HOST_ENC/authenticate" \
  -H 'Accept-Encoding: base64' -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode "jwt=$JWT")
CODE=${RESP##*$'\n'}; TOKEN=${RESP%$'\n'*}; unset JWT
[ "$CODE" = 200 ] || fail "HTTP $CODE (401 = signature/issuer/audience wrong, host not in authn-jwt/$AUTHN/apps, or annotation sub mismatch)"
echo "   ${G}HTTP 200${N}: access token ${#TOKEN} bytes ${D}(short-lived, never printed)${N}"
note "Tenant checks: signature (JWKS) + iss + aud=conjur + exp, host exists, host in group apps, annotation authn-jwt/$AUTHN/sub == sub."

step "4. Read secrets with the access token"
VARS=("$@")
[ ${#VARS[@]} -gt 0 ] || { echo "   (no variable ids given - pass them as arguments; 56-script-test.sh passes the environment's SECRETS)"; exit 0; }
for v in "${VARS[@]}"; do
  r=$(curl -sS -m 30 -w '\n%{http_code}' -H "Authorization: Token token=\"$TOKEN\"" "$SM_URL/secrets/conjur/variable/$(jq -rn --arg s "$v" '$s|@uri')")
  c=${r##*$'\n'}; val=${r%$'\n'*}
  if [ "$c" = 200 ]; then
    [ "${SHOW:-0}" = 1 ] && echo "   ${G}$v${N} = $val" || echo "   ${G}$v${N} = ${val:0:2}***** (${#val} chars)"
  else echo "   ${R}$v -> HTTP $c${N} ${D}(host has no read/execute permission on this variable)${N}"; fi
done
note "Permissions are per host: each workload is permitted only on its own environment's variables (40-grant.sh)."
