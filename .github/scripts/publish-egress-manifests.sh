#!/usr/bin/env bash

set -Eeuo pipefail

: "${IMAGE:?IMAGE is required}"
: "${IMAGE_REVISION_TAG:?IMAGE_REVISION_TAG is required}"
: "${IMAGE_BUILD_TAG:?IMAGE_BUILD_TAG is required}"

should_build="${SHOULD_BUILD:-false}"
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
      -t "$revision_ref" \
      "$IMAGE:$IMAGE_BUILD_TAG-amd64" \
      "$IMAGE:$IMAGE_BUILD_TAG-arm64"
    bash "$inspect_script" "$revision_ref"
  fi
else
  bash "$inspect_script" "$revision_ref"
fi

echo "Published commit-addressed image $revision_ref"

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
