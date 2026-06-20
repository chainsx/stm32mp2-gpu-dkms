#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

version=6.4.21
dest=upstream
upstream_url=https://github.com/STMicroelectronics/gcnano-binaries.git
commit=

usage() {
    cat <<'USAGE'
Usage: fetch-upstream.sh [options]
  --version VERSION     GCNANO release version; default: 6.4.21
  --dest DIRECTORY      Checkout target; default: upstream
  --url URL             Upstream Git URL
  --commit SHA          Optional exact upstream commit (recommended for release builds)
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) version="$2"; shift 2 ;;
        --dest) dest="$2"; shift 2 ;;
        --url) upstream_url="$2"; shift 2 ;;
        --commit) commit="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

safe_version "$version"
[[ ! -e "$dest" ]] || die "destination already exists: $dest"
need git

branch="gcnano-${version}-binaries"
if [[ -n "$commit" ]]; then
    [[ "$commit" =~ ^[0-9a-fA-F]{40}$ ]] || die "commit must be a 40-character Git SHA"
    git init -q "$dest"
    git -C "$dest" remote add origin "$upstream_url"
    git -C "$dest" fetch --depth 1 origin "$commit"
    git -C "$dest" checkout -q --detach FETCH_HEAD
else
    git clone --depth 1 --branch "$branch" "$upstream_url" "$dest"
fi

test -d "$dest/gcnano-driver-stm32mp" || die "upstream checkout lacks gcnano-driver-stm32mp"
installer="$dest/gcnano-userland-multi-stm32mp2-${version}-"
compgen -G "${installer}*.bin" >/dev/null || die "upstream checkout lacks a STM32MP2 user-space installer for $version"

resolved_commit="$(git -C "$dest" rev-parse HEAD)"
printf '%s\n' "$resolved_commit" > "$dest/.gcnano-upstream-commit"
printf 'branch=%s\ncommit=%s\nurl=%s\n' "$branch" "$resolved_commit" "$upstream_url" \
    > "$dest/.gcnano-upstream-origin"
printf 'Fetched %s at %s\n' "$branch" "$resolved_commit"
