#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

for file in "$ROOT"/scripts/*.sh "$ROOT"/packaging/dkms/*.sh; do
    bash -n "$file"
done

grep -q 'SOC_PLATFORM=st-mp2' "$ROOT/packaging/dkms/dkms-make.sh"
grep -q 'KERNEL_DIR=' "$ROOT/packaging/dkms/dkms-make.sh"
grep -q 'BUILD_EXCLUSIVE_ARCH="arm64"' "$ROOT/packaging/dkms/dkms.conf.in"
! grep -RqsE 'stm32mp1|armhf|st-mp1' \
    "$ROOT"/README.md "$ROOT"/sources "$ROOT"/packaging "$ROOT"/scripts "$ROOT"/.github

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

# Minimal ELF64/AArch64 header; readelf needs only the header for the packaging
# architecture check. The production build validates ST's actual libGAL payload.
python3 - "$work/elf" <<'PY'
import struct, sys
# ELF64, little endian, relocatable AArch64, header size 64.
hdr = bytearray(64)
hdr[0:4] = b'\x7fELF'
hdr[4:7] = b'\x02\x01\x01'
struct.pack_into('<HHIQQQIHHHHHH', hdr, 16,
                 1, 183, 1, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0)
open(sys.argv[1], 'wb').write(hdr)
PY
cp "$work/elf" "$mock/gcnano-userland-multi-stm32mp2-6.4.21-20250226/release/drivers/libGAL.so"
cp "$work/elf" "$mock/gcnano-userland-multi-stm32mp2-6.4.21-20250226/release/drivers/libEGL.so.1"
ln -s libEGL.so.1 "$mock/gcnano-userland-multi-stm32mp2-6.4.21-20250226/release/drivers/libEGL.so"
printf 'mock EULA\n' > "$mock/gcnano-userland-multi-stm32mp2-6.4.21-20250226/LICENSE"

# Re-create a self-contained mock extractor. build-userspace.sh copies the
# installer into a fresh directory before executing it, so the payload must not
# depend on files adjacent to the original mock installer.
cat > "$mock/gcnano-userland-multi-stm32mp2-6.4.21-20250226.bin" <<'SH'
#!/bin/sh
set -eu
dst="gcnano-userland-multi-stm32mp2-6.4.21-20250226"
mkdir -p "$dst/release/drivers"
python3 - "$dst/release/drivers/libGAL.so" <<'PY'
import struct, sys
hdr = bytearray(64)
hdr[0:4] = b'\x7fELF'
hdr[4:7] = b'\x02\x01\x01'
struct.pack_into('<HHIQQQIHHHHHH', hdr, 16,
                 1, 183, 1, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0)
open(sys.argv[1], 'wb').write(hdr)
PY
cp "$dst/release/drivers/libGAL.so" "$dst/release/drivers/libEGL.so.1"
ln -s libEGL.so.1 "$dst/release/drivers/libEGL.so"
printf 'mock EULA\n' > "$dst/LICENSE"
SH
chmod 0755 "$mock/gcnano-userland-multi-stm32mp2-6.4.21-20250226.bin"

"$ROOT/scripts/build-all.sh" \
    --source "$mock" --version 6.4.21 --userland-date 20250226 --out "$work/out" \
    --maintainer 'Template Test <test@example.invalid>' >/dev/null

dpkg-deb -f "$work/out/stm32mp2-gpu-dkms_6.4.21+20250226-1_all.deb" Package | grep -qx stm32mp2-gpu-dkms
dpkg-deb -f "$work/out/stm32mp2-gpu-userspace_6.4.21+20250226-1_arm64.deb" Architecture | grep -qx arm64
dpkg-deb -f "$work/out/stm32mp2-gpu-driver_6.4.21+20250226-1_all.deb" Package | grep -qx stm32mp2-gpu-driver
dpkg-deb -c "$work/out/stm32mp2-gpu-dkms_6.4.21+20250226-1_all.deb" | grep -q 'dkms-make.sh'
dpkg-deb -c "$work/out/stm32mp2-gpu-userspace_6.4.21+20250226-1_arm64.deb" | grep -q 'libGAL.so'

echo 'STM32MP2-only template checks passed.'
