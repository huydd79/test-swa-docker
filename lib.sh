# lib.sh - shared helpers
set -euo pipefail
cd "$(dirname "$0")"
[ -f ./config.env ] || { echo "ERROR: config.env missing -> cp config.env.example config.env and edit it" >&2; exit 1; }
source ./config.env
die(){ echo "ERROR: $*" >&2; exit 1; }
# api METHOD PATH [JSON] -> sets BODY and CODE
api(){
  local m=$1 p=$2 d=${3:-} tok; [ -s "$ADMIN_TOKEN_FILE" ] || die "admin token missing/expired -> ./01-get-token.sh"
  tok=$(tr -d '\n' < "$ADMIN_TOKEN_FILE")
  local out; out=$(curl -sS -m 30 -w '\n%{http_code}' -X "$m" "$SWA_API_BASE/api/swa$p" \
    -H "Authorization: Token token=\"$tok\"" -H 'Accept: application/x.secretsmgr.v2+json' -H 'Content-Type: application/json' ${d:+-d "$d"})
  CODE=${out##*$'\n'}; BODY=${out%$'\n'*}
  [ "$CODE" = 401 ] && die "admin token missing/expired -> ./01-get-token.sh"
  return 0
}
# ok_or_exists: 2xx or 409 counts as success
ok_or_exists(){ case "$CODE" in 2*) echo "  OK ($CODE)";; 409) echo "  already exists (409)";; *) echo "  HTTP $CODE: $BODY" >&2; return 1;; esac; }
# ensure_client: build swa-go-test from source if the binary is missing (hash is needed by 10 and 30)
ensure_client(){ [ -x "$SWA_CLIENT_BIN" ] || ./swa-go-test/build.sh; }
# ensure_server_image: load the SWA Server image from the bundle tar if it is not in local storage (never pulled)
ensure_server_image(){
  docker image inspect "$SWA_SERVER_IMAGE" >/dev/null 2>&1 && return 0
  [ -f "$SWA_SERVER_TAR" ] || die "server image not loaded and $SWA_SERVER_TAR missing -> extract swa-release-v$SWA_VERSION.tgz to $SWA_BUNDLE_DIR"
  echo "loading $SWA_SERVER_IMAGE from $SWA_SERVER_TAR"; docker load -q -i "$SWA_SERVER_TAR" >/dev/null
  docker image inspect "$SWA_SERVER_IMAGE" >/dev/null 2>&1 || die "$SWA_SERVER_TAR did not provide $SWA_SERVER_IMAGE"
}
# host_gw: address of the host as seen from a container on the default network (agents reach the server ports there)
host_gw(){
  [ -n "${HOST_GW:-}" ] && { echo "$HOST_GW"; return; }
  local g; g=$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)   # Docker
  [ -n "$g" ] || g=$(docker network inspect podman -f '{{range .Subnets}}{{.Gateway}}{{end}}' 2>/dev/null || true) # podman (docker alias)
  [ -n "$g" ] || die "cannot detect the container network gateway -> set HOST_GW in config.env"
  echo "$g"
}
need_conjur(){ conjur whoami >/dev/null 2>&1 || die "conjur CLI not logged in (conjur login)"; }
policy(){ # policy <branch> <yaml-string> : conjur policy update (create/modify, never deletes other records)
  local f out rc; f=$(mktemp); printf '%s\n' "$2" > "$f"
  out=$(conjur policy update -b "$1" -f "$f" 2>&1) && rc=0 || rc=$?; rm -f "$f"; echo "  [$1] ${out%%$'\n'*}"; return $rc; }
