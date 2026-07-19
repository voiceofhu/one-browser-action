#!/usr/bin/env bash

set -Eeuo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${REGISTRY:?REGISTRY is required}"
: "${EGRESS_REPOSITORY:?EGRESS_REPOSITORY is required}"
: "${IMAGE_NAME:?IMAGE_NAME is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}"

egress_repository="$EGRESS_REPOSITORY"
egress_ref="${EGRESS_REF_INPUT:-}"
image_name="$IMAGE_NAME"
image_name="$(printf '%s' "$image_name" | tr '[:upper:]' '[:lower:]')"
deploy="${DEPLOY_INPUT:-true}"

if [[ ! "$egress_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "Invalid Egress repository: $egress_repository" >&2
  exit 1
fi
if [[ ! "$image_name" =~ ^[a-z0-9][a-z0-9._/-]*$ ]]; then
  echo "Invalid GHCR image name: $image_name" >&2
  exit 1
fi

if [ -z "$egress_ref" ]; then
  egress_ref="$(gh api "repos/$egress_repository" --jq .default_branch)"
fi
if [[ "$egress_ref" == *$'\n'* || "$egress_ref" == *$'\r'* ]]; then
  echo "Egress ref must not contain newlines." >&2
  exit 1
fi
encoded_ref="$(jq -rn --arg value "$egress_ref" '$value | @uri')"
egress_sha="$(gh api "repos/$egress_repository/commits/$encoded_ref" --jq .sha)"
image_revision_tag="sha-$egress_sha"
image_build_tag="build-$egress_sha-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
case "$deploy" in
  true|1|yes) deploy=true ;;
  *) deploy=false ;;
esac

{
  echo "egress_repository=$egress_repository"
  echo "egress_sha=$egress_sha"
  echo "image_ref=$REGISTRY/$image_name"
  echo "image_revision_tag=$image_revision_tag"
  echo "image_build_tag=$image_build_tag"
  echo "deploy=$deploy"
} >> "$GITHUB_OUTPUT"

printf 'egress %s -> %s\n' "$egress_ref" "$egress_sha"
printf 'image  %s:%s\n' "$REGISTRY/$image_name" "$image_revision_tag"
