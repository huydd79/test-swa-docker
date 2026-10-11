#!/bin/bash
# 05-k3s-up.sh - Run the single-node k3s cluster (container $K3S_NAME, data in docker volume $K3S_NAME) that hosts the
#   SWA Servers, write $KUBECONFIG and import the SWA Server image. Idempotent: an existing container is (re)started.
#   Published ports: 127.0.0.1:$K3S_API_PORT -> kube-apiserver; [$API_BIND:]<API_PORT> -> NodePort of each env's server.
#   The service-account signing key lives in the volume, so recreating the container keeps the JWKS registered on the tenant.
source "$(dirname "$0")/lib.sh"
if ! docker container inspect "$K3S_NAME" >/dev/null 2>&1; then
  P=(-p "127.0.0.1:$K3S_API_PORT:6443")
  for e in $ENVS; do env_load "$e"; P+=(-p "${API_BIND:+$API_BIND:}$API_PORT:$NODE_PORT"); done
  docker volume create "$K3S_NAME" >/dev/null
  # privileged: k3s runs containerd + kubelet inside this container
  docker run -d --name "$K3S_NAME" --hostname "$K3S_NAME" --privileged --restart=unless-stopped "${P[@]}" \
    -v "$K3S_NAME:/var/lib/rancher/k3s" "$K3S_IMAGE" \
    server --disable=traefik --disable=metrics-server --tls-san 127.0.0.1 >/dev/null
  echo "$K3S_NAME: created ($K3S_IMAGE), ports: ${P[*]}"
else
  docker start "$K3S_NAME" >/dev/null; echo "$K3S_NAME: started (existing container; port mappings unchanged)"
fi
for i in $(seq 1 60); do k3s kubectl get nodes 2>/dev/null | grep -q ' Ready' && break; sleep 3; done
k3s kubectl get nodes 2>/dev/null | grep -q ' Ready' || die "k3s node not Ready -> docker logs $K3S_NAME"
umask 077; mkdir -p state
k3s cat /etc/rancher/k3s/k3s.yaml | sed "s#https://127.0.0.1:6443#https://127.0.0.1:$K3S_API_PORT#" > "$KUBECONFIG"
kubectl get nodes --no-headers | awk '{print "node     " $1 " " $2 " " $5}'
ensure_server_image
echo "issuer   $(kubectl get --raw /.well-known/openid-configuration | jq -r .issuer)"
echo "jwks kid $(kubectl get --raw /openid/v1/jwks | jq -r '[.keys[].kid] | join(", ")')"
