#!/usr/bin/env bash

set -Eeuo pipefail

: "${IMAGE:?IMAGE is required}"
: "${IMAGE_REVISION_TAG:?IMAGE_REVISION_TAG is required}"
: "${IMAGE_VERSION:?IMAGE_VERSION is required}"
: "${IMAGE_BUILD_TAG:?IMAGE_BUILD_TAG is required}"
: "${IMAGE_SOURCE:?IMAGE_SOURCE is required}"
: "${IMAGE_DESCRIPTION:?IMAGE_DESCRIPTION is required}"
: "${IMAGE_REVISION:?IMAGE_REVISION is required}"

should_build="${SHOULD_BUILD:-false}"
publish_latest="${PUBLISH_LATEST:-false}"
revision_ref="$IMAGE:$IMAGE_REVISION_TAG"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
inspect_script="$script_dir/inspect-egress-image.sh"

inspect_revision() {
  if bash "$inspect_script" "$revision_ref"; then
    return 0
  else
    return $?
  fi
}

if [ "$should_build" = "true" ]; then
  if inspect_revision; then
    echo "$revision_ref was published by an earlier queued run; keeping it unchanged."
  else
    status=$?
    if [ "$status" -ne 2 ]; then
      exit "$status"
    fi
    docker buildx imagetools create \
      --annotation "index:org.opencontainers.image.description=$IMAGE_DESCRIPTION" \
      --annotation "index:org.opencontainers.image.revision=$IMAGE_REVISION" \
      --annotation "index:org.opencontainers.image.source=$IMAGE_SOURCE" \
      --annotation "index:org.opencontainers.image.version=$IMAGE_REVISION_TAG" \
      -t "$revision_ref" \
      "$IMAGE:$IMAGE_BUILD_TAG-amd64" \
      "$IMAGE:$IMAGE_BUILD_TAG-arm64"
    bash "$inspect_script" "$revision_ref"
  fi
else
  bash "$inspect_script" "$revision_ref"
fi

echo "Published commit-addressed image $revision_ref"

alias_args=(-t "$IMAGE:$IMAGE_VERSION")
if [ "$publish_latest" = true ]; then
  alias_args+=(-t "$IMAGE:latest")
fi
docker buildx imagetools create \
  --annotation "index:org.opencontainers.image.description=$IMAGE_DESCRIPTION" \
  --annotation "index:org.opencontainers.image.revision=$IMAGE_REVISION" \
  --annotation "index:org.opencontainers.image.source=$IMAGE_SOURCE" \
  --annotation "index:org.opencontainers.image.version=$IMAGE_VERSION" \
  "${alias_args[@]}" \
  "$revision_ref"

echo "Published install image $IMAGE:$IMAGE_VERSION"
if [ "$publish_latest" = true ]; then
  echo "Published default install image $IMAGE:latest"
fi

manifest_json=$(docker buildx imagetools inspect \
  "$revision_ref" \
  --format '{{json .Manifest}}')
image_digest=$(jq -er '
  .digest
  | select(type == "string" and test("^sha256:[a-f0-9]{64}$"))
' <<<"$manifest_json")
image_pinned_ref="$IMAGE@$image_digest"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'image_pinned_ref=%s\n' "$image_pinned_ref" >> "$GITHUB_OUTPUT"
fi

echo "Pinned deploy image $image_pinned_ref"
