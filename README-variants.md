# docker-revssh: minimized runtime variants

Both variants use the same **static** `sshd_config` (`sshd_config` in the build context) and regenerate only `/run/sshd/authorized_keys` on startup. A statically compiled Go entrypoint replaces the Alpine shell script because neither runtime contains a shell. `/data/ssh_host_ed25519_key` persists if `/data` is mounted.

## Build

```bash
docker build -f Dockerfile.distroless -t docker-revssh:distroless .
docker build -f Dockerfile.chiseled -t docker-revssh:chiseled .
```

Both build commands must run in this directory, with `init.go`, `sshd_config`, `passwd`, and `group` included in the build context.

## Configuration

`TUNNELS` is a newline-separated list of `name|port,port|ssh-ed25519 PUBLIC_KEY`; alternatively, provide `TUNNELS_FILE=/path/to/readable/mounted/config`. A file takes precedence over the environment variable. Only reverse listeners on `0.0.0.0` and explicitly authorized ports are permitted. Ports must be 1024–65535, except 2222. Duplicate public keys and duplicate listening ports are rejected.

```bash
docker run --rm --name revssh -p 2222:2222 \
  -v revssh-hostkeys:/data \
  -e 'TUNNELS=site-a|18080|ssh-ed25519 REPLACE_WITH_REAL_PUBLIC_KEY' \
  docker-revssh:distroless
```

Remote endpoint:

```bash
autossh -M 0 -NT -p 2222 -i ~/.ssh/id_ed25519 \
  -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
  -R 0.0.0.0:18080:127.0.0.1:8080 tunnel@ssh.example.com
```

## Differences

- **Distroless:** Debian 13 OpenSSH binaries and dynamic library dependencies copied from a Debian 13 builder onto Google's `base-debian13`; no package manager/shell in runtime.
- **Ubuntu Chiseled:** Uses Ubuntu 24.04's published `openssh-server_bins` and `openssh-server_config` slices from Canonical Chisel; `scratch` runtime contains only selected files and custom configuration.

## Cautions

- `sshd` intentionally starts as root to bind and handle SSH authentication, then SSH's unprivileged account is used for the restricted forwarding session; do not set `user:` to an unprivileged UID without redesigning the server.
- Container `/data` should be writable; keep it on a trusted persistent volume. No host ports for forwarded services need be published: Traefik reaches forwarded listeners on the shared Docker overlay network.
- These variants were statically checked and their Go initializer was compiled locally, but **Docker builds and end-to-end SSH tests have not been executed** in this environment. Add both variants to your CI integration-test matrix before release. Verify library completeness on both amd64 and arm64.
- Image references and builders should be pinned to digests for reproducible releases. Use Trivy/SBOM scans and regular base refreshes. Avoid placing key authorization policy in unsecured public environment variable displays; Docker Swarm configs or secrets are preferable.
