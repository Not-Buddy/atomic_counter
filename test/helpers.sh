#!/bin/bash
# =============================================================================
# helpers.sh — shared functions and config for all test scripts.
# Source this file at the top of each test:  source "$(dirname "$0")/helpers.sh"
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via environment before sourcing)
# ---------------------------------------------------------------------------
HOST="${HOST:-127.0.0.1:8080}"
FLUSH_WAIT="${FLUSH_WAIT:-20}"
CONCURRENCY="${CONCURRENCY:-50}"
STACK_NAME="${STACK_NAME:-counter-stack}"
GATEWAY_SERVICE="${STACK_NAME}_gateway"

BASE_URL="http://${HOST}"
export BASE_URL

# Unique key prefix per test run
RUN_ID="$(date +%s)"

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${RESET} $*"; }
success() { echo -e "${GREEN}✓${RESET} $*"; }
failure() { echo -e "${RED}✗${RESET} $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET} $*"; }
header()  { echo -e "\n${BOLD}━━━ $* ━━━${RESET}"; }

# ---------------------------------------------------------------------------
# Key generation
# ---------------------------------------------------------------------------
make_key() { echo "test_${RUN_ID}_$1"; }

# ---------------------------------------------------------------------------
# Asserts
# ---------------------------------------------------------------------------
assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" -eq "$expected" ]; then
    success "${label}: got ${actual} (expected ${expected})"
    return 0
  else
    failure "${label}: got ${actual} (expected ${expected})"
    return 1
  fi
}

assert_gte() {
  local label="$1" actual="$2" threshold="$3"
  if [ "$actual" -ge "$threshold" ]; then
    success "${label}: got ${actual} (>= ${threshold})"
    return 0
  else
    failure "${label}: got ${actual} (expected >= ${threshold})"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# API helpers
# ---------------------------------------------------------------------------
get_count() {
  local key="$1"
  curl -sf "${BASE_URL}/count/${key}" | jq -r '.count // 0'
}

increment() {
  curl -sf -X POST "${BASE_URL}/increment/$1" -o /dev/null
}
export -f increment

# ---------------------------------------------------------------------------
# Flood: send N parallel increment requests through the nginx VIP
# ---------------------------------------------------------------------------
flood() {
  local key="$1" total="$2" concurrency="${3:-$CONCURRENCY}"
  log "Flooding ${key} with ${total} increments (concurrency=${concurrency})..."
  local t_start t_end elapsed
  t_start=$(date +%s%N)
  seq 1 "$total" \
    | timeout 120 xargs -P "$concurrency" -I{} bash -c "increment '$key'" 2>/dev/null
  t_end=$(date +%s%N)
  elapsed=$(( (t_end - t_start) / 1000000 ))
  log "Flood done in ${elapsed}ms ($(( total * 1000 / (elapsed + 1) )) req/s)"
}

# ---------------------------------------------------------------------------
# VIP-bypass helpers (for tests that need even distribution across replicas)
# ---------------------------------------------------------------------------
resolve_gateway_ips() {
  local gw
  gw=$(docker ps --filter "name=${GATEWAY_SERVICE}" --format "{{.ID}}" | head -1)
  if [ -z "$gw" ]; then
    echo ""
    return
  fi
  docker exec "$gw" getent hosts "tasks.${GATEWAY_SERVICE}" 2>/dev/null | awk '{print $1}'
}

# flood_direct — sends increments directly to individual gateway replicas
# using round-robin distribution (IP = ips[n % num_ips]).  This bypasses
# the Docker Swarm VIP source-IP hash so data is spread evenly across
# replicas regardless of scale.
#
# Because overlay IPs are not routable from the host, curl requests are
# executed inside the first available gateway container via docker exec.
flood_direct() {
  local key="$1" total="$2" concurrency="${3:-$CONCURRENCY}"
  local ips_file num_ips gw

  # Use the nginx container to execute curls from (it lives on the overlay
  # network and is never killed by tests, unlike gateway containers).
  local exec_via
  exec_via=$(docker ps --filter "name=${STACK_NAME}_nginx" --format "{{.ID}}" | head -1)
  if [ -z "$exec_via" ]; then
    warn "No proxy container available — falling back to VIP flood"
    flood "$key" "$total" "$concurrency"
    return
  fi

  ips_file=$(mktemp)
  resolve_gateway_ips > "$ips_file"
  num_ips=$(wc -l < "$ips_file" | tr -d ' ')

  if [ "$num_ips" -eq 0 ]; then
    warn "No gateway IPs resolved — falling back to VIP flood"
    flood "$key" "$total" "$concurrency"
    rm -f "$ips_file"
    return
  fi

  log "Flooding ${key} with ${total} increments (direct to ${num_ips} replicas, concurrency=${concurrency})..."
  local t_start t_end elapsed
  t_start=$(date +%s%N)

  seq 1 "$total" \
    | xargs -P "$concurrency" -I{} bash -c "
        line=\$(( {} % ${num_ips} + 1 ))
        ip=\$(sed -n \"\${line}p\" '${ips_file}')
        docker exec '${exec_via}' wget -q -O - --timeout=3 --post-data=\"\" \
          \"http://\${ip}:3000/increment/${key}\" >/dev/null 2>&1
      " 2>/dev/null

  t_end=$(date +%s%N)
  elapsed=$(( (t_end - t_start) / 1000000 ))
  log "Flood done in ${elapsed}ms ($(( total * 1000 / (elapsed + 1) )) req/s)"

  rm -f "$ips_file"
}

# ---------------------------------------------------------------------------
# Wait for flush then assert
# ---------------------------------------------------------------------------
wait_and_assert_eq() {
  local key="$1" expected="$2" label="${3:-count}"
  log "Waiting ${FLUSH_WAIT}s for self-flush..."
  sleep "$FLUSH_WAIT"
  local actual
  actual=$(get_count "$key")
  assert_eq "$label" "$actual" "$expected"
}
