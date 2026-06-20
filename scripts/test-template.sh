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
grep -q 'stm32mp2-gpu-dkms-rebuild' "$ROOT/scripts/build-dkms.sh"
grep -q 'BUILD_EXCLUSIVE_ARCH="arm64"' "$ROOT/packaging/dkms/dkms.conf.in"
! grep -RqsE 'stm32mp1|armhf|st-mp1' \
    "$ROOT"/README.md "$ROOT"/sources "$ROOT"/packaging "$ROOT"/scripts "$ROOT"/.github

# Publication must persist packages in main. Generated package types must not
# be hidden by .gitignore, otherwise `git add` cannot stage them.
grep -q '^  contents: write$' "$ROOT/.github/workflows/build-publish.yml"
grep -q 'Commit generated APT repository to main' "$ROOT/.github/workflows/build-publish.yml"
grep -q 'git push origin HEAD:main' "$ROOT/.github/workflows/build-publish.yml"
! git -C "$ROOT" check-ignore -q generated-test.deb
! git -C "$ROOT" check-ignore -q KEY.gpg

# Verify the OpenSTLinux default GCNANO feature closure and policy. The package
# must replace EGL/GBM/GLES APIs, retain libdrm/Wayland, reject GLVND and avoid
# packaging optional OpenCL/Vulkan merely because a binary blob contains them.
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
! grep -q 'OpenCL/vendors' "$ROOT/scripts/build-userspace.sh"
! grep -q 'vulkan/icd.d' "$ROOT/scripts/build-userspace.sh"

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
    libOpenCL.so.1 libvulkan.so.1; do
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
  libOpenCL.so.1 libvulkan.so.1; do
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
! grep -q 'libOpenCL.so.1' "$work/userspace.contents"
! grep -q 'libvulkan.so.1' "$work/userspace.contents"
dpkg-deb -e "$pkg" "$work/control"
test -x "$work/control/preinst"
test -x "$work/control/postinst"

echo 'STM32MP2-only template checks passed.'
