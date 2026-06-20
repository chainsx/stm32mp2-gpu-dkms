#!/usr/bin/env bash
set -Eeuo pipefail

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apt-utils binutils ca-certificates dpkg-dev file git gnupg make xz-utils
