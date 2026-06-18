#!/bin/bash
# =============================================================================
# TEST 07: Idempotent Reads
# Seed a key, wait for flush, then read it 20 times rapidly.
# All 20 reads must return the same value.
# =============================================================================
source "$(dirname "$0")/helpers.sh"

run() {
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

run "$@"
