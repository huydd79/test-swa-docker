#!/bin/bash
# 20-server-install.sh <prod|dev> - Install/upgrade the SWA Server in k3s namespace swa-<env> with the vendor helm chart.
#   The server authenticates to the tenant with its projected service-account token (aud conjur, rotated by k3s);
#   the Service is a NodePort pinned to $NODE_PORT, published on the host as [$API_BIND:]$API_PORT by the k3s container.
source "$(dirname "$0")/lib.sh"
env_load "${1:?prod|dev}"; need_k3s
[ -s "$ST/authn_id" ] || die "run 10-tenant-setup.sh $ENV first"
ensure_server_image
# rbac.createTokenReviewRole=false: only needed for the k8s_psat attestor (this lab uses x509pop) -> no ClusterRole
helm upgrade --install swa-server "$SWA_SERVER_CHART" -n "$NS" --create-namespace --wait --timeout 180s \
  --set fullnameOverride=swa-server --set serviceAccount.name=swa-server --set rbac.createTokenReviewRole=false \
  --set image.repository="${SWA_SERVER_IMAGE%:*}" --set image.tag="${SWA_SERVER_IMAGE##*:}" --set image.pullPolicy=Never \
  --set controlPlane.url="$SWA_API_BASE" --set controlPlane.auth.authnID="$(cat "$ST/authn_id")" --set controlPlane.auth.audience="$JWT_AUD" \
  --set service.type=NodePort >/dev/null
# the chart has no nodePort value -> pin the API port so the k3s container port mapping matches
kubectl -n "$NS" patch svc swa-server --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/ports/0/nodePort\",\"value\":$NODE_PORT}]" >/dev/null
kubectl -n "$NS" rollout status deploy/swa-server --timeout=120s >/dev/null || die "swa-server not ready -> kubectl -n $NS logs deploy/swa-server"
echo "$SERVER: $(kubectl -n "$NS" get deploy swa-server -o jsonpath='{.status.readyReplicas}/{.spec.replicas}') ready in ns $NS, api nodePort $NODE_PORT -> host ${API_BIND:-0.0.0.0}:$API_PORT"
kubectl -n "$NS" logs deploy/swa-server -c swa-server 2>&1 | grep -E 'KeyUploaded|CaBundleUploaded|level=ERROR' | grep -o 'msg=[^ ]*' | sort | uniq -c
