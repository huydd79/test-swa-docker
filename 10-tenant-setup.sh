#!/bin/bash
# 10-tenant-setup.sh <prod|dev> - Build the tenant side for one environment (idempotent):
#   x509pop CA -> trust domain -> server group -> server component (k3s service-account JWKS) -> node group (policy) -> workload authn-jwt
source "$(dirname "$0")/lib.sh"
env_load "${1:?prod|dev}"; need_conjur; need_k3s
umask 077; mkdir -p "$ST/pki"

echo "[1] CA x509pop ($ST/pki)"
[ -f "$ST/pki/ca.key" ] || openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes -keyout "$ST/pki/ca.key" -out "$ST/pki/ca.crt" \
  -subj "/O=HDOLab/OU=$ENV/CN=SWA x509pop CA $ENV" -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign 2>/dev/null

echo "[2] Trust domain $TD"
api POST /trust-domains "$(jq -nc --arg n "$TD" '{name:$n, jwt:{signing_key_type:"RSA_4096", signature_algorithm:"RS512"}}')"; ok_or_exists

echo "[3] Server group $SG"
api POST "/trust-domains/$TD/server-groups" "$(jq -nc --arg n "$SG" --rawfile ca "$ST/pki/ca.crt" '{name:$n, attestation:{x509pop:{ca_certificates:$ca}}}')"; ok_or_exists

echo "[4] Register server component $SERVER (k3s SA token: sub $JWT_SUB)"
# The tenant cannot reach the k3s API, so the JWKS is registered inline (public_keys) instead of a jwks_uri.
ISS=$(kubectl get --raw /.well-known/openid-configuration | jq -r .issuer)
JWKS=$(kubectl get --raw /openid/v1/jwks | jq -cS .)
[ -n "$ISS" ] && [ -n "$JWKS" ] || die "cannot read issuer/JWKS from k3s"
reg(){ api POST "/trust-domains/$TD/server-groups/$SG/components" "$(jq -nc --arg n "$SERVER" --arg iss "$ISS" --arg sub "$JWT_SUB" --arg aud "$JWT_AUD" --argjson j "$JWKS" \
    '{name:$n, authentication:{type:"JWT", data:{audience:$aud, issuer:$iss, sub:$sub, public_keys:{type:"jwks", value:$j}}}}')"; }
unreg(){ api DELETE "/trust-domains/$TD/server-groups/$SG/components/$SERVER"; echo "  delete old component: $CODE"; rm -f "$ST/authn_id" "$ST/jwks.json"; }
if [ -s "$ST/authn_id" ] && [ "$(cat "$ST/jwks.json" 2>/dev/null)" = "$JWKS" ]; then echo "  already registered (JWKS unchanged)"
else
  # k3s signing key changed (volume recreated) or authn_id lost -> re-register; the new authn_id goes to the helm release (20)
  [ -s "$ST/authn_id" ] && { echo "  k3s JWKS changed -> re-register"; unreg; }
  reg; [ "$CODE" = 409 ] && { unreg; reg; }
  ok_or_exists; jq -r .authn_id <<<"$BODY" > "$ST/authn_id"; printf '%s' "$JWKS" > "$ST/jwks.json"
fi
[ -s "$ST/authn_id" ] || die "no authn_id"

echo "[5] Node group $NG (policy: $SA_USER + sha256 swa-go-test  OR  $SA_USER + path swa-agent CLI for the swa-test.sh demo)"
ensure_client
H=$(sha256sum "$SWA_CLIENT_BIN" | cut -d' ' -f1)
# Element 1: pinned client binary. Element 2: swa-agent CLI (used by the swa-test.sh demo script) - any script run as
# $SA_USER can then get a JWT; remove element 2 outside demos.
POL=$(jq -nc --arg u "$SA_USER" --arg h "$H" '["unix.user == \"" + $u + "\" && unix.sha256 == \"" + $h + "\"", "unix.user == \"" + $u + "\" && unix.path == \"/opt/swa/bin/swa-agent\""]')
api POST "/trust-domains/$TD/server-groups/$SG/node-groups" "$(jq -nc --arg n "$NG" --argjson p "$POL" '{name:$n, workload_type:"unix", workload_configuration:{workload_registration_policies:$p}}')"
ok_or_exists
if [ "$CODE" = 409 ]; then   # update the policy (new client hash / policy change)
  api PATCH "/trust-domains/$TD/server-groups/$SG/node-groups/$NG" "$(jq -nc --argjson p "$POL" '{workload_configuration:{workload_registration_policies:$p}}')"; echo "  PATCH policy: $CODE"
  # the server syncs every 15m (chart default); restart it so the new policy applies now
  kubectl -n "$NS" get deploy swa-server >/dev/null 2>&1 && kubectl -n "$NS" rollout restart deploy/swa-server >/dev/null && echo "  restarted swa-server in $NS"
fi

echo "[6] Authenticator authn-jwt/$AUTHN (host-in-URL, jwks-uri trust domain $TD)"
policy conjur/authn-jwt "- !policy
  id: $AUTHN
  body:
  - !webservice
  - !variable jwks-uri
  - !variable issuer
  - !variable audience
  - !group apps
  - !permit
    role: !group apps
    privilege: [ read, authenticate ]
    resource: !webservice
  - !webservice status
  - !group operators
  - !permit
    role: !group operators
    privilege: [ read ]
    resource: !webservice status"
A="conjur/authn-jwt/$AUTHN"; TDURL="$SWA_API_BASE/api/swa/trust-domains/$TD"
conjur variable set -i "$A/jwks-uri" -v "$TDURL/.well-known/jwks" >/dev/null
conjur variable set -i "$A/issuer"   -v "$TDURL" >/dev/null
conjur variable set -i "$A/audience" -v "$JWT_AUD" >/dev/null
conjur authenticator enable -i "authn-jwt/$AUTHN"
echo "Tenant $ENV done: TD=$TD SG=$SG SERVER=$SERVER NG=$NG AUTHN=authn-jwt/$AUTHN"
