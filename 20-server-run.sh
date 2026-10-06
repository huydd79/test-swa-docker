#!/bin/bash
# 20-server-run.sh <prod|dev> - Mint the server JWT, then run container swa-server-<env> (docker, no k8s)
source "$(dirname "$0")/lib.sh"
env_load "${1:?prod|dev}"
[ -s "$ST/authn_id" ] || die "run 10-tenant-setup.sh $ENV first"
ensure_server_image
./mint-token.sh "$ENV"
mkdir -p "$ST/server-config"; chmod 777 "$ST/server-config"   # uid 65532 writes runtime CA files into /etc/swa
cat > "$ST/server-config/bootstrapConfig.yaml" <<YAML
controlPlane:
  url: $SWA_API_BASE
  syncInterval: 5m
  auth:
    type: jwt
    authnID: $(cat "$ST/authn_id")
    tokenPath: /var/run/secrets/tokens/swa-token
server:
  apiAddr: 0.0.0.0:8443
  webAddr: 0.0.0.0:8080
  trustRootDir: /var/swa/certs
telemetry:
  logging:
    level: info
    otlp: false
    grpcTransport: false
    cache:
      mode: memory
      memory:
        maxRecords: 1000
YAML
chmod 644 "$ST/server-config/bootstrapConfig.yaml"; chmod 711 state "$ST"
docker rm -f "$SERVER" >/dev/null 2>&1 || true
docker run -d --pull=never --name "$SERVER" --restart=always -p "$API_PORT:8443" -p "127.0.0.1:$WEB_PORT:8080" \
  -v "$PWD/$ST/server-config:/etc/swa:Z" -v "$PWD/$ST/tokens:/var/run/secrets/tokens:ro,Z" \
  --tmpfs /var/swa/certs:rw,mode=1777 "$SWA_SERVER_IMAGE" run --configDir /etc/swa >/dev/null
for i in $(seq 1 20); do curl -sf -m 3 "http://127.0.0.1:$WEB_PORT/readyz" >/dev/null && break; sleep 2; done
echo "$SERVER: readyz $(curl -s -o /dev/null -w '%{http_code}' -m 3 http://127.0.0.1:$WEB_PORT/readyz), api :$API_PORT"
docker logs "$SERVER" 2>&1 | grep -E 'KeyUploaded|CaBundleUploaded|level=ERROR' | grep -o 'msg=[^ ]*' | sort | uniq -c
