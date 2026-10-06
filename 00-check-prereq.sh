#!/bin/bash
# 00-check-prereq.sh - Check that this host has everything the lab needs. Reports only; never installs anything.
# Exit code: 0 = all required items OK, 1 = something required is missing.
cd "$(dirname "$0")"
[ -f ./config.env ] || { echo "config.env missing -> cp config.env.example config.env and edit it"; exit 1; }
source ./config.env
G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; N=$'\e[0m'
MISS=0; WARN=0
ok(){   printf "  ${G}OK${N}    %-28s %s\n" "$1" "$2"; }
bad(){  printf "  ${R}MISS${N}  %-28s %s\n" "$1" "$2"; MISS=$((MISS+1)); }
warn(){ printf "  ${Y}WARN${N}  %-28s %s\n" "$1" "$2"; WARN=$((WARN+1)); }
tool(){ # tool <cmd> <install hint>
  if command -v "$1" >/dev/null 2>&1; then ok "$1" "$(command -v "$1")"; else bad "$1" "install: $2"; fi; }

echo "== Config"
if grep -qE '^[A-Z_]+="[^"]*<[a-z-]+>' config.env; then printf "  MISS  %-28s %s\n" "config.env" "placeholders left: $(grep -oE '^[A-Z_]+="[^"]*<[a-z-]+>' config.env | cut -d= -f1 | tr '\n' ' ')"; MISS=1
else printf "  OK    %-28s %s\n" "config.env" "tenant $SWA_API_BASE, domain $BASE_DOMAIN"; fi
echo "== Host"
[ "$(id -u)" = 0 ] && ok "root" "required (docker daemon / rootful podman, systemd units in /etc)" || bad "root" "run as root (sudo -i)"
command -v systemctl >/dev/null && ok "systemd" "$(systemctl --version | head -1)" || bad "systemd" "token refresh timer needs systemd"

echo "== Tools"
tool bash      "dnf install bash"
tool curl      "dnf install curl"
tool jq        "dnf install jq"
tool openssl   "dnf install openssl"
tool python3   "dnf install python3   (01-get-token.sh, JWKS build in 10-tenant-setup.sh)"
tool docker    "Docker Engine (docker-ce) or podman + podman-docker"
docker info >/dev/null 2>&1 && ok "docker engine" "$(docker --version 2>/dev/null)" || bad "docker engine" "docker info failed -> start the daemon: systemctl enable --now docker"
tool conjur    "Secrets Manager CLI (conjur) from the CyberArk/Idira download page, then: conjur init + conjur login"
for c in sha256sum base64 mktemp shred sed grep; do tool "$c" "dnf install coreutils grep sed"; done
date -d @0 +%s >/dev/null 2>&1 && ok "date -d (GNU)" "" || bad "date -d (GNU)" "dnf install coreutils"

echo "== SWA release bundle ($SWA_BUNDLE_DIR)"
HINT="mkdir -p $SWA_BUNDLE_DIR && tar -xzf swa-release-v$SWA_VERSION.tgz -C $SWA_BUNDLE_DIR"
# Demo lab: bundle file ownership/permissions and vendor signature (.sig) are intentionally not checked.
if [ -d "$SWA_BUNDLE_DIR" ]; then
  rel=$(awk '/^release:/{print $2}' "$SWA_BUNDLE_DIR/manifest.txt" 2>/dev/null)
  [ "$rel" = "v$SWA_VERSION" ] && ok "bundle release" "$rel (manifest.txt)" || bad "bundle release" "manifest.txt says '${rel:-none}', expected v$SWA_VERSION -> $HINT"
  [ -x "$SWA_AGENT_BIN" ]  && ok "swa-agent binary" "${SWA_AGENT_BIN#$SWA_BUNDLE_DIR/}" || bad "swa-agent binary" "$SWA_AGENT_BIN missing"
  [ -f "$SWA_SERVER_TAR" ] && ok "swa-server image tar" "${SWA_SERVER_TAR#$SWA_BUNDLE_DIR/}" || bad "swa-server image tar" "$SWA_SERVER_TAR missing"
else
  bad "bundle directory" "$SWA_BUNDLE_DIR missing -> $HINT"
fi

echo "== Lab inputs"
[ -f swa-go-test/main.go ] && ok "swa-go-test source" "./swa-go-test (main.go, go.mod, go.sum)" || bad "swa-go-test source" "./swa-go-test/main.go missing"
[ -x "$SWA_CLIENT_BIN" ] && ok "swa-go-test binary" "built ($(sha256sum "$SWA_CLIENT_BIN" | cut -c1-12)...)" || warn "swa-go-test binary" "not built yet -> built automatically by 10/30 (needs docker.io/library/golang:1.24)"
if command -v docker >/dev/null; then
  docker image inspect "$SWA_SERVER_IMAGE" >/dev/null 2>&1 && ok "swa-server image" "$SWA_SERVER_IMAGE (loaded)" \
    || warn "swa-server image" "not loaded yet -> 20-server-run.sh loads it from the bundle tar (never pulled)"
  docker image inspect "$WL_IMAGE" >/dev/null 2>&1 && ok "workload image" "$WL_IMAGE" || warn "workload image" "not built yet -> ./30-build-image.sh (needs docker.io/library/alpine:3.20)"
fi

echo "== Network / firewall"
c=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$SWA_API_BASE/api/info" 2>/dev/null); [[ "$c" =~ ^(200|401)$ ]] \
  && ok "tenant reachable" "$SWA_API_BASE (HTTP $c)" || bad "tenant reachable" "$SWA_API_BASE -> HTTP ${c:-none} (proxy/DNS/firewall?)"
curl -s -o /dev/null -m 10 https://registry-1.docker.io/v2/ && ok "docker.io reachable" "(only for 30-build-image.sh)" || warn "docker.io reachable" "needed only to pull alpine for 30-build-image.sh"
if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
  for i in docker0 podman0; do
    ip link show "$i" >/dev/null 2>&1 || continue
    z=$(firewall-cmd --get-zone-of-interface="$i" 2>/dev/null || echo none)
    case "$z" in trusted|docker) ok "$i firewalld zone" "$z";;
      *) warn "$i firewalld zone" "'$z' - containers may lose egress / host ports; fix: firewall-cmd --permanent --zone=trusted --change-interface=$i && firewall-cmd --reload";; esac
  done
fi
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then   # Ubuntu: UFW drops container -> host ports
  for i in docker0 podman0; do
    ip link show "$i" >/dev/null 2>&1 || continue
    ufw status 2>/dev/null | grep -qE "18443,18543/tcp on $i +ALLOW" && ok "$i ufw" "18443,18543/tcp allowed" \
      || bad "$i ufw" "agents cannot reach the servers; fix: ufw allow in on $i to any port 18443,18543 proto tcp"
  done
fi
for p in 18443 18543 18080 18180; do ss -ltnH "sport = :$p" 2>/dev/null | grep -q . && warn "port $p" "already in use (ok if the lab is running)" ; done

echo "== Credentials"
if command -v conjur >/dev/null && [ ! -s "$HOME/.conjurrc" ]; then warn "conjur init" "~/.conjurrc missing -> conjur init (Secrets Manager SaaS, ${SWA_API_BASE}), then conjur login"
elif command -v conjur >/dev/null; then conjur whoami >/dev/null 2>&1 && ok "conjur login" "$(conjur whoami 2>/dev/null | jq -r .username 2>/dev/null)" || warn "conjur login" "run: conjur login -i <user>  (needed by 10, 40, 99)"; fi
if [ -s "$ADMIN_TOKEN_FILE" ]; then
  c=$(curl -s -o /dev/null -m 10 -w '%{http_code}' -H "Authorization: Token token=\"$(tr -d '\n' < "$ADMIN_TOKEN_FILE")\"" -H 'Accept: application/x.secretsmgr.v2+json' "$SWA_API_BASE/api/swa/trust-domains")
  [ "$c" = 200 ] && ok "admin token (.token)" "valid" || warn "admin token (.token)" "HTTP $c -> ./01-get-token.sh"
else warn "admin token (.token)" "missing -> ./01-get-token.sh"; fi

echo
if [ $MISS -gt 0 ]; then echo "${R}$MISS required item(s) missing${N}, $WARN warning(s). Install/fix the MISS items above, then rerun."; exit 1
else echo "${G}All required items OK${N}, $WARN warning(s)."; fi
