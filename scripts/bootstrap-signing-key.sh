#!/usr/bin/env bash
set -Eeuo pipefail

name=
email=
out=.secrets
usage() {
    cat <<'USAGE'
Usage: bootstrap-signing-key.sh --name NAME --email EMAIL [--out DIRECTORY]

Creates a dedicated OpenPGP signing key and exports only the files needed to
configure the GitHub Actions secrets. Store the output directory securely and
never commit its private-key.asc file.
USAGE
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name) name="$2"; shift 2 ;;
        --email) email="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 64 ;;
    esac
done
[[ -n "$name" && -n "$email" ]] || { usage >&2; exit 64; }
command -v gpg >/dev/null 2>&1 || { echo 'gpg is required' >&2; exit 1; }

mkdir -p "$out"
GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT
chmod 700 "$GNUPGHOME"
gpg --batch --passphrase '' --quick-generate-key "$name <$email>" ed25519 sign 3y
fingerprint="$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" {print $10; exit}')"
[[ -n "$fingerprint" ]] || { echo 'unable to obtain signing-key fingerprint' >&2; exit 1; }
gpg --batch --armor --export-secret-keys "$fingerprint" > "$out/private-key.asc"
gpg --batch --armor --export "$fingerprint" > "$out/public-key.asc"
printf '%s\n' "$fingerprint" > "$out/fingerprint.txt"
chmod 600 "$out/private-key.asc"
printf 'Wrote %s/{private-key.asc,public-key.asc,fingerprint.txt}\n' "$out"
