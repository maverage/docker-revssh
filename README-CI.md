# Three variants / two architectures

Build context: repository root containing `init.go`, `passwd`, `group`, `sshd_config`,
`Dockerfile.alpine`, `Dockerfile.chiseled`, and `Dockerfile.distroless`.

The workflow `.github/workflows/container.yml` builds and runtime-tests each of:

- Alpine (amd64 / arm64)
- Google Distroless (amd64 / arm64)
- Ubuntu Chiseled (amd64 / arm64)

It scans each built image with Trivy and only pushes after tests pass.
On `main` it creates `:alpine`, `:distroless`, `:chiseled`, and `:latest`.
**`:latest` always points to Chiseled.**
On `v1.2.3` it creates `:1.2.3-alpine`, `:1.2.3-distroless`,
`:1.2.3-chiseled`, `:1.2.3` (Chiseled), and corresponding `1.2` tags.
Each points to an amd64+arm64 manifest list.

Individual images are pushed first under temporary `ci-SHA-variant-arch` tags.
To limit registry growth, expire old `ci-*` tags using a GHCR retention policy.

Local build/test example:

```bash
docker buildx build --platform linux/amd64 --load -f Dockerfile.alpine -t revssh-test:alpine .
IMAGE=revssh-test:alpine PLATFORM=linux/amd64 bash tests/integration.sh
```

GitHub-hosted arm64 tests use QEMU and can be slower than native arm64 runners.
Both legacy minimal-image Dockerfiles must pass their own runtime integration tests;
this workflow does not assume that copying binaries/libs is sufficient.

## Private embedded-host-key builds

The matrix covers **3 distros × 2 architectures × 2 host-key modes = 12** jobs.
`runtime` mode has no embedded key and is eligible for GHCR publication after tests and vulnerability scanning.
`embedded` mode has a **private SSH host key inside the image**. The runner only builds, tests, and scans it locally. The workflow explicitly **skips login and push**, disables build caches, and does not upload these images as artifacts.

**NEVER publish an embedded image, build layer, tarball or build cache.** CI's generated embedded key is ephemeral and should not be used for production deployments. See `scripts/build-embedded.sh` for generating one common key across target architectures locally.

## SSH host identity isolation tests

Every matrix combination tests host identity in two independent containers:

- **`runtime` mode:** two containers started from the *same image*, without shared `/data` storage, must generate **different** Ed25519 SSH host keys. The test checks both on-disk public keys and the keys actually advertised by SSH. A container restart must still retain its own identity.
- **`embedded` mode:** two containers started from the same image must expose **identical** baked SSH host keys. Masking `/data` must fail closed rather than generate a replacement key.

Both checks run for Alpine, Distroless, and Chiseled on `linux/amd64` and `linux/arm64` as part of `tests/integration.sh`. A failed assertion blocks publishing.

## Ubuntu Chiseled version

`Dockerfile.chiseled` uses Ubuntu 26.04 slices with Chisel v1.5.1 (required for v3 slice definitions). The builder installs CA certificates for HTTPS access to the Chisel release repository.

### Alpine public-key authentication

The Alpine image sets the `tunnel` account shadow password field to `NP` (an unusable password marker) instead of BusyBox `adduser`'s locked `!` marker. OpenSSH can deny public-key authentication to a locked account. Password and keyboard-interactive authentication remain disabled in the static `sshd_config`; `MaxSessions 0` still prevents shell/exec sessions. On failure the integration test prints the server logs and client diagnostics.

### Authentication failure diagnostics

The integration suite reports concise server logs if authorized SSH authentication fails. The SSH server reads `/run/revssh/authorized_keys` using the unprivileged `tunnel` account (UID 10001), so the initializer sets `/run/sshd` to `0755` and the root-owned `authorized_keys` file to `0644`. These public keys are not secrets; the file remains unwritable by the tunnel account. Distroless/Chiseled supply a non-password `NP` shadow marker for the tunnel user; password and keyboard-interactive authentication remain disabled.


### Integration-test networking

On GitHub-hosted Linux runners the integration suite connects directly to the
container IP on its dedicated Docker bridge network (TCP 2222). It does not
rely on Docker allocating/publishing an ephemeral host port. The production
image still declares `EXPOSE 2222`; deployment configurations publish SSH
as required. The test assumes a Linux Docker host whose runner can reach
Docker bridge container addresses.

## Non-root regression

The CI integration test checks default and custom UID/GID settings and SSH functionality after privilege drop. Both SSH host-key modes and every architecture must successfully start the SSH server, authenticate forwarding-only clients, and enforce denied operations under this UID.
