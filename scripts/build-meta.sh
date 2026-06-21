#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

version=
release_date=
out_dir=dist/debian
maintainer="STM32MP2 GPU Packaging <noreply@example.invalid>"

usage() {
    cat <<'USAGE'
Usage: build-meta.sh --version VERSION --date YYYYMMDD [options]
  --version VERSION
  --date YYYYMMDD
  --out DIR
  --maintainer VALUE
USAGE
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) version="$2"; shift 2 ;;
        --date) release_date="$2"; shift 2 ;;
        --out) out_dir="$2"; shift 2 ;;
        --maintainer) maintainer="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[[ -n "$version" && -n "$release_date" ]] || { usage >&2; exit 64; }
safe_version "$version"
safe_date "$release_date"
need dpkg-deb

out_dir="$(mkdir -p "$out_dir" && cd "$out_dir" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pkgver="$(package_version "$version" "$release_date")"
mkdir -p "$work/root/DEBIAN" "$work/root/usr/share/doc/stm32mp2-gpu-driver"

cat > "$work/root/DEBIAN/control" <<CONTROL
Package: stm32mp2-gpu-driver
Version: ${pkgver}
Section: metapackages
Priority: optional
Architecture: all
Maintainer: ${maintainer}
Depends: stm32mp2-gpu-dkms (= ${pkgver}), stm32mp2-gpu-userspace (= ${pkgver})
Recommends: stm32mp2-gpu-full (= ${pkgver})
Description: Meta-package for the STM32MP2 Vivante GCNANO driver stack
 This package installs a matched STM32MP2 DKMS galcore module source package and
 the matching ST GCNANO arm64 user-space driver payload.
CONTROL

cat > "$work/root/usr/share/doc/stm32mp2-gpu-driver/README.Debian" <<DOC
Install matching kernel headers before installing or rebuilding the DKMS module:

  sudo apt install linux-headers-\$(uname -r)
  sudo dkms autoinstall

The stack is STM32MP2-specific. It cannot add missing GPU hardware support to a
kernel, device tree, clock/power domain configuration, or CMA reservation.
DOC

package="$out_dir/stm32mp2-gpu-driver_${pkgver}_all.deb"
dpkg-deb --root-owner-group --build "$work/root" "$package" >/dev/null
dpkg-deb -I "$package" >/dev/null
printf '%s\n' "$package"
