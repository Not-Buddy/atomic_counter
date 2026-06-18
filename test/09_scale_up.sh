#!/bin/bash
# =============================================================================
# TEST 09: Scale Up Mid-Flood  [DESTRUCTIVE]
# Starts a flood, scales gateway 3→5 mid-flight, asserts final count.
# Scales back to 3 after the test so other tests are unaffected.
# =============================================================================
source "$(dirname "$0")/helpers.sh"

run() {
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

  log "Waiting ${FLUSH_WAIT}s for self-flush..."
  sleep "$FLUSH_WAIT"

  local actual
  actual=$(get_count "$key")

  log "Scaling gateway back to 3 replicas..."
  docker service scale "${GATEWAY_SERVICE}=3" --detach=true 2>/dev/null || true

  assert_eq "count after scale-up" "$actual" "$total"
}

run "$@"
