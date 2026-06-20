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
Usage: build-userspace.sh --source DIR --version VERSION --date YYYYMMDD [options]
  --source DIR          gcnano-binaries checkout
  --version VERSION     GCNANO release version
  --date YYYYMMDD       STM32MP2 user-space installer build date
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
need readelf
need find

installer="$source_dir/gcnano-userland-multi-stm32mp2-${version}-${release_date}.bin"
test -f "$installer" || die "STM32MP2 user-space installer not found: $installer"

out_dir="$(mkdir -p "$out_dir" && cd "$out_dir" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$installer" "$work/installer.bin"
chmod 0755 "$work/installer.bin"

# ST's matching OpenSTLinux recipe executes this installer as a shell
# self-extractor with --auto-accept. It is not an ARM executable.
(
    cd "$work"
    sh ./installer.bin --auto-accept
)

extract_root="$(find "$work" -mindepth 1 -maxdepth 1 -type d -name 'gcnano-userland-multi-stm32mp2-*' -print \
    | LC_ALL=C sort | head -n 1 || true)"
[[ -n "$extract_root" ]] || die "installer did not create gcnano-userland-multi-stm32mp2-*"
lib_source="$extract_root/release/drivers"
test -d "$lib_source" || die "installer lacks release/drivers: $extract_root"

sample_elf="$(find -L "$lib_source" -maxdepth 1 -type f -name 'libGAL.so*' -print | LC_ALL=C sort | head -n 1 || true)"
[[ -n "$sample_elf" ]] || die "release/drivers lacks libGAL.so"
readelf -h "$sample_elf" | grep -Eq 'Machine:.*AArch64' \
    || die "unexpected user-space architecture; expected AArch64"

pkgroot="$work/pkgroot"
pkgver="$(package_version "$version" "$release_date")"
libdir=/usr/lib/aarch64-linux-gnu/stm32mp2-gpu
mkdir -p "$pkgroot/DEBIAN" "$pkgroot$libdir" "$pkgroot/etc/ld.so.conf.d" \
    "$pkgroot/usr/bin" "$pkgroot/usr/share/doc/stm32mp2-gpu-userspace"

# Keep the ST payload outside the generic multiarch library directory. The
# explicit ld.so entry makes the vendor stack discoverable without overwriting
# Debian/Ubuntu Mesa-owned files.
cp -a "$lib_source"/. "$pkgroot$libdir/"
printf '%s\n' "$libdir" > "$pkgroot/etc/ld.so.conf.d/00-stm32mp2-gpu.conf"
sed "s|@LIBDIR@|$libdir|g" "$ROOT/packaging/userspace/gcnano-env.in" \
    > "$pkgroot/usr/bin/stm32mp2-gpu-env"
chmod 0755 "$pkgroot/usr/bin/stm32mp2-gpu-env"

upstream_commit="$(get_upstream_commit "$source_dir")"
sed -e "s|@LIBDIR@|$libdir|g" \
    -e "s|@INSTALLER@|$(basename "$installer")|g" \
    -e "s|@UPSTREAM_COMMIT@|$upstream_commit|g" \
    "$ROOT/packaging/userspace/README.Debian.in" \
    > "$pkgroot/usr/share/doc/stm32mp2-gpu-userspace/README.Debian"
install -m 0644 "$ROOT/packaging/userspace/copyright.in" \
    "$pkgroot/usr/share/doc/stm32mp2-gpu-userspace/copyright"
printf '%s\n' "$upstream_commit" > "$pkgroot/usr/share/doc/stm32mp2-gpu-userspace/upstream-commit.txt"
printf '%s\n' 'https://github.com/STMicroelectronics/gcnano-binaries' \
    > "$pkgroot/usr/share/doc/stm32mp2-gpu-userspace/upstream-url.txt"
license_file="$(first_license_file "$extract_root" || true)"
if [[ -z "$license_file" ]]; then
    license_file="$(first_license_file "$source_dir" || true)"
fi
if [[ -n "$license_file" ]]; then
    install -m 0644 "$license_file" \
        "$pkgroot/usr/share/doc/stm32mp2-gpu-userspace/upstream-license-or-eula.txt"
fi

# The OpenSTLinux recipe emits an ICD only when the matching runtime library is
# present. Do the same rather than claiming support unconditionally.
opencl_lib="$(find "$pkgroot$libdir" -maxdepth 1 -type f -name 'libOpenCL*.so*' -printf '%f\n' \
    | LC_ALL=C sort | head -n 1 || true)"
if [[ -n "$opencl_lib" ]]; then
    mkdir -p "$pkgroot/etc/OpenCL/vendors"
    printf '%s/%s\n' "$libdir" "$opencl_lib" \
        > "$pkgroot/etc/OpenCL/vendors/stm32mp2-gcnano.icd"
fi

vulkan_lib="$(find "$pkgroot$libdir" -maxdepth 1 -type f -name 'libvulkan*.so*' -printf '%f\n' \
    | LC_ALL=C sort | head -n 1 || true)"
if [[ -n "$vulkan_lib" ]]; then
    vkver="${vulkan_lib#*.so.}"
    [[ "$vkver" != "$vulkan_lib" ]] || vkver=1.0.0
    mkdir -p "$pkgroot/etc/vulkan/icd.d"
    cat > "$pkgroot/etc/vulkan/icd.d/stm32mp2-gcnano.json" <<VULKAN
{
  "file_format_version": "1.0.0",
  "ICD": {
    "library_path": "${libdir}/${vulkan_lib}",
    "api_version": "${vkver}"
  }
}
VULKAN
fi

cat > "$pkgroot/DEBIAN/control" <<CONTROL
Package: stm32mp2-gpu-userspace
Version: ${pkgver}
Section: libs
Priority: optional
Architecture: arm64
Multi-Arch: same
Maintainer: ${maintainer}
Depends: libc6, libdrm2
Recommends: libwayland-client0, libwayland-egl1
Conflicts: gcnano-userland
Replaces: gcnano-userland
Provides: gcnano-userspace, gcnano-egl, gcnano-gles, gcnano-vivante-userspace
Description: STM32MP2 Vivante GCNANO proprietary user-space driver stack
 This package contains ST-supplied arm64 GCNANO user-space libraries for STM32MP2.
 It requires a compatible galcore kernel module and STM32MP2 GPU platform support.
 The payload is subject to the upstream ST license/EULA.
CONTROL

cat > "$pkgroot/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if command -v ldconfig >/dev/null 2>&1; then
    ldconfig
fi
exit 0
POSTINST
chmod 0755 "$pkgroot/DEBIAN/postinst"

cat > "$pkgroot/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
if command -v ldconfig >/dev/null 2>&1; then
    ldconfig
fi
exit 0
POSTRM
chmod 0755 "$pkgroot/DEBIAN/postrm"

package="$out_dir/stm32mp2-gpu-userspace_${pkgver}_arm64.deb"
dpkg-deb --root-owner-group --build "$pkgroot" "$package" >/dev/null
dpkg-deb -I "$package" >/dev/null
printf '%s\n' "$package"
