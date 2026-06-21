# stm32mp2-gpu-dkms

Debian packaging for the OpenSTLinux-compatible STMicroelectronics Vivante GCNANO GPU stack on
**STM32MP2 only**. The repository produces a signed GitHub Pages APT repository
for ARM64 targets and does not package STM32MP1 or `armhf` artifacts.

The package set is:

| Package | Architecture | Role |
|---|---:|---|
| `stm32mp2-gpu-dkms` | `all` | Installs the GCNANO source for DKMS and builds `galcore.ko` on the target. |
| `stm32mp2-gpu-userspace` | `arm64` | OpenSTLinux default aggregate: EGL, GBM, GLESv1, GLESv2 and OpenVG. |
| `stm32mp2-gpu-libclc` | `arm64` | OpenCL/OpenVX compiler support, emitted only when present upstream. |
| `stm32mp2-gpu-libspirv` | `arm64` | OpenCL/Vulkan SPIR-V support, emitted only when present upstream. |
| `stm32mp2-gpu-opencl` | `arm64` | GCNANO OpenCL ICD plus `/etc/OpenCL/vendors/VeriSilicon.icd`. |
| `stm32mp2-gpu-vulkan` | `arm64` | GCNANO Vulkan ICD plus `/etc/vulkan/icd.d/VeriSilicon_icd.json`. |
| `stm32mp2-gpu-openvx` | `arm64` | OpenVX runtime plus `/etc/profile.d/openvx_profile.sh`. |
| `stm32mp2-gpu-openvx-kernels` | `arm64` | OpenVX kernel binaries required by the OpenVX runtime. |
| `stm32mp2-gpu-full` | `arm64` | Aggregate of all complete feature closures found in the selected ST installer. |
| `stm32mp2-gpu-driver` | `all` | Installs the matched DKMS and default OpenSTLinux user-space stack. |

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

## Debian/Ubuntu global GCNANO provider mode

GCNANO uses the direct OpenSTLinux EGL/GBM/GLES/OpenVG ABI. On Debian/Ubuntu
this repository does **not** overwrite files owned by Mesa or GLVND and does
not declare conflicts with `libegl1`, `libgbm1`, `libgles2`, or Mesa packages.
Those packages remain installed so applications such as `kmscube` can satisfy
their normal APT dependencies.

Instead, `stm32mp2-gpu-userspace` installs the direct Vivante libraries under
`/usr/lib/aarch64-linux-gnu/stm32mp2-gpu` and registers that directory first in
`/etc/ld.so.conf.d/00-stm32mp2-gpu.conf`. Compatible applications consequently
select GCNANO by default without `LD_LIBRARY_PATH` or a wrapper. The build
refuses to publish if the vendor SONAMEs are not ABI-compatible with the
Debian/Ubuntu EGL, GBM, GLESv1, GLESv2 and OpenVG runtime names.

After installation, verify default provider selection with:

```bash
/usr/lib/stm32mp2-gpu/graphics-stack-check
```

OpenCL, OpenVX and Vulkan remain feature-specific and retain their respective
ICD/profile activation methods.

## OpenSTLinux-aligned optional runtime closures

The ST recipe keeps `libGAL.so` and `libVSC.so` as the vendor core; it then
splits EGL, GBM, GLESv1, GLESv2, OpenVG, OpenCL, Vulkan, OpenVX, GLSLC, CLC and
SPIR-V by runtime dependency. The default graphics closure remains in
`stm32mp2-gpu-userspace` for a safe upgrade from revisions `-1` through `-3`.
The feature-gated closures are emitted as dedicated packages only when the
selected ST installer supplies their complete dependency set.

No optional vendor library is published without the activation mechanism used
by OpenSTLinux:

- OpenCL writes `VeriSilicon.icd`; the system OpenCL ICD loader reads it.
- Vulkan writes `VeriSilicon_icd.json`; `libvulkan1` reads it.
- OpenVX writes the ST `VIVANTE_SDK_DIR=/usr` profile and installs an explicit
  `stm32mp2-gpu-openvx-env` wrapper.
- Optional libraries depend on `stm32mp2-gpu-userspace`, which owns the private
  library-directory `ld.so.conf.d` entry needed by `libGAL`, `libVSC`, GLSLC,
  CLC and SPIR-V.

The optional-packaging step fails rather than silently discard any new
`release/drivers/lib*.so*` file from a future ST installer. The generated
`stm32mp2-gpu-full` package contains `GCNANO-LIBRARY-MAP.tsv`, mapping each
recognized vendor library to its Debian package and loader/profile activation.

## Defaults pinned to current ST metadata

The workflow defaults to:

```text
GCNANO branch:      gcnano-6.4.21-binaries
STM32MP2 installer: gcnano-userland-multi-stm32mp2-6.4.21-20250226.bin
OpenSTLinux pin:    dc7084b153d26087c12c1b08256cedf17fa12b06
```

The selected branch, resolved commit, and package SHA-256 values are written to
`BUILD-MANIFEST.txt` in every publication. Update all three workflow inputs
together for a future ST release.

## Generated repository files

A successful manual workflow run writes the generated APT repository back to the
`main` branch. The generated files are intentionally versioned, so the `.deb`
packages can be downloaded directly from this GitHub repository as well as
consumed through GitHub Pages:

```text
/debian/                         # component .deb files and signed flat APT metadata
/debian/Packages{,.gz,.xz}
/debian/Release /debian/Release.gpg /debian/InRelease
/KEY.gpg                         # public key corresponding to the Actions secret
/stm32mp2-gpu.sources            # source-list file for target devices
/BUILD-MANIFEST.txt              # upstream pin and SHA-256 values
```

The workflow replaces the entire generated `debian/` directory on each run, so
superseded packages and index files are removed from `main`. The private signing
key remains only in the `APT_GPG_PRIVATE_KEY` Actions secret.

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

# Optional: install every complete OpenCL/OpenVX/Vulkan closure emitted by
# the selected ST installer.
sudo apt install stm32mp2-gpu-full
```

Verify the module and userspace stack:

```bash
dkms status
sudo modprobe galcore
modinfo galcore
journalctl -k -b | grep -i -E 'galcore|vivante|gpu'
stm32mp2-gpu-env eglinfo
/usr/lib/stm32mp2-gpu/graphics-stack-check

# Present after installing stm32mp2-gpu-full.
/usr/lib/stm32mp2-gpu/optional-stack-check
vulkaninfo
```

If `linux-headers-$(uname -r)` is unavailable, obtain headers that exactly
match the vendor kernel release before asking DKMS to build. A generic Ubuntu
ARM64 kernel is not automatically sufficient merely because the package builds.

A stock Ubuntu rootfs that installs `libglvnd0` is also intentionally not a
valid target for the system-provider package; the installation aborts before
replacing the GLVND dispatcher. Use a non-GLVND OpenSTLinux-compatible rootfs.

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

## Complete SDK package

`stm32mp2-gpu-sdk` contains every header and pkg-config file supplied by the
selected ST installer. It depends on `stm32mp2-gpu-full`, which installs every
complete OpenSTLinux-aligned runtime closure emitted by that installer. SDK
headers are placed under `/usr/include/stm32mp2-gpu` so they do not overwrite
Mesa or GLVND development headers on Debian/Ubuntu. Use:

```sh
/usr/lib/stm32mp2-gpu/sdk-env pkg-config --cflags <package>
/usr/lib/stm32mp2-gpu/sdk-env <compiler-or-build-command>
/usr/lib/stm32mp2-gpu/sdk-check
```
