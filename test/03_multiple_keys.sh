#!/bin/bash
# =============================================================================
# TEST 03: Multiple Keys Concurrently
# Three keys each receiving 500 increments simultaneously.
# Verifies correct per-key partitioning.
# =============================================================================
source "$(dirname "$0")/helpers.sh"

run() {
  local keys=("alpha" "beta" "gamma")
  local per_key=500
  local pids=()

  log "Flooding 3 keys concurrently (${per_key} each, concurrency=25)..."
  for k in "${keys[@]}"; do
    flood "$(make_key "$k")" "$per_key" 25 &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid"; done

  log "Waiting ${FLUSH_WAIT}s for self-flush..."
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

run "$@"
