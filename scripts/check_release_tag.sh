#!/usr/bin/env bash
# Usage: scripts/check_release_tag.sh <tag>
#
# A release build embeds its tag (DROPDRAWER_RELEASE_TAG) so in-app updates can
# compare it with GitHub releases. The tag must be v<pubspec version> or
# v<pubspec version>-<prerelease>, e.g. v0.2.0 or v0.2.0-preview.1.
set -euo pipefail

tag="${1:-}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(sed -n 's/^version:[[:space:]]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' "$root/app/pubspec.yaml" | head -n 1)"

if [[ -z "$version" ]]; then
  echo "error: cannot read the version from app/pubspec.yaml" >&2
  exit 1
fi
pattern="^v${version//./\\.}(-[0-9A-Za-z.-]+)?$"
if [[ ! "$tag" =~ $pattern ]]; then
  echo "error: release tag '$tag' does not match app/pubspec.yaml version $version" >&2
  echo "       use v$version or v$version-<prerelease>, or update app/pubspec.yaml first" >&2
  exit 1
fi
rust_version="$(sed -n '/^\[workspace.package\]$/,/^\[/s/^version = "\([^"]*\)"$/\1/p' "$root/Cargo.toml")"
if [[ "$rust_version" != "$version" ]]; then
  echo "error: Cargo.toml workspace version ($rust_version) does not match app/pubspec.yaml ($version)" >&2
  exit 1
fi
if [[ -f "$root/apple/project.yml" ]]; then
  apple_version="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)"\{0,1\}.*/\1/p' "$root/apple/project.yml" | head -n 1)"
  if [[ -n "$apple_version" && "$apple_version" != "$version" ]]; then
    echo "error: apple/project.yml MARKETING_VERSION ($apple_version) does not match app/pubspec.yaml ($version)" >&2
    exit 1
  fi
fi
echo "Release tag $tag matches version $version"
