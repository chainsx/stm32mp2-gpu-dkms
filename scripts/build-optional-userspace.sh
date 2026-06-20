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
Usage: build-optional-userspace.sh --source DIR --version VERSION --date YYYYMMDD [options]
Build OpenSTLinux-gated GCNANO user-space components only when the selected ST
installer contains a complete OpenCL, OpenVX, and/or Vulkan closure.
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
need sort
need readelf

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
[[ -n "$extract_root" ]] || die "installer did not create gcnano-userland-multi-stm32mp2-*"
lib_source="$extract_root/release/drivers"
test -d "$lib_source" || die "installer lacks release/drivers: $extract_root"

sample_elf="$(find -P "$lib_source" -maxdepth 1 -type f -name 'libGAL.so*' -print | LC_ALL=C sort | head -n 1 || true)"
[[ -n "$sample_elf" ]] || die "release/drivers lacks libGAL.so"
readelf -h "$sample_elf" | grep -Eq 'Machine:.*AArch64' || die "unexpected user-space architecture; expected AArch64"

pkgver="$(package_version "$version" "$release_date")"
libdir=/usr/lib/aarch64-linux-gnu/stm32mp2-gpu
base_dep="stm32mp2-gpu-userspace (= ${pkgver})"
optional_packages=()
inventory="$work/GCNANO-LIBRARY-MAP.tsv"
printf 'library\tpackage\tactivation\n' > "$inventory"

# The default aggregate is built by build-userspace.sh. Record that closure here
# so this generated manifest accounts for every library provided by the ST
# installer, not merely the optional feature groups below.
record_default() {
    while IFS='|' read -r library package activation; do
        printf '%s\t%s\t%s\n' "$library" "$package" "$activation"
    done <<'MAP'
libGAL.so|stm32mp2-gpu-userspace|ldconfig vendor core
libVSC.so|stm32mp2-gpu-userspace|ldconfig vendor core
libGLSLC.so|stm32mp2-gpu-userspace|GLES/OpenVG dependency
libEGL.so.*|stm32mp2-gpu-userspace|ldconfig EGL provider
libgbm.so.*|stm32mp2-gpu-userspace|ldconfig GBM provider
libgbm_viv.so|stm32mp2-gpu-userspace|GBM vendor backend
libGLESv1_CM.so.*|stm32mp2-gpu-userspace|ldconfig GLESv1 provider
libGLESv2.so.*|stm32mp2-gpu-userspace|ldconfig GLESv2/GLES3 provider
libOpenVG.so.*|stm32mp2-gpu-userspace|ldconfig OpenVG provider
MAP
}
record_default

declare -A mapped=()
for n in libGAL.so libVSC.so libGLSLC.so libgbm_viv.so; do mapped["$n"]=1; done

has_exact() { [[ -f "$lib_source/$1" ]]; }
has_glob() { find -P "$lib_source" -maxdepth 1 -type f -name "$1" -print -quit | grep -q .; }
require_exact() { has_exact "$1" || die "incomplete optional GCNANO closure: missing $1"; }
require_glob() { has_glob "$1" || die "incomplete optional GCNANO closure: missing $1"; }

pkgroot_for() { printf '%s/pkg-%s\n' "$work" "$1"; }
init_pkg() { rm -rf "$1"; mkdir -p "$1/DEBIAN" "$1$libdir"; }

copy_exact() {
    local root="$1" package="$2" activation="$3" name="$4"
    install -m 0555 "$lib_source/$name" "$root$libdir/$name"
    mapped["$name"]=1
    printf '%s\t%s\t%s\n' "$name" "$package" "$activation" >> "$inventory"
}

copy_glob() {
    local root="$1" package="$2" activation="$3" pattern="$4"
    local -a names=()
    mapfile -t names < <(find -P "$lib_source" -maxdepth 1 -type f -name "$pattern" -printf '%f\n' | LC_ALL=C sort -V)
    ((${#names[@]})) || die "incomplete optional GCNANO closure: missing $pattern"
    local name
    for name in "${names[@]}"; do
        install -m 0555 "$lib_source/$name" "$root$libdir/$name"
        mapped["$name"]=1
        printf '%s\t%s\t%s\n' "$name" "$package" "$activation" >> "$inventory"
    done
}

first_lib() {
    find "$1$libdir" -maxdepth 1 -type f -name "$2" -printf '%f\n' | LC_ALL=C sort -V | head -n 1
}

write_control() {
    local root="$1" package="$2" summary="$3" depends="$4"
    cat > "$root/DEBIAN/control" <<CONTROL
Package: ${package}
Version: ${pkgver}
Section: libs
Priority: optional
Architecture: arm64
Multi-Arch: same
Maintainer: ${maintainer}
Depends: ${depends}
Description: ${summary}
 GCNANO component split to mirror OpenSTLinux gcnano-userland runtime grouping.
 This package is generated only when the selected ST installer contains its full
 dependency closure and its loader or runtime activation configuration.
CONTROL
}

write_ldconfig_hooks() {
    local root="$1"
    cat > "$root/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
command -v ldconfig >/dev/null 2>&1 && ldconfig
exit 0
POSTINST
    cat > "$root/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
command -v ldconfig >/dev/null 2>&1 && ldconfig
exit 0
POSTRM
    chmod 0755 "$root/DEBIAN/postinst" "$root/DEBIAN/postrm"
}

finish_pkg() {
    local root="$1" package="$2"
    dpkg-deb --root-owner-group --build "$root" "$out_dir/${package}_${pkgver}_arm64.deb" >/dev/null
    optional_packages+=("${package} (= ${pkgver})")
}

# OpenSTLinux maps libCLC to OpenCL/OpenVX and libSPIRV_viv to OpenCL/Vulkan.
need_clc=false
need_spirv=false
has_opencl=false
has_vulkan=false
has_openvx=false
has_glob 'libOpenCL*.so.*' && has_opencl=true
has_glob 'libvulkan*.so*' && has_vulkan=true
has_glob 'libOpenVX*.so*' && has_openvx=true
$has_opencl && { need_clc=true; need_spirv=true; }
$has_vulkan && need_spirv=true
$has_openvx && need_clc=true

if "$need_clc"; then require_exact libCLC.so; fi
if "$need_spirv"; then require_exact libSPIRV_viv.so; fi
if "$has_openvx"; then
    for f in libArchModelSw.so libNNArchPerf.so libovxlib.so \
             libNNGPUBinary.so libNNVXCBinary.so libOvx12VXCBinary.so libOvxGPUVXCBinary.so; do
        require_exact "$f"
    done
fi

if "$need_clc"; then
    package=stm32mp2-gpu-libclc
    root="$(pkgroot_for "$package")"
    init_pkg "$root"
    copy_exact "$root" "$package" 'required by OpenCL/OpenVX' libCLC.so
    write_control "$root" "$package" 'STM32MP2 GCNANO OpenCL compiler support library' "$base_dep"
    write_ldconfig_hooks "$root"
    finish_pkg "$root" "$package"
fi

if "$need_spirv"; then
    package=stm32mp2-gpu-libspirv
    root="$(pkgroot_for "$package")"
    init_pkg "$root"
    copy_exact "$root" "$package" 'required by OpenCL/Vulkan' libSPIRV_viv.so
    write_control "$root" "$package" 'STM32MP2 GCNANO SPIR-V support library' "$base_dep"
    write_ldconfig_hooks "$root"
    finish_pkg "$root" "$package"
fi

if "$has_opencl"; then
    package=stm32mp2-gpu-opencl
    root="$(pkgroot_for "$package")"
    init_pkg "$root"
    copy_glob "$root" "$package" 'OpenCL ICD: /etc/OpenCL/vendors/VeriSilicon.icd' 'libOpenCL*.so.*'
    opencl_lib="$(first_lib "$root" 'libOpenCL*.so.*')"
    [[ -n "$opencl_lib" ]] || die 'OpenCL ICD library discovery failed'
    mkdir -p "$root/etc/OpenCL/vendors"
    sed "s|@LIBRARY_PATH@|$libdir/$opencl_lib|g" "$ROOT/packaging/userspace/opencl.icd.in" \
        > "$root/etc/OpenCL/vendors/VeriSilicon.icd"
    write_control "$root" "$package" 'STM32MP2 GCNANO OpenCL ICD driver' \
        "$base_dep, stm32mp2-gpu-libclc (= ${pkgver}), stm32mp2-gpu-libspirv (= ${pkgver}), ocl-icd-libopencl1 | libopencl1"
    write_ldconfig_hooks "$root"
    finish_pkg "$root" "$package"
fi

if "$has_vulkan"; then
    package=stm32mp2-gpu-vulkan
    root="$(pkgroot_for "$package")"
    init_pkg "$root"
    copy_glob "$root" "$package" 'Vulkan ICD: /etc/vulkan/icd.d/VeriSilicon_icd.json' 'libvulkan*.so*'
    vulkan_lib="$(first_lib "$root" 'libvulkan*.so*')"
    [[ -n "$vulkan_lib" ]] || die 'Vulkan ICD library discovery failed'
    vulkan_version="${vulkan_lib#*.so.}"
    [[ "$vulkan_version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "cannot derive Vulkan API version from $vulkan_lib"
    mkdir -p "$root/etc/vulkan/icd.d"
    sed -e "s|@LIBRARY_PATH@|$libdir/$vulkan_lib|g" \
        -e "s|@API_VERSION@|$vulkan_version|g" \
        "$ROOT/packaging/userspace/vulkan_icd.json.in" \
        > "$root/etc/vulkan/icd.d/VeriSilicon_icd.json"
    write_control "$root" "$package" 'STM32MP2 GCNANO Vulkan ICD driver' \
        "$base_dep, stm32mp2-gpu-libspirv (= ${pkgver}), libvulkan1"
    write_ldconfig_hooks "$root"
    finish_pkg "$root" "$package"
fi

if "$has_openvx"; then
    kernels=stm32mp2-gpu-openvx-kernels
    root="$(pkgroot_for "$kernels")"
    init_pkg "$root"
    for f in libNNGPUBinary.so libNNVXCBinary.so libOvx12VXCBinary.so libOvxGPUVXCBinary.so; do
        copy_exact "$root" "$kernels" 'required OpenVX kernel binary' "$f"
    done
    write_control "$root" "$kernels" 'STM32MP2 GCNANO OpenVX kernel binaries' "$base_dep"
    write_ldconfig_hooks "$root"
    finish_pkg "$root" "$kernels"

    package=stm32mp2-gpu-openvx
    root="$(pkgroot_for "$package")"
    init_pkg "$root"
    copy_glob "$root" "$package" 'OpenVX runtime with /etc/profile.d/openvx_profile.sh' 'libOpenVX*.so*'
    for f in libArchModelSw.so libNNArchPerf.so libovxlib.so; do
        copy_exact "$root" "$package" 'OpenVX runtime dependency' "$f"
    done
    mkdir -p "$root/etc/profile.d" "$root/usr/bin"
    sed 's|@VIVANTE_SDK_DIR@|/usr|g' "$ROOT/packaging/userspace/openvx_profile.sh.in" \
        > "$root/etc/profile.d/openvx_profile.sh"
    chmod 0644 "$root/etc/profile.d/openvx_profile.sh"
    sed -e 's|@VIVANTE_SDK_DIR@|/usr|g' -e "s|@LIBDIR@|$libdir|g" \
        "$ROOT/packaging/userspace/openvx-env.in" > "$root/usr/bin/stm32mp2-gpu-openvx-env"
    chmod 0755 "$root/usr/bin/stm32mp2-gpu-openvx-env"
    write_control "$root" "$package" 'STM32MP2 GCNANO OpenVX runtime' \
        "$base_dep, stm32mp2-gpu-libclc (= ${pkgver}), ${kernels} (= ${pkgver})"
    write_ldconfig_hooks "$root"
    finish_pkg "$root" "$package"
fi

# Refuse to silently discard a new vendor library. This is intentional: an ST
# installer update must add an explicit package and activation rule here.
while IFS= read -r name; do
    case "$name" in
      libGAL.so|libVSC.so|libGLSLC.so|libgbm_viv.so|\
      libEGL.so.*|libgbm.so.*|libGLESv1_CM.so.*|libGLESv2.so.*|libOpenVG.so.*)
        ;;
      *)
        [[ -n "${mapped[$name]:-}" ]] || die "unmapped vendor library '$name': add an OpenSTLinux-aligned package and activation rule"
        ;;
    esac
done < <(find -P "$lib_source" -maxdepth 1 -type f -name 'lib*.so*' -printf '%f\n' | LC_ALL=C sort)

package=stm32mp2-gpu-full
root="$(pkgroot_for "$package")"
init_pkg "$root"
upstream_commit="$(get_upstream_commit "$source_dir")"
mkdir -p "$root/usr/share/doc/$package" "$root/usr/lib/stm32mp2-gpu"
install -m 0644 "$inventory" "$root/usr/share/doc/$package/GCNANO-LIBRARY-MAP.tsv"
sed "s|@LIBDIR@|$libdir|g" "$ROOT/packaging/userspace/optional-stack-check.in" \
    > "$root/usr/lib/stm32mp2-gpu/optional-stack-check"
chmod 0755 "$root/usr/lib/stm32mp2-gpu/optional-stack-check"
printf '%s\n' "$upstream_commit" > "$root/usr/share/doc/$package/upstream-commit.txt"
all_dep="$base_dep"
if ((${#optional_packages[@]})); then
    all_dep+=", $(IFS=', '; echo "${optional_packages[*]}")"
fi
write_control "$root" "$package" 'STM32MP2 GCNANO complete OpenSTLinux feature set' "$all_dep"
# A meta package deliberately has no ldconfig hook: its dependencies own files.
dpkg-deb --root-owner-group --build "$root" "$out_dir/${package}_${pkgver}_arm64.deb" >/dev/null

echo "Built optional OpenSTLinux GCNANO feature packages: ${optional_packages[*]:-none}"
