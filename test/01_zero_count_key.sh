#!/bin/bash
# =============================================================================
# TEST 01: Zero Count Key
# GET /count on a key that has never been incremented → should return 0.
# =============================================================================
source "$(dirname "$0")/helpers.sh"

run() {
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

run "$@"
