#!/bin/bash
# 31-workload-run.sh <prod|dev> - Issue the x509pop cert (CN = node group, signed by the environment CA) and run container wl-<env>
#   (agent points to swa-server-<env> via the host port). This is the "install agent on a new machine" step.
source "$(dirname "$0")/lib.sh"
env_load "${1:?prod|dev}"
D="$ST/agent"; umask 077; mkdir -p "$D"
if [ ! -f "$D/x509pop.cert" ]; then   # machine generates key+CSR, CA signs (done in one place in this lab for simplicity)
  openssl req -newkey rsa:2048 -nodes -keyout "$D/x509pop.key" -out "$D/x509pop.csr" -subj "/CN=$NG" 2>/dev/null
  openssl x509 -req -in "$D/x509pop.csr" -CA "$ST/pki/ca.crt" -CAkey "$ST/pki/ca.key" -CAcreateserial -CAserial "$ST/pki/ca.srl" \
    -days 30 -sha256 -out "$D/x509pop.cert" -extfile <(printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n') 2>/dev/null
fi
cat > "$D/config.yaml" <<YAML
trustDomain:
  name: $TD
bootstrap:
  bundleSourceUrl: $SWA_API_BASE/api/swa/trust-domains/$TD/.well-known/ca-bundles
  insecure: false
servers:
  - addr: $(host_gw):$API_PORT
agent:
  socketPath: /run/swa-agent/api.sock
  nodeAttestor:
    type: x509pop
    config:
      key: x509pop.key
      cert: x509pop.cert
workload:
  attestors:
    - type: unix
      config:
        discover_workload_path: true
        workload_size_limit: -1
telemetry:
  logging:
    level: info
YAML
docker rm -f "$WL" >/dev/null 2>&1 || true
docker run -d --pull=never --name "$WL" --hostname "$WL" --cap-add SYS_PTRACE -v "$PWD/$D:/etc/swa:Z" "$WL_IMAGE" >/dev/null
sleep 12
echo "$WL: $(docker inspect -f '{{.State.Status}}' "$WL"), cert CN=$(openssl x509 -in "$D/x509pop.cert" -noout -subject | sed 's/.*CN = //')"
docker exec "$WL" sh -c 'ls -l /run/swa-agent/api.sock; grep -E "level=(ERROR|WARN)" /var/log/swa-agent.log | tail -3 | cut -c1-200' || true
