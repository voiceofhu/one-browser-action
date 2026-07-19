#!/usr/bin/env bash

set -Eeuo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: inspect-egress-image.sh <registry/image:tag>" >&2
  exit 1
fi

image_ref="$1"
manifest_file="$(mktemp)"
error_file="$(mktemp)"
cleanup() {
  rm -f "$manifest_file" "$error_file"
}
trap cleanup EXIT

if ! docker buildx imagetools inspect --raw "$image_ref" \
  >"$manifest_file" 2>"$error_file"; then
  error_text="$(tr '[:upper:]' '[:lower:]' <"$error_file")"
  if [[ "$error_text" == *"manifest unknown"* ||
        "$error_text" == *"name unknown"* ||
        "$error_text" == *"no such manifest"* ||
        "$error_text" == *": not found"* ||
        "$error_text" == *"404 not found"* ]]; then
    echo "Image does not exist: $image_ref"
    exit 2
  fi

  echo "Failed to inspect $image_ref; refusing to treat the error as a missing image." >&2
  cat "$error_file" >&2
  exit 1
fi

if ! jq -e '
  [
    .manifests[]?
    | select(.platform.os == "linux")
    | .platform.architecture
  ] as $architectures
  | ($architectures | index("amd64") != null)
    and ($architectures | index("arm64") != null)
' "$manifest_file" >/dev/null; then
  echo "$image_ref is not a valid linux/amd64 + linux/arm64 image index." >&2
  exit 1
fi

echo "Validated multi-platform image $image_ref"
