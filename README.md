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
`make egress`, or `make deploy-app` in this repository with the pushed version
and exact source commit SHA. `make egress` publishes both native Release assets
and the multi-platform Docker image. Egress node installation is performed by
the Server-generated `install.sh` command, not by an Action SSH deployment
target.

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

### Egress Release

File: `.github/workflows/egress-release.yml`

This workflow is dispatched by `make egress` alongside the build-only Egress
image workflow. It resolves an immutable `one-browser-egress` commit, verifies
the optional requested version against that commit's `Cargo.toml`, and
publishes an immutable `egress-v<version>` Release in
`voiceofhu/one-browser-action`.
The public, architecture-independent `install.sh` and `uninstall.sh` remain
ordinary files at the repository root; they are not copied into the Release.
`install.sh` detects `amd64`/`arm64`, supports `--mode native|docker`, and
accepts an optional `--version`. Omitting the version installs `latest`. Native
assets are built against musl so Debian 12 and supported Ubuntu versions do not
depend on the runner's newer glibc.

Release assets:

- `one-browser-egress-linux-amd64`
- `one-browser-egress-linux-arm64`
- `one-browser-egress-<version>.tar.gz`
- `SHA256SUMS`

If that Release already exists, its recorded source SHA and complete asset list
must match. The workflow never replaces existing assets. The same complete
`dist` directory is also retained as an Action run artifact for 30 days.

Validate the public installer locally with:

```bash
bash -n install.sh uninstall.sh tests/egress-*_test.sh
shellcheck install.sh uninstall.sh tests/egress-*_test.sh
tests/egress-install_test.sh
tests/egress-uninstall_test.sh
```

To inspect installer changes independently before publishing a Release, serve
the exact public source tree over HTTP:

```bash
make serve-egress-installer
```

This exposes the working-tree `install.sh` and `uninstall.sh` under
`http://host.orb.internal:27610/`. Generated Server commands use the public
root files from `raw.githubusercontent.com`; the local helper is only for
editing and testing the scripts.

### Egress Image

File: `.github/workflows/egress.yml`

`make egress` dispatches this image-only workflow after dispatching the native
Release workflow. It resolves the same Egress ref and builds or locates the
corresponding GHCR image without connecting to any node.

The source and image are deliberately fixed to the trusted
`voiceofhu/one-browser-egress` repository. The two architecture jobs publish
run-specific staging tags, so concurrent runs cannot mix their amd64 and arm64
artifacts. A queued manifest job validates or publishes:

- `sha-<egress_sha>` containing both `linux/amd64` and `linux/arm64`.
- `<Cargo.toml version>` for `install.sh --version <version>`.
- `latest` when the workflow resolves the Egress default branch.

The workflow never force-overwrites this commit-addressed tag and fails closed
when registry inspection fails for any reason other than a confirmed missing
manifest. Server-generated commands install the semantic version or `latest`
directly on each node; GitHub Actions no longer SSH-deploys Egress nodes.

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
`Contents: read` for source repositories, `Contents: write` for releases in
`one-browser-action`, and `Actions: read/write` for `one-browser-action`. A
classic token should have the `repo` scope.

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

Package native Linux binaries and publish the multi-platform Docker image:

```bash
make egress
```

By default, this resolves the latest Egress default-branch commit and reads its
version from `Cargo.toml`. Pin both when preparing a specific package:

```bash
make egress TAG=v26.724.1 EGRESS_REF=v26.724.1
```

The resulting Action release is named `egress-v26.724.1`. The root
`install.sh`/`uninstall.sh` files are used directly and are not Release assets.
The same command publishes `sha-<egress_sha>`, the Cargo semantic version, and
`latest` for the default branch. It never connects to or changes an Egress
node. Create the node in Server and run one of its generated installation
commands on the target host.

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
| `GH_TOKEN` | PAT used to read private source repositories, publish App/Egress Releases, and read/write private GHCR images. |
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

Egress publication does not require per-node GitHub Environments, SSH keys, or
target manifests. Nodes pull the public Release asset or GHCR image through the
Server-generated installer command.

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

For each production node, prepare a unique lowercase DNS name whose DNS-only A
record points to that host's public IPv4 address. Do not publish an AAAA record.
Allow inbound TCP `80` for Certbot HTTP-01 and TCP `27600` for the Egress data
plane. The host also needs outbound HTTPS access to GitHub, GHCR, Let's Encrypt,
and the public Server origin.

Create the node in Server with its domain and display name. Server owns the
node ID and one-time enrollment token, then returns native, Docker, and
uninstall commands. Run exactly one installation mode before the enrollment
expires:

```bash
install.sh --mode native --control-url <origin> --tls-enabled <true|false>
install.sh --mode docker --control-url <origin> --tls-enabled <true|false>
```

Add `--version 26.724.1` only when a specific runtime version is required.
Without it, the newest native Release or the `latest` Docker image is used.
Remove either installation with the generated `uninstall.sh` command.
In development, Server returns `tls_enabled=false`; private and OrbStack domains
are allowed and no certificate is requested. Outside development, Server
returns `tls_enabled=true`; the installer validates public IPv4 DNS and obtains
the certificate automatically. No GitHub Environment, deployment SSH key, or
target manifest is required for node enrollment.

## Trigger Note

`make push-tag` in each source repository stops immediately if the tag push
fails. After a successful push it invokes the matching local deploy target with
the current source commit SHA. A later dispatch failure does not roll back the
already-pushed Git tag.
