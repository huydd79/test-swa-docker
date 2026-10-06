#!/bin/bash
# 01-get-token.sh - Get a Secrets Manager admin access token (user with MFA), saved to .token in this directory (chmod 600).
# Copied from ../03-get-token.sh; used by every script here via ADMIN_TOKEN_FILE (config.env).
# Run INTERACTIVELY in your terminal (prompts for password + OTP). The token is never printed.
# Conjur tokens are short-lived (~8 min, unconfirmed): rerun before each use.
set -euo pipefail
cd "$(dirname "$0")"
[ -f config.env ] || { echo "config.env missing -> cp config.env.example config.env and edit it" >&2; exit 1; }
source config.env
: "${IDENTITY_URL:?set IDENTITY_URL in config.env}" "${SWA_API_BASE:?set SWA_API_BASE in config.env}"
SM_USER="${SM_USER:-}"
echo "Identity tenant: $IDENTITY_URL"
if [ -t 0 ]; then   # interactive: always show the user; Enter keeps the SM_USER default from config.env
  read -r -p "Identity user${SM_USER:+ [$SM_USER]}: " U; SM_USER="${U:-$SM_USER}"
else
  echo "Identity user: $SM_USER"
fi
[ -n "$SM_USER" ] || { echo "no user" >&2; exit 1; }

J() { python3 -c "import sys,json;d=json.load(sys.stdin);$1"; }
post() { curl -sS -m 30 -X POST "$IDENTITY_URL/Security/$1" -H 'Accept: application/json' -H 'Content-Type: application/json' -d "$2"; }
# oob_poll_once: AdvanceAuthentication Action=Poll for the current out-of-band mechanism (push approved / link clicked).
# Returns 0 and sets RESP when confirmed (Summary LoginSuccess or StartNextChallenge), 1 while OobPending.
oob_poll_once() {
  local P SUM; P=$(post AdvanceAuthentication "{\"Action\":\"Poll\",\"SessionId\":\"$SID\",\"MechanismId\":\"$MID\"}")
  [ "$(printf %s "$P" | J "print(d.get('success'))")" = "True" ] || { echo; echo "Poll failed: $(printf %s "$P" | J "print(d.get('Message'))")" >&2; exit 1; }
  SUM=$(printf %s "$P" | J "print((d.get('Result') or {}).get('Summary',''))")
  case "$SUM" in LoginSuccess|StartNextChallenge) RESP="$P"; return 0;; *) return 1;; esac
}

START=$(post StartAuthentication "{\"Version\":\"1.0\",\"User\":\"$SM_USER\"}")
printf %s "$START" | J "sys.exit(0 if d.get('success') and 'SessionId' in d.get('Result',{}) else 1)" 2>/dev/null \
  || { echo "StartAuthentication failed (user='$SM_USER'): $(printf %s "$START" | head -c 300)" >&2; exit 1; }
SID=$(printf %s "$START" | J "print(d['Result']['SessionId'])")
NCH=$(printf %s "$START" | J "print(len(d['Result']['Challenges']))")
RESP="$START"

for ((i=0; i<NCH; i++)); do
  # List the mechanisms of challenge i
  MECHS=()
  # The challenge list is in the StartAuthentication response (Advance does not return it)
  while IFS= read -r line; do MECHS+=("$line"); done < <(printf %s "$START" | J "
for m in d['Result']['Challenges'][$i]['Mechanisms']: print(m['MechanismId']+'|'+m['Name']+'|'+m['PromptMechChosen']+'|'+m.get('AnswerType',''))")
  if [ "${#MECHS[@]}" -gt 1 ]; then
    echo "Choose an authentication method:"
    for k in "${!MECHS[@]}"; do echo "  $((k+1))) $(echo "${MECHS[$k]}" | cut -d'|' -f2-3)"; done
    if [ -n "${SM_MFA:-}" ]; then   # preselect by name (OATH|EMAIL|SMS)
      SEL=0; for k in "${!MECHS[@]}"; do [ "$(echo "${MECHS[$k]}" | cut -d'|' -f2)" = "$SM_MFA" ] && SEL=$k; done
    else
      read -r -p "Number [1-${#MECHS[@]}]: " SEL
      [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= ${#MECHS[@]} )) || { echo "Invalid choice: $SEL" >&2; exit 1; }
      SEL=$((SEL-1))   # menu is 1-based, array is 0-based
    fi
  else SEL=0; fi
  MID=${MECHS[$SEL]%%|*}; MNAME=$(echo "${MECHS[$SEL]}" | cut -d'|' -f2); ATYPE=$(echo "${MECHS[$SEL]}" | cut -d'|' -f4)
  case "$MNAME" in
    UP) if [ -n "${SM_PASS:-}" ]; then ANS="$SM_PASS"; else read -r -s -p "Password: " ANS; echo; fi ;;
    *)  # AnswerType StartTextOob/StartOob (EMAIL, SMS and - on this tenant - OATH too) must be started with StartOOB
        # before answering; only AnswerType "Text" is answered directly. Decide by AnswerType, not by mechanism name.
        if [ "$ATYPE" != "Text" ]; then
          OOB=$(post AdvanceAuthentication "{\"Action\":\"StartOOB\",\"SessionId\":\"$SID\",\"MechanismId\":\"$MID\"}")
          [ "$(printf %s "$OOB" | J "print(d.get('success'))")" = "True" ] \
            || { echo "StartOOB failed for $MNAME: $(printf %s "$OOB" | J "print(d.get('Message'))")" >&2; exit 1; }
        fi
        POLLED=0
        if [ -n "${SM_OTP_FILE:-}" ]; then   # non-interactive mode: code in a file OR push approved (polled)
          rm -f "$SM_OTP_FILE"; echo "Waiting up to 180s: put the $MNAME code in $SM_OTP_FILE, or approve the push..."
          ANS=""
          for n in $(seq 1 180); do
            [ -s "$SM_OTP_FILE" ] && { ANS=$(tr -d ' \r\n' < "$SM_OTP_FILE"); rm -f "$SM_OTP_FILE"; break; }
            if [ "$ATYPE" != "Text" ] && (( n % 3 == 0 )) && oob_poll_once; then POLLED=1; break; fi
            sleep 1
          done
          [ -n "$ANS" ] || [ "$POLLED" = 1 ] || { echo "Timed out waiting for OTP / push action" >&2; exit 1; }
        else
          [ "$ATYPE" != "Text" ] && echo "  ($MNAME) enter the code, OR just press Enter and approve the push (or click the link)"
          read -r -p "Verification code ($MNAME) [Enter = wait for push action]: " ANS
          if [ -z "$ANS" ] && [ "$ATYPE" != "Text" ]; then
            echo -n "  waiting for push action (up to 180s)"
            for _ in $(seq 1 90); do oob_poll_once && { POLLED=1; break; }; echo -n "."; sleep 2; done; echo
            [ "$POLLED" = 1 ] || { echo "Timed out waiting for push action" >&2; exit 1; }
          fi
        fi
        if [ "$POLLED" = 1 ]; then echo "  $MNAME confirmed via push action"; continue; fi ;;
  esac
  BODY=$(SID="$SID" MID="$MID" ANS="$ANS" python3 -c '
import json,os
print(json.dumps(dict(Action="Answer", SessionId=os.environ["SID"], MechanismId=os.environ["MID"], Answer=os.environ["ANS"])))')
  RESP=$(post AdvanceAuthentication "$BODY")
  unset ANS BODY
  OK=$(printf %s "$RESP" | J "print(d.get('success'))")
  [ "$OK" = "True" ] || { echo "Authentication failed: $(printf %s "$RESP" | J "print(d.get('Message'))")" >&2; exit 1; }
done

ID_TOKEN=$(printf %s "$RESP" | J "print(d['Result'].get('Token',''))")
[ -n "$ID_TOKEN" ] || { echo "No ID token yet (Summary: $(printf %s "$RESP" | J "print(d['Result'].get('Summary'))"))" >&2; exit 1; }

umask 077
curl -sS -m 30 -X POST "$SWA_API_BASE/api/authn-oidc/cyberark/conjur/authenticate" \
  -H 'Accept-Encoding: base64' -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "id_token=$ID_TOKEN" > .token
unset ID_TOKEN
chmod 600 .token
[ -s .token ] && echo "OK: token saved to .token ($(wc -c < .token) bytes)" || { echo "Token exchange failed" >&2; exit 1; }
