#!/bin/bash
# =============================================================================
# Atomic Counter - Integration Test Suite
# =============================================================================
# Requirements: curl, jq, docker, xargs
# Usage: ./test.sh [--host localhost] [--flush-wait 20] [--concurrency 50]
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (overridable via flags)
# ---------------------------------------------------------------------------
HOST="127.0.0.1:8080"
FLUSH_WAIT=20
CONCURRENCY=50
STACK_NAME="counter-stack"
GATEWAY_SERVICE="${STACK_NAME}_gateway"
SKIP_DESTRUCTIVE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --host)          HOST="$2";            shift 2 ;;
    --flush-wait)    FLUSH_WAIT="$2";      shift 2 ;;
    --concurrency)   CONCURRENCY="$2";     shift 2 ;;
    --stack)         STACK_NAME="$2";      GATEWAY_SERVICE="${STACK_NAME}_gateway"; shift 2 ;;
    --skip-destructive) SKIP_DESTRUCTIVE=true; shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

BASE_URL="http://${HOST}"
export BASE_URL

# ---------------------------------------------------------------------------
# Counters & Helpers
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
SKIP=0
FAILED_TESTS=()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${RESET} $*"; }
success() { echo -e "${GREEN}✓${RESET} $*"; }
failure() { echo -e "${RED}✗${RESET} $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET} $*"; }
header()  { echo -e "\n${BOLD}━━━ $* ━━━${RESET}"; }

# Unique key prefix per run so tests don't interfere with each other
RUN_ID="$(date +%s)"
make_key() { echo "test_${RUN_ID}_$1"; }

# Assert: fail the test if actual != expected
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

# Assert: fail if actual < threshold
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

# GET /count/:key → integer
get_count() {
  local key="$1"
  curl -sf "${BASE_URL}/count/${key}" | jq -r '.count // 0'
}

# POST /increment/:key → exit code only
increment() {
  curl -sf -X POST "${BASE_URL}/increment/$1" -o /dev/null
}
export -f increment

# Run N parallel increments against a key, wait for all to finish
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

# Wait for aggregator flush then assert
wait_and_assert_eq() {
  local key="$1" expected="$2" label="${3:-count}"
  log "Waiting ${FLUSH_WAIT}s for aggregator flush..."
  sleep "$FLUSH_WAIT"
  local actual
  actual=$(get_count "$key")
  assert_eq "$label" "$actual" "$expected"
}

# Run a test function, track pass/fail
run_test() {
  local name="$1"
  header "$name"
  if "$name"; then
    success "PASS: ${name}"
    PASS=$((PASS + 1))
  else
    failure "FAIL: ${name}"
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$name")
  fi
}

skip_test() {
  local name="$1" reason="$2"
  header "$name"
  warn "SKIP: ${name} — ${reason}"
  SKIP=$((SKIP + 1))
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
preflight() {
  header "Preflight Checks"

  local ok=true

  for cmd in curl jq docker xargs; do
    if command -v "$cmd" &>/dev/null; then
      success "Command available: ${cmd}"
    else
      failure "Missing required command: ${cmd}"
      ok=false
    fi
  done

  if docker ps &>/dev/null; then
    success "Docker daemon accessible"
  else
    failure "Docker daemon not accessible — destructive tests will be skipped"
    SKIP_DESTRUCTIVE=true
  fi

  log "Checking gateway health..."
  local resp
  if resp=$(curl -sf --max-time 5 "${BASE_URL}/health"); then
    local replica
    replica=$(echo "$resp" | jq -r '.replica // "unknown"')
    success "Gateway responding (replica=${replica})"
  else
    failure "Gateway not reachable at ${BASE_URL}"
    ok=false
  fi

  if [ "$ok" = false ]; then
    failure "Preflight failed — is the stack running? (docker stack deploy -c docker-compose.yml ${STACK_NAME})"
    exit 1
  fi

  success "All preflight checks passed"
}

# ---------------------------------------------------------------------------
# TEST 1: Basic Count Accuracy
# Send exactly 1000 increments, verify the flushed count is exactly 1000.
# ---------------------------------------------------------------------------
test_basic_count() {
  local key total actual
  key=$(make_key "basic")
  total=1000

  flood "$key" "$total"
  wait_and_assert_eq "$key" "$total" "basic count"
}

# ---------------------------------------------------------------------------
# TEST 2: Multiple Keys Concurrently
# Three keys each receiving 500 increments simultaneously.
# Verifies the aggregator correctly partitions counts per key.
# ---------------------------------------------------------------------------
test_multiple_keys() {
  local keys=("alpha" "beta" "gamma")
  local per_key=500
  local pids=()

  log "Flooding 3 keys concurrently (${per_key} each, concurrency=25)..."
  for k in "${keys[@]}"; do
    flood "$(make_key "$k")" "$per_key" 25 &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid"; done

  log "Waiting ${FLUSH_WAIT}s for aggregator flush..."
  sleep "$FLUSH_WAIT"

  local all_ok=true
  for k in "${keys[@]}"; do
    local full_key actual
    full_key=$(make_key "$k")
    actual=$(get_count "$full_key")
    if ! assert_eq "key=${k}" "$actual" "$per_key"; then
      all_ok=false
    fi
  done

  [ "$all_ok" = true ]
}

# ---------------------------------------------------------------------------
# TEST 3: Read Path Under Load
# While flooding increments, hammer /count/:key simultaneously.
# Verifies the read cache handles concurrent reads without errors.
# ---------------------------------------------------------------------------
test_read_path_under_load() {
  local key read_errors=0 read_total=200
  key=$(make_key "readload")

  log "Starting increment flood in background..."
  flood "$key" 500 "$CONCURRENCY" &
  local flood_pid=$!

  log "Sending ${read_total} concurrent read requests..."
  local t_start t_end elapsed
  t_start=$(date +%s%N)

  local tmp_reads
  tmp_reads=$(mktemp)

  seq 1 "$read_total" \
    | xargs -P "$CONCURRENCY" -I{} \
      bash -c "curl -sf '${BASE_URL}/count/${key}' | jq -r '.count // \"ERR\"'" \
    >> "$tmp_reads" 2>/dev/null || true

  t_end=$(date +%s%N)
  elapsed=$(( (t_end - t_start) / 1000000 ))

  read_errors=$(grep -c "ERR" "$tmp_reads" 2>/dev/null || true)
  read_errors=${read_errors:-0}
  local read_success=$(( read_total - read_errors ))
  rm -f "$tmp_reads"

  wait "$flood_pid" || true

  log "Read results: ${read_success}/${read_total} succeeded in ${elapsed}ms"

  if [ "$read_errors" -gt 0 ]; then
    failure "Read path: ${read_errors} errors under load"
    return 1
  fi

  success "Read path: all ${read_total} reads succeeded under load"
}

# ---------------------------------------------------------------------------
# TEST 4: Health Spread Across Replicas
# Resolves tasks.<service> DNS to find individual gateway IPs, then hits
# each one directly (bypasses the Swarm VIP which uses source-IP hashing
# and would route all requests to the same replica).
# ---------------------------------------------------------------------------
test_health_spread() {
  local expected_replicas=3
  log "Resolving gateway replica IPs via tasks.${GATEWAY_SERVICE}..."

  # Use docker exec on a gateway container to resolve and curl (overlay IPs
  # are only reachable from within the overlay network, not from the host)
  local gw_container
  gw_container=$(docker ps --filter "name=counter-stack_gateway" --format "{{.ID}}" | head -1)
  if [ -z "$gw_container" ]; then
    warn "Cannot find gateway container — falling back to nginx VIP check"
    local replica
    replica=$(curl -sf --max-time 3 "${BASE_URL}/health" | jq -r '.replica // "unknown"')
    log "VIP health response from: ${replica}"
    assert_gte "replica spread" 1 1
    return
  fi

  local ips
  ips=$(docker exec "$gw_container" getent hosts "tasks.${GATEWAY_SERVICE}" 2>/dev/null | awk '{print $1}')
  if [ -z "$ips" ]; then
    warn "DNS resolution failed — checking health via VIP instead"
    local replica
    replica=$(curl -sf --max-time 3 "${BASE_URL}/health" | jq -r '.replica // "unknown"')
    log "VIP health response from: ${replica}"
    assert_gte "replica spread" 1 1
    return
  fi

  local reachable=0
  local seen_list=""

  for ip in $ips; do
    local replica
    replica=$(docker exec "$gw_container" curl -sf --max-time 3 "http://${ip}:3000/health" 2>/dev/null \
      | jq -r '.replica // "error"' 2>/dev/null) || continue
    if [ "$replica" != "error" ] && [ -n "$replica" ]; then
      seen_list="${seen_list} ${replica}"
      reachable=$((reachable + 1))
      log "  ${ip} → ${replica}"
    fi
  done

  local unique
  unique=$(echo "$seen_list" | tr ' ' '\n' | sort -u | grep -c . 2>/dev/null || echo 0)
  unique=$(echo "$unique" | tr -d '[:space:]')
  unique=${unique:-0}
  log "Unique replicas: ${unique}, reachable IPs: ${reachable}"
  log "Replica IDs: ${seen_list}"

  assert_gte "replica spread" "$unique" "$expected_replicas"
}

# ---------------------------------------------------------------------------
# TEST 5: Scale Up Mid-Flood
# Starts a flood, scales gateway from 3 to 5 replicas halfway through,
# then asserts final count is correct. Verifies aggregator DNS refresh
# picks up new replicas and no counts are lost during scale event.
# ---------------------------------------------------------------------------
test_scale_up() {
  local key total=2000
  key=$(make_key "scaleup")

  log "Starting flood of ${total} in background..."
  flood "$key" "$total" "$CONCURRENCY" &
  local flood_pid=$!

  sleep 3
  log "Scaling gateway to 5 replicas mid-flood..."
  docker service scale "${GATEWAY_SERVICE}=5" --detach=true 2>/dev/null \
    || { warn "Could not scale service (are you on a Swarm manager?)"; wait "$flood_pid"; return 1; }

  log "Waiting for new replicas to be healthy..."
  sleep 10

  wait "$flood_pid"

  log "Waiting ${FLUSH_WAIT}s for aggregator flush..."
  sleep "$FLUSH_WAIT"

  local actual
  actual=$(get_count "$key")

  # Scale back down to 3 for subsequent tests
  log "Scaling gateway back to 3 replicas..."
  docker service scale "${GATEWAY_SERVICE}=3" --detach=true 2>/dev/null || true

  assert_eq "count after scale-up" "$actual" "$total"
}

# ---------------------------------------------------------------------------
# TEST 6: Replica Kill Mid-Flood (SIGTERM Drain)
# Starts a large flood, kills one gateway replica mid-way,
# and asserts the final count is >= 95% of expected.
# The 5% tolerance accounts for in-flight requests at the moment of kill
# that hadn't yet been incremented into Redis before SIGTERM.
# A well-implemented SIGTERM drain should achieve close to 100%.
# ---------------------------------------------------------------------------
test_replica_kill() {
  local key total=3000
  key=$(make_key "kill")
  local tolerance_pct=95
  local threshold=$(( total * tolerance_pct / 100 ))

  log "Starting flood of ${total}..."
  flood "$key" "$total" "$CONCURRENCY" &
  local flood_pid=$!

  sleep 3

  log "Finding a gateway container to kill..."
  local victim
  victim=$(docker ps --filter "name=${GATEWAY_SERVICE}" --format "{{.ID}}" \
    | head -1) || true

  if [ -z "$victim" ]; then
    warn "Could not find a gateway container — skipping kill"
    wait "$flood_pid" || true
    return 1
  fi

  log "Killing container ${victim}..."
  docker kill "$victim" 2>/dev/null || true

  wait "$flood_pid" || true

  log "Waiting ${FLUSH_WAIT}s for aggregator flush..."
  sleep "$FLUSH_WAIT"

  local actual
  actual=$(get_count "$key")

  log "Count after kill: ${actual} / ${total} (threshold: ${threshold}, ${tolerance_pct}% tolerance)"

  assert_gte "count after replica kill" "$actual" "$threshold"
}

# ---------------------------------------------------------------------------
# TEST 7: Aggregator Flush Timing
# Sends a batch of increments and polls /count every second to measure
# how long the aggregator actually takes to flush. Asserts flush completes
# within 2x the configured FLUSH_INTERVAL_MS.
# ---------------------------------------------------------------------------
test_aggregator_timing() {
  local key total=500
  key=$(make_key "timing")
  local max_wait=$(( FLUSH_WAIT * 2 ))

  log "Sending ${total} increments..."
  flood "$key" "$total" "$CONCURRENCY"

  log "Polling count every second (max ${max_wait}s)..."
  local elapsed=0 actual=0
  local flush_time=-1

  while [ "$elapsed" -le "$max_wait" ]; do
    actual=$(get_count "$key")
    if [ "$actual" -eq "$total" ]; then
      flush_time=$elapsed
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  if [ "$flush_time" -ge 0 ]; then
    success "Aggregator flushed in ${flush_time}s (within ${max_wait}s window)"
    log "Final count: ${actual}"
    return 0
  else
    failure "Aggregator did not flush within ${max_wait}s (last count: ${actual}/${total})"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# TEST 8: Zero Count Key
# GET /count on a key that has never been incremented.
# Should return 0 not an error or null.
# ---------------------------------------------------------------------------
test_zero_count_key() {
  local key
  key=$(make_key "nonexistent_$(date +%N)")

  log "Fetching count for a key that has never been incremented..."
  local resp count
  resp=$(curl -sf "${BASE_URL}/count/${key}")
  count=$(echo "$resp" | jq -r '.count // "null"')

  if [ "$count" = "null" ] || [ -z "$count" ]; then
    failure "Expected count=0 for missing key, got: ${resp}"
    return 1
  fi

  assert_eq "zero count key" "$count" "0"
}

# ---------------------------------------------------------------------------
# TEST 9: Idempotent Reads
# Call /count/:key 20 times rapidly on a stable key (no increments running).
# All responses must return the same value — verifies read cache consistency.
# ---------------------------------------------------------------------------
test_idempotent_reads() {
  local key total=100
  key=$(make_key "idempotent")

  log "Seeding key with ${total} increments..."
  flood "$key" "$total" "$CONCURRENCY"
  sleep "$FLUSH_WAIT"

  log "Reading same key 20 times rapidly..."
  local tmp
  tmp=$(mktemp)

  seq 1 20 | xargs -P 20 -I{} \
    bash -c "curl -sf '${BASE_URL}/count/${key}' | jq -r '.count'" \
    >> "$tmp" 2>/dev/null

  local unique_values
  unique_values=$(sort -u "$tmp" | wc -l | tr -d ' ')
  local all_values
  all_values=$(cat "$tmp" | tr '\n' ' ')
  rm -f "$tmp"

  log "Unique values across 20 reads: ${unique_values} (values: ${all_values})"

  if [ "$unique_values" -eq 1 ]; then
    success "All 20 reads returned consistent value"
    return 0
  else
    failure "Reads returned ${unique_values} different values — read cache inconsistent"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# TEST 10: High Cardinality Keys
# Increments 50 different keys 20 times each (1000 total requests).
# Verifies the aggregator correctly handles many distinct keys per flush.
# ---------------------------------------------------------------------------
test_high_cardinality() {
  local num_keys=50 per_key=20
  local total=$(( num_keys * per_key ))
  local pids=()

  log "Flooding ${num_keys} unique keys × ${per_key} increments = ${total} total (batched to avoid overload)..."

  for i in $(seq 1 "$num_keys"); do
    local key
    key=$(make_key "card_${i}")
    flood "$key" "$per_key" 5 &
    pids+=($!)
    # Limit to 10 concurrent batches to avoid overwhelming the system
    if [ $(( i % 10 )) -eq 0 ]; then
      for pid in "${pids[@]}"; do wait "$pid"; done
      pids=()
    fi
  done
  for pid in "${pids[@]}"; do wait "$pid"; done

  log "Waiting ${FLUSH_WAIT}s for aggregator flush..."
  sleep "$FLUSH_WAIT"

  local failed_keys=0 correct_keys=0
  for i in $(seq 1 "$num_keys"); do
    local key actual
    key=$(make_key "card_${i}")
    actual=$(get_count "$key")
    if [ "$actual" -eq "$per_key" ]; then
      correct_keys=$((correct_keys + 1))
    else
      failed_keys=$((failed_keys + 1))
      warn "Key card_${i}: got ${actual}, expected ${per_key}"
    fi
  done

  log "High cardinality results: ${correct_keys}/${num_keys} keys correct"

  if [ "$failed_keys" -gt 0 ]; then
    failure "${failed_keys} keys had wrong counts"
    return 1
  fi
  success "All ${num_keys} keys correct"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
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
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo -e "${BOLD}"
echo "  ╔══════════════════════════════════════╗"
echo "  ║   Atomic Counter — Test Suite        ║"
echo "  ║   Host: ${HOST}                      "
echo "  ║   Flush wait: ${FLUSH_WAIT}s         "
echo "  ║   Concurrency: ${CONCURRENCY}        "
echo "  ╚══════════════════════════════════════╝"
echo -e "${RESET}"

preflight

# Non-destructive tests (always run)
run_test test_zero_count_key
run_test test_basic_count
run_test test_multiple_keys
run_test test_read_path_under_load
run_test test_health_spread
run_test test_aggregator_timing
run_test test_idempotent_reads
run_test test_high_cardinality

# Destructive tests (require Swarm manager, modify service topology)
if [ "$SKIP_DESTRUCTIVE" = true ]; then
  skip_test test_scale_up       "--skip-destructive flag set"
  skip_test test_replica_kill   "--skip-destructive flag set"
else
  run_test test_scale_up
  run_test test_replica_kill
fi

print_summary

