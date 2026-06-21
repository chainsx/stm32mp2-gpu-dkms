#!/usr/bin/env bash
# Build an OpenSTLinux-aligned GCNANO SDK package from the ST STM32MP2 installer.
# Runtime libraries remain owned by the existing runtime split packages.  This
# script refuses to package headers when an installer library has no runtime
# package owner, preventing a partial SDK from being published.
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
Usage: build-complete-sdk-v5.sh --source DIR --version VERSION --date YYYYMMDD [options]

Build stm32mp2-gpu-sdk from the ST GCNANO installer.  All vendor shared
libraries must already be owned by one of the runtime .deb packages in --out.
The package installs every release/include header, every supplied pkg-config
file, and development linker names missing from the runtime split.

  --source DIR       gcnano-binaries checkout
  --version VERSION  GCNANO release version
  --date YYYYMMDD    STM32MP2 user-space installer build date
  --out DIR          Existing runtime package output directory
  --maintainer TEXT  Debian Maintainer field
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

[[ -n "$source_dir" && -n "$version" && -n "$release_date" ]] || {
  usage >&2
  exit 64
}

safe_version "$version"
safe_date "$release_date"
need dpkg-deb
need find
need sort
need install
need sed
need tar

installer="$source_dir/gcnano-userland-multi-stm32mp2-${version}-${release_date}.bin"
test -f "$installer" || die "STM32MP2 user-space installer not found: $installer"
out_dir="$(mkdir -p "$out_dir" && cd "$out_dir" && pwd)"

pkgver="$(package_version "$version" "$release_date")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The ST installer is a self-extracting archive.  It is not an AArch64 binary;
# extraction is therefore safe on the x86_64 GitHub Actions build runner.
cp "$installer" "$work/installer.bin"
chmod 0755 "$work/installer.bin"
(
  cd "$work"
  sh ./installer.bin --auto-accept
)
extract_root="$(find "$work" -mindepth 1 -maxdepth 1 -type d \
  -name 'gcnano-userland-multi-stm32mp2-*' -print | LC_ALL=C sort | head -n 1 || true)"
[[ -n "$extract_root" ]] || die "installer did not create gcnano-userland-multi-stm32mp2-*"
release_root="$extract_root/release"
lib_source="$release_root/drivers"
include_source="$release_root/include"
test -d "$lib_source" || die "installer lacks release/drivers: $extract_root"
test -d "$include_source" || die "installer lacks release/include: $extract_root"

libdir=/usr/lib/aarch64-linux-gnu/stm32mp2-gpu
runtime_extract="$work/runtime"
mkdir -p "$runtime_extract"

declare -A owner=()
declare -A runtime_path=()
full_seen=false
runtime_debs=0

# Inspect the packages built by build-userspace.sh and build-optional-userspace.sh
# instead of duplicating their runtime files in the SDK package.
shopt -s nullglob
for deb in "$out_dir"/stm32mp2-gpu-*.deb; do
  package="$(dpkg-deb -f "$deb" Package)"
  [[ "$package" == "stm32mp2-gpu-sdk" ]] && continue
  ((runtime_debs += 1))
  root="$runtime_extract/$package"
  mkdir -p "$root"
  dpkg-deb -x "$deb" "$root"
  [[ "$package" == "stm32mp2-gpu-full" ]] && full_seen=true
  while IFS= read -r -d '' path; do
    name="${path##*/}"
    owner["$name"]="$package"
    runtime_path["$name"]="${path#"$root"}"
  done < <(find -P "$root$libdir" -maxdepth 1 -type f -name 'lib*.so*' -print0 2>/dev/null || true)
done
shopt -u nullglob
((runtime_debs > 0)) || die "no stm32mp2-gpu runtime .deb packages found in $out_dir"
"$full_seen" || die "stm32mp2-gpu-full is missing; build optional runtime packages before SDK packaging"

# Every actual vendor library must have one and only one runtime package owner.
missing=0
while IFS= read -r name; do
  if [[ -z "${owner[$name]:-}" ]]; then
    printf 'SDK validation: %s is present in the ST installer but absent from all runtime .deb packages\n' "$name" >&2
    missing=1
  fi
done < <(find -P "$lib_source" -maxdepth 1 -type f -name 'lib*.so*' -printf '%f\n' | LC_ALL=C sort -u)
((missing == 0)) || die "incomplete GCNANO runtime split; refusing to publish SDK headers"

root="$work/pkg"
mkdir -p \
  "$root/DEBIAN" \
  "$root/usr/include" \
  "$root$libdir" \
  "$root/usr/lib/aarch64-linux-gnu/pkgconfig" \
  "$root/usr/share/doc/stm32mp2-gpu-sdk" \
  "$root/usr/lib/stm32mp2-gpu"

# OpenSTLinux installs vendor headers below ${includedir}; retain the vendor
# include tree verbatim so EGL/GLES/CL/VX consumers use their normal includes.
cp -a "$include_source/." "$root/usr/include/"

# A runtime package owns versioned objects.  Add only development link names
# that are absent from those packages, so dpkg never sees duplicate ownership.
while IFS= read -r name; do
  case "$name" in
    *.so.[0-9]*)
      dev_name="${name%%.so.*}.so"
      if [[ -z "${owner[$dev_name]:-}" && ! -e "$root$libdir/$dev_name" ]]; then
        ln -s "$name" "$root$libdir/$dev_name"
      fi
      ;;
  esac
done < <(find -P "$lib_source" -maxdepth 1 -type f -name 'lib*.so*' -printf '%f\n' | LC_ALL=C sort -V)

# Preserve all supplied pkg-config files.  The vendor files use placeholders in
# several releases; translate the OpenSTLinux values without editing ABI names.
while IFS= read -r -d '' pc; do
  target="$root/usr/lib/aarch64-linux-gnu/pkgconfig/${pc##*/}"
  sed -e 's|#PREFIX#|/usr|g' -e 's|#VERSION#|24.0.7|g' "$pc" > "$target"
  chmod 0644 "$target"
done < <(find -P "$release_root" -type f -name '*.pc' -print0 | LC_ALL=C sort -z)

map="$root/usr/share/doc/stm32mp2-gpu-sdk/GCNANO-PAYLOAD-MAP.tsv"
printf 'kind\tpath\truntime-package\tactivation\n' > "$map"
activation_for() {
  case "$1" in
    stm32mp2-gpu-opencl) printf '%s' '/etc/OpenCL/vendors/VeriSilicon.icd' ;;
    stm32mp2-gpu-vulkan) printf '%s' '/etc/vulkan/icd.d/VeriSilicon_icd.json' ;;
    stm32mp2-gpu-openvx) printf '%s' '/etc/profile.d/openvx_profile.sh' ;;
    *) printf '%s' 'ldconfig / standard dynamic linker path' ;;
  esac
}
while IFS= read -r name; do
  package="${owner[$name]}"
  printf 'library\t%s/%s\t%s\t%s\n' "$libdir" "$name" "$package" "$(activation_for "$package")" >> "$map"
done < <(find -P "$lib_source" -maxdepth 1 -type f -name 'lib*.so*' -printf '%f\n' | LC_ALL=C sort -u)
while IFS= read -r -d '' header; do
  printf 'header\t/usr/include/%s\tstm32mp2-gpu-sdk\tcompiler include path\n' \
    "${header#"$include_source/"}" >> "$map"
done < <(find -P "$include_source" -type f -print0 | LC_ALL=C sort -z)
while IFS= read -r -d '' pc; do
  printf 'pkgconfig\t/usr/lib/aarch64-linux-gnu/pkgconfig/%s\tstm32mp2-gpu-sdk\tpkg-config\n' \
    "${pc##*/}" >> "$map"
done < <(find -P "$release_root" -type f -name '*.pc' -print0 | LC_ALL=C sort -z)

cat > "$root/usr/lib/stm32mp2-gpu/sdk-check" <<'CHECK'
#!/bin/sh
set -eu
map=/usr/share/doc/stm32mp2-gpu-sdk/GCNANO-PAYLOAD-MAP.tsv
[ -r "$map" ] || { echo "Missing $map" >&2; exit 1; }
tail -n +2 "$map" | while IFS="$(printf '\t')" read -r kind path package activation; do
  case "$kind" in
    library|header|pkgconfig) [ -e "$path" ] || { echo "Missing $kind: $path" >&2; exit 1; } ;;
  esac
done
if grep -q 'stm32mp2-gpu-opencl' "$map"; then
  [ -s /etc/OpenCL/vendors/VeriSilicon.icd ] || { echo "Missing OpenCL ICD" >&2; exit 1; }
fi
if grep -q 'stm32mp2-gpu-vulkan' "$map"; then
  [ -s /etc/vulkan/icd.d/VeriSilicon_icd.json ] || { echo "Missing Vulkan ICD" >&2; exit 1; }
fi
if grep -q 'stm32mp2-gpu-openvx' "$map"; then
  [ -r /etc/profile.d/openvx_profile.sh ] || { echo "Missing OpenVX profile" >&2; exit 1; }
fi
echo "GCNANO SDK payload, headers, pkg-config files, and runtime activators are present."
CHECK
chmod 0755 "$root/usr/lib/stm32mp2-gpu/sdk-check"

cat > "$root/DEBIAN/control" <<CONTROL
Package: stm32mp2-gpu-sdk
Version: ${pkgver}
Section: libdevel
Priority: optional
Architecture: arm64
Maintainer: ${maintainer}
Depends: stm32mp2-gpu-full (= ${pkgver})
Description: Complete STM32MP2 GCNANO OpenSTLinux-compatible SDK
 This package installs all headers and pkg-config metadata supplied by the ST
 GCNANO STM32MP2 installer. Runtime libraries remain in their OpenSTLinux-
 aligned component packages; the dependency on stm32mp2-gpu-full ensures every
 mapped library and its OpenCL, Vulkan, or OpenVX activation file is installed.
CONTROL

printf '%s\n' "$(get_upstream_commit "$source_dir")" > "$root/usr/share/doc/stm32mp2-gpu-sdk/upstream-commit.txt"
dpkg-deb --root-owner-group --build "$root" "$out_dir/stm32mp2-gpu-sdk_${pkgver}_arm64.deb" >/dev/null
printf '%s\n' "$out_dir/stm32mp2-gpu-sdk_${pkgver}_arm64.deb"
