#!/bin/bash
# =============================================================================
# run.sh — Run a single test by number or name
#   ./test/run.sh 03              # runs test/03_multiple_keys.sh
#   ./test/run.sh replica_kill    # runs test/10_replica_kill.sh
#   ./test/run.sh --list          # list available tests
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

SCRIPT_DIR="$(pwd)"

list_tests() {
  for f in [0-9][0-9]_*.sh; do
    local num="${f:0:2}"
    local name="${f#??_}"
    name="${name%.sh}"
    local desc
    desc=$(head -4 "$f" | grep "TEST" | head -1 | sed 's/.*TEST [0-9]*: //' || echo "")
    printf "  %s  %-24s %s\n" "$num" "$name" "$desc"
  done
}

if [ $# -eq 0 ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
  echo "Usage: ./test/run.sh <number|name> [--skip-destructive]"
  echo ""
  echo "Available tests:"
  list_tests
  echo ""
  echo "Examples:"
  echo "  ./test/run.sh 03"
  echo "  ./test/run.sh basic_count"
  echo "  ./test/run.sh 10 --skip-destructive"
  exit 1
fi

if [ "$1" = "--list" ]; then
  list_tests
  exit 0
fi

TARGET="$1"
shift || true

# Try exact filename match first
if [ -f "${TARGET}" ]; then
  exec bash "${TARGET}" "$@"
fi

# Try by number: "03" → "03_multiple_keys.sh"
MATCH=$(ls [0-9][0-9]_*.sh 2>/dev/null | grep "^${TARGET}_" | head -1)
if [ -n "$MATCH" ]; then
  exec bash "${SCRIPT_DIR}/${MATCH}" "$@"
fi

# Try by name substring
MATCH=$(ls [0-9][0-9]_*.sh 2>/dev/null | grep "${TARGET}" | head -1)
if [ -n "$MATCH" ]; then
  exec bash "${SCRIPT_DIR}/${MATCH}" "$@"
fi

echo "No test found matching: ${TARGET}"
echo "Run './test/run.sh --list' to see available tests."
exit 1
