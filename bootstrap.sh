#!/bin/sh
# One step from a bare machine to a synced, tooled workspace, on Linux and macOS:
#
#   curl -fsSL https://raw.githubusercontent.com/V-Sekai-fire/contract-manifest-weftspun/main/main/bootstrap.sh | sh
#
# Runs in the current directory, which becomes the repo client root.
set -eu

raw=${WEFTSPUN_RAW:-https://raw.githubusercontent.com/V-Sekai-fire/contract-manifest-weftspun/main/main}
manifest=${WEFTSPUN_MANIFEST:-https://github.com/V-Sekai-fire/contract-manifest-weftspun.git}
branch=${WEFTSPUN_BRANCH:-main/main}
bin="${LOCAL_BIN:-$HOME/.local/bin}"
pixi_bin="${PIXI_HOME:-$HOME/.pixi}/bin"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# 1. The pins, over the CDN, which is the one fetch nothing on disk can vouch for yet.
curl -fsSL -o "$work/pins" "$raw/bootstrap-pins.txt"
repo_source=$(awk '$1=="repo" && $2=="source"{print $3}' "$work/pins")
repo_sha=$(awk '$1=="repo" && $2=="sha256"{print $3}' "$work/pins")

# 2. The pinned repo launcher.
curl -fsSL -o "$work/repo" "$repo_source"
got=$(sha_of "$work/repo")
[ "$got" = "$repo_sha" ] || { echo "checksum mismatch for the repo launcher: got $got, pinned $repo_sha" >&2; exit 1; }
mkdir -p "$bin"
install -m 0755 "$work/repo" "$bin/repo"
PATH="$bin:$PATH"
export PATH

# 3. The manifest, over git, which is what makes the pins trustworthy.
#    The heavy Hugging Face projects are git-lfs, and repo leaves LFS content as
#    pointer files unless --git-lfs asked for it, so the default sync is metadata
#    only; set WEFTSPUN_GIT_LFS=1 to pull the blobs too, tens of gigabytes of them.
repo init ${WEFTSPUN_GIT_LFS:+--git-lfs} -u "$manifest" -b "$branch"

# 4. The CDN copy against the git copy. A difference means the pins that chose the
#    launcher in step 2 were not the pins this repository holds.
if ! cmp -s "$work/pins" .repo/manifests/bootstrap-pins.txt; then
  echo "the pins served by $raw differ from the ones in the manifest repository" >&2
  exit 1
fi

# 5. pixi, from the pins now on disk, then the whole workspace.
sh .repo/manifests/install.sh
repo sync
PATH="$pixi_bin:$PATH"
export PATH
pixi install --manifest-path .repo/manifests/pixi.toml --all

echo
echo "Workspace ready. Add these to PATH: $bin $pixi_bin"
