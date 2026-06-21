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
grep -Fq 'BUILD_EXCLUSIVE_ARCH="^(aarch64|arm64)$"' "$ROOT/packaging/dkms/dkms.conf.in"
! grep -RqsE 'stm32mp1|armhf|st-mp1' \
  "$ROOT"/README.md "$ROOT"/sources "$ROOT"/packaging "$ROOT"/scripts "$ROOT"/.github

# Publication must preserve the signed repository in main.
grep -q '^  contents: write$' "$ROOT/.github/workflows/build-publish.yml"
grep -q 'Commit generated APT repository to main' "$ROOT/.github/workflows/build-publish.yml"
grep -q 'git push origin HEAD:main' "$ROOT/.github/workflows/build-publish.yml"
! git -C "$ROOT" check-ignore -q generated-test.deb
! git -C "$ROOT" check-ignore -q KEY.gpg

# Debian/Ubuntu global-provider policy: GCNANO is first in ld.so.cache, while
# GLVND and Mesa remain co-installable for normal APT dependency resolution.
grep -q '00-stm32mp2-gpu.conf' "$ROOT/scripts/build-userspace.sh"
grep -q 'require_soname' "$ROOT/scripts/build-userspace.sh"
grep -q 'libwayland-server0' "$ROOT/scripts/build-userspace.sh"
grep -q 'Conflicts: gcnano-userland' "$ROOT/scripts/build-userspace.sh"
! grep -qE 'Conflicts:.*(libegl|libgbm|libgles|libglvnd|mesa)' "$ROOT/scripts/build-userspace.sh"
! grep -q 'dpkg-query -W.*libglvnd0' "$ROOT/scripts/build-userspace.sh"
grep -q 'OpenCL/vendors/VeriSilicon.icd' "$ROOT/scripts/build-optional-userspace.sh"
grep -q 'vulkan/icd.d/VeriSilicon_icd.json' "$ROOT/scripts/build-optional-userspace.sh"
grep -q 'openvx_profile.sh' "$ROOT/scripts/build-optional-userspace.sh"
grep -q 'libwayland-server0' "$ROOT/scripts/build-optional-userspace.sh"
grep -q 'libwayland-client0' "$ROOT/scripts/build-optional-userspace.sh"
grep -q 'libdrm2' "$ROOT/scripts/build-optional-userspace.sh"
grep -q 'libffi8' "$ROOT/scripts/build-optional-userspace.sh"

command -v dpkg-deb >/dev/null
command -v readelf >/dev/null
command -v python3 >/dev/null

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mock="$work/upstream"
mkdir -p "$mock/gcnano-driver-stm32mp"
printf 'all:\n\t@true\nclean:\n\t@true\n' > "$mock/gcnano-driver-stm32mp/Makefile"
printf '# mock Kbuild\n' > "$mock/gcnano-driver-stm32mp/Kbuild"
printf 'mock-upstream-commit\n' > "$mock/.gcnano-upstream-commit"

# The production package checks both AArch64 and public SONAMEs. The mock
# installer consequently emits compact AArch64 ELF shared-object headers with
# a PT_DYNAMIC table; no executable vendor code is ever run in CI.
cat > "$mock/gcnano-userland-multi-stm32mp2-6.4.21-20250226.bin" <<'INSTALLER'
#!/bin/sh
set -eu
dst='gcnano-userland-multi-stm32mp2-6.4.21-20250226'
mkdir -p "$dst/release/drivers"
python3 - "$dst/release/drivers" <<'PY'
import pathlib
import struct
import sys

out = pathlib.Path(sys.argv[1])
libs = {
    'libGAL.so': 'libGAL.so',
    'libVSC.so': 'libVSC.so',
    'libGLSLC.so': 'libGLSLC.so',
    'libEGL.so.1.5.0': 'libEGL.so.1',
    'libgbm.so.1.0.0': 'libgbm.so.1',
    'libgbm_viv.so': 'libgbm_viv.so',
    'libGLESv1_CM.so.1.1.0': 'libGLESv1_CM.so.1',
    'libGLESv2.so.2.0.0': 'libGLESv2.so.2',
    'libOpenVG.so.1.1.0': 'libOpenVG.so.1',
}
for filename, soname in libs.items():
    data = bytearray(0x400)
    data[0:16] = b'\x7fELF' + bytes([2, 1, 1, 0]) + bytes(8)
    struct.pack_into('<HHIQQQIHHHHHH', data, 16,
                     3, 183, 1, 0, 64, 0, 0, 64, 56, 2, 0, 0, 0)
    struct.pack_into('<IIQQQQQQ', data, 64,
                     1, 4, 0, 0, 0, 0x400, 0x400, 0x1000)
    struct.pack_into('<IIQQQQQQ', data, 120,
                     2, 4, 0x200, 0x200, 0x200, 0x40, 0x40, 8)
    strings = b'\0' + soname.encode() + b'\0'
    data[0x300:0x300 + len(strings)] = strings
    for index, (tag, value) in enumerate(((5, 0x300), (10, len(strings)), (14, 1), (0, 0))):
        struct.pack_into('<qQ', data, 0x200 + index * 16, tag, value)
    (out / filename).write_bytes(data)
PY
printf 'mock EULA\n' > "$dst/LICENSE"
INSTALLER
chmod 0755 "$mock/gcnano-userland-multi-stm32mp2-6.4.21-20250226.bin"

"$ROOT/scripts/build-dkms.sh" \
  --source "$mock" --version 6.4.21 --date 20250226 --out "$work/out" \
  --maintainer 'Template Test <test@example.invalid>' >/dev/null
"$ROOT/scripts/build-userspace.sh" \
  --source "$mock" --version 6.4.21 --date 20250226 --out "$work/out" \
  --maintainer 'Template Test <test@example.invalid>' >/dev/null

userspace="$work/out/stm32mp2-gpu-userspace_6.4.21+20250226-1_arm64.deb"
dpkg-deb -f "$work/out/stm32mp2-gpu-dkms_6.4.21+20250226-1_all.deb" Package | grep -qx stm32mp2-gpu-dkms
dpkg-deb -f "$userspace" Architecture | grep -qx arm64
dpkg-deb -f "$userspace" Depends | grep -q 'libwayland-server0'
dpkg-deb -f "$userspace" Conflicts | grep -qx 'gcnano-userland'
! dpkg-deb -f "$userspace" Conflicts | grep -Eq '(libegl|libgbm|libgles|libglvnd|mesa)'
! dpkg-deb -f "$userspace" Provides | grep -Eq '(libegl|libgbm|libgles)'

dpkg-deb -c "$userspace" > "$work/userspace.contents"
grep -q '00-stm32mp2-gpu.conf' "$work/userspace.contents"
grep -q 'graphics-stack-check' "$work/userspace.contents"
grep -q 'libEGL.so ->' "$work/userspace.contents"
grep -q 'libGLESv2.so ->' "$work/userspace.contents"

dpkg-deb -e "$userspace" "$work/control"
test ! -e "$work/control/preinst"
test -x "$work/control/postinst"

dpkg-deb -x "$userspace" "$work/root"
grep -qx '/usr/lib/aarch64-linux-gnu/stm32mp2-gpu' \
  "$work/root/etc/ld.so.conf.d/00-stm32mp2-gpu.conf"

echo 'STM32MP2 global-provider template checks passed.'
