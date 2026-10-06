#!/bin/bash
# 10-tenant-setup.sh <prod|dev> - Build the tenant side for one environment (idempotent):
#   x509pop CA -> trust domain -> server group -> server JWT signing key + server component registration -> node group (policy) -> workload authn-jwt
source "$(dirname "$0")/lib.sh"
env_load "${1:?prod|dev}"; need_conjur
umask 077; mkdir -p "$ST/pki" "$ST/signer"

echo "[1] CA x509pop ($ST/pki)"
[ -f "$ST/pki/ca.key" ] || openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes -keyout "$ST/pki/ca.key" -out "$ST/pki/ca.crt" \
  -subj "/O=HDOLab/OU=$ENV/CN=SWA x509pop CA $ENV" -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign 2>/dev/null

echo "[2] Trust domain $TD"
api POST /trust-domains "$(jq -nc --arg n "$TD" '{name:$n, jwt:{signing_key_type:"RSA_4096", signature_algorithm:"RS512"}}')"; ok_or_exists

echo "[3] Server group $SG"
api POST "/trust-domains/$TD/server-groups" "$(jq -nc --arg n "$SG" --rawfile ca "$ST/pki/ca.crt" '{name:$n, attestation:{x509pop:{ca_certificates:$ca}}}')"; ok_or_exists

echo "[4] Server JWT signing key + register server component $SERVER"
if [ ! -f "$ST/signer/jwt.key" ]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$ST/signer/jwt.key" 2>/dev/null
  python3 - "$ST/signer" <<'PY'
import subprocess, base64, json, hashlib, sys
d=sys.argv[1]; k=d+"/jwt.key"
der=subprocess.run(["openssl","rsa","-in",k,"-pubout","-outform","DER"],capture_output=True,check=True).stdout
mod=subprocess.run(["openssl","rsa","-in",k,"-noout","-modulus"],capture_output=True,check=True,text=True).stdout.strip().split("=")[1]
b64=lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode(); kid=hashlib.sha256(der).hexdigest()[:16]
json.dump({"keys":[{"kty":"RSA","use":"sig","alg":"RS256","kid":kid,"n":b64(bytes.fromhex(mod)),"e":b64((65537).to_bytes(3,"big"))}]},open(d+"/jwks.json","w"))
open(d+"/kid","w").write(kid)
PY
fi
if [ ! -s "$ST/authn_id" ]; then
  api POST "/trust-domains/$TD/server-groups/$SG/components" "$(jq -nc --arg n "$SERVER" --arg iss "$JWT_ISS" --arg sub "$JWT_SUB" --arg aud "$JWT_AUD" --slurpfile j "$ST/signer/jwks.json" \
    '{name:$n, authentication:{type:"JWT", data:{audience:$aud, issuer:$iss, sub:$sub, public_keys:{type:"jwks", value:$j[0]}}}}')"
  ok_or_exists; [[ "$CODE" == 2* ]] && jq -r .authn_id <<<"$BODY" > "$ST/authn_id"
fi
[ -s "$ST/authn_id" ] || die "no authn_id (component exists but the file is missing? delete the component and rerun)"

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
