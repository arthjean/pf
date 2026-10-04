#!/bin/bash
# Publishes a signed pf release: the GitHub Release first, then every archive,
# checksum, and signature to R2 under agent/<version>/, and agent/latest.txt
# last, so clients never see a version whose files are incomplete.
#
# With --dev it publishes a dev build instead: no GitHub Release, the files go
# under agent/dev/<commit>/, agent/dev.json moves to the build only while main
# still points at its commit, and retention then removes the oldest dev builds
# beyond the newest 30, never the one dev.json names.
#
# With --dry-run it checks the release files and prints every destination and
# header it would write, without credentials and without writing anything.
# --r2-only skips the GitHub Release and --no-latest leaves agent/latest.txt
# alone; scripts/backfill-release.sh uses them to restore R2 from GitHub.

set -euo pipefail

rclone_bin="${PF_PUBLISH_RCLONE_BIN:-rclone}"
gh_bin="${PF_PUBLISH_GH_BIN:-gh}"
git_bin="${PF_PUBLISH_GIT_BIN:-git}"

immutable_cache="Cache-Control: public, max-age=31536000, immutable"
manifest_cache="Cache-Control: no-cache"
dev_retention=30
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

note() {
    echo "$1"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        echo "$1" >>"${GITHUB_STEP_SUMMARY}"
    fi
}

dry_run=false
dev=false
github_release=true
update_latest=true
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --dry-run) dry_run=true ;;
        --dev) dev=true ;;
        --r2-only) github_release=false ;;
        --no-latest) update_latest=false ;;
        *) fail "Unknown option: $1" ;;
    esac
    shift
done
commit=""
notes_file=""
if [[ "${dev}" == true ]]; then
    if [[ $# -ne 3 ]]; then
        fail "usage: publish-release.sh --dev [--dry-run] <version> <commit> <artifact-dir>"
    fi
    version="$1"
    commit="$2"
    artifact_dir="$3"
    github_release=false
    if [[ ! "${commit}" =~ ^[0-9a-f]{40}$ ]]; then
        fail "Dev build commit must be a full commit SHA: ${commit}"
    fi
    release_path="dev/${commit}"
    manifest=dev.json
else
    if [[ $# -lt 2 || $# -gt 3 ]]; then
        fail "usage: publish-release.sh [--dry-run] [--r2-only] [--no-latest] <version> <artifact-dir> [<notes-file>]"
    fi
    version="$1"
    artifact_dir="$2"
    notes_file="${3:-}"
    release_path="${version}"
    manifest=latest.txt
fi
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
        fail "Upload failed: ${name}; ${manifest} unchanged."
    fi
}

for file in "${files[@]}"; do
    case "${file}" in
        *.tar.gz) content_type=application/gzip ;;
        *.zip) content_type=application/zip ;;
        *) content_type=text/plain ;;
    esac
    upload "${artifact_dir}/${file}" "${destination}/${release_path}/${file}" \
        "${content_type}" "${immutable_cache}" "${file}"
done

# Removes the oldest dev builds beyond the newest ${dev_retention}, ordered by
# their newest upload time, and never the build that dev.json names.
retain_dev_builds() {
    local current="$1" listing builds count=0 build
    if ! listing="$("${rclone_bin}" lsf --recursive --files-only --use-server-modtime \
        --format tp --separator ';' "${destination}/dev/")"; then
        fail "Retention failed: cannot list dev builds; no build was removed."
    fi
    builds="$(printf '%s\n' "${listing}" | awk -F';' '
        { n = split($2, parts, "/"); build = parts[1] }
        n == 2 && length(build) == 40 && build ~ /^[0-9a-f]+$/ {
            if ($1 > newest[build]) newest[build] = $1
        }
        END { for (build in newest) print newest[build] ";" build }
    ' | sort -r)"
    while IFS=';' read -r _ build; do
        [[ -n "${build}" ]] || continue
        count=$((count + 1))
        if ((count <= dev_retention)) || [[ "${build}" == "${current}" ]]; then
            continue
        fi
        echo "Removing dev build ${build}"
        if ! "${rclone_bin}" purge "${destination}/dev/${build}"; then
            fail "Retention failed: could not remove dev build ${build}."
        fi
    done <<<"${builds}"
}

if [[ "${dev}" == true ]]; then
    if [[ "${dry_run}" == true ]]; then
        echo "${prefix}dev.json -> ${destination}/dev.json (Content-Type: application/json; ${manifest_cache}) if main still points at ${commit}"
        echo "${prefix}retention keeps the newest ${dev_retention} dev builds under ${destination}/dev/ and the one dev.json names"
    else
        if ! main_sha="$("${git_bin}" ls-remote origin refs/heads/main | cut -f1)" \
            || [[ ! "${main_sha}" =~ ^[0-9a-f]{40}$ ]]; then
            fail "Cannot read main from origin; dev.json unchanged."
        fi
        if [[ "${main_sha}" == "${commit}" ]]; then
            manifest_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pf-publish.XXXXXX")"
            trap 'rm -rf "${manifest_dir}"' EXIT
            printf '{"version":"%s","commit":"%s"}\n' "${version#v}" "${commit}" >"${manifest_dir}/dev.json"
            upload "${manifest_dir}/dev.json" "${destination}/dev.json" \
                application/json "${manifest_cache}" dev.json
            current="${commit}"
        else
            note "main advanced to ${main_sha}; dev.json unchanged."
            current=""
            if dev_json="$("${rclone_bin}" cat "${destination}/dev.json")" \
                && [[ "${dev_json}" =~ \"commit\":\"([0-9a-f]{40})\" ]]; then
                current="${BASH_REMATCH[1]}"
            fi
        fi
        if [[ -n "${current}" ]]; then
            retain_dev_builds "${current}"
        else
            note "Retention skipped: cannot read the commit dev.json names; no build was removed."
        fi
    fi
    echo "${prefix}Published dev build ${commit}"
    exit 0
fi

if [[ "${update_latest}" == true ]]; then
    latest_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pf-publish.XXXXXX")"
    trap 'rm -rf "${latest_dir}"' EXIT
    printf '%s' "${version}" >"${latest_dir}/latest.txt"
    upload "${latest_dir}/latest.txt" "${destination}/latest.txt" \
        text/plain "${manifest_cache}" latest.txt
fi
echo "${prefix}Published ${version}"
