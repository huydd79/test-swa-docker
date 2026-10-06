#!/bin/bash
# 30-build-image.sh - Build the workload image: alpine + swa-agent 1.1.4 (from $SWA_BUNDLE_DIR) + swa-go-test (built from ./swa-go-test) + swa-test.sh
#   + user swa-demo-sa (nologin)
source "$(dirname "$0")/lib.sh"
ensure_client
[ -x "$SWA_AGENT_BIN" ] || die "$SWA_AGENT_BIN missing -> extract swa-release-v$SWA_VERSION.tgz to $SWA_BUNDLE_DIR"
cp "$SWA_AGENT_BIN" image/swa-agent; cp "$SWA_CLIENT_BIN" image/swa-go-test
docker build -q -f image/Dockerfile -t "$WL_IMAGE" --build-arg SA_USER="$SA_USER" --build-arg SA_UID="$SA_UID" image/
rm -f image/swa-agent image/swa-go-test
echo "sha256 swa-go-test in image : $(docker run --rm --pull=never --entrypoint sha256sum "$WL_IMAGE" "$WL_CLIENT" | cut -d' ' -f1)"
echo "sha256 swa-go-test built    : $(sha256sum "$SWA_CLIENT_BIN" | cut -d' ' -f1)"
