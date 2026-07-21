# one-browser-action

Public GitHub Actions entrypoint for One Browser builds.

This repository owns the release/deploy workflows. The source repositories can
stay private:

- `voiceofhu/one-browser-server`
- `voiceofhu/one-browser-egress`
- `voiceofhu/one-browser-app`
- `voiceofhu/one-browser-web`

## Recommended Shape

Keep source repositories private, but run the heavy CI/CD implementation here.
The source repositories do not need tag-trigger workflows. Their local
`make push-tag` targets push the tag first, then call `make deploy-server`,
`make deploy-egress`, or `make deploy-app` in this repository with the pushed
version and exact source commit SHA. Egress commands add a positional target,
for example `make deploy-egress 3`. This repository then checks out that
immutable source revision and runs the build.

## Workflows

### Server Deploy

File: `.github/workflows/server.yml`

This workflow is dispatched by the local `make deploy-server` command. It
resolves immutable server and web revisions, checks whether the matching GHCR
image already exists, and only rebuilds when that exact source pair is missing
or the run is forced. A requested deploy still runs when the immutable image
already exists.

Triggers:

- `workflow_dispatch`: local Make or manual deploy

Build inputs:

- `server_repository`: server repository, default `voiceofhu/one-browser-server`
- `server_ref`: server branch/tag/sha. Empty means the repository's default branch
- `version_tag`: optional image version tag. Empty publishes only SHA and `latest`
- `web_repository`: web repository, default `voiceofhu/one-browser-web`
- `web_ref`: web branch/tag/sha. Empty means the repository's default branch
- `image_name`: GHCR image name without `ghcr.io/`
- `force`: rebuild even if `sha-<server_sha>` already exists
- `deploy`: deploy after publishing the image

The workflow:

1. Resolves the requested refs, or each repository's latest default-branch commit, through the GitHub API.
2. Checks out `one-browser-server`.
3. Checks out `one-browser-web` into the server frontend build directory.
4. Runs the server repo's existing `.github/scripts/build-frontend-dist.sh`.
5. Builds and pushes multi-platform Docker images.
6. Runs the server repo's existing Docker Compose deploy scripts.

Image tags pushed:

- `sha-<server_sha>-web-<web_sha>`
- an optional explicit version tag, for example `v26.709.1542`
- `latest`

Production deploys always use the combined immutable SHA tag rather than the
optional version or `latest` aliases.

### Egress Deploy

File: `.github/workflows/egress.yml`

This workflow builds and deploys the independently released Egress data plane.
It resolves an immutable `one-browser-egress` source commit, reuses its existing
GHCR image when available, and can still deploy when no build was needed.

Inputs:

- `egress_ref`: branch, tag, or commit; empty means the default branch
- `deploy`: deploy after publishing or locating the image
- `deploy_targets`: `all` enabled targets or a comma-separated target ID list,
  for example `egress-3` or `egress-1,egress-2`
- `rollout`: `canary` deploys only the first selected wave; `full` continues to
  later waves after the canary succeeds

The source and image are deliberately fixed to the trusted
`voiceofhu/one-browser-egress` repository. The two architecture jobs publish
run-specific staging tags, so concurrent runs cannot mix their amd64 and arm64
artifacts. A queued manifest job validates or publishes:

- `sha-<egress_sha>` containing both `linux/amd64` and `linux/arm64`.

The workflow never force-overwrites this commit-addressed tag and fails closed
when registry inspection fails for any reason other than a confirmed missing
manifest. Production deploys use `sha-<egress_sha>`. The Egress source
repository owns its Dockerfile, Compose file, SSH setup, and rollback-aware
deployment scripts.

The deploy stage reads `.github/config/egress-targets.json` and creates one
matrix job for each selected node. Each matrix job binds its target's GitHub
Environment directly, then invokes the composite entrypoint at
`.github/actions/egress/action.yml`; its identity check, registry login, public
probe, and rollback helpers live together in the same action directory. The
image is built and published once, then pinned by manifest digest for every
deployment. The lowest selected wave runs first as a canary; later-wave matrix
jobs start only after that canary succeeds. Each node job has independent
concurrency, verifies the host
identity before changing Compose, and performs its own rollback-aware container
deploy and public readiness check. After deployment, the workflow verifies the
public certificate and ALPN `h2`, then requires the unauthenticated protocol
response to be `407 Proxy Authentication Required` with a Bearer challenge.
Failure of that public check restores the pre-deploy Compose file and image.

Target configuration contains no private keys, registry credentials, or Egress
control tokens. Per-node SSH credentials remain in GitHub Environment secrets,
the shared `GH_TOKEN` remains a Repository secret, and each control token
remains only in Server registration and the target host's persistent `.env`.

### App Release

File: `.github/workflows/app.yml`

This workflow is dispatched by the local `make deploy-app` command. It checks
out the requested app ref, or the latest commit on the repository's default
branch. When no release tag is supplied, it reads the version from that commit's
`package.json`, creates the Release in `voiceofhu/one-browser-action`, builds
the desktop bundles, and uploads the installers to this public repository.

Triggers:

- `workflow_dispatch`: local Make or manual app release

### Windows App Debug

File: `.github/workflows/app-debug.yml`

This manually triggered workflow builds a Windows x64 Tauri debug package from
a selected `one-browser-app` branch, tag, or commit. It uploads the NSIS
installer, raw executable, and PDB symbols as a workflow artifact for 14 days.
It does not create a tag or GitHub Release.

## Manual Trigger Commands

Run these commands from this repository with `GH_TOKEN` in `.env`:

```bash
GH_TOKEN=ghp_xxx
```

The token must be able to read the private source repositories and run workflows
in `voiceofhu/one-browser-action`. Keep the raw token only; do
not include a `Bearer` prefix or shell quotes in `.env`. Classic tokens usually
start with `ghp_`; fine-grained tokens usually start with `github_pat_`.

Check the local token before triggering a release:

```bash
make check-token
```

For a fine-grained personal access token, select the `voiceofhu` organization
and allow repository access to `one-browser-action`, `one-browser-server`,
`one-browser-egress`, `one-browser-web`, and `one-browser-app`. It needs
`Contents: read` for source repositories and
`Actions: read/write` for `one-browser-action`. A classic token should have the
`repo` scope.

Trigger a server release:

```bash
make deploy-server
```

By default, this builds the latest commit on
`voiceofhu/one-browser-server`'s default branch together with the selected web
commit. It publishes the combined immutable
`sha-<server_sha>-web-<web_sha>` tag plus `latest`; pass `TAG` only when a
versioned image tag is also needed.

Common server options:

```bash
make deploy-server \
  TAG=v26.709.1542 \
  SERVER_REF=v26.709.1542 \
  WEB_REF=main \
  IMAGE_NAME=voiceofhu/one-browser-server
```

Build without deploying:

```bash
make deploy-server TAG=v26.709.1542 DEPLOY=false
```

Deploy Egress node 3:

```bash
make deploy-egress 3
```

Common Egress options:

```bash
make deploy-egress 3 EGRESS_REF=v26.709.1542
```

Deploy nodes 1 or 2:

```bash
make deploy-egress 1
make deploy-egress 2
```

Deploy every enabled target. The first wave must succeed before later waves:

```bash
make deploy-egress all
```

Build and publish the commit-addressed image without deployment:

```bash
make deploy-egress all DEPLOY=false
```

Exactly one positional target is required. `1`, `2`, and `3` map to
`egress-1`, `egress-2`, and `egress-3`; `all` selects every `enabled: true`
entry. Missing, unknown, or multiple targets fail before dispatch.

Trigger an app release:

```bash
make deploy-app
```

By default, this builds the latest commit on
`voiceofhu/one-browser-app`'s default branch and reads the release version from
that commit's `package.json`. Override the source ref or version when needed:

```bash
make deploy-app TAG=v26.707.1821 APP_REF=main
```

Trigger a Windows debug package build from `main`:

```bash
make debug-app APP_REF=main
```

`APP_REF` can also be a test branch, tag, or exact commit SHA. The package is
available from the completed `Windows App Debug` run under `Artifacts`.

## Secrets

The local `one-browser-action/.env` provides `GH_TOKEN` to `make` for workflow
dispatch. GitHub Actions uses these Repository secrets:

| Secret | Purpose |
| --- | --- |
| `GH_TOKEN` | PAT used to read the private source repositories, publish App Releases, and read/write the private GHCR images. |
| `DEPLOY_USER` | SSH account used for Server deployment; currently `gh-deploy`. |

The workflows resolve the GitHub login associated with `GH_TOKEN` at runtime,
so `GHCR_USERNAME`, `GHCR_READ_TOKEN`, `GHCR_TOKEN`, and
`ONE_BROWSER_ACTION_TOKEN` are not required. `DEPLOY_USER` is only an SSH/Linux
account name; it is not used as the GHCR username.

Server deployment binds the `egress-3` GitHub Environment and reuses its
`DEPLOY_SSH_KEY` and `DEPLOY_KNOWN_HOSTS`. Its production host is the same
machine as `egress-3` (`51.68.38.135:22`). No separate Repository-level
`DEPLOY_HOST`, `DEPLOY_SSH_KEY`, or `DEPLOY_KNOWN_HOSTS` is required. Server and
`egress-3` deployments share one concurrency group so their temporary registry
logins cannot race on the same Docker host.

For Egress, create one GitHub Environment per target ID, for example
`egress-3`. Add these same secret names to every environment:

- `DEPLOY_SSH_KEY`: private login key for that node's deploy account
- `DEPLOY_KNOWN_HOSTS`: pinned SSH host-key line for exactly that target

Run this on each Egress server to generate the complete
`DEPLOY_KNOWN_HOSTS` value without hard-coding its public IPv4:

```bash
# Detect this server's public IPv4 and format its local ED25519 Host Key as a
# known_hosts record. Copy the entire output line into DEPLOY_KNOWN_HOSTS.
EGRESS_PUBLIC_IPV4="$(curl -4fsS https://api.ipify.org)" &&
  sudo awk -v host="$EGRESS_PUBLIC_IPV4" \
    '{print host, $1, $2}' \
    /etc/ssh/ssh_host_ed25519_key.pub
```

The output must look like `IP ssh-ed25519 AAAA...`; the `SHA256:...` value from
`ssh-keygen -lf` is only a fingerprint and is not a valid known-hosts record.
The detected IP must exactly match this node's `host` in
`egress-targets.json`. This command assumes the current standard SSH port `22`;
for a custom port, the host field must be `[IP]:PORT`. The IPv4 lookup uses the
[ipify text endpoint](https://www.ipify.org/).

Do not put a private key, control token, GitHub token, or host `.env` value in
`egress-targets.json`. Egress does not require any GitHub Actions Variables
(`vars.*`). During a private-image deploy, the workflow derives the registry
username from the Repository `GH_TOKEN`, sends the token to `docker login`
through stdin, pulls the image, and logs the target out afterward. The token is
never passed to the Egress container.

Non-secret deploy parameters live in
`.github/config/egress-targets.json`:

| Field | Purpose |
| --- | --- |
| `id` | Stable selection key and node identity used by the workflow |
| `enabled` | Whether `deploy_targets=all` may select this node |
| `wave` | Rollout wave; the lowest selected wave is the canary gate |
| `environment` | GitHub Environment that supplies the node's secrets and approval policy |
| `host`, `port`, `user` | SSH destination |
| `endpoint` | Public Egress TLS/H2 endpoint checked after deploy |
| `control_url` | Expected public Server URL in the node's persistent `.env` |
| `remote_dir` | Persistent deployment directory; currently `/opt/one-browser-egress` |
| Compose and container fields | Per-host project, service, container, and network names |
| `use_sudo` | `0` for direct Docker access or `1` for the exact passwordless sudo contract |
| log/check fields | Per-node public validation and bounded post-deploy logs |

`egress-1`, `egress-2`, and `egress-3` are currently enabled, so `all` selects
all three nodes. Keep any new node disabled until its persistent files,
certificate, Server registration, SSH Environment secrets, Docker access, and
public `27600` path are ready.

The control network name is now a per-target parameter. Docker networks are
host-local and do not connect Egress nodes on different servers.

## Production Server Prerequisites

`/opt/one-browser` is provisioned once on the server and remains the persistent
deployment directory. The workflow requires the directory and `.env` to exist;
it stages and atomically replaces only `docker-compose.yml`. It uses `.env`
during the remote preflight, but never uploads, overwrites, prints, or copies
its contents back to Actions. Database and Redis configuration remain
server-owned.

Server deployment does not manage the Egress listener, certificates, firewall,
or public Egress readiness. Those belong to the independent Egress deployment.

## Production Egress Prerequisites

Provision this persistent layout once:

```text
/opt/one-browser-egress/
  .env
  docker-compose.yml
  certs/fullchain.pem
  certs/privkey.pem
```

Every Egress process requires its own `EGRESS_ID`, public endpoint, and
`EGRESS_CONTROL_TOKEN` of at least 32 bytes. Never reuse a token between nodes
and never reuse `APP_SECRET`, `EGRESS_TOKEN_PEPPER`, or
`PROXY_CREDENTIAL_KEY`. Register the same plaintext once through the Server
`egress-node upsert` CLI; Server stores its HMAC instead of adding every node
token to its long-running `.env`.

The current remote-node control path uses the public Server HTTPS endpoint:

```dotenv
EGRESS_ID=egress-3
EGRESS_PUBLIC_ENDPOINT=egress-3.aicbe.com:27600
EGRESS_CONTROL_URL=https://browser.aicbe.com
EGRESS_CONTROL_TOKEN=<unique random value for this node>
EGRESS_PUBLISH_ADDR=0.0.0.0
EGRESS_HOST_PORT=27600
```

The Compose deployment still expects its configured external network to exist
on that host. It is a local container-network requirement, not a cross-server
control path:

```bash
docker network inspect one-browser-control >/dev/null 2>&1 || \
  docker network create one-browser-control
```

The Egress workflow requires `/opt/one-browser-egress` and its `.env` to exist.
Its source-owned deployment script preserves `.env` and `certs/`, deploys the
digest-pinned image, waits for container health, and then the Action checks the
public H2 protocol signature. A trusted certificate by itself is insufficient:
the `407` Bearer response proves public TCP port `27600` reached the Egress
service.

With the recommended `DEPLOY_USE_SUDO=0`, provision the directory as a setgid,
group-writable directory owned by the deployment group, and make `.env`
group-readable but not group-writable. Keep `certs/` owned by `root:65532`.

Certbot renewal, its deploy hook, the DNS-only A record, and inbound TCP `27600`
firewall policy remain host provisioning. Routine Egress releases do not edit
DNS, firewall rules, existing Nginx `443` sites, or issue certificates.
Every Egress data hostname must remain DNS only unless a compatible layer-4
service is introduced. The workflow's public TLS/H2 check happens after the
container deployment. A failure restores the previous container image and
Compose file, but intentionally does not rewrite host DNS or firewall policy.

### Add another Egress deploy target

For a fresh Debian amd64 host, use
`.github/actions/egress/bootstrap-debian-amd64.sh`. It installs Docker Engine,
Compose, Nginx, Certbot, and OpenSSH; creates `gh-deploy`; prepares the
persistent directory, `.env`, public certificate, and renewal hook; and leaves
the first container deployment to this Action. The deployment account has an
impossible password marker instead of a locked shadow entry, so OpenSSH accepts
its configured public key while password login remains unavailable. Certificate
issuance always uses a domain-specific Nginx webroot virtual host, so existing
Nginx websites remain on the same listener. Run it without configuration
arguments:

```bash
sudo bash .github/actions/egress/bootstrap-debian-amd64.sh
```

To create or repair only the shared deployment account on an existing Debian
host, run `.github/actions/egress/setup-gh-deploy-user.sh` as root after Docker
is installed. This standalone script manages `authorized_keys` as exactly the
repository's fixed `gh-deploy@one-browser` public key. Its matching private key
is used as `DEPLOY_SSH_KEY` in every Egress Environment:

```bash
sudo bash .github/actions/egress/setup-gh-deploy-user.sh
```

The script interactively asks for the node number or ID, public domain,
certificate email, and the public half of the deployment SSH key. The Server
control URL is fixed at `https://browser.aicbe.com`. It generates the unique
node token automatically, stores the registration copy as
`/root/<node-id>.control-token` with mode `0600`, and never prints it. The script
never pulls or starts Egress and never stores GHCR credentials.
See [the Chinese multi-node guide](docs/egress-multi-node.zh-CN.md#新服务器初始化顺序)
for the complete operator sequence.

Use this order for `egress-N`:

1. Configure the DNS-only A record and inbound TCP `27600`, then run the host
   bootstrap to provision `/opt/one-browser-egress/.env`, the public
   certificate, Certbot hook, deployment account, and Docker access.
2. Use the generated control token and the host's unique `EGRESS_ID`,
   `EGRESS_PUBLIC_ENDPOINT`, and public `EGRESS_CONTROL_URL` for Server
   registration.
3. Register that exact ID, endpoint, capacity, region, carrier, and one-time
   token through `one-browser-server egress-node upsert`.
4. Create a GitHub Environment with the same name as the target ID and add only
   its `DEPLOY_SSH_KEY` and `DEPLOY_KNOWN_HOSTS`. Configure Repository
   `GH_TOKEN` and `DEPLOY_USER` once; the workflow derives the GHCR username
   from `GH_TOKEN` and logs the target out after the pull. Add required
   reviewers if production approval is desired.
5. Add or update the non-secret entry in `egress-targets.json`, including its
   `wave` and expected `control_url`. Keep
   `enabled: false` until manual `validate-config`, container health, and public
   TLS/H2 checks pass; then set it to `true`.
6. Validate target resolution locally:

   ```bash
   output=$(mktemp)
   GITHUB_OUTPUT="$output" EGRESS_TARGETS_INPUT=egress-N \
     bash .github/scripts/resolve-egress-targets.sh \
     .github/config/egress-targets.json
   ```

7. Deploy only the new node first:

   ```bash
   make deploy-egress 1  # replace 1 with the node number
   ```

   The current Make entry accepts `N` values `1`, `2`, or `3`.

The Action never creates a node's host `.env`, certificate, firewall policy,
Server registry row, or control token. This keeps routine image releases from
silently provisioning or re-identifying a production exit.

## Trigger Note

`make push-tag` in each source repository stops immediately if the tag push
fails. After a successful push it invokes the matching local deploy target with
the current source commit SHA. A later dispatch failure does not roll back the
already-pushed Git tag.
