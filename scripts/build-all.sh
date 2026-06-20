#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

source_dir=
version=
release_date=
out_dir=dist/debian
maintainer="STM32MP2 GPU Packaging <noreply@example.invalid>"

usage() {
    cat <<'USAGE'
Usage: build-all.sh --source DIR --version VERSION --userland-date YYYYMMDD [options]
  --source DIR
  --version VERSION
  --userland-date YYYYMMDD
  --out DIR
  --maintainer VALUE
USAGE
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source) source_dir="$2"; shift 2 ;;
        --version) version="$2"; shift 2 ;;
        --userland-date) release_date="$2"; shift 2 ;;
        --out) out_dir="$2"; shift 2 ;;
        --maintainer) maintainer="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[[ -n "$source_dir" && -n "$version" && -n "$release_date" ]] || { usage >&2; exit 64; }

mkdir -p "$out_dir"
"$SCRIPT_DIR/build-dkms.sh" --source "$source_dir" --version "$version" --date "$release_date" \
    --out "$out_dir" --maintainer "$maintainer"
"$SCRIPT_DIR/build-userspace.sh" --source "$source_dir" --version "$version" --date "$release_date" \
    --out "$out_dir" --maintainer "$maintainer"
"$SCRIPT_DIR/build-meta.sh" --version "$version" --date "$release_date" \
    --out "$out_dir" --maintainer "$maintainer"
