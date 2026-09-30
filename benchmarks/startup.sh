#!/usr/bin/env bash
#
# Startup latency benchmarks for pf.
#
# Measures wall-clock time for common CLI commands using hyperfine.
# Results are written to benchmarks/results/ in JSON format for CI consumption.
#
# Usage:
#   ./benchmarks/startup.sh              # run all benchmarks
#   ./benchmarks/startup.sh --quick      # fewer iterations (20 runs)
#   ./benchmarks/startup.sh --ci         # CI settings (100 runs, skip build)
#
# Requires: hyperfine (https://github.com/sharkdp/hyperfine)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PF_BIN="${REPO_ROOT}/zig-out/bin/pf"
RESULTS_DIR="${REPO_ROOT}/benchmarks/results"
SESSION_FIXTURE_ROOT="${TMPDIR:-/tmp}/pf-session-list-benchmark-$$"
SESSION_FIXTURE_HOME="${SESSION_FIXTURE_ROOT}/home"
SESSION_FIXTURE_WORKSPACE="${SESSION_FIXTURE_ROOT}/workspace"
GENERAL_FIXTURE_HOME="${SESSION_FIXTURE_ROOT}/general-home"

cleanup() {
  rm -rf "$SESSION_FIXTURE_ROOT"
}
trap cleanup EXIT

if ! command -v hyperfine &>/dev/null; then
  echo "error: hyperfine is not installed"
  echo "       brew install hyperfine  (macOS)"
  echo "       apt install hyperfine   (Debian/Ubuntu)"
  echo "       cargo install hyperfine (Rust/Cargo)"
  exit 1
fi

RUNS=100
WARMUP=10
SKIP_BUILD=false
SHELL_OPTS=(-N)
case "${1:-}" in
  --quick)  RUNS=20;  WARMUP=3 ;;
  --ci)     RUNS=100; WARMUP=10; SKIP_BUILD=true ;;
esac

if [ "$SKIP_BUILD" = false ]; then
  echo "Building pf (ReleaseSafe)..."
  (cd "$REPO_ROOT" && zig build -Doptimize=ReleaseSafe)
fi

if [ ! -x "$PF_BIN" ]; then
  echo "error: pf binary not found at $PF_BIN"
  exit 1
fi

mkdir -p "$RESULTS_DIR"
rm -f "${RESULTS_DIR}/tasks.json"
mkdir -p "$SESSION_FIXTURE_HOME" "$SESSION_FIXTURE_WORKSPACE" "$GENERAL_FIXTURE_HOME"
mkdir -p "$GENERAL_FIXTURE_HOME/.pf"
chmod 700 "$GENERAL_FIXTURE_HOME/.pf"
printf '%s\n' \
  '{"model":"openai/gpt-5.4","effort":"high","fast_mode":false,"startup_scrollback":true,"prompt_history":{"enabled":true},"statusLine":{"sandbox":true,"context":true},"permission":{"bash":{"git status *":"allow"}}}' \
  > "$GENERAL_FIXTURE_HOME/.pf/settings.json"
chmod 600 "$GENERAL_FIXTURE_HOME/.pf/settings.json"
python3 "${REPO_ROOT}/benchmarks/session_list_fixture.py" \
  --home "$SESSION_FIXTURE_HOME" \
  --workspace "$SESSION_FIXTURE_WORKSPACE"

if [ -x /usr/bin/true ]; then
  TRUE_BIN=/usr/bin/true
elif [ -x /bin/true ]; then
  TRUE_BIN=/bin/true
else
  TRUE_BIN=true
fi

echo "=== pf startup benchmarks ==="
echo "binary: $PF_BIN"
echo "runs:   $RUNS (warmup: $WARMUP)"
echo ""

# Baseline: process launch floor on this host. This is reported for context;
# the budget checker still enforces each pf command's raw wall-clock mean.
echo "--- process baseline ---"
HOME="$GENERAL_FIXTURE_HOME" hyperfine \
  "${SHELL_OPTS[@]}" \
  --runs "$RUNS" \
  --warmup "$WARMUP" \
  --export-json "${RESULTS_DIR}/baseline.json" \
  --command-name "process baseline" \
  "$TRUE_BIN"

echo ""

# Benchmark 0: pf startup (CLI dispatch, no TTY needed)
echo "--- pf (startup) ---"
HOME="$GENERAL_FIXTURE_HOME" PF_BENCH=1 hyperfine \
  "${SHELL_OPTS[@]}" \
  --runs "$RUNS" \
  --warmup "$WARMUP" \
  --export-json "${RESULTS_DIR}/startup.json" \
  --command-name "pf (startup)" \
  "$PF_BIN"

echo ""

# Benchmark 1: pf help (minimal startup path)
echo "--- pf help ---"
HOME="$GENERAL_FIXTURE_HOME" hyperfine \
  "${SHELL_OPTS[@]}" \
  --runs "$RUNS" \
  --warmup "$WARMUP" \
  --export-json "${RESULTS_DIR}/help.json" \
  --command-name "pf help" \
  "$PF_BIN help"

echo ""

# Benchmark 2: pf status --json (config load + JSON serialize)
echo "--- pf status --json ---"
HOME="$GENERAL_FIXTURE_HOME" hyperfine \
  "${SHELL_OPTS[@]}" \
  --runs "$RUNS" \
  --warmup "$WARMUP" \
  --export-json "${RESULTS_DIR}/status.json" \
  --command-name "pf status --json" \
  "$PF_BIN status --json"

echo ""

# Benchmark 3: pf doctor --json (system checks)
echo "--- pf doctor --json ---"
HOME="$GENERAL_FIXTURE_HOME" hyperfine \
  "${SHELL_OPTS[@]}" \
  --runs "$RUNS" \
  --warmup "$WARMUP" \
  --export-json "${RESULTS_DIR}/doctor.json" \
  --command-name "pf doctor --json" \
  "$PF_BIN doctor --json"

echo ""

# Benchmark 4: pf sessions --json (file I/O path)
echo "--- pf sessions --json ---"
HOME="$SESSION_FIXTURE_HOME" hyperfine \
  "${SHELL_OPTS[@]}" \
  --runs "$RUNS" \
  --warmup "$WARMUP" \
  --export-json "${RESULTS_DIR}/sessions.json" \
  --command-name "pf sessions --json" \
  "$PF_BIN sessions --json"

echo ""

# Combine results into a single summary for CI
echo "--- summary ---"
python3 "${REPO_ROOT}/benchmarks/summarize.py"
python3 "${REPO_ROOT}/benchmarks/check_budgets.py"
