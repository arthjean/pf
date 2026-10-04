#!/bin/bash
# Restores pf release files in R2 from GitHub Releases, their canonical copy.
# For each release it downloads every archive, checksum, and signature,
# verifies each signature and its trusted comment against a public key in
# release_keys.zig, then uploads the files with scripts/publish-release.sh,
# so paths and headers match release.yml. A release that fails is skipped and
# reported, and the script exits nonzero after processing the others.
#
# agent/latest.txt moves only with --update-latest, when the newest GitHub
# Release is among the targets and was verified and uploaded, so it never
# points backward. With --dry-run it downloads and verifies, then prints the
# uploads it would make, without credentials and without writing anything.

set -euo pipefail

gh_bin="${PF_PUBLISH_GH_BIN:-gh}"
minisign_bin="${PF_MINISIGN_BIN:-minisign}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
release_keys="${PF_RELEASE_KEYS_FILE:-${script_dir}/../src/core/upgrade/release_keys.zig}"
archives=(
    pf-linux-x86_64.tar.gz
    pf-linux-aarch64.tar.gz
    pf-macos-x86_64.tar.gz
    pf-macos-aarch64.tar.gz
    pf-windows-x86_64.zip
)
version_re='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

report() {
    echo "$1"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        echo "$1" >>"${GITHUB_STEP_SUMMARY}"
    fi
}

fail() {
    report "$1" >&2
    exit 1
}

contains() {
    local needle="$1" item
    shift
    for item in "$@"; do
        [[ "${item}" == "${needle}" ]] && return 0
    done
    return 1
}

dry_run=false
update_latest=false
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --dry-run) dry_run=true ;;
        --update-latest) update_latest=true ;;
        *) fail "Unknown option: $1" ;;
    esac
    shift
done
if [[ $# -ne 1 ]]; then
    fail "usage: backfill-release.sh [--dry-run] [--update-latest] <vX.Y.Z|all>"
fi
target="$1"
if [[ "${target}" != all && ! "${target}" =~ ${version_re} ]]; then
    fail "Version must be vX.Y.Z or all: ${target}"
fi

keys=()
for slot in active next; do
    key="$(sed -n "s/^pub const ${slot} = \"\(.*\)\";$/\1/p" "${release_keys}")"
    [[ -n "${key}" ]] && keys+=("${key}")
done
[[ ${#keys[@]} -gt 0 ]] || fail "release_keys.zig has no minisign public key"

listing="$("${gh_bin}" release list --exclude-drafts --exclude-pre-releases \
    --limit 1000 --json tagName --jq '.[].tagName')" || fail "Could not list GitHub Releases."
releases=()
while IFS= read -r tag; do
    [[ "${tag}" =~ ${version_re} ]] && releases+=("${tag}")
done < <(sort -V <<<"${listing}")
if [[ ${#releases[@]} -eq 0 ]]; then
    report "No GitHub Release exists; nothing to backfill."
    exit 0
fi
newest="${releases[${#releases[@]} - 1]}"
if [[ "${target}" == all ]]; then
    targets=("${releases[@]}")
elif contains "${target}" "${releases[@]}"; then
    targets=("${target}")
else
    fail "No GitHub Release ${target} exists; nothing to backfill."
fi

work_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pf-backfill.XXXXXX")"
trap 'rm -rf "${work_dir}"' EXIT

# Prints why a signature is refused, or nothing when one key verifies it and
# its trusted comment names this file, version, and the stable channel.
signature_problem() {
    local dir="$1" name="$2" version="$3" key output
    [[ -f "${dir}/${name}" ]] || { echo "missing ${name}"; return; }
    [[ -f "${dir}/${name}.minisig" ]] || { echo "missing ${name}.minisig"; return; }
    for key in "${keys[@]}"; do
        if output="$("${minisign_bin}" -V -P "${key}" -m "${dir}/${name}" \
            -x "${dir}/${name}.minisig" 2>&1)"; then
            if grep -qxF "Trusted comment: file:${name} version:${version} channel:stable" <<<"${output}"; then
                return
            fi
            echo "${name}.minisig belongs to a different release"
            return
        fi
    done
    echo "${name}.minisig does not verify against release_keys.zig"
}

failed=()
for version in "${targets[@]}"; do
    dir="${work_dir}/${version}"
    mkdir -p "${dir}"
    if ! "${gh_bin}" release download "${version}" --dir "${dir}" --pattern 'pf-*'; then
        report "Skipped ${version}: its assets could not be downloaded."
        failed+=("${version}")
        continue
    fi
    problem=""
    for archive in "${archives[@]}"; do
        problem="$(signature_problem "${dir}" "${archive}" "${version}")"
        [[ -z "${problem}" ]] || break
    done
    if [[ -n "${problem}" ]]; then
        report "Skipped ${version}: ${problem}."
        failed+=("${version}")
        continue
    fi
    args=(--r2-only)
    [[ "${dry_run}" == true ]] && args+=(--dry-run)
    if [[ "${update_latest}" != true || "${version}" != "${newest}" ]]; then
        args+=(--no-latest)
    fi
    if ! "${script_dir}/publish-release.sh" "${args[@]}" "${version}" "${dir}"; then
        report "Skipped ${version}: its upload failed."
        failed+=("${version}")
    fi
done

if [[ "${update_latest}" == true ]] && ! contains "${newest}" "${targets[@]}"; then
    report "latest.txt unchanged: ${newest} is the newest release and was not backfilled."
fi
if [[ ${#failed[@]} -gt 0 ]]; then
    fail "Backfill failed for ${failed[*]}; the other releases were processed."
fi
report "Backfilled ${#targets[@]} release(s)."
