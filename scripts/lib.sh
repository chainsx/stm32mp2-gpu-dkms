#!/usr/bin/env bash
set -Eeuo pipefail

die() {
    echo "error: $*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

safe_version() {
    local version="$1"
    [[ "$version" =~ ^[0-9][0-9A-Za-z.+:~_-]*$ ]] || die "invalid Debian version: $version"
}

safe_date() {
    [[ "$1" =~ ^[0-9]{8}$ ]] || die "date must use YYYYMMDD"
}

first_license_file() {
    local root="$1"
    find "$root" -maxdepth 5 -type f \( -iname 'license*' -o -iname 'eula*' -o -iname 'copying*' \) -print \
        | LC_ALL=C sort \
        | head -n 1
}

get_upstream_commit() {
    local source="$1"
    if [[ -f "$source/.gcnano-upstream-commit" ]]; then
        cat "$source/.gcnano-upstream-commit"
    elif [[ -d "$source/.git" ]]; then
        git -C "$source" rev-parse HEAD
    else
        printf 'unknown\n'
    fi
}

package_version() {
    local version="$1" date="$2"
    printf '%s+%s-1\n' "$version" "$date"
}

dkms_version() {
    local version="$1" date="$2"
    printf '%s+%s\n' "$version" "$date"
}
