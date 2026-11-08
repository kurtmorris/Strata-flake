#!/usr/bin/env bash
# Move the flake to Strata's latest release: the strata input, `version`, the
# llama-cpp input (the commit that release's CMakeLists.txt pins) and models.json.
#
# Usage: scripts/update-strata.sh [TAG]   (default: the latest release)
# Prints the new tag, or nothing when the flake is already on it. Needs curl, jq, nix.
set -euo pipefail
cd "$(dirname "$0")/.."

repo=niko1221/strata
api() {
  curl -fsSL -H "Accept: application/vnd.github+json" \
    ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} "https://api.github.com/repos/$1"
}

tag=${1:-$(api "$repo/releases/latest" | jq -r .tag_name)}
current=$(sed -nE 's|.*url = "github:niko1221/strata/([^"]+)";|\1|p' flake.nix)
if [ "$tag" = "$current" ]; then
  exit 0
fi

cmake=$(api "$repo/contents/CMakeLists.txt?ref=$tag" | jq -r .content | base64 -d)
llama=$(grep -oE 'GIT_TAG [0-9a-f]{40}' <<<"$cmake" | head -1 | cut -d' ' -f2)
[ -n "$llama" ] || { echo "no llama.cpp commit in $tag's CMakeLists.txt" >&2; exit 1; }

sed -i -E \
  -e "s|(url = \"github:niko1221/strata/)[^\"]+\";|\1$tag\";|" \
  -e "s|(url = \"github:ggml-org/llama.cpp/)[0-9a-f]{40}\";|\1$llama\";|" \
  -e "s|^(      version = \")[^\"]+\";|\1${tag#v}\";|" \
  flake.nix
nix flake update strata llama-cpp >&2

# The model catalogue (files, sizes, SHA-256s) from the new release's setup.py.
src=$(nix flake archive --json | jq -r .inputs.strata.path)
nix shell nixpkgs#python3 -c python3 scripts/gen-models.py "$src" > models.json

echo "$tag"
