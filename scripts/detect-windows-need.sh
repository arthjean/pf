#!/usr/bin/env bash
# Decide whether a change needs the Windows x86_64 checks.
#
# Usage: detect-windows-need.sh <base-revision> <head-revision>
#
# Windows runs only when a change touches behavior that can differ on Windows:
# a Zig file with a Windows code path or any operating system branch before or
# after the change, build.zig, the Windows signing script, an E2E file that
# tests/e2e/windows-subset.ts runs, a shared E2E helper that reads the platform
# before or after the change, or the Windows checks themselves. Any operating
# system branch counts because Windows may take its other path. Set
# WINDOWS_REQUESTED to a reason to force the checks.
#
# Writes needed=true|false to $GITHUB_OUTPUT and the reasons to
# $GITHUB_STEP_SUMMARY when those files are set. Exits non-zero when either
# revision cannot be read, so the Windows check fails instead of passing
# without having looked at the change.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  printf 'usage: %s <base-revision> <head-revision>\n' "$0" >&2
  exit 2
fi

base="$1"
head="$2"
subset=tests/e2e/windows-subset.ts

needed=false
reasons=()

require() {
  needed=true
  reasons+=("$1")
}

# Matches either side of the change, so removing a platform branch counts too.
has_platform_code() {
  local content
  content="$({ git show "$head:$1" 2>/dev/null; git show "$base:$1" 2>/dev/null; } || true)"
  grep -Eq "$2" <<<"$content"
}

zig_platform_code='\.windows([^A-Za-z0-9_]|$)|[Ww]in32|[Cc]on[Pp][Tt][Yy]|os\.tag|native_os'
ts_platform_code='process\.platform|platform\(\)'

if [ ! -f "$subset" ]; then
  printf 'error: %s is missing; the Windows check cannot decide\n' "$subset" >&2
  exit 1
fi
subset_files="$(grep -Eo '"[A-Za-z0-9_.-]+\.test\.ts"' "$subset" | tr -d '"' || true)"
if [ -z "$subset_files" ]; then
  printf 'error: %s lists no test file; the Windows check cannot decide\n' "$subset" >&2
  exit 1
fi

for revision in "$base" "$head"; do
  if ! git rev-parse --verify --quiet "$revision^{commit}" >/dev/null; then
    printf 'error: cannot read revision %s; the Windows check cannot decide\n' "$revision" >&2
    exit 1
  fi
done

if ! changed_files="$(git diff --name-only --no-renames "$base" "$head")"; then
  printf 'error: git diff %s %s failed; the Windows check cannot decide\n' "$base" "$head" >&2
  exit 1
fi

is_subset_test() {
  grep -q -x -F "$1" <<<"$subset_files"
}

if [ -n "${WINDOWS_REQUESTED:-}" ]; then
  require "$WINDOWS_REQUESTED"
fi

while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    .github/workflows/windows.yml | scripts/detect-windows-need.sh | "$subset")
      require "$path: the Windows checks changed" ;;
    build.zig | build.zig.zon)
      require "$path: build configuration changed" ;;
    scripts/sign-windows.ps1)
      require "$path: Windows signing changed" ;;
    *.zig)
      if has_platform_code "$path" "$zig_platform_code"; then
        require "$path: has a Windows or operating system code path"
      fi ;;
    tests/e2e/*.test.ts)
      name="${path#tests/e2e/}"
      if [[ "$name" != */* ]] && is_subset_test "$name"; then
        require "$path: Windows E2E file changed"
      fi ;;
    tests/e2e/*.ts)
      if has_platform_code "$path" "$ts_platform_code"; then
        require "$path: shared E2E helper has a platform branch"
      fi ;;
  esac
done <<<"$changed_files"

if [ "$needed" = true ]; then
  printf 'Windows x86_64 checks needed:\n'
  printf '  %s\n' "${reasons[@]}"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      printf '### Windows x86_64 checks run\n\n'
      printf -- '- %s\n' "${reasons[@]}"
    } >>"$GITHUB_STEP_SUMMARY"
  fi
else
  printf 'No Windows-specific change; Windows x86_64 checks skipped.\n'
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf 'No Windows-specific change; Windows x86_64 checks skipped.\n' >>"$GITHUB_STEP_SUMMARY"
  fi
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'needed=%s\n' "$needed" >>"$GITHUB_OUTPUT"
fi
