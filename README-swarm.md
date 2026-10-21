# Docker Swarm deployment (embedded SSH host key)

This walkthrough uses [`compose.swarm-embedded.yml`](compose.swarm-embedded.yml) in the **repository root**. It launches **Traefik** (HTTPS termination and automatic Let's Encrypt certificates) and a local-only **Ubuntu Chiseled docker-revssh** image with its SSH **server private host key embedded at build time**. The tunnel policy (public endpoint keys and authorized ports) is still generated at **container startup** through `TUNNELS`.

> [!CAUTION]
> **NEVER PUSH OR PUBLISH AN EMBEDDED-HOST-KEY IMAGE TO A REGISTRY, REMOTE BUILD CACHE, ARTIFACT STORE, OR OTHER UNTRUSTED SYSTEM.** The image layers contain the unencrypted private SSH **server host key**. Anyone with access to the image can extract it and impersonate your SSH server. Build only on trusted infrastructure and distribute only privately between trusted Swarm nodes. Do **not** mount a volume over `/data` in embedded-key mode.


## Health checks

All three distributions (Alpine, Google Distroless, and Ubuntu Chiseled) use **the same health-check command** in both runtime-key and embedded-key modes:

```text
/revssh-init healthcheck
```

The Go initializer opens a TCP connection to `127.0.0.1:2222` and confirms that the OpenSSH server sends an `SSH-2.0-` identification banner. It does not require a shell, `curl`, `nc`, a client SSH key, or an HTTP endpoint. The Dockerfiles define this as the default `HEALTHCHECK`; both example Compose files also define it explicitly with a 30-second interval, 5-second timeout, 15-second startup grace period and three retries.

Check the status with `docker inspect --format '{{json .State.Health}}' <container>` for regular Compose, or `docker service ps revssh_revssh` and `docker inspect` of the relevant task container in Swarm. **Healthy means sshd is responding on port 2222, not that any autossh reverse tunnel or upstream application is connected.** Traefik can still return a 502/503 if the specific forwarded port is not listening. Docker health status alone does not guarantee Swarm will replace every unhealthy task; monitor health events and service availability separately.

## 1. Architecture and prerequisites

| Public entry point | Traefik / SSH listener | Back-end on remote endpoint |
| --- | --- | --- |
| `https://app1.example.com` | Traefik HTTPS → revssh port `18080` | Endpoint A `127.0.0.1:8080` |
| `https://app2.example.com` | Traefik HTTPS → revssh port `13000` | Endpoint B `127.0.0.1:3000` |
| `ssh.example.com:2222` | SSH server TCP `2222` | Incoming `autossh -R` connections |

You need Docker Engine with Swarm initialized, a trusted Swarm **manager** that will run both services, DNS records pointing to that node (or a suitable load balancer), and TCP ports **80, 443, and 2222** reachable. Port 80 is used for Let's Encrypt's HTTP challenge. Ensure no existing service occupies these published ports.

Use the actual `app1.example.com` and `app2.example.com` names in `compose.swarm-embedded.yml` or change the file before deployment. For simplicity, this example stores Let's Encrypt state in a local named volume and fixes both services to one labeled node.

**Swarm cannot build images:** `docker stack deploy` ignores the Compose `build:` section. You must run `docker compose ... build` first, and then run `docker stack deploy ...`. The same file is deliberately used for both operations.

## 2. Configure authorized endpoint public keys

Generate **distinct client** Ed25519 keys on the two endpoints if you don't already have them:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/revssh-endpoint-a -C revssh-endpoint-a
ssh-keygen -t ed25519 -f ~/.ssh/revssh-endpoint-b -C revssh-endpoint-b
```

Only provide **public keys** (`.pub`) to the server. On the Swarm manager, export your values (adjust the paths to where you copied the `.pub` files):

```bash
export ACME_EMAIL='admin@example.com'
export ENDPOINT_A_PUBLIC_KEY="$(cat ./endpoint-a.pub)"
export ENDPOINT_B_PUBLIC_KEY="$(cat ./endpoint-b.pub)"
```

`compose.swarm-embedded.yml` uses `TUNNELS` to grant endpoint A **only** `0.0.0.0:18080` and endpoint B **only** `0.0.0.0:13000`. For additional endpoints, add another `name|port[,port...]|ssh-ed25519 ...` line and corresponding Traefik router/service labels. Key changes take effect on container restart/redeployment.

## 3. Prepare the Swarm node

From the repository root on a Swarm manager:

```bash
# Only if Swarm has not been initialized:
docker swarm init

# Identify the manager on which you will build and run the services:
docker node ls

# Replace GATEWAY_NODE with that node's real name:
docker node update --label-add revssh_gateway=true GATEWAY_NODE
```

For a single manager, build and deploy on that **same** host. The image is local-only; other nodes cannot pull it from any registry. `--resolve-image never` avoids remote tag resolution but **does not replicate or distribute local images**.

## 4. Build locally, then deploy

```bash
# Run from the repository root with the environment variables exported above.
docker compose -f compose.swarm-embedded.yml build --no-cache revssh

# DO NOT run `docker compose push`.
docker stack deploy \
  --compose-file compose.swarm-embedded.yml \
  --resolve-image never \
  revssh
```

The build generates the server Ed25519 host key **inside the image**. Save the public fingerprint obtained from a trusted deployment and pin it on clients. Do not turn off SSH host-key verification.

Check the running stack:

```bash
docker stack services revssh
docker service ps revssh_revssh
docker service logs revssh_revssh
```

If a worker gets scheduled that does not have the image locally, the task can fail. Keep the placement constraint or pre-load **the exact same image** on any eligible failover node using a trusted encrypted transport (for example `docker save ... | ssh ... docker load`); never rebuild independently to reproduce the same host key.

On **mixed amd64/arm64 Swarms**, independent embedded builds produce different host keys. To preserve one identity across architectures, generate one private Ed25519 host key and use the supplied `scripts/build-embedded.sh` BuildKit-secret workflow to bake that same key into each architecture's image. Only transfer it within trusted infrastructure; never publish those images.

## 5. Connect the two remote endpoints

Endpoint A, where its application listens on `127.0.0.1:8080`:

```bash
autossh -M 0 -NT \
  -p 2222 -i ~/.ssh/revssh-endpoint-a \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=yes \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -R 0.0.0.0:18080:127.0.0.1:8080 \
  tunnel@ssh.example.com
```

Endpoint B, where its application listens on `127.0.0.1:3000`:

```bash
autossh -M 0 -NT \
  -p 2222 -i ~/.ssh/revssh-endpoint-b \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=yes \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -R 0.0.0.0:13000:127.0.0.1:3000 \
  tunnel@ssh.example.com
```

**Before connecting**, securely obtain and pin the server host public key in each client's `known_hosts` (port 2222), based on a trusted fingerprint. Do not blindly trust the first key seen over an untrusted network. The `0.0.0.0:` prefix is required by the server's `GatewayPorts clientspecified` and per-key `permitlisten` policy.

Once the tunnels have connected, browse `https://app1.example.com` and `https://app2.example.com`. Traefik routes both HTTPS sites to separate **internal** SSH reverse-forwarded listeners. Ports 18080 and 13000 are **not** exposed on the Docker host.

## 6. Operations and security notes

- The embedded server key is fixed per image digest, not per container. Recreating or rescheduling **the same image** preserves host identity. Rebuilding the image creates a new key unless you explicitly supply the previous key via BuildKit secret.
- `authorized_keys` is regenerated on **each container start**; `sshd_config` is static inside the image. No external SSH host-key volume is required.
- A read-only Docker socket mount still allows powerful Docker API access. For stronger isolation, use a socket proxy that allows only the necessary read endpoints, or a trusted external Traefik configuration provider.
- Traefik's ACME volume is node-local in this example. Back it up; ensure only one Traefik replica manages the ACME state.
- Embedded images are inappropriate for public build systems with accessible build artifacts/caches. Treat host-key compromise as an SSH server identity compromise and rotate the key and every pinned fingerprint if exposed.
- Public HTTP(S) services are still public services: deploy authentication, rate limiting, and app-specific safeguards as needed.
- This example is designed for a single labeled Swarm node. A production HA design also needs image pre-distribution, persistent ACME state, proper ingress reachability, and a strategy for long-lived SSH sessions when the active server changes.

For an automatic **single-host** build and startup with `docker compose up --build`, use [`compose.embedded.yml`](compose.embedded.yml) and the section in the [main README](README.md).
