#!/usr/bin/env bash
# DKMS wrapper for the STM32MP2 GCNANO kernel module.
#
# This deliberately reproduces the OpenSTLinux recipe invocation:
#   make -C <kernel-build> M=<module-source> AQROOT=<module-source> ... modules
# Calling the Vivante top-level Makefile hides this relationship and makes
# failures harder to diagnose in DKMS logs.
set -Eeuo pipefail

kernelver="${1:?missing kernel version}"
module_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
kernel_build="/lib/modules/${kernelver}/build"
config=/etc/dkms/stm32mp2-gpu.conf

GCNANO_DEBUG="${GCNANO_DEBUG:-0}"
if [[ -r "$config" ]]; then
    # shellcheck disable=SC1090
    . "$config"
fi

case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
    arm64|aarch64)
        ;;
    *)
        echo "stm32mp2-gpu-dkms: STM32MP2 builds are supported only on arm64" >&2
        exit 2
        ;;
esac

if [[ ! -f "$kernel_build/Makefile" ]]; then
    echo "stm32mp2-gpu-dkms: missing matching kernel build Makefile: $kernel_build/Makefile" >&2
    echo "Install headers/source built for kernel ${kernelver}, then rerun dkms." >&2
    exit 3
fi

# Keep this command structurally identical to the ST OpenSTLinux module recipe.
# KERNEL_DIR is consumed by the Vivante source; M and AQROOT make the Linux
# Kbuild invocation unambiguous and preserve the source-root include paths.
exec make -C "$kernel_build" \
    M="$module_dir" \
    AQROOT="$module_dir" \
    KERNEL_DIR="$kernel_build" \
    SOC_PLATFORM=st-mp2 \
    DEBUG="$GCNANO_DEBUG" \
    modules
