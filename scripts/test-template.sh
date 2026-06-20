#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

for file in "$ROOT"/scripts/*.sh "$ROOT"/packaging/dkms/*.sh; do
    bash -n "$file"
done

grep -q 'SOC_PLATFORM=st-mp2' "$ROOT/packaging/dkms/dkms-make.sh"
grep -q 'KERNEL_DIR=' "$ROOT/packaging/dkms/dkms-make.sh"
grep -q 'M="$module_dir"' "$ROOT/packaging/dkms/dkms-make.sh"
grep -q 'AQROOT="$module_dir"' "$ROOT/packaging/dkms/dkms-make.sh"
grep -q 'make -C "$kernel_build"' "$ROOT/packaging/dkms/dkms-make.sh"
grep -q 'stm32mp2-gpu-dkms-rebuild' "$ROOT/scripts/build-dkms.sh"
grep -Fq 'BUILD_EXCLUSIVE_ARCH="^(aarch64|arm64)$"' "$ROOT/packaging/dkms/dkms.conf.in"
grep -q 'dkms remove -m "\$module" -v "\$version" --all' "$ROOT/packaging/dkms/stm32mp2-gpu-dkms-rebuild.in"
grep -q 'dkms add -m "\$module" -v "\$version"' "$ROOT/packaging/dkms/stm32mp2-gpu-dkms-rebuild.in"
! grep -RqsE 'stm32mp1|armhf|st-mp1' \
    "$ROOT"/README.md "$ROOT"/sources "$ROOT"/packaging "$ROOT"/scripts "$ROOT"/.github

# Publication must persist packages in main. Generated package types must not
# be hidden by .gitignore, otherwise `git add` cannot stage them.
grep -q '^  contents: write$' "$ROOT/.github/workflows/build-publish.yml"
grep -q 'Commit generated APT repository to main' "$ROOT/.github/workflows/build-publish.yml"
grep -q 'git push origin HEAD:main' "$ROOT/.github/workflows/build-publish.yml"
! git -C "$ROOT" check-ignore -q generated-test.deb
! git -C "$ROOT" check-ignore -q KEY.gpg

# Verify the default OpenSTLinux closure and the separately activated optional
# OpenCL/OpenVX/Vulkan closures. No vendor library may be published without its
# corresponding ICD, profile, or dependency package.
grep -q "copy_exact libGAL.so" "$ROOT/scripts/build-userspace.sh"
grep -q "copy_exact libVSC.so" "$ROOT/scripts/build-userspace.sh"
grep -q "copy_exact libGLSLC.so" "$ROOT/scripts/build-userspace.sh"
grep -q "copy_glob 'libEGL.so.\*'" "$ROOT/scripts/build-userspace.sh"
grep -q "copy_glob 'libgbm.so.\*'" "$ROOT/scripts/build-userspace.sh"
grep -q "copy_glob 'libGLESv1_CM.so.\*'" "$ROOT/scripts/build-userspace.sh"
grep -q "copy_glob 'libGLESv2.so.\*'" "$ROOT/scripts/build-userspace.sh"
grep -q "copy_glob 'libOpenVG.so.\*'" "$ROOT/scripts/build-userspace.sh"
grep -q 'Conflicts: gcnano-userland, libegl, libegl1, libegl-mesa0, libgbm, libgbm1' "$ROOT/scripts/build-userspace.sh"
grep -q "dpkg-query -W -f='\${db:Status-Status}' libglvnd0" "$ROOT/scripts/build-userspace.sh"
grep -q 'OpenCL/vendors/VeriSilicon.icd' "$ROOT/scripts/build-optional-userspace.sh"
grep -q 'vulkan/icd.d/VeriSilicon_icd.json' "$ROOT/scripts/build-optional-userspace.sh"
grep -q 'openvx_profile.sh' "$ROOT/scripts/build-optional-userspace.sh"
grep -q 'unmapped vendor library' "$ROOT/scripts/build-optional-userspace.sh"

command -v dpkg-deb >/dev/null
command -v readelf >/dev/null
command -v python3 >/dev/null

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mock="$work/upstream"
mkdir -p "$mock/gcnano-driver-stm32mp" \
    "$mock/gcnano-userland-multi-stm32mp2-6.4.21-20250226/release/drivers"
printf 'all:\n\t@true\nclean:\n\t@true\n' > "$mock/gcnano-driver-stm32mp/Makefile"
printf '# mock Kbuild\n' > "$mock/gcnano-driver-stm32mp/Kbuild"
printf 'mock-upstream-commit\n' > "$mock/.gcnano-upstream-commit"

# Minimal ELF64/AArch64 header. The production build validates the actual ST
# libGAL payload; template tests only need an architecture-bearing ELF header.
python3 - "$work/elf" <<'PY'
import struct, sys
hdr = bytearray(64)
hdr[0:4] = b'\x7fELF'
hdr[4:7] = b'\x02\x01\x01'
struct.pack_into('<HHIQQQIHHHHHH', hdr, 16,
                 1, 183, 1, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0)
open(sys.argv[1], 'wb').write(hdr)
PY

drv="$mock/gcnano-userland-multi-stm32mp2-6.4.21-20250226/release/drivers"
for name in \
    libGAL.so libVSC.so libGLSLC.so \
    libEGL.so.1 libgbm.so.1 libgbm_viv.so \
    libGLESv1_CM.so.1 libGLESv2.so.2 libOpenVG.so.1 \
    libCLC.so libSPIRV_viv.so libOpenCL_VSI.so.1 libvulkan_VSI.so.1.3 \
    libOpenVX.so.1 libOpenVXU.so.1 libArchModelSw.so libNNArchPerf.so libovxlib.so \
    libNNGPUBinary.so libNNVXCBinary.so libOvx12VXCBinary.so libOvxGPUVXCBinary.so; do
    cp "$work/elf" "$drv/$name"
done
printf 'mock EULA\n' > "$mock/gcnano-userland-multi-stm32mp2-6.4.21-20250226/LICENSE"

# Re-create a self-contained mock installer. build-userspace.sh copies it into
# a fresh workdir before running it, so it must reconstruct its own payload.
cat > "$mock/gcnano-userland-multi-stm32mp2-6.4.21-20250226.bin" <<'SH'
#!/bin/sh
set -eu
dst="gcnano-userland-multi-stm32mp2-6.4.21-20250226"
mkdir -p "$dst/release/drivers"
python3 - "$dst/release/drivers/base" <<'PY'
import struct, sys
hdr = bytearray(64)
hdr[0:4] = b'\x7fELF'
hdr[4:7] = b'\x02\x01\x01'
struct.pack_into('<HHIQQQIHHHHHH', hdr, 16,
                 1, 183, 1, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0)
open(sys.argv[1], 'wb').write(hdr)
PY
for name in \
  libGAL.so libVSC.so libGLSLC.so \
  libEGL.so.1 libgbm.so.1 libgbm_viv.so \
  libGLESv1_CM.so.1 libGLESv2.so.2 libOpenVG.so.1 \
  libCLC.so libSPIRV_viv.so libOpenCL_VSI.so.1 libvulkan_VSI.so.1.3 \
  libOpenVX.so.1 libOpenVXU.so.1 libArchModelSw.so libNNArchPerf.so libovxlib.so \
  libNNGPUBinary.so libNNVXCBinary.so libOvx12VXCBinary.so libOvxGPUVXCBinary.so; do
  cp "$dst/release/drivers/base" "$dst/release/drivers/$name"
done
rm "$dst/release/drivers/base"
printf 'mock EULA\n' > "$dst/LICENSE"
SH
chmod 0755 "$mock/gcnano-userland-multi-stm32mp2-6.4.21-20250226.bin"

"$ROOT/scripts/build-all.sh" \
    --source "$mock" --version 6.4.21 --userland-date 20250226 --out "$work/out" \
    --maintainer 'Template Test <test@example.invalid>' >/dev/null

pkg="$work/out/stm32mp2-gpu-userspace_6.4.21+20250226-1_arm64.deb"
dpkg-deb -f "$work/out/stm32mp2-gpu-dkms_6.4.21+20250226-1_all.deb" Package | grep -qx stm32mp2-gpu-dkms
dpkg-deb -f "$pkg" Architecture | grep -qx arm64
dpkg-deb -f "$work/out/stm32mp2-gpu-driver_6.4.21+20250226-1_all.deb" Package | grep -qx stm32mp2-gpu-driver
dpkg-deb -f "$pkg" Provides | grep -q 'libegl1'
dpkg-deb -f "$pkg" Conflicts | grep -q 'libegl-mesa0'
dpkg-deb -f "$pkg" Depends | grep -q 'libdrm2'
dpkg-deb -c "$work/out/stm32mp2-gpu-dkms_6.4.21+20250226-1_all.deb" > "$work/dkms.contents"
dpkg-deb -c "$pkg" > "$work/userspace.contents"
grep -q 'dkms-make.sh' "$work/dkms.contents"
grep -q 'libGAL.so' "$work/userspace.contents"
grep -q 'libEGL.so ->' "$work/userspace.contents"
grep -q 'libGLESv2.so ->' "$work/userspace.contents"
! grep -q 'libOpenCL_VSI.so.1' "$work/userspace.contents"
! grep -q 'libvulkan_VSI.so.1.3' "$work/userspace.contents"
for optional in stm32mp2-gpu-libclc stm32mp2-gpu-libspirv stm32mp2-gpu-opencl stm32mp2-gpu-vulkan stm32mp2-gpu-openvx stm32mp2-gpu-openvx-kernels stm32mp2-gpu-full; do
    test -f "$work/out/${optional}_6.4.21+20250226-1_arm64.deb"
done
dpkg-deb -c "$work/out/stm32mp2-gpu-opencl_6.4.21+20250226-1_arm64.deb" | grep -q 'etc/OpenCL/vendors/VeriSilicon.icd'
dpkg-deb -c "$work/out/stm32mp2-gpu-vulkan_6.4.21+20250226-1_arm64.deb" | grep -q 'etc/vulkan/icd.d/VeriSilicon_icd.json'
dpkg-deb -c "$work/out/stm32mp2-gpu-openvx_6.4.21+20250226-1_arm64.deb" | grep -q 'etc/profile.d/openvx_profile.sh'
dpkg-deb -c "$work/out/stm32mp2-gpu-full_6.4.21+20250226-1_arm64.deb" | grep -q 'GCNANO-LIBRARY-MAP.tsv'
dpkg-deb -c "$work/out/stm32mp2-gpu-full_6.4.21+20250226-1_arm64.deb" | grep -q 'optional-stack-check'
mkdir -p "$work/check-opencl" "$work/check-vulkan" "$work/check-openvx" "$work/check-full"
dpkg-deb -x "$work/out/stm32mp2-gpu-opencl_6.4.21+20250226-1_arm64.deb" "$work/check-opencl"
dpkg-deb -x "$work/out/stm32mp2-gpu-vulkan_6.4.21+20250226-1_arm64.deb" "$work/check-vulkan"
dpkg-deb -x "$work/out/stm32mp2-gpu-openvx_6.4.21+20250226-1_arm64.deb" "$work/check-openvx"
dpkg-deb -x "$work/out/stm32mp2-gpu-full_6.4.21+20250226-1_arm64.deb" "$work/check-full"
grep -qx '/usr/lib/aarch64-linux-gnu/stm32mp2-gpu/libOpenCL_VSI.so.1' "$work/check-opencl/etc/OpenCL/vendors/VeriSilicon.icd"
grep -q '"library_path": "/usr/lib/aarch64-linux-gnu/stm32mp2-gpu/libvulkan_VSI.so.1.3"' "$work/check-vulkan/etc/vulkan/icd.d/VeriSilicon_icd.json"
grep -qx 'export VIVANTE_SDK_DIR="/usr"' "$work/check-openvx/etc/profile.d/openvx_profile.sh"
grep -q '^libvulkan_VSI.so.1.3' "$work/check-full/usr/share/doc/stm32mp2-gpu-full/GCNANO-LIBRARY-MAP.tsv"
dpkg-deb -e "$pkg" "$work/control"
test -x "$work/control/preinst"
test -x "$work/control/postinst"

echo 'STM32MP2-only template checks passed.'
