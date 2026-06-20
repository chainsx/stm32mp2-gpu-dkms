#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

repo_dir=
key_id=
public_key=
origin="STM32MP2 GCNANO APT Archive"
label="STM32MP2 GCNANO APT Archive"

usage() {
    cat <<'USAGE'
Usage: update-apt-repo.sh --repo DIR --key-id KEY --public-key PATH [options]
  --repo DIR           Flat repository directory containing .deb files
  --key-id KEY         GPG fingerprint/key ID used to sign Release
  --public-key PATH    Output ASCII-armored archive key
  --origin TEXT        Release Origin field
  --label TEXT         Release Label field
USAGE
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) repo_dir="$2"; shift 2 ;;
        --key-id) key_id="$2"; shift 2 ;;
        --public-key) public_key="$2"; shift 2 ;;
        --origin) origin="$2"; shift 2 ;;
        --label) label="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[[ -n "$repo_dir" && -n "$key_id" && -n "$public_key" ]] || { usage >&2; exit 64; }
need apt-ftparchive
need gpg

test -d "$repo_dir" || die "repository directory does not exist: $repo_dir"
compgen -G "$repo_dir/*.deb" >/dev/null || die "no .deb files in $repo_dir"
mkdir -p "$(dirname -- "$public_key")"

pushd "$repo_dir" >/dev/null
apt-ftparchive packages . > Packages
gzip -9 -f -k Packages
xz -9e -f -k Packages
apt-ftparchive \
    -o "APT::FTPArchive::Release::Origin=$origin" \
    -o "APT::FTPArchive::Release::Label=$label" \
    -o 'APT::FTPArchive::Release::Suite=./' \
    -o 'APT::FTPArchive::Release::Codename=./' \
    -o 'APT::FTPArchive::Release::Architectures=arm64 all' \
    -o 'APT::FTPArchive::Release::Components=main' \
    release . > Release

gpg_sign_args=(--batch --yes --local-user "$key_id")
if [[ -n "${APT_GPG_PASSPHRASE:-}" ]]; then
    gpg_sign_args+=(--pinentry-mode loopback --passphrase "$APT_GPG_PASSPHRASE")
fi
gpg "${gpg_sign_args[@]}" --armor --detach-sign --output Release.gpg Release
gpg "${gpg_sign_args[@]}" --clearsign --output InRelease Release
popd >/dev/null

gpg --batch --yes --armor --export "$key_id" > "$public_key"
