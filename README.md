# docker-revssh

**A minimal, key-restricted SSH reverse-tunneling server for Docker and Docker Swarm.**

`docker-revssh` lets applications behind NAT or a firewall become reachable through a central server without opening inbound ports at the remote endpoint. Each endpoint uses a dedicated **Ed25519 SSH key** and can request only its explicitly assigned **reverse (`-R`) listening ports**.

Three public image variants are available: **Ubuntu Chiseled (default)**, Alpine, and Google Distroless. Each is built for **linux/amd64** and **linux/arm64**.

> **Release status:** Building and running these images must be verified through CI on your repository. The Dockerfiles and integration tests supplied with this project have not been independently validated end-to-end in this environment.

## 🚨 CRITICAL SECURITY WARNING — embedded-host-key images

> [!CAUTION]
> **NEVER publish, push, upload, or share any image built with `HOST_KEY_MODE=embedded` to GHCR, Docker Hub, any container registry, public artifact store, or untrusted cache.**
> These images contain an **unencrypted SSH server PRIVATE KEY inside an image layer**. Anyone who can read the image, layers, exported tarball, or a leaked build cache can extract that key and impersonate the SSH server. Deleting a tag is **not** sufficient to revoke an exposed key. If leaked, regenerate the key and securely rotate trusted host fingerprints on every endpoint.
>
> Embedded images are for **trusted, privately controlled Docker Swarm infrastructure only**. Build and distribute privately (for example over encrypted SSH), ensure restrictive access to every Swarm node, and never use remote BuildKit caches or remote builders you do not trust. CI builds and tests these variants but **does not publish or upload them**.

The default `HOST_KEY_MODE=runtime` images **do not contain private host keys**, and those are the only images published by CI.

## Features

- Multiple simultaneous endpoint connections with one Ed25519 public key per endpoint.
- Per-key reverse-listener allowlists enforced with OpenSSH `authorized_keys` `permitlisten`.
- Public-key-only authentication; password, interactive shell, exec, SFTP, agent forwarding, X11, local forwarding, and SOCKS forwarding disabled.
- **Static `sshd_config` baked into each image**, shared by all three variants.
- **`authorized_keys` regenerated at every container start** from `TUNNELS` or `TUNNELS_FILE` by the compiled Go initializer (`init.go`).
- Atomic authorized-key replacement, input validation and duplicate-key/port rejection; fail-closed startup.
- Two SSH host identity modes: startup-generated key persisted in `/data`, or a private host key baked into a local-only image for Swarm portability.
- Docker Swarm deployment with reverse-proxy access over a private overlay network.
- 12-way CI matrix: three distributions × two architectures × two host-key modes; **only runtime-key images** go to GHCR.

## Architecture

```text
Endpoint A behind firewall                 Docker host / Docker Swarm
  http://127.0.0.1:8080 ─┐                 ┌─────────────────────────────┐
                         └── autossh -R ──►│ SSH server :2222            │
Endpoint B behind firewall                 │  ├─ 0.0.0.0:18080 (key A) │
  http://127.0.0.1:3000 ─── autossh -R ──►│  └─ 0.0.0.0:13000 (key B) │
                                           └──────────┬──────────────────┘
                                                      │ Docker network
                                                 Traefik / other proxy
                                                      │
                                          HTTPS clients → apps.example.com
```

Remote clients initiate outbound SSH connections. The gateway's SSH port must be reachable by these clients; application listener ports do **not** need to be published on the host.

## Choose an image

Substitute `<owner>` with your GitHub account or organization (GHCR repository names are lowercase).

| Base | Image | Description |
| --- | --- | --- |
| **Ubuntu Chiseled** (default) | `ghcr.io/<owner>/docker-revssh:latest` or `:chiseled` | Ubuntu 26.04 OpenSSH package slices assembled with Chisel; minimal `scratch` runtime |
| Alpine | `ghcr.io/<owner>/docker-revssh:alpine` | Alpine 3.24 with packaged OpenSSH |
| Google Distroless | `ghcr.io/<owner>/docker-revssh:distroless` | Distroless Debian 13 base plus Debian OpenSSH binaries and dependencies |

The table above lists **runtime-key images only**. An additional **embedded host-key build mode** exists for each distribution and architecture; those images MUST stay private and are never published by CI. All variants use identical SSH authorization policies. **`:latest` always selects Chiseled**, not Alpine. Tags on `main` include `latest`, `chiseled`, `alpine`, and `distroless`; a `v1.2.3` release also creates `1.2.3` (Chiseled), `1.2.3-chiseled`, `1.2.3-alpine`, `1.2.3-distroless` and corresponding `1.2*` tags. The published tags are multi-platform manifests with `linux/amd64` and `linux/arm64` entries.


## Health checks

All three distributions (Alpine, Google Distroless, and Ubuntu Chiseled) use **the same health-check command** in both runtime-key and embedded-key modes:

```text
/revssh-init healthcheck
```

The Go initializer opens a TCP connection to `127.0.0.1:2222` and confirms that the OpenSSH server sends an `SSH-2.0-` identification banner. It does not require a shell, `curl`, `nc`, a client SSH key, or an HTTP endpoint. The Dockerfiles define this as the default `HEALTHCHECK`; both example Compose files also define it explicitly with a 30-second interval, 5-second timeout, 15-second startup grace period and three retries.

Check the status with `docker inspect --format '{{json .State.Health}}' <container>` for regular Compose, or `docker service ps revssh_revssh` and `docker inspect` of the relevant task container in Swarm. **Healthy means sshd is responding on port 2222, not that any autossh reverse tunnel or upstream application is connected.** Traefik can still return a 502/503 if the specific forwarded port is not listening. Docker health status alone does not guarantee Swarm will replace every unhealthy task; monitor health events and service availability separately.

## Ready-to-run Traefik examples

Two examples are included in the **repository root**, both using an **embedded server host key** and two authorized public client keys (`ENDPOINT_A_PUBLIC_KEY` → port `18080`, `ENDPOINT_B_PUBLIC_KEY` → port `13000`). Traefik terminates HTTPS for separate subdomains; the SSH gateway listens on TCP `2222`. **Neither embedded image may be pushed to a registry.**

### Single Docker host: build and start with Docker Compose

[`compose.embedded.yml`](compose.embedded.yml) uses Traefik's **Docker provider**, a bridge network, and a Chiseled build with `HOST_KEY_MODE=embedded`. It **builds directly when you run** `docker compose up --build` (unlike Swarm):

```bash
export ACME_EMAIL='admin@example.com'
export APP1_HOST='app1.example.com'
export APP2_HOST='app2.example.com'
export ENDPOINT_A_PUBLIC_KEY="$(cat ./endpoint-a.pub)"
export ENDPOINT_B_PUBLIC_KEY="$(cat ./endpoint-b.pub)"

docker compose -f compose.embedded.yml up --build -d
```

Set DNS records for the HTTPS hosts and `ssh.example.com`; allow inbound TCP `80`, `443`, and `2222`. Client A uses `-R 0.0.0.0:18080:127.0.0.1:8080`; client B uses `-R 0.0.0.0:13000:127.0.0.1:3000`. Both connect as `tunnel@ssh.example.com` on port 2222, with distinct private keys. Pin the server's SSH host key; do **not** disable host-key verification.

> [!WARNING]
> `--build` builds or rebuilds the image, but Docker's build cache can reuse the existing embedded-key layer. A clean `--no-cache` rebuild generates a **different** server host key, invalidating clients' pinned host identity. If you require continuity across future rebuilds, reuse the existing image or pass an existing private host key as a BuildKit secret. Never push/export embedded-key images or remote caches.

### Docker Swarm: build first, then deploy

[`compose.swarm-embedded.yml`](compose.swarm-embedded.yml) uses Traefik's **Swarm provider**, overlay networking, node placement constraints, and an embedded-key Chiseled image. **`docker stack deploy` ignores `build:`**; use `docker compose -f compose.swarm-embedded.yml build --no-cache revssh` first on the designated node, then `docker stack deploy -c compose.swarm-embedded.yml --resolve-image never revssh`. Local images are **not** automatically distributed to other nodes.

See **[README-swarm.md](README-swarm.md)** for full prerequisites, DNS configuration, public keys, Swarm placement, deployment commands, autossh client examples, and secure image distribution to failover nodes.

## SSH host-key storage: runtime mode and explicit `/data` volumes

This behavior is **identical for Alpine, Google Distroless, and Ubuntu Chiseled**. All three use the same `init.go` initializer and support `HOST_KEY_MODE=runtime` (the default, used by published images) and `HOST_KEY_MODE=embedded` (private builds only). The mode is chosen **when building the image**, not by setting a runtime environment variable.

### Default runtime mode (`HOST_KEY_MODE=runtime`)

The published images contain **no pre-generated SSH server private key**. On startup, the initializer checks for `/data/ssh_host_ed25519_key`:

- If it **does not exist**, it generates a new Ed25519 SSH server host key and its `.pub` file in `/data`.
- If it **already exists**, it reuses the key to preserve the server's SSH identity.
- Independently created containers with separate filesystems and no shared volume therefore generate **different host keys**. Restarting the *same* container keeps its key, but removing and recreating that container generally loses it unless `/data` is mounted persistently.
- `authorized_keys` is regenerated from `TUNNELS` / `TUNNELS_FILE` on **every** startup, independently of the SSH host key's lifetime. The static `sshd_config` is never regenerated.

### Why the Dockerfiles do not declare `VOLUME /data`

The directory `/data` is still present and writable, but **none of the three Dockerfiles declares a Docker `VOLUME` instruction**. This is intentional: Docker will not implicitly create an anonymous volume for every container. You explicitly decide whether its host identity survives container replacement.

| Deployment | What happens to the server host key? |
| --- | --- |
| Runtime mode, no `/data` mount | A fresh key on the first start of each new container; survives `docker restart` of that container, but **not** container removal/recreation |
| Runtime mode, named volume mounted at `/data` | Key is generated once and reused across recreated containers **using that same volume** |
| Runtime mode, bind mount at `/data` | Key is reused as long as the host directory and its contents persist and remain writable |
| Two runtime containers, different or no volumes | Separate host identities, even when using the same image |
| Runtime mode, two containers sharing one `/data` volume | Same server host key; sharing writable storage between simultaneous SSH servers is generally unnecessary and should be managed carefully |
| Embedded mode, **no** `/data` mount | Uses the private host key baked into the image; replicas of that exact image have the same identity |
| Embedded mode, empty `/data` mount | **Startup fails** because the mount hides the baked-in key; it does not silently generate a replacement |

### Persisting the runtime host key manually (recommended)

For a stable identity across image upgrades, container recreation, and Compose redeployments, **mount a named volume explicitly**:

```yaml
services:
  revssh:
    image: ghcr.io/<owner>/docker-revssh:latest
    environment:
      TUNNELS: |
        endpoint-a|18080|ssh-ed25519 REPLACE_WITH_REAL_KEY endpoint-a
    volumes:
      - revssh-hostkeys:/data
    ports:
      - "2222:2222"

volumes:
  revssh-hostkeys:
```

Alternatively, with `docker run`, use `-v docker-revssh-data:/data`, as shown in [Quick start](#quick-start). Docker manages a named volume separately from the container, so deleting and recreating the container does not delete the volume unless you explicitly remove it. **Back up the volume** and protect its contents: `/data/ssh_host_ed25519_key` is an unencrypted private SSH server key. Avoid `docker compose down -v` if you need to retain that identity.

**Docker Swarm caveat:** A named volume using Docker's default `local` driver is **local to the node**. If the service is rescheduled to another node, that node may have an empty volume and consequently generate a new key, causing SSH host-key verification failures for clients. Use persistent shared storage, constrain the service to a node with its volume, or use a privately built embedded-key image distributed securely to the relevant nodes. A volume name alone does **not** synchronize data across Swarm members.

For **embedded mode**, do **not** mount `/data` at all; its contents must remain visible from the image. Never publish embedded-key images to a registry (see the warning above).

## Embedded host-key builds — private Swarm deployment only

**DO NOT PUSH EMBEDDED-KEY IMAGES TO REGISTRIES.** Read the security warning above before using this option. The normal `:latest` image is **always Chiseled with runtime-generated host keys**.

By default, `/revssh-init` generates `/data/ssh_host_ed25519_key` on the first startup. When the image is built with `--build-arg HOST_KEY_MODE=embedded`, a server Ed25519 key is baked into `/data` at **build time**, and startup still **regenerates `authorized_keys` only**. `sshd_config` remains static.

In embedded mode, if the baked host key is absent (for example because you mounted an empty volume over `/data`), initialization **fails closed** rather than generating a different identity. **Do not mount anything at `/data` for embedded images.** Dockerfiles deliberately do not declare a `VOLUME` so the baked key remains available in the container filesystem.

### Single-architecture local build

```bash
# Locally built only; contains a SECRET PRIVATE HOST KEY.
docker build --no-cache -f Dockerfile.chiseled \
  --build-arg HOST_KEY_MODE=embedded \
  -t docker-revssh:chiseled-embedded-amd64 .
# Never use docker push with this image!
```

Change `Dockerfile.chiseled` to `Dockerfile.alpine` or `Dockerfile.distroless` for the other distros. Use Buildx with `--platform linux/arm64` when targeting ARM.

### Multi-architecture build with the SAME key

**Warning:** Independently built `amd64` and `arm64` embedded images have **different** host keys, even when they use identical tags. To maintain a single SSH host identity on heterogeneous Swarm nodes, supply **one generated private key** via a BuildKit secret to every architecture build. The supplied script handles this:

```bash
bash scripts/build-embedded.sh
```

It creates one temporary Ed25519 private key, then builds these six **local-only** images without remote build caching or pushing:

```text
docker-revssh:alpine-embedded-amd64
docker-revssh:alpine-embedded-arm64
docker-revssh:distroless-embedded-amd64
docker-revssh:distroless-embedded-arm64
docker-revssh:chiseled-embedded-amd64
docker-revssh:chiseled-embedded-arm64
```

**Secure distribution is your responsibility.** For a multi-node Swarm, transfer the appropriate images over an authenticated encrypted channel and import them on each node (e.g., `docker save | ssh node docker load`). Use a consistent image reference/tag on the nodes participating in a deployment, or explicitly constrain placement by architecture. A Swarm service created with `docker stack deploy` normally relies on a registry to resolve and distribute an image; local-only images require deliberate placement and distribution, and deploying with `--resolve-image never` can avoid registry lookups. Test failover between nodes before relying on it. Do not transfer image tarballs through untrusted intermediaries.

**Build-time keys are not automatically rotated.** Rebuilding the image with a new host key changes its identity. Rebuild all architectures together using a shared key and distribute them atomically when rotating. Never upload embedded images as CI artifacts.

## Quick start

### 1. Create a dedicated SSH key for each remote endpoint

On endpoint A:

```bash
ssh-keygen -t ed25519 -a 100 -f ~/.ssh/docker-revssh -C endpoint-a
cat ~/.ssh/docker-revssh.pub
```

Keep the private key only on the endpoint. Repeat for other endpoints with independent keys.

### 2. Configure authorized endpoints

Create `tunnels.conf` alongside your deployment:

```text
# name|allowed-server-listening-ports|SSH-public-key
endpoint-a|18080,18081|ssh-ed25519 REPLACE_WITH_REAL_BASE64_KEY endpoint-a
endpoint-b|13000|ssh-ed25519 REPLACE_WITH_REAL_BASE64_KEY endpoint-b
```

The example keys are placeholders; **replace them with complete, valid public keys** before starting.

**Rules:** Endpoint names use letters, numbers, `_` and `-`. Ports must be unique across endpoints, numeric, in `1024–65535`, and not `2222` (the fixed SSH port inside the image). Keys must be Ed25519, valid, and unique. Blank lines and lines starting with `#` are ignored. Invalid configurations prevent startup.

### 3. Start the container

```bash
docker volume create docker-revssh-data

docker run -d \
  --name docker-revssh \
  --restart unless-stopped \
  -p 2222:2222/tcp \
  -v docker-revssh-data:/data \
  -v "$PWD/tunnels.conf:/config/tunnels.conf:ro" \
  -e TUNNELS_FILE=/config/tunnels.conf \
  ghcr.io/<owner>/docker-revssh:latest
```

For a locally built image, substitute `docker-revssh:chiseled` (see [Building locally](#building-locally)).

### 4. Connect via autossh

From endpoint A, forwarding its local port `8080` to remote listener `18080`:

```bash
autossh -M 0 -NT \
  -i ~/.ssh/docker-revssh \
  -p 2222 \
  -o BatchMode=yes \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -R 0.0.0.0:18080:127.0.0.1:8080 \
  tunnel@ssh.example.com
```

Endpoint B, using its *own key*, can request `-R 0.0.0.0:13000:127.0.0.1:3000`. An attempt by B to listen on A's assigned ports will be rejected. `-N` is required because the server does not allow interactive SSH sessions.

**SSH host identity:** Verify and pin the gateway host key in each client's `known_hosts` during initial provisioning. Do **not** disable host-key checking. The host key is generated only if absent from `/data`.

## Configuration

| Variable | Meaning | Default |
| --- | --- | --- |
| `TUNNELS` | Multiline endpoint definitions in `name|ports|public-key` format | Empty |
| `TUNNELS_FILE` | Path to a readable mounted endpoint-definition file; takes precedence over `TUNNELS` | Empty |

Both are parsed by `/revssh-init`. For an environment-variable configuration, for example:

```yaml
environment:
  TUNNELS: |
    endpoint-a|18080|ssh-ed25519 REPLACE_WITH_REAL_KEY endpoint-a
    endpoint-b|13000|ssh-ed25519 REPLACE_WITH_REAL_KEY endpoint-b
```

For production, prefer a read-only mounted configuration or a Docker Swarm secret rather than embedding key policy in deployment manifests. Public keys are not private credentials, but the policy may be operationally sensitive. No private endpoint keys belong on this server.

### Which files are generated?

| File | Lifetime | Purpose |
| --- | --- | --- |
| `/etc/ssh/sshd_config` | **Image build**, never rewritten at startup | Common SSH authentication and forwarding policy |
| `/run/sshd/authorized_keys` | **Regenerated each container startup** | Per-key `restrict,port-forwarding,permitlisten=...` restrictions |
| `/data/ssh_host_ed25519_key` | Runtime: generated **only if missing**; embedded: baked into image | SSH server identity; mount `/data` explicitly only for runtime-mode persistence |

The internal SSH service always listens on **TCP 2222**; change the *published host port* if needed (e.g. `-p 2200:2222`) and use the corresponding `autossh -p` value. There is no runtime `SSH_PORT` configuration in these variants.

The `authorized_keys` file is regenerated on **restart**, not on-the-fly. After updating the mounted policy, restart or redeploy the container. A restart disconnects active tunnels; `autossh` should reconnect.

## Docker Swarm + Traefik example

This assumes an **existing external overlay network** named `proxy`, with Traefik attached and configured for the Docker Swarm provider. Traefik terminates client HTTPS; SSH itself is published directly via TCP 2222 rather than through a Traefik HTTP router.

```yaml
services:
  revssh:
    image: ghcr.io/<owner>/docker-revssh:latest
    environment:
      TUNNELS_FILE: /run/configs/tunnels
    configs:
      - source: endpoints
        target: /run/configs/tunnels
    volumes:
      - ssh-host-keys:/data
    networks:
      - proxy
    ports:
      - target: 2222
        published: 2222
        protocol: tcp
        mode: host
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.labels.revssh == true
      restart_policy:
        condition: on-failure
      labels:
        - traefik.enable=true
        - traefik.swarm.network=proxy
        - traefik.http.routers.app-a.rule=Host(`app-a.example.com`)
        - traefik.http.routers.app-a.entrypoints=websecure
        - traefik.http.routers.app-a.tls=true
        - traefik.http.routers.app-a.service=app-a
        - traefik.http.services.app-a.loadbalancer.server.port=18080
        - traefik.http.routers.app-b.rule=Host(`app-b.example.com`)
        - traefik.http.routers.app-b.entrypoints=websecure
        - traefik.http.routers.app-b.tls=true
        - traefik.http.routers.app-b.service=app-b
        - traefik.http.services.app-b.loadbalancer.server.port=13000
configs:
  endpoints:
    file: ./tunnels.conf
volumes:
  ssh-host-keys:
networks:
  proxy:
    external: true
```

Deploy with `docker stack deploy -c stack.yml revssh`. Label the node that holds your persistent host-key volume using `docker node update --label-add revssh=true NODE_NAME`, or replace the constraint with your storage-aware placement policy.

Keep a **single replica** unless you deliberately partition endpoint ports between instances: connections and listeners are local to one container, and arbitrary load balancing across replicas would break routing. Traefik must be able to reach its listeners over the overlay network. **Do not publish ports 18080 / 13000** from the Docker container.

## Security model and limitations

The static OpenSSH policy allows only authenticated user `tunnel`, only remote TCP forwarding (`AllowTcpForwarding remote`), and no session channels (`MaxSessions 0`). Each authorized key is written with `restrict,port-forwarding` and one `permitlisten="0.0.0.0:PORT"` per granted port.

| Operation | Policy |
| --- | --- |
| Ed25519 public-key authentication for configured endpoint | Allowed |
| `ssh -R 0.0.0.0:<assigned-port>:...` | Allowed |
| Listening on another endpoint's or unassigned port | Rejected |
| `ssh -L`, `ssh -D`, command execution, shell, SFTP, X11, agent forwarding | Disabled |
| Password login | Disabled |

Important boundaries:

- **`permitlisten` restricts the listening address/port on the server**, not the destination behind a remote client's tunnel. Authorized clients control their *own* forwarding destinations.
- With `GatewayPorts clientspecified`, clients must specify **`0.0.0.0:PORT`** explicitly in `-R`; `-R PORT:...` is a different listener request.
- The forwarded listeners bind to `0.0.0.0` **inside the container** so the reverse proxy can reach them. Other containers on the same reachable network may also connect; use a dedicated network and additional network policy where necessary. They are not exposed on the host unless explicitly published.
- The service starts `sshd` as root for SSH daemon initialization and account handling. Do not force a non-root Docker user without validating a different sshd deployment model.
- Keep `/data` persistent and protected, restrict host SSH port 2222 in the firewall where feasible, and pin host keys on clients.

## Building locally

Run builds at the **repository root**, where the shared `init.go`, `sshd_config`, `passwd`, and `group` files live:

```bash
docker build -f Dockerfile.alpine -t docker-revssh:alpine .
docker build -f Dockerfile.distroless -t docker-revssh:distroless .
docker build -f Dockerfile.chiseled -t docker-revssh:chiseled .
```

For a multi-architecture publication to your own registry:

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -f Dockerfile.chiseled \
  -t ghcr.io/<owner>/docker-revssh:chiseled --push .
```

For release publishing, use the provided CI pipeline instead: it tests each platform/variant before creating multi-architecture tags. The Chiseled build uses host-platform Chisel with `--arch "$TARGETARCH"` to download target architecture package slices; the Go initializer is cross-compiled with `GOOS`/`GOARCH`.

## Tests and CI/CD

Workflow: [`.github/workflows/container.yml`](.github/workflows/container.yml)  
Test suite: [`tests/integration.sh`](tests/integration.sh)  
Details: [`README-CI.md`](README-CI.md)

The GitHub Actions build matrix covers **Alpine, Distroless, Chiseled × amd64, arm64** (six jobs). Each builds a local architecture image, runs black-box SSH integration checks, scans for vulnerabilities and Dockerfile issues using Trivy, and publishes the tested architecture image to GHCR when allowed. A downstream job assembles the multi-platform manifests **after all six jobs succeed**. Pull requests test but do not publish. Scheduled jobs rebuild and scan dependencies; Dependabot can propose base-image and GitHub Action updates.

The integration suite includes positive reverse forwarding, per-key separation, unauthorized-port and unknown-key rejection, refusal of remote command execution, static `sshd_config` validation, regenerated authorization after restart, and host key persistence. Runtime tests use the host SSH client and an external probe container, not an assumed shell in Distroless/Chiseled.

Quick local smoke test (requires Docker and SSH client):

```bash
docker buildx build --platform linux/amd64 --load \
  -f Dockerfile.alpine -t revssh-test:alpine .
IMAGE=revssh-test:alpine PLATFORM=linux/amd64 bash tests/integration.sh
```

> For security-sensitive releases, pin base images and actions to immutable digests/commit hashes and review scan exceptions. CI passing does not replace a deployment-specific firewall/network review.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Container exits on startup | `docker logs docker-revssh`; check complete Ed25519 key material, numeric unique ports and readable `TUNNELS_FILE` |
| `Permission denied (publickey)` | Correct key, `-i` path, username **`tunnel`**, and current authorized config; use `ssh -vvv` |
| `remote port forwarding failed` | Explicit `-R 0.0.0.0:PORT:...`, port present in the key's allowlist, and no existing listener on that port |
| Tunnel works but application unreachable through Traefik | Confirm same Docker overlay network, Traefik router/service labels, app health, and tunnel still connected |
| Host-key warning after restart | Ensure `/data` is persistent and mounted on the intended node; do not ignore unexpected host key changes |
| Chiseled / Distroless image fails to start | Check architecture-specific binaries, dynamic libraries, required runtime paths, and CI integration-test logs |

## Project layout

```text
.
├── Dockerfile.alpine
├── Dockerfile.chiseled
├── Dockerfile.distroless
├── init.go
├── sshd_config
├── passwd
├── group
├── tests/
│   └── integration.sh
├── .github/
│   └── workflows/
│       └── container.yml
├── README-CI.md
└── README.md
```

## License

Add a `LICENSE` file defining the terms under which you distribute this project.

### Host-key isolation in CI

The integration tests start two independent containers from each image. For standard runtime-key images, they require **different** SSH host keys (no shared `/data` volume); for embedded-key images, they require **matching** host keys. Both identities are checked against the keys served by SSH, and restart persistence is verified. These checks cover all three image variants and both CPU architectures before a release is published.
