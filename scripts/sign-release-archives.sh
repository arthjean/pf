#!/bin/bash
# Signs pf release archives with the release minisign key, then verifies each
# signature against the active public key committed in release_keys.zig.

set -euo pipefail

umask 077

minisign_bin="${PF_MINISIGN_BIN:-minisign}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
release_keys="${PF_RELEASE_KEYS_FILE:-${script_dir}/../src/core/upgrade/release_keys.zig}"

fail() {
    echo "$1" >&2
    exit 1
}

if [[ $# -lt 3 ]]; then
    fail "usage: sign-release-archives.sh <version> <channel> <archive>..."
fi
version="$1"
channel="$2"
shift 2
if [[ ! "${version}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    fail "Release version must look like vX.Y.Z: ${version}"
fi
if [[ "${channel}" != stable ]]; then
    fail "Unsupported release channel: ${channel}"
fi
for archive in "$@"; do
    [[ -f "${archive}" ]] || fail "Archive not found: ${archive}"
done
if [[ -z "${PF_MINISIGN_SECRET_KEY:-}" ]]; then
    fail "Missing required environment variable: PF_MINISIGN_SECRET_KEY"
fi
public_key="$(sed -n 's/^pub const active = "\(.*\)";$/\1/p' "${release_keys}")"
if [[ ! "${public_key}" =~ ^RW[A-Za-z0-9+/]{54}$ ]]; then
    fail "release_keys.zig has no active minisign public key"
fi

key_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pf-minisign.XXXXXX")"
trap 'rm -rf "${key_dir}"' EXIT
printf '%s\n' "${PF_MINISIGN_SECRET_KEY}" >"${key_dir}/minisign.key"

for archive in "$@"; do
    name="$(basename "${archive}")"
    comment="file:${name} version:${version} channel:${channel}"
    if ! "${minisign_bin}" -S -s "${key_dir}/minisign.key" -m "${archive}" \
        -x "${archive}.minisig" -t "${comment}" </dev/null >/dev/null; then
        fail "minisign failed to sign ${name}"
    fi
    if ! sed -n 2p "${archive}.minisig" | base64 -d >"${key_dir}/signature" 2>/dev/null \
        || [[ "$(head -c 2 "${key_dir}/signature")" != ED ]]; then
        fail "${name}.minisig does not use the prehashed ED algorithm"
    fi
    if ! verification="$("${minisign_bin}" -V -P "${public_key}" -m "${archive}" \
        -x "${archive}.minisig" 2>&1)"; then
        fail "minisign verification failed for ${name}"
    fi
    if [[ "${verification}" != *"Trusted comment: ${comment}"* ]]; then
        fail "${name}.minisig carries an unexpected trusted comment"
    fi
    echo "Signed and verified ${name} (${comment})"
done
