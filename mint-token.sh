#!/bin/bash
# mint-token.sh <prod|dev> - Sign an RS256 JWT for the server (replaces the k8s SA token), written atomically to state/<env>/tokens/swa-token. Called periodically by the timer.
source "$(dirname "$0")/lib.sh"
env_load "${1:?prod|dev}"
b64url(){ openssl base64 -A | tr '+/' '-_' | tr -d '='; }
NOW=$(date +%s)
H=$(printf '{"alg":"RS256","typ":"JWT","kid":"%s"}' "$(cat "$ST/signer/kid")" | b64url)
P=$(printf '{"iss":"%s","sub":"%s","aud":"%s","iat":%d,"nbf":%d,"exp":%d,"jti":"%s"}' "$JWT_ISS" "$JWT_SUB" "$JWT_AUD" "$NOW" "$((NOW-30))" "$((NOW+JWT_TTL))" "$(openssl rand -hex 8)" | b64url)
S=$(printf '%s.%s' "$H" "$P" | openssl dgst -sha256 -sign "$ST/signer/jwt.key" -binary | b64url)
mkdir -p "$ST/tokens"; chmod 755 "$ST/tokens"
T=$(mktemp "$ST/tokens/.t.XXXX"); printf '%s.%s.%s' "$H" "$P" "$S" > "$T"; chmod 644 "$T"; mv -f "$T" "$ST/tokens/swa-token"
echo "$ENV: token exp $(date -d @$((NOW+JWT_TTL)) '+%F %T')"
