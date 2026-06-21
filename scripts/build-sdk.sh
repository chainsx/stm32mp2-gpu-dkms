#!/usr/bin/env bash
# Build the development SDK without duplicating files owned by runtime packages.
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
Usage: build-sdk.sh --source DIR --version VERSION --date YYYYMMDD [options]

Build stm32mp2-gpu-sdk from the STM32MP2 GCNANO installer. Runtime shared
libraries remain owned by the existing OpenSTLinux-aligned runtime packages.
The SDK owns every installer header, pkg-config file and only those unversioned
lib*.so development links that no runtime package already owns.
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
need find
need tar
need sed

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
[[ -n "$extract_root" ]] || die 'installer did not create an extraction directory'
lib_source="$extract_root/release/drivers"
include_source="$extract_root/release/include"
test -d "$lib_source" || die 'installer lacks release/drivers'
test -d "$include_source" || die 'installer lacks release/include'

pkgver="$(package_version "$version" "$release_date")"
package=stm32mp2-gpu-sdk
libdir=/usr/lib/aarch64-linux-gnu/stm32mp2-gpu
includedir=/usr/include/stm32mp2-gpu
pkgconfigdir="$libdir/pkgconfig"
root="$work/root"
mkdir -p "$root/DEBIAN" "$root$includedir" "$root$pkgconfigdir" \
  "$root/usr/lib/stm32mp2-gpu" "$root/usr/share/doc/$package"

# Record every installed runtime library path, including symlinks. The previous
# implementation considered only regular files, then recreated libEGL.so in the
# SDK and caused a dpkg ownership collision.
declare -A runtime_owner=()
shopt -s nullglob
for deb in "$out_dir"/stm32mp2-gpu-*.deb; do
  [[ -f "$deb" ]] || continue
  owner_pkg="$(dpkg-deb -f "$deb" Package)"
  [[ "$owner_pkg" = "$package" ]] && continue
  while IFS= read -r path; do
    path="${path#./}"
    case "$path" in
      usr/lib/aarch64-linux-gnu/stm32mp2-gpu/lib*.so*) runtime_owner["$path"]="$owner_pkg" ;;
    esac
  done < <(dpkg-deb --fsys-tarfile "$deb" | tar -tf -)
done
shopt -u nullglob

# Headers are intentionally vendor-prefixed. OpenSTLinux installs them in an
# isolated sysroot; this equivalent avoids overwriting Ubuntu/Mesa development
# headers while retaining every original header for cross/native builds.
cp -a "$include_source/." "$root$includedir/"

map_file="$root/usr/share/doc/$package/GCNANO-SDK-MAP.tsv"
printf 'path\tkind\towner\n' > "$map_file"
while IFS= read -r -d '' f; do
  rel="${f#"$include_source/"}"
  printf '%s\theader\t%s\n' "$includedir/$rel" "$package" >> "$map_file"
done < <(find -P "$include_source" \( -type f -o -type l \) -print0 | LC_ALL=C sort -z)

# Preserve every upstream pkg-config file. Vendor namespace and the SDK wrapper
# prevent it from replacing Mesa's generic *.pc files on Debian/Ubuntu.
while IFS= read -r -d '' pc; do
  base="$(basename "$pc")"
  dest="$root$pkgconfigdir/$base"
  sed \
    -e 's|#PREFIX#|/usr|g' \
    -e "s|#VERSION#|$version|g" \
    -e "s|^includedir=.*|includedir=$includedir|" \
    "$pc" > "$dest"
  grep -q '^Cflags:' "$dest" || printf 'Cflags: -I%s\n' "$includedir" >> "$dest"
  printf '%s\tpkgconfig\t%s\n' "$pkgconfigdir/$base" "$package" >> "$map_file"
done < <(find -P "$extract_root/release" -type f -name '*.pc' -print0 | LC_ALL=C sort -z)

# Add development links only where no runtime package owns the same pathname.
# This covers optional OpenCL/Vulkan/OpenVX libraries while preserving ownership
# of libEGL.so, libGLESv2.so, etc. in their runtime packages.
while IFS= read -r name; do
  base="${name%%.so.*}.so"
  [[ "$base" != "$name" ]] || continue
  rel="usr/lib/aarch64-linux-gnu/stm32mp2-gpu/$base"
  if [[ -n "${runtime_owner[$rel]:-}" ]]; then
    printf '%s\tdevelopment-link\t%s\n' "/$rel" "${runtime_owner[$rel]}" >> "$map_file"
    continue
  fi
  ln -s "$name" "$root/$rel"
  printf '%s\tdevelopment-link\t%s\n' "/$rel" "$package" >> "$map_file"
done < <(find -P "$lib_source" -maxdepth 1 -type f -name 'lib*.so.*' -printf '%f\n' | LC_ALL=C sort -V)

# Verify this package cannot claim a library path already held by a runtime .deb.
while IFS= read -r -d '' f; do
  rel="${f#"$root/"}"
  [[ -z "${runtime_owner[$rel]:-}" ]] || die "SDK would duplicate runtime path /$rel owned by ${runtime_owner[$rel]}"
done < <(find -P "$root$libdir" \( -type f -o -type l \) -name 'lib*.so*' -print0)

cat > "$root/usr/lib/stm32mp2-gpu/sdk-env" <<ENV
#!/bin/sh
export C_INCLUDE_PATH="$includedir\${C_INCLUDE_PATH:+:\$C_INCLUDE_PATH}"
export CPLUS_INCLUDE_PATH="$includedir\${CPLUS_INCLUDE_PATH:+:\$CPLUS_INCLUDE_PATH}"
export LIBRARY_PATH="$libdir\${LIBRARY_PATH:+:\$LIBRARY_PATH}"
export PKG_CONFIG_PATH="$pkgconfigdir\${PKG_CONFIG_PATH:+:\$PKG_CONFIG_PATH}"
exec "\$@"
ENV
chmod 0755 "$root/usr/lib/stm32mp2-gpu/sdk-env"

cat > "$root/usr/lib/stm32mp2-gpu/sdk-check" <<CHECK
#!/bin/sh
set -eu
printf '%s\n' 'GCNANO SDK check:'
test -d "$includedir"
test -f "/usr/share/doc/$package/GCNANO-SDK-MAP.tsv"
printf 'Headers: '
find "$includedir" -type f | wc -l
printf 'Pkg-config files: '
find "$pkgconfigdir" -type f -name '*.pc' | wc -l
printf '%s\n' 'Use /usr/lib/stm32mp2-gpu/sdk-env <compiler-or-command> for vendor include and pkg-config paths.'
CHECK
chmod 0755 "$root/usr/lib/stm32mp2-gpu/sdk-check"

cat > "$root/DEBIAN/control" <<CONTROL
Package: ${package}
Version: ${pkgver}
Section: libdevel
Priority: optional
Architecture: arm64
Maintainer: ${maintainer}
Depends: stm32mp2-gpu-full (= ${pkgver}), pkgconf | pkg-config
Description: Development SDK for the STM32MP2 Vivante GCNANO stack
 This package contains every header and pkg-config file supplied by the selected
 ST GCNANO installer, plus development links not already owned by a runtime
 package. It does not duplicate runtime library paths.
CONTROL

cat > "$root/usr/share/doc/$package/README.Debian" <<DOC
Headers are installed under $includedir to avoid overwriting Mesa/GLVND headers.
Use /usr/lib/stm32mp2-gpu/sdk-env before invoking a compiler or pkg-config.
Runtime activation remains owned by the OpenSTLinux-aligned EGL/GBM/GLES/OpenVG,
OpenCL ICD, Vulkan ICD and OpenVX profile packages.
DOC

dpkg-deb --root-owner-group --build "$root" "$out_dir/${package}_${pkgver}_arm64.deb" >/dev/null
dpkg-deb -I "$out_dir/${package}_${pkgver}_arm64.deb" >/dev/null
printf '%s\n' "$out_dir/${package}_${pkgver}_arm64.deb"
