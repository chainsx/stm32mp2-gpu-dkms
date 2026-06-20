#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

source_dir=
packages=
out=
branch=

usage() {
    cat <<'USAGE'
Usage: make-manifest.sh --source DIR --packages DIR --out FILE --branch NAME
USAGE
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source) source_dir="$2"; shift 2 ;;
        --packages) packages="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        --branch) branch="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[[ -n "$source_dir" && -n "$packages" && -n "$out" && -n "$branch" ]] || { usage >&2; exit 64; }
need sha256sum

mkdir -p "$(dirname -- "$out")"
{
    printf 'Upstream URL: https://github.com/STMicroelectronics/gcnano-binaries\n'
    printf 'Upstream branch: %s\n' "$branch"
    printf 'Upstream commit: %s\n' "$(get_upstream_commit "$source_dir")"
    printf 'Generated UTC: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '\nSHA256:\n'
    (cd "$packages" && sha256sum ./*.deb)
} > "$out"
