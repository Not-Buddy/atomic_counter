#!/bin/bash
# =============================================================================
# TEST 06: Self-Flush Timing
# Sends 500 increments, polls /count every second until it reaches 500.
# Asserts flush completes within 2× FLUSH_WAIT seconds.
# =============================================================================
source "$(dirname "$0")/helpers.sh"

run() {
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
    success "Self-flush completed in ${flush_time}s (within ${max_wait}s window)"
    log "Final count: ${actual}"
    return 0
  else
    failure "Self-flush did not complete within ${max_wait}s (last count: ${actual}/${total})"
    return 1
  fi
}

run "$@"
