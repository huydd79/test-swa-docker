#!/bin/bash
# build.sh - Build swa-go-test (static binary) in a golang container; no Go install needed on the host.
# VERSION=x.y ./build.sh  -> overrides the version variable in main.go (default: keep the value in the code).
# Output: ./swa-go-test. Its sha256 is pinned in the node group policy (10-tenant-setup.sh), so a rebuild with
# different code/version = different hash = blocked until the policy is updated.
set -euo pipefail
cd "$(dirname "$0")"
LDX=""; [ -n "${VERSION:-}" ] && LDX="-X main.version=$VERSION"
docker run --rm -v "$PWD":/src:Z -w /src -e CGO_ENABLED=0 -e GOFLAGS=-trimpath -e LDX="$LDX" docker.io/library/golang:1.24 \
  sh -c 'go mod download && go build -ldflags="-s -w $LDX" -o swa-go-test .'
echo "built: $PWD/swa-go-test  sha256 $(sha256sum swa-go-test | cut -d' ' -f1)"
