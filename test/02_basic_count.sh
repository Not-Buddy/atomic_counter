#!/bin/bash
# =============================================================================
# TEST 02: Basic Count Accuracy
# Send exactly 1000 increments, verify the flushed count is exactly 1000.
# =============================================================================
source "$(dirname "$0")/helpers.sh"

run() {
  local key total
  key=$(make_key "basic")
  total=1000

  flood "$key" "$total"
  wait_and_assert_eq "$key" "$total" "basic count"
}

run "$@"
