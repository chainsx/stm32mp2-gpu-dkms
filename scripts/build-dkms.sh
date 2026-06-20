#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

source_dir=
version=
release_date=
out_dir=dist/debian
maintainer="STM32MP2 GPU Packaging <noreply@example.invalid>"

usage() {
    cat <<'USAGE'
Usage: build-dkms.sh --source DIR --version VERSION --date YYYYMMDD [options]
  --source DIR          gcnano-binaries checkout
  --version VERSION     GCNANO release version
  --date YYYYMMDD       STM32MP2 user-space release date; forms the package revision
  --out DIR             Output directory; default: dist/debian
  --maintainer VALUE    Debian Maintainer field
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source) source_dir="$2"; shift 2 ;;
        --version) version="$2"; shift 2 ;;
        --date) release_date="$2"; shift 2 ;;
        --out) out_dir="$2"; shift 2 ;;
        --maintainer) maintainer="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -n "$source_dir" && -n "$version" && -n "$release_date" ]] || { usage >&2; exit 64; }
safe_version "$version"
safe_date "$release_date"
need dpkg-deb
need sed

driver="$source_dir/gcnano-driver-stm32mp"
test -f "$driver/Makefile" || die "driver Makefile not found: $driver/Makefile"
test -f "$driver/Kbuild" || die "driver Kbuild not found: $driver/Kbuild"

out_dir="$(mkdir -p "$out_dir" && cd "$out_dir" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pkgroot="$work/root"
pkgver="$(package_version "$version" "$release_date")"
dkmsver="$(dkms_version "$version" "$release_date")"
source_name="stm32mp2-gpu-${dkmsver}"

mkdir -p "$pkgroot/DEBIAN" "$pkgroot/usr/src" "$pkgroot/etc/dkms" \
    "$pkgroot/usr/sbin" "$pkgroot/usr/share/doc/stm32mp2-gpu-dkms"
cp -a "$driver" "$pkgroot/usr/src/$source_name"
rm -rf "$pkgroot/usr/src/$source_name/.git"

sed "s/@DKMS_VERSION@/$dkmsver/g" "$ROOT/packaging/dkms/dkms.conf.in" \
    > "$pkgroot/usr/src/$source_name/dkms.conf"
install -m 0755 "$ROOT/packaging/dkms/dkms-make.sh" \
    "$pkgroot/usr/src/$source_name/dkms-make.sh"
install -m 0644 "$ROOT/packaging/dkms/stm32mp2-gpu.conf" \
    "$pkgroot/etc/dkms/stm32mp2-gpu.conf"
install -m 0644 "$ROOT/packaging/dkms/README.Debian" \
    "$pkgroot/usr/share/doc/stm32mp2-gpu-dkms/README.Debian"

# Install the explicit rebuild utility before postinst is run.  It keeps the
# module package observable: current packages must never silently swallow a
# DKMS compiler failure.
sed "s/@DKMS_VERSION@/$dkmsver/g" \
    "$ROOT/packaging/dkms/stm32mp2-gpu-dkms-rebuild.in" \
    > "$pkgroot/usr/sbin/stm32mp2-gpu-dkms-rebuild"
chmod 0755 "$pkgroot/usr/sbin/stm32mp2-gpu-dkms-rebuild"

license_file="$(first_license_file "$source_dir" || true)"
if [[ -n "$license_file" ]]; then
    install -m 0644 "$license_file" "$pkgroot/usr/share/doc/stm32mp2-gpu-dkms/upstream-license-reference.txt"
fi
upstream_commit="$(get_upstream_commit "$source_dir")"
printf '%s\n' "$upstream_commit" > "$pkgroot/usr/share/doc/stm32mp2-gpu-dkms/upstream-commit.txt"
printf '%s\n' 'https://github.com/STMicroelectronics/gcnano-binaries' \
    > "$pkgroot/usr/share/doc/stm32mp2-gpu-dkms/upstream-url.txt"

cat > "$pkgroot/DEBIAN/control" <<CONTROL
Package: stm32mp2-gpu-dkms
Version: ${pkgver}
Section: kernel
Priority: optional
Architecture: all
Maintainer: ${maintainer}
Depends: dkms (>= 2.8.4), kmod, make, gcc
Conflicts: gcnano-dkms
Replaces: gcnano-dkms
Description: STM32MP2 Vivante GCNANO galcore module source for DKMS
 This package contains ST's GCNANO galcore module source and registers it with
 DKMS. It builds only on arm64 and always targets SOC_PLATFORM=st-mp2.
 It requires matching kernel headers and an STM32MP2 GPU-enabled kernel/device tree.
CONTROL

sed "s/@DKMS_VERSION@/$dkmsver/g" \
    "$ROOT/packaging/dkms/postinst.in" \
    > "$pkgroot/DEBIAN/postinst"
chmod 0755 "$pkgroot/DEBIAN/postinst"

cat > "$pkgroot/DEBIAN/postrm" <<POSTRM
#!/bin/sh
set -e
if [ "\$1" = remove ] || [ "\$1" = purge ]; then
    if command -v dkms >/dev/null 2>&1; then
        dkms remove -m stm32mp2-gpu -v '${dkmsver}' --all >/dev/null 2>&1 || true
    fi
fi
exit 0
POSTRM
chmod 0755 "$pkgroot/DEBIAN/postrm"

package="$out_dir/stm32mp2-gpu-dkms_${pkgver}_all.deb"
dpkg-deb --root-owner-group --build "$pkgroot" "$package" >/dev/null
dpkg-deb -I "$package" >/dev/null
printf '%s\n' "$package"
