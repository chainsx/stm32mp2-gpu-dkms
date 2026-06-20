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
need sort

installer="$source_dir/gcnano-userland-multi-stm32mp2-${version}-${release_date}.bin"
test -f "$installer" || die "STM32MP2 user-space installer not found: $installer"

out_dir="$(mkdir -p "$out_dir" && cd "$out_dir" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$installer" "$work/installer.bin"
chmod 0755 "$work/installer.bin"

# This exactly matches the OpenSTLinux binary recipe. The installer is a shell
# self-extractor, so it can be unpacked on an x86_64 GitHub runner.
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
    "$pkgroot/usr/bin" "$pkgroot/usr/lib/stm32mp2-gpu" \
    "$pkgroot/usr/share/doc/stm32mp2-gpu-userspace"

# OpenSTLinux gcnano-userland-binary.inc defaults to precisely this API set:
# egl, gbm, glesv1, glesv2 and vg. Copy only its runtime closure. In particular
# do not publish OpenCL/OpenVX/Vulkan merely because the binary installer happens
# to carry those files; OpenSTLinux gates those through MACHINE_FEATURES.
copy_exact() {
    local name="$1"
    test -e "$lib_source/$name" || die "OpenSTLinux-required GCNANO runtime library is missing: $name"
    install -m 0555 "$lib_source/$name" "$pkgroot$libdir/$name"
}

copy_glob() {
    local pattern="$1"
    local -a names=()
    mapfile -t names < <(find -L "$lib_source" -maxdepth 1 -type f -name "$pattern" -printf '%f\n' | LC_ALL=C sort -V)
    ((${#names[@]} > 0)) || die "OpenSTLinux-required GCNANO runtime library is missing: $pattern"
    local name
    for name in "${names[@]}"; do
        install -m 0555 "$lib_source/$name" "$pkgroot$libdir/$name"
    done
}

# libGAL/libVSC form the vendor core; libGLSLC is required by the default
# GLESv1/GLESv2/OpenVG packages in ST's recipe.
copy_exact libGAL.so
copy_exact libVSC.so
copy_exact libGLSLC.so
copy_glob 'libEGL.so.*'
copy_glob 'libgbm.so.*'
copy_exact libgbm_viv.so
copy_glob 'libGLESv1_CM.so.*'
copy_glob 'libGLESv2.so.*'
copy_glob 'libOpenVG.so.*'

# ST explicitly documents that the unversioned EGL/GLES/OpenVG names must be
# present because the vendor stack dlopens them. Preserve/construct those links
# even when the installer only ships versioned ELF files.
ensure_unversioned_link() {
    local stem="$1" candidate target
    candidate="$(find "$pkgroot$libdir" -maxdepth 1 -type f -name "${stem}.so.*" -printf '%f\n' | LC_ALL=C sort -V | head -n 1 || true)"
    [[ -n "$candidate" ]] || die "no runtime candidate found for ${stem}.so"
    target="$pkgroot$libdir/${stem}.so"
    if [[ ! -e "$target" && ! -L "$target" ]]; then
        ln -s "$candidate" "$target"
    fi
}
ensure_unversioned_link libEGL
ensure_unversioned_link libgbm
ensure_unversioned_link libGLESv1_CM
ensure_unversioned_link libGLESv2
ensure_unversioned_link libOpenVG

# Use a private vendor directory plus an explicit ld.so entry, exactly as the
# ST recipe supports through ST_SPECIFIC_OUTPUT_LIBDIR. The directory is sorted
# first so that the vendor API libraries become the system provider after APT
# removes the matching generic/Mesa packages listed in the control metadata.
printf '%s\n' "$libdir" > "$pkgroot/etc/ld.so.conf.d/00-stm32mp2-gpu.conf"
sed "s|@LIBDIR@|$libdir|g" "$ROOT/packaging/userspace/gcnano-env.in" \
    > "$pkgroot/usr/bin/stm32mp2-gpu-env"
chmod 0755 "$pkgroot/usr/bin/stm32mp2-gpu-env"
sed "s|@LIBDIR@|$libdir|g" "$ROOT/packaging/userspace/graphics-stack-check.in" \
    > "$pkgroot/usr/lib/stm32mp2-gpu/graphics-stack-check"
chmod 0755 "$pkgroot/usr/lib/stm32mp2-gpu/graphics-stack-check"

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

# The provider/Conflict model below is copied from the OpenSTLinux recipe's
# generated-deb policy. It replaces only the EGL/GBM/GLES/OpenVG surfaces that
# the 6.4.21 STM32MP2 binary recipe enables. It deliberately does not replace
# libGL, GLX, libglvnd, libdrm, Mesa DRI drivers, OpenCL, or Vulkan.
cat > "$pkgroot/DEBIAN/control" <<CONTROL
Package: stm32mp2-gpu-userspace
Version: ${pkgver}
Section: libs
Priority: optional
Architecture: arm64
Multi-Arch: same
Maintainer: ${maintainer}
Depends: libc6, libdrm2, libwayland-client0
Recommends: libwayland-egl1
Provides: gcnano-userspace, gcnano-egl, gcnano-gbm, gcnano-gles, gcnano-openvg, libegl, libegl1, libgbm, libgbm1, libgles1, libglesv1-cm1, libgles2, libglesv2-2, libopenvg
Conflicts: gcnano-userland, libegl, libegl1, libegl-mesa0, libgbm, libgbm1, libgles1, libglesv1-cm1, libgles2, libglesv2-2
Replaces: gcnano-userland, libegl, libegl1, libegl-mesa0, libgbm, libgbm1, libgles1, libglesv1-cm1, libgles2, libglesv2-2
Description: STM32MP2 GCNANO OpenSTLinux EGL/GBM/GLES provider stack
 This package installs the ST Vivante GCNANO user-space runtime closure used by
 OpenSTLinux for STM32MP2: EGL, GBM, GLESv1, GLESv2 and OpenVG.
 It replaces the corresponding generic/Mesa runtime providers on non-GLVND
 OpenSTLinux-compatible ARM64 root filesystems. It does not provide desktop
 OpenGL/GLX or replace libdrm, libglvnd, Mesa DRI, OpenCL or Vulkan.
CONTROL

# The ST binary is a non-GLVND EGL implementation. Refuse a full-provider
# install on a GLVND rootfs rather than silently replacing the dispatch ABI.
cat > "$pkgroot/DEBIAN/preinst" <<'PREINST'
#!/bin/sh
set -e
case "${1:-}" in
  install|upgrade)
    if dpkg-query -W -f='${db:Status-Status}' libglvnd0 2>/dev/null | grep -qx installed; then
      cat >&2 <<'MSG'
stm32mp2-gpu-userspace implements the OpenSTLinux non-GLVND provider model.
This rootfs has libglvnd0 installed, so replacing libEGL/libGLES/libgbm would
replace the GLVND dispatch ABI and is intentionally refused. Use an
OpenSTLinux-compatible non-GLVND rootfs, or keep the vendor payload isolated
and select it only with a tested application-specific integration.
MSG
      exit 1
    fi
    ;;
esac
exit 0
PREINST
chmod 0755 "$pkgroot/DEBIAN/preinst"

cat > "$pkgroot/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if command -v ldconfig >/dev/null 2>&1; then
    ldconfig
fi
if [ -x /usr/lib/stm32mp2-gpu/graphics-stack-check ]; then
    /usr/lib/stm32mp2-gpu/graphics-stack-check || {
        echo "warning: GCNANO graphics provider links are not yet active; inspect ldconfig -p and /etc/ld.so.conf.d/00-stm32mp2-gpu.conf" >&2
    }
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
