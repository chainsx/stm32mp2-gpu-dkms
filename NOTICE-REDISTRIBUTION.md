# Third-party payload and redistribution notice

This repository contains only packaging glue. It does not commit or vendor the
STMicroelectronics GCNANO user-space installer. The GitHub Actions workflow
fetches the installer from the STMicroelectronics upstream repository only when
it is run.

The OpenSTLinux `gcnano-userland-binary.inc` recipe declares the user-space
component as `Proprietary` and requires explicit acceptance of the ST EULA.
Before enabling a public GitHub Pages APT repository, the operator must review
the exact upstream license/EULA and independently determine whether public
redistribution of the generated `stm32mp2-gpu-userspace` `.deb` is permitted.

The workflow requires both `accept_st_eula=true` and
`confirm_public_redistribution_rights=true`. These acknowledgements are an
operator-controlled gate; they are not legal advice and do not grant rights.
