#!/bin/bash
# =============================================================================
# TEST 08: High Cardinality Keys
# 50 different keys × 20 increments each = 1000 total.
# Floods are batched (10 at a time) to avoid system overload.
# =============================================================================
source "$(dirname "$0")/helpers.sh"

run() {
  local num_keys=50 per_key=20
  local total=$(( num_keys * per_key ))
  local pids=()

  log "Flooding ${num_keys} unique keys × ${per_key} increments = ${total} total (batched 10 at a time)..."

  for i in $(seq 1 "$num_keys"); do
    local key
    key=$(make_key "card_${i}")
    flood "$key" "$per_key" 5 &
    pids+=($!)
    if [ $(( i % 10 )) -eq 0 ]; then
      for pid in "${pids[@]}"; do wait "$pid"; done
      pids=()
    fi
  done
  for pid in "${pids[@]}"; do wait "$pid"; done

  log "Waiting ${FLUSH_WAIT}s for self-flush..."
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

run "$@"
