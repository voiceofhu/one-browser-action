# one-browser-action

Public GitHub Actions entrypoint for One Browser builds.

This repository owns the release/deploy workflows. The source repositories can
stay private:

- `voiceofhu/one-browser-server`
- `voiceofhu/one-browser-app`
- `voiceofhu/one-browser-web`

## Recommended Shape

Keep source repositories private, but run the heavy CI/CD implementation here.
Private source repositories keep only thin tag-trigger workflows that send
`repository_dispatch` events to this repository.

For server releases, `one-browser-server` pushes a tag and dispatches
`server-release` to this repository:

```yaml
on:
  push:
    tags:
      - "v*.*.*"

jobs:
  dispatch:
    runs-on: ubuntu-latest
    steps:
      - run: gh api --method POST repos/voiceofhu/one-browser-action/dispatches ...
```

For app releases, `one-browser-app` pushes a tag and dispatches `app-release`
to this repository. This repository then checks out the private app repository,
builds installers, and publishes them to this repository's public GitHub
Release.

## Workflows

### Server Deploy

File: `.github/workflows/server.yml`

This workflow receives server release events and runs in this repository. It
resolves the server revision, checks whether the matching GHCR image already
exists, and only builds/deploys when the run is forced or the server commit has
not been built yet.

Triggers:

- `repository_dispatch`: `server-release`
- `workflow_dispatch`: manual deploy

Build inputs:

- `server_repository`: server repository, default `voiceofhu/one-browser-server`
- `server_ref`: server branch/tag/sha, default `main`
- `version_tag`: image version tag. Empty means latest server tag from GitHub API
- `web_repository`: web repository, default `voiceofhu/one-browser-web`
- `web_ref`: web branch/tag/sha, default `main`
- `image_name`: GHCR image name without `ghcr.io/`
- `force`: rebuild even if `sha-<server_sha>` already exists
- `deploy`: deploy after publishing the image

The workflow:

1. Reads the server commit and latest server tag through the GitHub API.
2. Checks out `one-browser-server`.
3. Checks out `one-browser-web` into the server frontend build directory.
4. Runs the server repo's existing `.github/scripts/build-frontend-dist.sh`.
5. Builds and pushes multi-platform Docker images.
6. Runs the server repo's existing Docker Compose deploy scripts.

Image tags pushed:

- `sha-<server_sha>`
- latest server tag, for example `v26.709.1542`
- `latest`

### App Release

File: `.github/workflows/app.yml`

This workflow receives app release events and runs in this repository. It checks
out the app commit from the private source repository, validates that the source
tag matches `one-browser-app/package.json`, builds the desktop bundles, and
uploads assets to the release in this public repository.

Triggers:

- `repository_dispatch`: `app-release`
- `workflow_dispatch`: manual app release

## Secrets

The private source repositories need `ONE_BROWSER_ACTION_TOKEN` only for their
thin dispatch workflows. The token must be able to call
`repos/voiceofhu/one-browser-action/dispatches`.

This public action repository needs `ONE_BROWSER_ACTION_TOKEN` to checkout the
private source repositories:

| Secret | Purpose |
| --- | --- |
| `ONE_BROWSER_ACTION_TOKEN` | Fine-grained PAT that can read the private source repositories. |

Server deploy secrets now live in this public action repository because the
deploy job runs here:

- `DEPLOY_HOST`
- `DEPLOY_USER`
- `DEPLOY_SSH_KEY`
- `DEPLOY_KNOWN_HOSTS`
- optional `DEPLOY_PORT`
- optional `DEPLOY_REMOTE_DIR`
- optional `GHCR_USERNAME`
- optional `GHCR_TOKEN`

## Trigger Note

A workflow in this repository cannot directly receive `push` events from a
different repository. The private source repositories handle that by keeping
thin tag-trigger workflows that call GitHub's repository dispatch API. The real
server/app release jobs then run in this repository.
