# stm32mp2-gpu-dkms

Debian/Ubuntu packaging for the STMicroelectronics Vivante GCNANO GPU stack on
**STM32MP2 only**. The repository produces a signed GitHub Pages APT repository
for ARM64 targets and does not package STM32MP1 or `armhf` artifacts.

The package set is:

| Package | Architecture | Role |
|---|---:|---|
| `stm32mp2-gpu-dkms` | `all` | Installs the GCNANO source for DKMS and builds `galcore.ko` on the target. |
| `stm32mp2-gpu-userspace` | `arm64` | Installs the ST user-space payload in a private AArch64 library directory. |
| `stm32mp2-gpu-driver` | `all` | Installs the matched DKMS and user-space packages. |

## Scope

The DKMS wrapper is hard-coded for the upstream STM32MP2 build parameters:

```text
SOC_PLATFORM=st-mp2
ARCH_TYPE=arm64
KERNEL_DIR=/lib/modules/<kernel-release>/build
```

It deliberately does not use an `O=` parameter because the ST upstream Makefile
passes `KERNEL_DIR` into its Kbuild call. The package builds a kernel module; it
does not add a missing Vivante GPU device-tree node, clocks, power domains, CMA
reservation, or DRM/KMS configuration. Use it only with a GPU-enabled
STM32MP2-compatible kernel and device tree.

## Defaults pinned to current ST metadata

The workflow defaults to:

```text
GCNANO branch:      gcnano-6.4.21-binaries
STM32MP2 installer: gcnano-userland-multi-stm32mp2-6.4.21-20250226.bin
OpenSTLinux pin:    dc7084b153d26087c12c1b08256cedf17fa12b06
```

The selected branch, resolved commit, and package SHA-256 values are written to
`BUILD-MANIFEST.txt` in every Pages deployment. Update all three workflow inputs
together for a future ST release.

## Licensing and publication gate

The ST OpenSTLinux recipe marks the GCNANO user-space component as proprietary
and requires ST EULA acceptance. This repository contains no upstream installer
or output `.deb` by default. Before publishing a Pages repository, review the
applicable ST license/EULA and your redistribution rights.

The workflow refuses to run unless both manual confirmations are `true`:

- `accept_st_eula`
- `confirm_public_redistribution_rights`

See [NOTICE-REDISTRIBUTION.md](NOTICE-REDISTRIBUTION.md).

## GitHub setup for `chainsx/stm32mp2-gpu-dkms`

The target repository currently has no files, so the initial push can be made
from this template directory:

```bash
git init -b main
git add .
git commit -m "Add STM32MP2 GCNANO DKMS and APT Pages packaging"
git remote add origin https://github.com/chainsx/stm32mp2-gpu-dkms.git
git push -u origin main
```

Then configure **Settings → Pages → Source → GitHub Actions**.

Create and export a dedicated archive-signing key locally:

```bash
./scripts/bootstrap-signing-key.sh \
  --name "STM32MP2 GCNANO APT Archive" \
  --email "cchainsx@gmail.com" \
  --out .secrets
```

Add `.secrets/private-key.asc` as the Actions secret `APT_GPG_PRIVATE_KEY`.
`APT_GPG_PASSPHRASE` is optional if the key was created with a passphrase.
Run **Actions → Build and publish STM32MP2 GCNANO APT repository** and provide
the two mandatory legal acknowledgements.

## Target-side installation

After the first successful Pages deployment, the APT root is:

```text
https://chainsx.github.io/stm32mp2-gpu-dkms/
```

On the STM32MP2 ARM64 target:

```bash
curl -fsSL https://chainsx.github.io/stm32mp2-gpu-dkms/KEY.gpg \
  | gpg --dearmor \
  | sudo tee /usr/share/keyrings/stm32mp2-gpu-archive-keyring.gpg >/dev/null

sudo tee /etc/apt/sources.list.d/stm32mp2-gpu.sources >/dev/null <<'EOF2'
Types: deb
URIs: https://chainsx.github.io/stm32mp2-gpu-dkms/debian
Suites: ./
Architectures: arm64
Signed-By: /usr/share/keyrings/stm32mp2-gpu-archive-keyring.gpg
EOF2

sudo apt update
sudo apt install linux-headers-$(uname -r) build-essential dkms
sudo apt install stm32mp2-gpu-driver
```

Verify the module and userspace stack:

```bash
dkms status
sudo modprobe galcore
modinfo galcore
journalctl -k -b | grep -i -E 'galcore|vivante|gpu'
stm32mp2-gpu-env eglinfo
```

If `linux-headers-$(uname -r)` is unavailable, obtain headers that exactly
match the vendor kernel release before asking DKMS to build. A generic Ubuntu
ARM64 kernel is not automatically sufficient merely because the package builds.

## Local package build

The self-extracting ST user-space installer is invoked with `sh … --auto-accept`,
matching the OpenSTLinux recipe, so an x86_64 builder can create the ARM64 `.deb`
without executing AArch64 code. The actual kernel module compilation occurs on
the target through DKMS.

```bash
./scripts/install-build-deps.sh
./scripts/fetch-upstream.sh \
  --version 6.4.21 \
  --commit dc7084b153d26087c12c1b08256cedf17fa12b06 \
  --dest upstream
./scripts/build-all.sh \
  --source upstream \
  --version 6.4.21 \
  --userland-date 20250226 \
  --out dist/debian \
  --maintainer "chainsx <cchainsx@gmail.com>"
```

For a static template check that does not fetch upstream or redistribute any
binary payload:

```bash
./scripts/test-template.sh
```

## Upstream basis

- ST OpenSTLinux distribution documentation: `STM32MPU Distribution Package`
- ST GCNANO repository: `STMicroelectronics/gcnano-binaries`
- ST OpenSTLinux recipe: `recipes-graphics/gcnano-userland/gcnano-userland-binary.inc`

This repository is independent packaging glue and is not affiliated with or
supported by STMicroelectronics.
