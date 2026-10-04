#!/bin/bash
# Publishes a signed pf release: the GitHub Release first, then every archive,
# checksum, and signature to R2 under agent/<version>/, and agent/latest.txt
# last, so clients never see a version whose files are incomplete.
#
# With --dry-run it checks the release files and prints every destination and
# header it would write, without credentials and without writing anything.
# --r2-only skips the GitHub Release and --no-latest leaves agent/latest.txt
# alone; scripts/backfill-release.sh uses them to restore R2 from GitHub.

set -euo pipefail

rclone_bin="${PF_PUBLISH_RCLONE_BIN:-rclone}"
gh_bin="${PF_PUBLISH_GH_BIN:-gh}"

immutable_cache="Cache-Control: public, max-age=31536000, immutable"
manifest_cache="Cache-Control: no-cache"
archives=(
    pf-linux-x86_64.tar.gz
    pf-linux-aarch64.tar.gz
    pf-macos-x86_64.tar.gz
    pf-macos-aarch64.tar.gz
    pf-windows-x86_64.zip
)

fail() {
    echo "$1" >&2
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        echo "$1" >>"${GITHUB_STEP_SUMMARY}"
    fi
    exit 1
}

dry_run=false
github_release=true
update_latest=true
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --dry-run) dry_run=true ;;
        --r2-only) github_release=false ;;
        --no-latest) update_latest=false ;;
        *) fail "Unknown option: $1" ;;
    esac
    shift
done
if [[ $# -lt 2 || $# -gt 3 ]]; then
    fail "usage: publish-release.sh [--dry-run] [--r2-only] [--no-latest] <version> <artifact-dir> [<notes-file>]"
fi
version="$1"
artifact_dir="$2"
notes_file="${3:-}"
if [[ ! "${version}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    fail "Release version must look like vX.Y.Z: ${version}"
fi

files=()
for archive in "${archives[@]}"; do
    for file in "${archive}" "${archive}.sha256" "${archive}.minisig"; do
        [[ -f "${artifact_dir}/${file}" ]] || fail "Missing release file: ${file}"
        files+=("${file}")
    done
done

if [[ "${dry_run}" == false ]]; then
    if [[ "${github_release}" == true && ! -f "${notes_file}" ]]; then
        fail "Missing release notes file: ${notes_file:-<none>}"
    fi
    for required_name in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET; do
        if [[ -z "${!required_name:-}" ]]; then
            fail "Missing required environment variable: ${required_name}"
        fi
    done
    # A bucket path in the endpoint makes rclone store every key under
    # <bucket>/ inside the bucket and still report success.
    if [[ ! "${R2_ENDPOINT}" =~ ^https://[0-9a-f]{32}\.r2\.cloudflarestorage\.com/?$ ]]; then
        fail "R2_ENDPOINT must be https://<account-id>.r2.cloudflarestorage.com with no path"
    fi
    export RCLONE_CONFIG_R2_TYPE=s3
    export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
    export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
    export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
    export RCLONE_CONFIG_R2_ENDPOINT="${R2_ENDPOINT}"
    export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
fi
destination="r2:${R2_BUCKET:-<R2_BUCKET>}/agent"
prefix=""
[[ "${dry_run}" == true ]] && prefix="dry run: "

if [[ "${github_release}" == true ]]; then
    echo "${prefix}GitHub Release ${version} with ${#files[@]} assets"
fi
if [[ "${dry_run}" == false && "${github_release}" == true ]]; then
    asset_paths=()
    for file in "${files[@]}"; do
        asset_paths+=("${artifact_dir}/${file}")
    done
    if ! "${gh_bin}" release create "${version}" --verify-tag --title "${version}" \
        --notes-file "${notes_file}" "${asset_paths[@]}"; then
        fail "GitHub Release ${version} failed; nothing was uploaded to R2."
    fi
fi

upload() {
    local source="$1" target="$2" content_type="$3" cache="$4" name="$5"
    echo "${prefix}${name} -> ${target} (Content-Type: ${content_type}; ${cache})"
    [[ "${dry_run}" == true ]] && return 0
    if ! "${rclone_bin}" copyto "${source}" "${target}" \
        --header-upload "${cache}" \
        --header-upload "Content-Type: ${content_type}"; then
        fail "Upload failed: ${name}; latest.txt unchanged."
    fi
}

for file in "${files[@]}"; do
    case "${file}" in
        *.tar.gz) content_type=application/gzip ;;
        *.zip) content_type=application/zip ;;
        *) content_type=text/plain ;;
    esac
    upload "${artifact_dir}/${file}" "${destination}/${version}/${file}" \
        "${content_type}" "${immutable_cache}" "${file}"
done

if [[ "${update_latest}" == true ]]; then
    latest_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pf-publish.XXXXXX")"
    trap 'rm -rf "${latest_dir}"' EXIT
    printf '%s' "${version}" >"${latest_dir}/latest.txt"
    upload "${latest_dir}/latest.txt" "${destination}/latest.txt" \
        text/plain "${manifest_cache}" latest.txt
fi
echo "${prefix}Published ${version}"
