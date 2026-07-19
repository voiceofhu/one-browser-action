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
version and exact source commit SHA. This repository then checks out that
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

The source and image are deliberately fixed to the trusted
`voiceofhu/one-browser-egress` repository. The two architecture jobs publish
run-specific staging tags, so concurrent runs cannot mix their amd64 and arm64
artifacts. A queued manifest job validates or publishes:

- `sha-<egress_sha>` containing both `linux/amd64` and `linux/arm64`.

The workflow never force-overwrites this commit-addressed tag and fails closed
when registry inspection fails for any reason other than a confirmed missing
manifest. Production deploys use `sha-<egress_sha>`. The Egress source
repository owns its Dockerfile, Compose file, SSH setup, and rollback-aware
deployment scripts. After deployment, this workflow verifies the public
certificate and ALPN `h2`, then requires the unauthenticated protocol response
to be `407 Proxy Authentication Required` with a Bearer challenge.

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

Trigger an Egress release and production deploy:

```bash
make deploy-egress
```

Common Egress options:

```bash
make deploy-egress \
  EGRESS_REF=v26.709.1542
```

Build and publish the commit-addressed image without deployment:

```bash
make deploy-egress DEPLOY=false
```

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

The source repositories no longer need an Actions dispatch token. The local
`one-browser-action/.env` provides `GH_TOKEN` for workflow dispatch, while this
public action repository needs `ONE_BROWSER_ACTION_TOKEN` to checkout private
source repositories and publish its App Releases:

| Secret | Purpose |
| --- | --- |
| `ONE_BROWSER_ACTION_TOKEN` | PAT with source repository read access and `Contents: read/write` on `one-browser-action`. |

Server and Egress deploy secrets live in this public action repository because
the deploy jobs run here:

- `DEPLOY_HOST`
- `DEPLOY_USER`
- `DEPLOY_SSH_KEY`
- `DEPLOY_KNOWN_HOSTS`
- optional `DEPLOY_PORT`
- optional Server-only `DEPLOY_REMOTE_DIR`
- optional `GHCR_USERNAME`
- optional `GHCR_TOKEN`

Optional Egress deploy variables:

- `DEPLOY_EGRESS_ENDPOINT`, default `egress.aicbe.com:27600`
- `DEPLOY_EGRESS_CHECK=false` to skip the public TLS/H2 protocol readiness check
- `DEPLOY_EGRESS_LOG_TAIL` and `DEPLOY_EGRESS_LOG_FOLLOW_SECONDS`
- shared `DEPLOY_USE_SUDO=1` when the SSH user requires sudo for Docker

`DEPLOY_CONTROL_NETWORK` is shared by the Server and Egress workflows and
defaults to `one-browser-control`; both deployments must use the same value.

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

The Egress process requires `EGRESS_CONTROL_URL` and a dedicated
`EGRESS_CONTROL_TOKEN` of at least 32 bytes; the production Compose environment
also publishes TCP port `27600` explicitly. Store the same token in the Server
`.env`; never reuse `APP_SECRET` or `PROXY_CREDENTIAL_KEY`. The Server and Egress
Compose projects must join the external `one-browser-control` Docker network.
Create that network once before either service deploys:

```dotenv
EGRESS_CONTROL_URL=http://one-browser-server:27512
EGRESS_CONTROL_TOKEN=<same independent random value used by Server>
EGRESS_PUBLISH_ADDR=0.0.0.0
EGRESS_HOST_PORT=27600
```

```bash
docker network inspect one-browser-control >/dev/null 2>&1 || \
  docker network create one-browser-control
```

The Egress workflow requires `/opt/one-browser-egress` and its `.env` to exist.
Its source-owned deployment script preserves `.env` and `certs/`, deploys the
commit-addressed image, waits for container health, and then the Action checks the
public H2 protocol signature. A trusted certificate by itself is insufficient:
the `407` Bearer response proves public TCP port `27600` reached the Egress
service.

Certbot renewal, its deploy hook, the DNS-only A record, and inbound TCP `27600`
firewall policy remain host provisioning. Routine Egress releases do not edit
DNS, firewall rules, existing Nginx `443` sites, or issue certificates.
`egress.aicbe.com` must remain DNS only unless a compatible layer-4 service is
introduced. The workflow's public TLS/H2 check happens after the container
deployment; it reports a failed deployment but intentionally does not rewrite
host network policy or roll the container back for a public-routing error.

## Trigger Note

`make push-tag` in each source repository stops immediately if the tag push
fails. After a successful push it invokes the matching local deploy target with
the current source commit SHA. A later dispatch failure does not roll back the
already-pushed Git tag.
