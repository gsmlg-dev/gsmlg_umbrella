#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || "$1" == -* ]]; then
  echo "Usage: scripts/prepare_release.sh VERSION" >&2
  exit 1
fi

version="$1"
tag="v$version"
if [[ ! "$tag" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]]; then
  echo "Release version must form a Docker-compatible vVERSION tag of at most 128 characters (no build metadata)." >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "$script_dir/.." && pwd)"

if [[ -n "$(git -C "$root" status --porcelain)" ]]; then
  echo "Release preparation requires a clean checkout." >&2
  exit 1
fi

bash "$script_dir/update_version.sh" "$version"

files=(mix.exs)
for app_file in "$root"/apps/*/mix.exs; do
  if [[ -f "$app_file" ]]; then
    files+=("${app_file#"$root"/}")
  fi
done
git -C "$root" add -- "${files[@]}"

source_tree="$(git -C "$root" write-tree)"

if git -C "$root" show-ref --verify --quiet "refs/tags/$tag"; then
  tag_tree="$(git -C "$root" rev-parse "refs/tags/$tag^{tree}")"
  if [[ "$source_tree" != "$tag_tree" ]]; then
    echo "Tag $tag already exists with a different source tree." >&2
    exit 1
  fi
  sha="$(git -C "$root" rev-parse "refs/tags/$tag^{commit}")"
else
  if ! git -C "$root" diff --cached --quiet; then
    git -C "$root" commit -m "chore(release): $version"
  fi
  sha="$(git -C "$root" rev-parse HEAD)"
  git -C "$root" tag -a "$tag" "$sha" -m "Release $version"
fi

git -C "$root" push origin "refs/tags/$tag:refs/tags/$tag"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'sha=%s\n' "$sha" >> "$GITHUB_OUTPUT"
fi
printf 'Prepared %s at %s\n' "$tag" "$sha"
