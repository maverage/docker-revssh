#!/usr/bin/env bash
set -Eeuo pipefail
: "${IMAGE:?Set IMAGE}"
: "${PLATFORM:?Set PLATFORM to linux/amd64 or linux/arm64}"
HOST_KEY_MODE=${HOST_KEY_MODE:-runtime}
work=$(mktemp -d)
name="revssh-test-$$"
net="revssh-net-$$"
web_pid=''
cleanup() {
  docker rm -f "$name" "${name}-second" "${name}-custom" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  [[ -z "$web_pid" ]] || kill "$web_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
cd "$work"
for key in a b unknown; do ssh-keygen -q -t ed25519 -N '' -f "$key"; done
printf 'a|18080,18081|%s\nb|13000|%s\n' "$(cat a.pub)" "$(cat b.pub)" > tunnels.conf
docker network create "$net" >/dev/null
docker run -d --platform "$PLATFORM" --name "$name" --network "$net" \
  -v "$work/tunnels.conf:/config/tunnels:ro" \
  -e TUNNELS_FILE=/config/tunnels "$IMAGE" >/dev/null
# GitHub-hosted Linux runners can reach containers on a user-defined bridge.
# Do not rely on Docker publishing an ephemeral host port.
container_ip() {
  docker inspect -f "{{with index .NetworkSettings.Networks \"$net\"}}{{.IPAddress}}{{end}}" "$1"
}
ssh_host=$(container_ip "$name")
if [[ -z "$ssh_host" ]]; then
  echo 'Failed to resolve test container IP; diagnostics:' >&2
  docker inspect "$name" >&2 || true
  docker logs "$name" >&2 || true
  exit 1
fi
for i in {1..60}; do
  if ssh-keyscan -T 2 -p 2222 "$ssh_host" > known_hosts 2>/dev/null && [[ -s known_hosts ]]; then break; fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "$name")" != true ]]; then
    echo 'SSH container exited; diagnostics:' >&2
    docker inspect --format 'Status={{.State.Status}} ExitCode={{.State.ExitCode}} Error={{.State.Error}}' "$name" >&2 || true
    docker logs "$name" >&2 || true
    exit 1
  fi
  sleep 1
done
test -s known_hosts
# Verify host identity against the generated public key, without needing a shell in the image.
docker cp "$name:/data/ssh_host_ed25519_key.pub" hostkey.pub
if [[ "$HOST_KEY_MODE" == embedded ]]; then
  # A second instance without shared storage MUST have exactly the same baked identity.
  other="${name}-second"
  docker run -d --platform "$PLATFORM" --name "$other" --network "$net" \
    -v "$work/tunnels.conf:/config/tunnels:ro" -e TUNNELS_FILE=/config/tunnels "$IMAGE" >/dev/null
  docker cp "$other:/data/ssh_host_ed25519_key.pub" hostkey-other.pub
  cmp hostkey.pub hostkey-other.pub
  docker rm -f "$other" >/dev/null
  # Masking the baked key must fail closed rather than generating a new key.
  mkdir -p "$work/emptydata"
  if docker run --rm --platform "$PLATFORM" -v "$work/emptydata:/data" \
      -e TUNNELS_FILE=/config/tunnels -v "$work/tunnels.conf:/config/tunnels:ro" "$IMAGE"; then
    echo 'SECURITY FAILURE: embedded mode generated key when /data was masked' >&2; exit 1
  fi
else
  # Runtime-key images must generate a unique host key per independent container.
  # Do not share /data; verify the identity actually advertised by each sshd.
  other="${name}-second"
  docker run -d --platform "$PLATFORM" --name "$other" --network "$net" \
    -v "$work/tunnels.conf:/config/tunnels:ro" \
    -e TUNNELS_FILE=/config/tunnels "$IMAGE" >/dev/null
  other_host=$(container_ip "$other")
  test -n "$other_host"
  for i in {1..60}; do
    if ssh-keyscan -T 2 -p 2222 "$other_host" > other-known-hosts 2>/dev/null && [[ -s other-known-hosts ]]; then break; fi
    if [[ "$(docker inspect -f '{{.State.Running}}' "$other")" != true ]]; then
      echo 'Second runtime-key SSH container exited; diagnostics:' >&2
      docker inspect --format 'Status={{.State.Status}} ExitCode={{.State.ExitCode}} Error={{.State.Error}}' "$other" >&2 || true
      docker logs "$other" >&2 || true
      exit 1
    fi
    sleep 1
  done
  test -s other-known-hosts
  docker cp "$other:/data/ssh_host_ed25519_key.pub" hostkey-other.pub
  if cmp -s hostkey.pub hostkey-other.pub; then
    echo 'SECURITY FAILURE: distinct runtime-key containers share the same SSH host key' >&2
    exit 1
  fi
  observed_other=$(awk '$2=="ssh-ed25519" {print $2 " " $3; exit}' other-known-hosts)
  expected_other=$(awk '{print $1 " " $2}' hostkey-other.pub)
  test "$observed_other" = "$expected_other"
  docker rm -f "$other" >/dev/null
fi
observed=$(awk '$2=="ssh-ed25519" {print $2 " " $3; exit}' known_hosts)
expected=$(awk '{print $1 " " $2}' hostkey.pub)
test "$observed" = "$expected"
docker cp "$name:/run/revssh/authorized_keys" authkeys
# Verify daemon and initializer execute with the intended unprivileged UID.
# Verify sshd really runs under the default unprivileged identity after bootstrap.
if ! docker top "$name" -eo pid,uid,gid,comm | grep -Eq '^[[:space:]]*[0-9]+[[:space:]]+10001[[:space:]]+10001[[:space:]]+sshd'; then
  echo 'SSH daemon did not drop to UID/GID 10001:10001' >&2
  docker top "$name" -eo pid,uid,gid,comm >&2 || true
  exit 1
fi
# No process in the container (init has exec'd into sshd) may remain root.
if docker top "$name" -eo pid,uid,comm | awk 'NR>1 && $2==0 {found=1} END {exit !found}'; then
  echo 'A root process is still running in the container' >&2
  docker top "$name" -eo pid,uid,gid,comm >&2 || true
  exit 1
fi
# A distinct UID and GID must work without rebuilding the image.
custom="${name}-custom"
docker run -d --platform "$PLATFORM" --name "$custom" --network "$net" \
  -v "$work/tunnels.conf:/config/tunnels:ro" -e TUNNELS_FILE=/config/tunnels \
  -e UID=12000 -e GID=13000 "$IMAGE" >/dev/null
for i in {1..30}; do
  if docker top "$custom" -eo pid,uid,gid,comm 2>/dev/null | grep -Eq '^[[:space:]]*[0-9]+[[:space:]]+12000[[:space:]]+13000[[:space:]]+sshd'; then break; fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "$custom")" != true ]]; then
    echo 'Custom UID/GID container failed; logs:' >&2
    docker logs "$custom" >&2 || true
    exit 1
  fi
  sleep 1
done
if ! docker top "$custom" -eo pid,uid,gid,comm | grep -Eq '^[[:space:]]*[0-9]+[[:space:]]+12000[[:space:]]+13000[[:space:]]+sshd'; then
  echo 'Custom UID/GID was not applied to sshd' >&2
  exit 1
fi
docker exec "$custom" /revssh-init healthcheck
docker rm -f "$custom" >/dev/null

docker exec "$name" /revssh-init healthcheck
[[ $(grep -c '^restrict,port-forwarding,' authkeys) -eq 2 ]]
docker exec "$name" /usr/sbin/sshd -t -f /etc/ssh/sshd_config
sshopt=(-p 2222 -o BatchMode=yes -o IdentitiesOnly=yes -o UserKnownHostsFile="$PWD/known_hosts" -o StrictHostKeyChecking=yes -o ExitOnForwardFailure=yes -o ConnectTimeout=5)
printf 'tunnel-works\n' > index.html
python3 -m http.server 28080 --bind 127.0.0.1 >/dev/null 2>&1 & web_pid=$!
if ! ssh "${sshopt[@]}" -i a -fNT -R 0.0.0.0:18080:127.0.0.1:28080 tunnel@"$ssh_host"; then
  echo 'Endpoint A SSH authentication/forwarding failed; sshd logs:' >&2
  docker logs "$name" >&2 || true
  exit 1
fi
if ! ssh "${sshopt[@]}" -i b -fNT -R 0.0.0.0:13000:127.0.0.1:28080 tunnel@"$ssh_host"; then
  echo 'Endpoint B SSH authentication/forwarding failed; sshd logs:' >&2
  docker logs "$name" >&2 || true
  exit 1
fi
# Probe from a separate container. Distroless and chiseled have no curl/sh.
probe() { docker run --rm --network "$net" curlimages/curl:8.16.0 -fsS --max-time 5 "http://$name:$1/"; }
for port in 18080 13000; do
  for i in {1..15}; do if probe "$port" 2>/dev/null | grep -qx tunnel-works; then break; fi; sleep 1; done
  probe "$port" | grep -qx tunnel-works
done
reject() { if timeout 12 ssh "${sshopt[@]}" "$@"; then echo 'SECURITY FAILURE: forbidden operation accepted' >&2; exit 1; fi; }
reject -i b -NT -R 0.0.0.0:18081:127.0.0.1:28080 tunnel@"$ssh_host"
reject -i a -NT -R 0.0.0.0:19999:127.0.0.1:28080 tunnel@"$ssh_host"
reject -i unknown -NT -R 0.0.0.0:19000:127.0.0.1:28080 tunnel@"$ssh_host"
reject -i a -T tunnel@"$ssh_host" id
# Restart regenerates authorized_keys, preserves host identity.
docker restart "$name" >/dev/null
for i in {1..30}; do
  if docker exec "$name" /usr/sbin/sshd -t -f /etc/ssh/sshd_config >/dev/null 2>&1; then break; fi
  sleep 1
done
docker cp "$name:/data/ssh_host_ed25519_key.pub" hostkey2.pub
cmp hostkey.pub hostkey2.pub
docker cp "$name:/run/revssh/authorized_keys" authkeys2
cmp authkeys authkeys2
# Fail closed on malformed declarations.
for bad in 'a|80|ssh-ed25519 INVALID' 'a|nope|ssh-ed25519 INVALID' 'a|18080|ssh-rsa INVALID'; do
  if docker run --rm --platform "$PLATFORM" -e TUNNELS="$bad" "$IMAGE"; then
    echo "SECURITY FAILURE: invalid config accepted: $bad" >&2; exit 1
  fi
done
printf 'Integration tests passed: %s %s %s\n' "$IMAGE" "$PLATFORM" "$HOST_KEY_MODE"
