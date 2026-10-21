#!/usr/bin/env bash
# Build an embedded-key image entirely locally. No push, no remote cache.
# Reuses ONE generated key for all selected architectures and variants.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
command -v docker >/dev/null
command -v ssh-keygen >/dev/null
variants=(alpine distroless chiseled)
architectures=(amd64 arm64)
keydir=$(mktemp -d)
trap 'rm -rf "$keydir"' EXIT
chmod 700 "$keydir"
ssh-keygen -q -t ed25519 -N '' -f "$keydir/hostkey"
echo 'IMPORTANT: This image contains the SSH server PRIVATE KEY. NEVER PUSH IT TO A REGISTRY.'
for variant in "${variants[@]}"; do
  for arch in "${architectures[@]}"; do
    tag="docker-revssh:${variant}-embedded-${arch}"
    docker buildx build --platform "linux/${arch}" \
      -f "Dockerfile.${variant}" --build-arg HOST_KEY_MODE=embedded \
      --secret "id=revssh_hostkey,src=${keydir}/hostkey" \
      --no-cache --load -t "$tag" .
    echo "Built local-only $tag"
  done
done
printf '%s\n' 'Distribute images ONLY through a trusted, encrypted private channel.' \
  'Never upload image tarballs, image caches or layers to publicly accessible storage.'
