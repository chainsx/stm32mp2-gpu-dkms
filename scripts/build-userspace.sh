#!/usr/bin/env bash
# Build the OpenSTLinux default GCNANO graphics closure for Debian-family
# systems. GCNANO remains in a private directory to avoid dpkg file ownership
# collisions, but that directory is registered first with ldconfig so direct
# Vivante EGL/GBM/GLES/OpenVG libraries become the default runtime provider.
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
(
  cd "$work"
  sh ./installer.bin --auto-accept
)

extract_root="$(find "$work" -mindepth 1 -maxdepth 1 -type d -name 'gcnano-userland-multi-stm32mp2-*' -print | LC_ALL=C sort | head -n 1 || true)"
[[ -n "$extract_root" ]] || die 'installer did not create gcnano-userland-multi-stm32mp2-*'
lib_source="$extract_root/release/drivers"
test -d "$lib_source" || die "installer lacks release/drivers: $extract_root"

sample_elf="$(find -L "$lib_source" -maxdepth 1 -type f -name 'libGAL.so*' -print | LC_ALL=C sort | head -n 1 || true)"
[[ -n "$sample_elf" ]] || die 'release/drivers lacks libGAL.so'
readelf -h "$sample_elf" | grep -Eq 'Machine:.*AArch64' || die 'unexpected user-space architecture; expected AArch64'

pkgroot="$work/pkgroot"
pkgver="$(package_version "$version" "$release_date")"
package=stm32mp2-gpu-userspace
libdir=/usr/lib/aarch64-linux-gnu/stm32mp2-gpu
mkdir -p "$pkgroot/DEBIAN" "$pkgroot$libdir" "$pkgroot/etc/ld.so.conf.d" \
  "$pkgroot/usr/lib/stm32mp2-gpu" "$pkgroot/usr/share/doc/$package"

copy_exact() {
  local name="$1"
  test -e "$lib_source/$name" || die "OpenSTLinux-required GCNANO runtime library is missing: $name"
  install -m 0555 "$lib_source/$name" "$pkgroot$libdir/$name"
}

copy_glob() {
  local pattern="$1"
  local -a names=()
  mapfile -t names < <(find -L "$lib_source" -maxdepth 1 -type f -name "$pattern" -printf '%f\n' | LC_ALL=C sort -V)
  ((${#names[@]})) || die "OpenSTLinux-required GCNANO runtime library is missing: $pattern"
  local name
  for name in "${names[@]}"; do
    install -m 0555 "$lib_source/$name" "$pkgroot$libdir/$name"
  done
}

# OpenSTLinux default PACKAGECONFIG: egl gbm glesv1 glesv2 vg.
copy_exact libGAL.so
copy_exact libVSC.so
copy_exact libGLSLC.so
copy_glob 'libEGL.so.*'
copy_glob 'libgbm.so.*'
copy_exact libgbm_viv.so
copy_glob 'libGLESv1_CM.so.*'
copy_glob 'libGLESv2.so.*'
copy_glob 'libOpenVG.so.*'

ensure_unversioned_link() {
  local stem="$1" candidate target
  candidate="$(find "$pkgroot$libdir" -maxdepth 1 -type f -name "${stem}.so.*" -printf '%f\n' | LC_ALL=C sort -V | head -n 1 || true)"
  [[ -n "$candidate" ]] || die "no runtime candidate found for ${stem}.so"
  target="$pkgroot$libdir/${stem}.so"
  [[ -e "$target" || -L "$target" ]] || ln -s "$candidate" "$target"
}
ensure_unversioned_link libEGL
ensure_unversioned_link libgbm
ensure_unversioned_link libGLESv1_CM
ensure_unversioned_link libGLESv2
ensure_unversioned_link libOpenVG

# Global selection is safe only when the vendor binaries expose the exact
# sonames used by normal Debian/Ubuntu applications. Fail the build otherwise.
require_soname() {
  local pattern="$1" expected="$2" file actual
  file="$(find "$pkgroot$libdir" -maxdepth 1 -type f -name "$pattern" -printf '%p\n' | LC_ALL=C sort -V | head -n 1 || true)"
  [[ -n "$file" ]] || die "cannot find vendor library matching $pattern"
  actual="$(readelf -d "$file" 2>/dev/null | sed -n 's/.*SONAME.*\[\([^]]*\)\].*/\1/p' | head -n 1)"
  [[ "$actual" == "$expected" ]] || die "incompatible GCNANO SONAME for $(basename "$file"): expected $expected, got ${actual:-none}"
}
require_soname 'libEGL.so.*' 'libEGL.so.1'
require_soname 'libgbm.so.*' 'libgbm.so.1'
require_soname 'libGLESv1_CM.so.*' 'libGLESv1_CM.so.1'
require_soname 'libGLESv2.so.*' 'libGLESv2.so.2'
require_soname 'libOpenVG.so.*' 'libOpenVG.so.1'

# Do not overwrite files owned by libglvnd/Mesa.  Their packages remain
# co-installable so APT dependencies such as kmscube continue to resolve. The
# numeric filename ensures the vendor direct ABI appears first in ld.so.cache.
printf '%s\n' "$libdir" > "$pkgroot/etc/ld.so.conf.d/00-stm32mp2-gpu.conf"

cat > "$pkgroot/usr/lib/stm32mp2-gpu/graphics-stack-check" <<CHECK
#!/bin/sh
set -eu
libdir='$libdir'
status=0
check_provider() {
  soname="\$1"
  resolved="\$(ldconfig -p 2>/dev/null | awk -v soname="\$soname" '\$1 == soname {print \$NF; exit}')"
  case "\$resolved" in
    "\$libdir"/*) printf '%s -> %s\n' "\$soname" "\$resolved" ;;
    *) echo "\$soname: expected GCNANO provider under \$libdir, got \${resolved:-not-found}" >&2; status=1 ;;
  esac
}
check_provider libEGL.so.1
check_provider libgbm.so.1
check_provider libGLESv1_CM.so.1
check_provider libGLESv2.so.2
check_provider libOpenVG.so.1
exit "\$status"
CHECK
chmod 0755 "$pkgroot/usr/lib/stm32mp2-gpu/graphics-stack-check"

upstream_commit="$(get_upstream_commit "$source_dir")"
cat > "$pkgroot/usr/share/doc/$package/README.Debian" <<DOC
STM32MP2 GCNANO global graphics provider
=========================================

This package follows the OpenSTLinux default GCNANO feature set: EGL, GBM,
GLESv1, GLESv2, OpenVG, libGAL, libVSC and libGLSLC.

The Vivante libraries are stored in $libdir to avoid overwriting files owned by
Debian/Ubuntu GLVND and Mesa packages.  /etc/ld.so.conf.d/00-stm32mp2-gpu.conf
places that directory first in the dynamic-linker cache. Ordinary applications
therefore resolve the compatible direct GCNANO ABI by default, without
LD_LIBRARY_PATH or a wrapper command.

GLVND/Mesa packages are deliberately left installed: they satisfy APT package
dependencies and remain fallback libraries if this package is removed. This
package does not replace libGL/GLX, libdrm, Wayland, Mesa DRI drivers, OpenCL or
Vulkan.

Verify default resolution after installation:
  /usr/lib/stm32mp2-gpu/graphics-stack-check
  ldconfig -p | grep -E 'libEGL.so.1|libgbm.so.1|libGLESv1_CM.so.1|libGLESv2.so.2|libOpenVG.so.1'

Installer: $(basename "$installer")
Upstream commit: $upstream_commit
DOC
install -m 0644 "$ROOT/packaging/userspace/copyright.in" "$pkgroot/usr/share/doc/$package/copyright"
printf '%s\n' "$upstream_commit" > "$pkgroot/usr/share/doc/$package/upstream-commit.txt"
printf '%s\n' 'https://github.com/STMicroelectronics/gcnano-binaries' > "$pkgroot/usr/share/doc/$package/upstream-url.txt"
license_file="$(first_license_file "$extract_root" || true)"
[[ -n "$license_file" ]] || license_file="$(first_license_file "$source_dir" || true)"
[[ -z "$license_file" ]] || install -m 0644 "$license_file" "$pkgroot/usr/share/doc/$package/upstream-license-or-eula.txt"

cat > "$pkgroot/DEBIAN/control" <<CONTROL
Package: ${package}
Version: ${pkgver}
Section: libs
Priority: optional
Architecture: arm64
Multi-Arch: same
Maintainer: ${maintainer}
Depends: libc6, libdrm2, libwayland-client0, libwayland-server0
Recommends: libwayland-egl1
Conflicts: gcnano-userland
Replaces: gcnano-userland
Provides: gcnano-userspace
Description: STM32MP2 Vivante GCNANO global EGL/GBM/GLES runtime
 OpenSTLinux-aligned GCNANO EGL, GBM, GLESv1, GLESv2 and OpenVG runtime.
 Vendor libraries are the default linker-selected provider while Debian/Ubuntu
 GLVND and Mesa packages remain installed to satisfy application dependencies.
CONTROL

cat > "$pkgroot/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
command -v ldconfig >/dev/null 2>&1 && ldconfig
/usr/lib/stm32mp2-gpu/graphics-stack-check
POSTINST
cat > "$pkgroot/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
command -v ldconfig >/dev/null 2>&1 && ldconfig
POSTRM
chmod 0755 "$pkgroot/DEBIAN/postinst" "$pkgroot/DEBIAN/postrm"

package_file="$out_dir/${package}_${pkgver}_arm64.deb"
dpkg-deb --root-owner-group --build "$pkgroot" "$package_file" >/dev/null
dpkg-deb -I "$package_file" >/dev/null
printf '%s\n' "$package_file"
