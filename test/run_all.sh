#!/bin/bash
# =============================================================================
# run_all.sh — Run all tests in order, print pass/fail summary.
#   ./test/run_all.sh                    # all 10 tests
#   ./test/run_all.sh --skip-destructive # tests 01-08 only
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

SCRIPT_DIR="$(pwd)"
SKIP_DESTRUCTIVE=false

for arg in "$@"; do
  case "$arg" in
    --skip-destructive) SKIP_DESTRUCTIVE=true ;;
  esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'
BLUE='\033[0;34m'

# Headers for log output
log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${RESET} $*"; }

PASS=0
FAIL=0
SKIP=0
FAILED_TESTS=()

run_one() {
  local file="$1" destructive="$2"

  if [ "$destructive" = "true" ] && [ "$SKIP_DESTRUCTIVE" = true ]; then
    local name="${file##*/}"
    name="${name%.sh}"
    name="${name#??_}"
    echo -e "\n${BOLD}━━━ ${name} ━━━${RESET}"
    echo -e "${YELLOW}⚠${RESET} SKIP: ${name} — --skip-destructive flag set"
    SKIP=$((SKIP + 1))
    return
  fi

  echo ""
  if bash "$file"; then
    PASS=$((PASS + 1))
    echo -e "${GREEN}✓${RESET} PASS"
  else
    FAIL=$((FAIL + 1))
    local name="${file##*/}"
    name="${name%.sh}"
    name="${name#??_}"
    FAILED_TESTS+=("$name")
    echo -e "${RED}✗${RESET} FAIL"
  fi
}

# Banner
echo -e "${BOLD}"
echo "  ╔══════════════════════════════════════╗"
echo "  ║   Atomic Counter — Test Suite        ║"
echo "  ╚══════════════════════════════════════╝"
echo -e "${RESET}"

log "Running tests..."

# Non-destructive
run_one "${SCRIPT_DIR}/01_zero_count_key.sh"       false
run_one "${SCRIPT_DIR}/02_basic_count.sh"          false
run_one "${SCRIPT_DIR}/03_multiple_keys.sh"        false
run_one "${SCRIPT_DIR}/04_read_path_under_load.sh" false
run_one "${SCRIPT_DIR}/05_health_spread.sh"         false
run_one "${SCRIPT_DIR}/06_aggregator_timing.sh"    false
run_one "${SCRIPT_DIR}/07_idempotent_reads.sh"     false
run_one "${SCRIPT_DIR}/08_high_cardinality.sh"     false

# Destructive
run_one "${SCRIPT_DIR}/09_scale_up.sh"     true
run_one "${SCRIPT_DIR}/10_replica_kill.sh" true

# Summary
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  Test Results${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  ${GREEN}Passed:${RESET}  ${PASS}"
echo -e "  ${RED}Failed:${RESET}  ${FAIL}"
echo -e "  ${YELLOW}Skipped:${RESET} ${SKIP}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

if [ "${#FAILED_TESTS[@]}" -gt 0 ]; then
  echo -e "\n${RED}Failed tests:${RESET}"
  for t in "${FAILED_TESTS[@]}"; do
    echo -e "  ${RED}✗${RESET} ${t}"
  done
  echo ""
fi

if [ "$FAIL" -eq 0 ]; then
  echo -e "\n${GREEN}${BOLD}All tests passed ✓${RESET}\n"
  exit 0
else
  echo -e "\n${RED}${BOLD}${FAIL} test(s) failed ✗${RESET}\n"
  exit 1
fi
