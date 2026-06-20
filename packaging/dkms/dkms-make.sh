#!/usr/bin/env bash
# DKMS wrapper for STM32MP2 only.  The ST Makefile invokes Kbuild itself and
# consumes KERNEL_DIR; passing Linux's O= argument here is ineffective.
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
    echo "stm32mp2-gpu-dkms: missing matching kernel headers at $kernel_build" >&2
    exit 3
fi

# `gcnano-driver-stm32mp/Makefile` defines KERNEL_DIR and then delegates to
# Kbuild, whose `all` target runs: make -C $(KERNEL_DIR) M=$(pwd) modules.
# Build on the target, therefore no CROSS_COMPILE value is supplied.
make -C "$module_dir" \
    KERNEL_DIR="$kernel_build" \
    SOC_PLATFORM=st-mp2 \
    ARCH_TYPE=arm64 \
    DEBUG="$GCNANO_DEBUG"

test -f "$module_dir/galcore.ko"
